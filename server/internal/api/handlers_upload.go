package api

import (
	"errors"
	"mime"
	"net/http"
	"path"
	"strconv"

	"fileswitch/internal/blob"
	"fileswitch/internal/store"
)

// chunkSize is what clients should send per PUT. It must be a multiple of
// blob.SegSize so chunks line up with encryption segments.
const chunkSize = 8 << 20

type uploadParams struct {
	ParentID   string `json:"parent_id"`
	CategoryID string `json:"category_id"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	MTime      int64  `json:"mtime"`
	Timeline   bool   `json:"timeline"`
	Conflict   string `json:"conflict"`
}

// prepare validates an upload request and resolves the destination folder.
func (s *Server) prepare(a *Auth, p *uploadParams) error {
	if _, err := store.SplitRelPath(p.Path); err != nil {
		return errf(http.StatusBadRequest, "invalid", "无效的文件路径")
	}
	if p.Size < 0 {
		return errf(http.StatusBadRequest, "invalid", "无效的文件大小")
	}
	if s.cfg.MaxFileSize > 0 && p.Size > s.cfg.MaxFileSize {
		return errf(http.StatusRequestEntityTooLarge, "too_large", "文件超过服务器限制")
	}
	if free, _ := diskSpace(s.cfg.DataDir); free > 0 && p.Size > int64(free)-(256<<20) {
		return errf(http.StatusInsufficientStorage, "disk_full", "服务器磁盘空间不足")
	}
	switch p.Conflict {
	case "":
		p.Conflict = store.ConflictRename
	case store.ConflictRename, store.ConflictOverwrite, store.ConflictSkip, store.ConflictFail:
	default:
		return errf(http.StatusBadRequest, "invalid", "无效的冲突策略")
	}
	if p.CategoryID != "" {
		if _, err := s.db.Category(a.User.ID, p.CategoryID); err != nil {
			return errf(http.StatusBadRequest, "invalid", "分类不存在")
		}
	}
	parent, err := s.resolveParent(a, p.ParentID, p.CategoryID)
	if err != nil {
		return err
	}
	pn, err := s.db.Node(a.User.ID, parent)
	if err != nil {
		return err
	}
	if !pn.IsDir {
		return errf(http.StatusBadRequest, "not_dir", "目标不是文件夹")
	}
	p.ParentID = parent
	return nil
}

func (s *Server) handleCreateUpload(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var p uploadParams
	if err := readJSON(r, &p); err != nil {
		return err
	}
	if err := s.prepare(a, &p); err != nil {
		return err
	}
	u := &store.Upload{
		ID: store.NewID(), UserID: a.User.ID, DeviceID: a.Device.ID, ParentID: p.ParentID, RelPath: p.Path,
		Size: p.Size, Enc: s.blobs.Encrypted(), CategoryID: p.CategoryID, Timeline: p.Timeline,
		MTime: p.MTime, Conflict: p.Conflict,
	}
	bw, err := s.blobs.Create(u.ID, u.Size)
	if err != nil {
		return err
	}
	u.Received, u.HashState = bw.Received(), bw.HashState()
	bw.Close()
	if err := s.db.CreateUpload(u); err != nil {
		s.blobs.RemoveTmp(u.ID)
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{"upload": u, "chunk_size": chunkSize})
	return nil
}

func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request, a *Auth) error {
	u, err := s.db.Upload(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"upload": u, "chunk_size": chunkSize})
	return nil
}

func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request, a *Auth) error {
	id := r.PathValue("id")
	if !s.lockUpload(id) {
		return errf(http.StatusConflict, "busy", "该上传正在进行中")
	}
	defer s.unlockUpload(id)
	u, err := s.db.Upload(a.User.ID, id)
	if err != nil {
		return err
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset != u.Received {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    map[string]string{"code": "offset_mismatch", "message": "偏移量不匹配"},
			"received": u.Received,
		})
		return nil
	}
	bw, err := s.blobs.Resume(id, u.Size, u.Received, u.HashState, u.Enc)
	if err != nil {
		return err
	}
	fillErr := bw.Fill(r.Body)
	bw.Close()
	// Whatever arrived intact is durable on disk; record it even if the
	// connection broke so the client can resume from there.
	if err := s.db.SetUploadProgress(id, u.Received, bw.Received(), bw.HashState()); err != nil {
		return err
	}
	if errors.Is(fillErr, blob.ErrTooLarge) {
		return errf(http.StatusBadRequest, "too_large", "数据超出声明的文件大小")
	}
	if fillErr != nil {
		s.log.Info("upload chunk interrupted", "upload", id, "received", bw.Received(), "err", fillErr)
		return nil
	}
	writeJSON(w, http.StatusOK, map[string]any{"received": bw.Received(), "size": u.Size})
	return nil
}

func (s *Server) handleCompleteUpload(w http.ResponseWriter, r *http.Request, a *Auth) error {
	id := r.PathValue("id")
	if !s.lockUpload(id) {
		return errf(http.StatusConflict, "busy", "该上传正在进行中")
	}
	defer s.unlockUpload(id)
	var req struct {
		SHA256 string `json:"sha256"`
	}
	if r.ContentLength != 0 {
		if err := readJSON(r, &req); err != nil {
			return err
		}
	}
	u, err := s.db.Upload(a.User.ID, id)
	if err != nil {
		return err
	}
	if u.Received != u.Size {
		return errf(http.StatusBadRequest, "incomplete", "文件尚未传输完整")
	}
	sum, err := blob.SumFromState(u.HashState)
	if err != nil {
		return err
	}
	if req.SHA256 != "" && req.SHA256 != sum {
		s.db.DeleteUpload(id)
		s.blobs.RemoveTmp(id)
		return errf(http.StatusUnprocessableEntity, "checksum", "文件校验失败，请重新上传")
	}
	p := uploadParams{ParentID: u.ParentID, CategoryID: u.CategoryID, Path: u.RelPath, Size: u.Size,
		MTime: u.MTime, Timeline: u.Timeline, Conflict: u.Conflict}
	n, skipped, err := s.finish(a, id, u.Enc, sum, p)
	if err != nil {
		return err
	}
	s.db.DeleteUpload(id)
	writeJSON(w, http.StatusOK, map[string]any{"node": n, "skipped": skipped})
	return nil
}

// finish moves a complete blob into place and records the file node.
func (s *Server) finish(a *Auth, blobID string, enc bool, sum string, p uploadParams) (store.Node, bool, error) {
	if err := s.blobs.Commit(blobID); err != nil {
		return store.Node{}, false, err
	}
	name := path.Base(p.Path)
	mt := mime.TypeByExtension(path.Ext(name))
	n, replaced, err := s.db.InsertFile(a.User.ID, p.ParentID, p.Path, p.Conflict,
		store.Meta{DeviceID: a.Device.ID, DeviceName: a.Device.Name, CategoryID: p.CategoryID, Timeline: p.Timeline, MTime: p.MTime},
		store.FileInfo{Size: p.Size, Mime: mt, SHA256: sum, Blob: blobID, Enc: enc})
	if errors.Is(err, store.ErrSkipped) {
		s.blobs.Remove(blobID)
		return n, true, nil
	}
	if err != nil {
		s.blobs.Remove(blobID)
		return n, false, err
	}
	if replaced != nil {
		s.hub.Publish(a.User.ID, Event{Type: "node.trashed", Node: replaced, ParentID: replaced.ParentID, DeviceID: a.Device.ID})
	}
	s.hub.Publish(a.User.ID, Event{Type: "node.created", Node: &n, ParentID: n.ParentID, DeviceID: a.Device.ID})
	if p.CategoryID != "" {
		s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	}
	return n, false, nil
}

func (s *Server) handleAbortUpload(w http.ResponseWriter, r *http.Request, a *Auth) error {
	id := r.PathValue("id")
	if !s.lockUpload(id) {
		return errf(http.StatusConflict, "busy", "该上传正在进行中")
	}
	defer s.unlockUpload(id)
	if _, err := s.db.Upload(a.User.ID, id); err != nil {
		return err
	}
	s.db.DeleteUpload(id)
	s.blobs.RemoveTmp(id)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// handleDirectUpload takes a whole file in one request; clients use it for
// small files where a resumable session isn't worth the extra round trips.
func (s *Server) handleDirectUpload(w http.ResponseWriter, r *http.Request, a *Auth) error {
	q := r.URL.Query()
	p := uploadParams{
		ParentID: q.Get("parent_id"), CategoryID: q.Get("category_id"), Path: q.Get("path"),
		Timeline: q.Get("timeline") == "1", Conflict: q.Get("conflict"),
	}
	var err error
	if p.Size, err = strconv.ParseInt(q.Get("size"), 10, 64); err != nil {
		return errf(http.StatusBadRequest, "invalid", "缺少 size 参数")
	}
	if r.ContentLength >= 0 && r.ContentLength != p.Size {
		return errf(http.StatusBadRequest, "invalid", "Content-Length 与 size 不一致")
	}
	p.MTime, _ = strconv.ParseInt(q.Get("mtime"), 10, 64)
	if err := s.prepare(a, &p); err != nil {
		return err
	}
	id := store.NewID()
	bw, err := s.blobs.Create(id, p.Size)
	if err != nil {
		return err
	}
	fillErr := bw.Fill(r.Body)
	bw.Close()
	if fillErr != nil || !bw.Done() {
		s.blobs.RemoveTmp(id)
		if errors.Is(fillErr, blob.ErrTooLarge) {
			return errf(http.StatusBadRequest, "too_large", "数据超出声明的文件大小")
		}
		return errf(http.StatusBadRequest, "incomplete", "传输中断")
	}
	n, skipped, err := s.finish(a, id, s.blobs.Encrypted(), bw.SHA256(), p)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"node": n, "skipped": skipped})
	return nil
}
