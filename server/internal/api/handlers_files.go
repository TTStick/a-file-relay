package api

import (
	"archive/zip"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"fileswitch/internal/store"
)

func (s *Server) resolveParent(a *Auth, parentID, categoryID string) (string, error) {
	switch {
	case parentID != "":
		return parentID, nil
	case categoryID != "":
		return s.db.CategoryFolder(a.User.ID, categoryID, a.User.RootID)
	default:
		return a.User.RootID, nil
	}
}

func (s *Server) handleChildren(w http.ResponseWriter, r *http.Request, a *Auth) error {
	parent := r.URL.Query().Get("parent")
	if parent == "" {
		parent = a.User.RootID
	}
	pn, err := s.db.Node(a.User.ID, parent)
	if err != nil {
		return err
	}
	if !pn.IsDir {
		return errf(http.StatusBadRequest, "not_dir", "不是文件夹")
	}
	children, err := s.db.Children(a.User.ID, parent, r.URL.Query().Get("dirs") == "1")
	if err != nil {
		return err
	}
	path, err := s.db.Path(a.User.ID, parent)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"parent": pn, "path": path, "children": children})
	return nil
}

func (s *Server) handleNode(w http.ResponseWriter, r *http.Request, a *Auth) error {
	n, err := s.db.Node(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	path, err := s.db.Path(a.User.ID, n.ID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"node": n, "path": path})
	return nil
}

func (s *Server) handleCreateFolder(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		ParentID   string `json:"parent_id"`
		CategoryID string `json:"category_id"`
		Name       string `json:"name"`
		Path       string `json:"path"` // alternative to name: create nested folders (mkdir -p)
		Conflict   string `json:"conflict"`
		Timeline   bool   `json:"timeline"`
		MTime      int64  `json:"mtime"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	parent, err := s.resolveParent(a, req.ParentID, req.CategoryID)
	if err != nil {
		return err
	}
	if req.Path != "" {
		n, err := s.db.MkdirAll(a.User.ID, parent, req.Path, store.Meta{DeviceID: a.Device.ID, DeviceName: a.Device.Name})
		if err != nil {
			return err
		}
		s.audit(a, "folder_created", s.where(a, n))
		writeJSON(w, http.StatusCreated, n)
		return nil
	}
	if req.Conflict == "" {
		req.Conflict = store.ConflictFail
	}
	n, err := s.db.CreateDir(a.User.ID, parent, strings.TrimSpace(req.Name), req.Conflict, store.Meta{
		DeviceID: a.Device.ID, DeviceName: a.Device.Name, CategoryID: req.CategoryID, Timeline: req.Timeline, MTime: req.MTime,
	})
	if err != nil {
		return err
	}
	s.audit(a, "folder_created", s.where(a, n))
	s.hub.Publish(a.User.ID, Event{Type: "node.created", Node: &n, ParentID: n.ParentID, DeviceID: a.Device.ID})
	writeJSON(w, http.StatusCreated, n)
	return nil
}

type nodePatch struct {
	Name       *string `json:"name"`
	ParentID   *string `json:"parent_id"`
	CategoryID *string `json:"category_id"`
	Timeline   *bool   `json:"timeline"`
}

func (s *Server) patchNode(a *Auth, id string, p nodePatch) (store.Node, error) {
	before, err := s.db.Node(a.User.ID, id)
	if err != nil {
		return store.Node{}, err
	}
	n := before
	if p.ParentID != nil && *p.ParentID == "" {
		root := a.User.RootID
		p.ParentID = &root
	}
	if p.ParentID != nil && *p.ParentID != n.ParentID {
		if n, err = s.db.Move(a.User.ID, id, *p.ParentID, true); err != nil {
			return n, err
		}
		s.audit(a, "moved", s.where(a, n))
	}
	if p.Name != nil && *p.Name != n.Name {
		old := n.Name
		if n, err = s.db.Rename(a.User.ID, id, strings.TrimSpace(*p.Name)); err != nil {
			return n, err
		}
		s.audit(a, "renamed", old+" → "+n.Name)
	}
	if p.CategoryID != nil && *p.CategoryID != n.CategoryID {
		if n, err = s.db.SetCategory(a.User.ID, id, *p.CategoryID); err != nil {
			return n, err
		}
		s.audit(a, "category_set", n.Name)
	}
	if p.Timeline != nil && *p.Timeline != n.Timeline {
		if err = s.db.SetTimeline(a.User.ID, id, *p.Timeline); err != nil {
			return n, err
		}
		n.Timeline = *p.Timeline
	}
	s.hub.Publish(a.User.ID, Event{Type: "node.updated", Node: &n, ParentID: n.ParentID, OldParentID: before.ParentID, DeviceID: a.Device.ID})
	if p.CategoryID != nil {
		s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	}
	return n, nil
}

func (s *Server) handlePatchNode(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var p nodePatch
	if err := readJSON(r, &p); err != nil {
		return err
	}
	n, err := s.patchNode(a, r.PathValue("id"), p)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, n)
	return nil
}

func (s *Server) trashNode(a *Auth, id string) error {
	n, err := s.db.Trash(a.User.ID, id)
	if err != nil {
		return err
	}
	s.audit(a, "trashed", s.where(a, n))
	s.hub.Publish(a.User.ID, Event{Type: "node.trashed", Node: &n, ParentID: n.ParentID, DeviceID: a.Device.ID})
	return nil
}

func (s *Server) handleTrashNode(w http.ResponseWriter, r *http.Request, a *Auth) error {
	if err := s.trashNode(a, r.PathValue("id")); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleBatch(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Action     string   `json:"action"`
		IDs        []string `json:"ids"`
		ParentID   string   `json:"parent_id"`
		CategoryID string   `json:"category_id"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if len(req.IDs) > 1000 {
		return errf(http.StatusBadRequest, "invalid", "一次最多操作 1000 项")
	}
	type result struct {
		ID    string `json:"id"`
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}
	results := make([]result, 0, len(req.IDs))
	for _, id := range req.IDs {
		var err error
		switch req.Action {
		case "move":
			_, err = s.patchNode(a, id, nodePatch{ParentID: &req.ParentID})
		case "categorize":
			_, err = s.patchNode(a, id, nodePatch{CategoryID: &req.CategoryID})
		case "trash":
			err = s.trashNode(a, id)
		default:
			return errf(http.StatusBadRequest, "invalid", "未知操作 %q", req.Action)
		}
		res := result{ID: id, OK: err == nil}
		if err != nil {
			res.Error = err.Error()
		}
		results = append(results, res)
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
	return nil
}

func contentDisposition(name string) string {
	ascii := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e || r == '"' || r == '\\' {
			return '_'
		}
		return r
	}, name)
	return `attachment; filename="` + ascii + `"; filename*=UTF-8''` + url.PathEscape(name)
}

func (s *Server) handleContent(w http.ResponseWriter, r *http.Request, a *Auth) error {
	n, err := s.db.Node(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	if n.IsDir {
		return errf(http.StatusBadRequest, "is_dir", "文件夹请使用 zip 下载")
	}
	f, err := s.blobs.Open(n.Blob, n.Size, n.Enc)
	if err != nil {
		return err
	}
	defer f.Close()
	h := w.Header()
	if n.Mime != "" {
		h.Set("Content-Type", n.Mime)
	} else {
		h.Set("Content-Type", "application/octet-stream")
	}
	h.Set("Content-Disposition", contentDisposition(n.Name))
	if n.SHA256 != "" {
		h.Set("ETag", `"`+n.SHA256+`"`)
		h.Set("X-Content-SHA256", n.SHA256)
	}
	http.ServeContent(w, r, "", time.UnixMilli(n.MTime), f)
	return nil
}

func (s *Server) handleZip(w http.ResponseWriter, r *http.Request, a *Auth) error {
	entries, err := s.db.Walk(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	h := w.Header()
	h.Set("Content-Type", "application/zip")
	h.Set("Content-Disposition", contentDisposition(entries[0].Name+".zip"))
	zw := zip.NewWriter(w)
	for _, e := range entries {
		fh := &zip.FileHeader{Name: e.RelPath, Method: zip.Store, Modified: time.UnixMilli(e.MTime)}
		if e.IsDir {
			fh.Name += "/"
			if _, err := zw.CreateHeader(fh); err != nil {
				return nil // client went away; headers are already sent
			}
			continue
		}
		fw, err := zw.CreateHeader(fh)
		if err != nil {
			return nil
		}
		f, err := s.blobs.Open(e.Blob, e.Size, e.Enc)
		if err != nil {
			s.log.Error("zip: open blob", "node", e.ID, "err", err)
			return nil
		}
		_, err = io.Copy(fw, f)
		f.Close()
		if err != nil {
			return nil
		}
	}
	zw.Close()
	return nil
}

func (s *Server) handleWalk(w http.ResponseWriter, r *http.Request, a *Auth) error {
	entries, err := s.db.Walk(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
	return nil
}

func pageArgs(r *http.Request) (before int64, limit int, err error) {
	q := r.URL.Query()
	before = time.Now().UnixMilli() + 1
	if v := q.Get("before"); v != "" {
		if before, err = strconv.ParseInt(v, 10, 64); err != nil || before <= 0 {
			return 0, 0, errf(http.StatusBadRequest, "bad_query", "before 参数无效")
		}
	}
	limit = 100
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 500 {
			return 0, 0, errf(http.StatusBadRequest, "bad_query", "limit 必须在 1 到 500 之间")
		}
	}
	return before, limit, nil
}

func (s *Server) handleTimeline(w http.ResponseWriter, r *http.Request, a *Auth) error {
	before, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	cat := r.URL.Query().Get("category")
	if cat != "" && cat != "none" {
		if _, err := s.db.Category(a.User.ID, cat); err != nil {
			return err
		}
	}
	nodes, err := s.db.Timeline(a.User.ID, before, limit, cat)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": nodes, "has_more": len(nodes) == limit})
	return nil
}

func (s *Server) handleTagged(w http.ResponseWriter, r *http.Request, a *Auth) error {
	before, limit, err := pageArgs(r)
	if err != nil {
		return err
	}
	if _, err := s.db.Category(a.User.ID, r.PathValue("category")); err != nil {
		return err
	}
	nodes, err := s.db.Tagged(a.User.ID, r.PathValue("category"), before, limit)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": nodes, "has_more": len(nodes) == limit})
	return nil
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request, a *Auth) error {
	q, err := freeText(r.URL.Query().Get("q"), 100)
	if err != nil {
		return err
	}
	if q == "" {
		writeJSON(w, http.StatusOK, map[string]any{"items": []store.Node{}})
		return nil
	}
	nodes, err := s.db.Search(a.User.ID, q, 300)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": nodes})
	return nil
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request, a *Auth) error {
	st, err := s.db.Stats(a.User.ID)
	if err != nil {
		return err
	}
	free, total := diskSpace(s.cfg.DataDir)
	writeJSON(w, http.StatusOK, map[string]any{"stats": st, "disk_free": free, "disk_total": total})
	return nil
}

// --- trash ---

func (s *Server) handleTrashList(w http.ResponseWriter, r *http.Request, a *Auth) error {
	nodes, err := s.db.ListTrash(a.User.ID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": nodes})
	return nil
}

func (s *Server) handleRestore(w http.ResponseWriter, r *http.Request, a *Auth) error {
	n, err := s.db.Restore(a.User.ID, r.PathValue("id"), a.User.RootID)
	if err != nil {
		return err
	}
	s.audit(a, "restored", s.where(a, n))
	s.hub.Publish(a.User.ID, Event{Type: "node.created", Node: &n, ParentID: n.ParentID, DeviceID: a.Device.ID})
	writeJSON(w, http.StatusOK, n)
	return nil
}

func (s *Server) handlePurge(w http.ResponseWriter, r *http.Request, a *Auth) error {
	blobs, err := s.db.PurgeTrash(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	s.removeBlobs(blobs)
	s.db.Audit(a.User.ID, a.Device.ID, "trash_purged", r.PathValue("id"), s.clientIP(r))
	s.hub.Publish(a.User.ID, Event{Type: "trash.changed", DeviceID: a.Device.ID})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleEmptyTrash(w http.ResponseWriter, r *http.Request, a *Auth) error {
	blobs, err := s.db.EmptyTrash(a.User.ID)
	if err != nil {
		return err
	}
	s.removeBlobs(blobs)
	s.db.Audit(a.User.ID, a.Device.ID, "trash_emptied", strconv.Itoa(len(blobs)), s.clientIP(r))
	s.hub.Publish(a.User.ID, Event{Type: "trash.changed", DeviceID: a.Device.ID})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// --- categories ---

func (s *Server) handleCategories(w http.ResponseWriter, r *http.Request, a *Auth) error {
	cats, err := s.db.Categories(a.User.ID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"categories": cats})
	return nil
}

func (s *Server) handleCreateCategory(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Name  string `json:"name"`
		Color string `json:"color"`
		Icon  string `json:"icon"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	c, err := s.db.CreateCategory(a.User.ID, req.Name, req.Color, req.Icon)
	if err == nil {
		s.audit(a, "category_created", c.Name)
	}
	if errors.Is(err, store.ErrConflict) {
		return errf(http.StatusConflict, "name_conflict", "已有同名分类")
	}
	if err != nil {
		return err
	}
	s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	writeJSON(w, http.StatusCreated, c)
	return nil
}

func (s *Server) handleUpdateCategory(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var p store.CategoryPatch
	if err := readJSON(r, &p); err != nil {
		return err
	}
	c, err := s.db.UpdateCategory(a.User.ID, r.PathValue("id"), p)
	if err == nil {
		s.audit(a, "category_updated", c.Name)
	}
	if errors.Is(err, store.ErrConflict) {
		return errf(http.StatusConflict, "name_conflict", "已有同名分类")
	}
	if err != nil {
		return err
	}
	s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	writeJSON(w, http.StatusOK, c)
	return nil
}

func (s *Server) handleDeleteCategory(w http.ResponseWriter, r *http.Request, a *Auth) error {
	c, err := s.db.Category(a.User.ID, r.PathValue("id"))
	if err != nil {
		return err
	}
	if err := s.db.DeleteCategory(a.User.ID, c.ID); err != nil {
		return err
	}
	s.audit(a, "category_deleted", c.Name)
	s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleReorderCategories(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if err := s.db.ReorderCategories(a.User.ID, req.IDs); err != nil {
		return err
	}
	s.hub.Publish(a.User.ID, Event{Type: "category.changed", DeviceID: a.Device.ID})
	w.WriteHeader(http.StatusNoContent)
	return nil
}
