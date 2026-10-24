// Package api implements the FileSwitch HTTP API (JSON over HTTPS).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"path"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"time"

	"fileswitch/internal/auth"
	"fileswitch/internal/blob"
	"fileswitch/internal/config"
	"fileswitch/internal/store"
)

const Version = "1.1.2"

type Server struct {
	cfg     *config.Config
	db      *store.DB
	blobs   *blob.Store
	hub     *Hub
	limiter *auth.Limiter
	log     *slog.Logger
	tls     bool

	// dummyHash is verified against when the username doesn't exist, so a
	// failed login takes the same time either way.
	dummyHash string

	busyMu sync.Mutex
	busy   map[string]bool // upload ids with a request in flight

	seenMu sync.Mutex
	seen   map[string]time.Time // device id -> last time we wrote last_seen_at

	relay     *relayAgent
	relayKick chan struct{}

	// bodyIdle: how long a request body may stall before the request fails.
	bodyIdle time.Duration
}

func New(cfg *config.Config, db *store.DB, blobs *blob.Store, log *slog.Logger, tlsOn bool) *Server {
	dh, _ := auth.HashPassword(auth.RandomPassword())
	s := &Server{
		cfg: cfg, db: db, blobs: blobs, log: log, tls: tlsOn,
		hub: NewHub(), limiter: auth.NewLimiter(), dummyHash: dh,
		busy: map[string]bool{}, seen: map[string]time.Time{},
		relayKick: make(chan struct{}, 1),
		bodyIdle:  time.Minute,
	}
	// Local changes are pushed to the relay promptly (still NAS-initiated).
	s.hub.onPublish = s.kickRelay
	return s
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	a := s.authed

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /api/v1/info", s.public(s.handleInfo))
	mux.HandleFunc("POST /api/v1/auth/login", s.public(s.handleLogin))

	mux.Handle("POST /api/v1/auth/logout", a(s.handleLogout))
	mux.Handle("GET /api/v1/auth/me", a(s.handleMe))
	mux.Handle("POST /api/v1/auth/password", a(s.handleChangePassword))
	mux.Handle("GET /api/v1/devices", a(s.handleDevices))
	mux.Handle("PATCH /api/v1/devices/{id}", a(s.handleRenameDevice))
	mux.Handle("DELETE /api/v1/devices/{id}", a(s.handleRevokeDevice))
	mux.Handle("GET /api/v1/audit", a(s.handleAudit))
	mux.Handle("GET /api/v1/stats", a(s.handleStats))
	mux.Handle("GET /api/v1/events", a(s.handleEvents))

	mux.Handle("GET /api/v1/categories", a(s.handleCategories))
	mux.Handle("POST /api/v1/categories", a(s.handleCreateCategory))
	mux.Handle("POST /api/v1/categories/reorder", a(s.handleReorderCategories))
	mux.Handle("PATCH /api/v1/categories/{id}", a(s.handleUpdateCategory))
	mux.Handle("DELETE /api/v1/categories/{id}", a(s.handleDeleteCategory))

	mux.Handle("GET /api/v1/nodes", a(s.handleChildren))
	mux.Handle("POST /api/v1/nodes/folder", a(s.handleCreateFolder))
	mux.Handle("POST /api/v1/nodes/batch", a(s.handleBatch))
	mux.Handle("GET /api/v1/nodes/{id}", a(s.handleNode))
	mux.Handle("PATCH /api/v1/nodes/{id}", a(s.handlePatchNode))
	mux.Handle("DELETE /api/v1/nodes/{id}", a(s.handleTrashNode))
	mux.Handle("GET /api/v1/nodes/{id}/content", a(s.handleContent))
	mux.Handle("GET /api/v1/nodes/{id}/zip", a(s.handleZip))
	mux.Handle("GET /api/v1/nodes/{id}/walk", a(s.handleWalk))
	mux.Handle("GET /api/v1/timeline", a(s.handleTimeline))
	mux.Handle("GET /api/v1/tagged/{category}", a(s.handleTagged))
	mux.Handle("GET /api/v1/search", a(s.handleSearch))

	mux.Handle("GET /api/v1/trash", a(s.handleTrashList))
	mux.Handle("POST /api/v1/trash/{id}/restore", a(s.handleRestore))
	mux.Handle("DELETE /api/v1/trash/{id}", a(s.handlePurge))
	mux.Handle("DELETE /api/v1/trash", a(s.handleEmptyTrash))

	mux.Handle("POST /api/v1/uploads", a(s.handleCreateUpload))
	mux.Handle("GET /api/v1/uploads/{id}", a(s.handleUploadStatus))
	mux.Handle("PUT /api/v1/uploads/{id}", a(s.handleUploadChunk))
	mux.Handle("POST /api/v1/uploads/{id}/complete", a(s.handleCompleteUpload))
	mux.Handle("DELETE /api/v1/uploads/{id}", a(s.handleAbortUpload))
	mux.Handle("PUT /api/v1/files", a(s.handleDirectUpload))

	mux.Handle("POST /api/v1/relay/enroll", a(s.handleRelayEnroll))
	mux.Handle("POST /api/v1/relay/pair", a(s.handleRelayPair))

	mux.Handle("GET /api/v1/admin/users", a(s.admin(s.handleListUsers)))
	mux.Handle("POST /api/v1/admin/users", a(s.admin(s.handleCreateUser)))
	mux.Handle("DELETE /api/v1/admin/users/{id}", a(s.admin(s.handleDeleteUser)))
	mux.Handle("POST /api/v1/admin/users/{id}/password", a(s.admin(s.handleResetPassword)))

	return s.middleware(s.gate(mux))
}

// --- plumbing ---

type Auth struct {
	User   store.User
	Device store.Device
	IP     string // "relay" for operations that came through the relay
}

// Endpoints that answer without a device token. Every other request is
// authenticated before it is routed, so an anonymous caller gets the same 401
// whether a path exists or not and can't map the API through 404/405 answers.
var publicRoutes = map[string]bool{"GET /healthz": true, "GET /api/v1/info": true, "POST /api/v1/auth/login": true}

// Query parameters each endpoint understands. Anything else is an error
// rather than being silently ignored.
var queryParams = map[string][]string{
	"GET /api/v1/nodes":             {"parent", "dirs"},
	"GET /api/v1/timeline":          {"before", "limit", "category"},
	"GET /api/v1/tagged/{category}": {"before", "limit"},
	"GET /api/v1/search":            {"q"},
	"GET /api/v1/audit":             {"before", "limit", "action", "q", "all"},
	"PUT /api/v1/uploads/{id}":      {"offset"},
	"PUT /api/v1/files":             {"parent_id", "category_id", "path", "timeline", "conflict", "size", "mtime"},
}

type authKey struct{}

func (s *Server) gate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Bodies must state their length. Refusing chunked HTTP/1.1 bodies also
		// settles requests carrying both Content-Length and Transfer-Encoding,
		// which a proxy in front might frame differently than we do.
		if r.ProtoMajor == 1 && len(r.TransferEncoding) > 0 {
			s.writeErr(w, r, errf(http.StatusLengthRequired, "length_required", "请求必须带 Content-Length"))
			return
		}
		// url.Query() drops every parameter when the query has a bad escape
		// or a bare ';', which would quietly turn e.g. parent_id into "root".
		if _, err := url.ParseQuery(r.URL.RawQuery); err != nil {
			s.writeErr(w, r, errf(http.StatusBadRequest, "bad_query", "查询参数格式错误"))
			return
		}
		method := r.Method
		if method == http.MethodHead {
			method = http.MethodGet
		}
		if !publicRoutes[method+" "+r.URL.Path] {
			au, err := s.authenticate(r)
			if err != nil {
				s.writeErr(w, r, err)
				return
			}
			r = r.WithContext(context.WithValue(r.Context(), authKey{}, au))
		}
		next.ServeHTTP(w, r)
	})
}

// checkQuery runs after routing, when r.Pattern names the endpoint.
func checkQuery(r *http.Request) error {
	allowed := queryParams[r.Pattern]
	for k := range r.URL.Query() {
		if !slices.Contains(allowed, k) {
			return errf(http.StatusBadRequest, "bad_query", "不支持的参数：%s", k)
		}
	}
	return nil
}

// public wraps an endpoint that needs no token.
func (s *Server) public(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := checkQuery(r); err != nil {
			s.writeErr(w, r, err)
			return
		}
		h(w, r)
	}
}

type handler func(w http.ResponseWriter, r *http.Request, a *Auth) error

type apiError struct {
	status int
	code   string
	msg    string
}

func (e *apiError) Error() string { return e.msg }

func errf(status int, code, format string, args ...any) error {
	return &apiError{status: status, code: code, msg: fmt.Sprintf(format, args...)}
}

var (
	errUnauthorized = errf(http.StatusUnauthorized, "unauthorized", "未登录或登录已失效")
	errForbidden    = errf(http.StatusForbidden, "forbidden", "没有权限")
)

func (s *Server) writeErr(w http.ResponseWriter, r *http.Request, err error) {
	var ae *apiError
	switch {
	case errors.As(err, &ae):
	case errors.Is(err, store.ErrNotFound):
		ae = &apiError{http.StatusNotFound, "not_found", "文件或对象不存在"}
	case errors.Is(err, store.ErrConflict):
		ae = &apiError{http.StatusConflict, "name_conflict", "同名项目已存在"}
	case errors.Is(err, store.ErrInvalid):
		ae = &apiError{http.StatusBadRequest, "invalid", err.Error()}
	default:
		s.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		ae = &apiError{http.StatusInternalServerError, "internal", "服务器内部错误"}
	}
	writeJSON(w, ae.status, map[string]any{"error": map[string]string{"code": ae.code, "message": ae.msg}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// readJSON decodes a request body. Errors name at most the offending field,
// never Go's own type names.
func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	if err := dec.Decode(v); err != nil {
		var te *json.UnmarshalTypeError
		var big *http.MaxBytesError
		switch {
		case errors.As(err, &te) && te.Field != "":
			return errf(http.StatusBadRequest, "bad_json", "字段 %s 的类型不对", te.Field)
		case errors.As(err, &big):
			return errf(http.StatusRequestEntityTooLarge, "too_large", "请求体太大")
		default:
			return errf(http.StatusBadRequest, "bad_json", "请求格式错误")
		}
	}
	return nil
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxy {
		// The proxy appends the address it saw, so the last entry is the one
		// we can trust; anything before it came from the client.
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			return lastHop(xff)
		}
		if xr := r.Header.Get("X-Real-IP"); xr != "" {
			return strings.TrimSpace(xr)
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func lastHop(xff string) string {
	parts := strings.Split(xff, ",")
	return strings.TrimSpace(parts[len(parts)-1])
}

func (s *Server) authenticate(r *http.Request) (*Auth, error) {
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return nil, errUnauthorized
	}
	dev, err := s.db.DeviceByToken(auth.HashToken(tok))
	if err != nil {
		return nil, errUnauthorized
	}
	user, err := s.db.User(dev.UserID)
	if err != nil {
		return nil, errUnauthorized
	}
	ip := s.clientIP(r)
	s.touch(dev.ID, ip)
	return &Auth{User: user, Device: dev, IP: ip}, nil
}

func (s *Server) authed(h handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		au, _ := r.Context().Value(authKey{}).(*Auth)
		if au == nil {
			var err error
			if au, err = s.authenticate(r); err != nil {
				s.writeErr(w, r, err)
				return
			}
		}
		if err := checkQuery(r); err != nil {
			s.writeErr(w, r, err)
			return
		}
		if err := h(w, r, au); err != nil {
			s.writeErr(w, r, err)
		}
	})
}

// audit records something a device did, for the security log.
func (s *Server) audit(a *Auth, action, detail string) {
	s.db.Audit(a.User.ID, a.Device.ID, action, detail, a.IP)
}

// where is a node's full path for the log, e.g. "/工作/报告.pdf".
func (s *Server) where(a *Auth, n store.Node) string {
	ns := []store.Node{n}
	s.db.FillLocations(a.User.ID, ns)
	return path.Join("/", ns[0].Location, n.Name)
}

// idleBody fails a request body that stops arriving, instead of holding the
// connection open forever (e.g. a chunked upload cut off mid-chunk).
type idleBody struct {
	io.ReadCloser
	rc   *http.ResponseController
	idle time.Duration
}

func (b *idleBody) Read(p []byte) (int, error) {
	b.rc.SetReadDeadline(time.Now().Add(b.idle))
	n, err := b.ReadCloser.Read(p)
	// Clear the deadline only once the body is complete. After a failure it
	// has to stay: before replying, net/http tries to drain what's left of
	// the body, and without a deadline that read would wait forever.
	if err == io.EOF {
		b.rc.SetReadDeadline(time.Time{})
	}
	return n, err
}

// touch records device activity, at most once a minute per device.
func (s *Server) touch(deviceID, ip string) {
	s.seenMu.Lock()
	last := s.seen[deviceID]
	now := time.Now()
	if now.Sub(last) < time.Minute {
		s.seenMu.Unlock()
		return
	}
	s.seen[deviceID] = now
	s.seenMu.Unlock()
	s.db.TouchDevice(deviceID, ip)
}

func (s *Server) admin(h handler) handler {
	return func(w http.ResponseWriter, r *http.Request, a *Auth) error {
		if !a.User.IsAdmin {
			return errForbidden
		}
		return h(w, r, a)
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int64
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		if r.Body != nil && r.Body != http.NoBody {
			r.Body = &idleBody{ReadCloser: r.Body, rc: http.NewResponseController(w), idle: s.bodyIdle}
		}
		sw := &statusWriter{ResponseWriter: w}
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		if s.tls {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		defer func() {
			if rec := recover(); rec != nil {
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				s.log.Error("panic", "err", rec, "stack", string(debug.Stack()))
				if sw.status == 0 {
					s.writeErr(sw, r, errors.New("panic"))
				}
			}
			if r.URL.Path != "/healthz" && r.URL.Path != "/api/v1/events" {
				s.log.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status,
					"bytes", sw.bytes, "ms", time.Since(start).Milliseconds(), "ip", s.clientIP(r))
			}
		}()
		next.ServeHTTP(sw, r)
	})
}

func (s *Server) lockUpload(id string) bool {
	s.busyMu.Lock()
	defer s.busyMu.Unlock()
	if s.busy[id] {
		return false
	}
	s.busy[id] = true
	return true
}

func (s *Server) unlockUpload(id string) {
	s.busyMu.Lock()
	delete(s.busy, id)
	s.busyMu.Unlock()
}

func (s *Server) removeBlobs(ids []string) {
	for _, id := range ids {
		if err := s.blobs.Remove(id); err != nil {
			s.log.Warn("remove blob", "blob", id, "err", err)
		}
	}
}

func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	info := map[string]any{
		"name":              s.cfg.ServerName,
		"version":           Version,
		"api":               1,
		"encrypted_at_rest": s.blobs.Encrypted(),
		"chunk_size":        chunkSize,
		"max_file_size":     s.cfg.MaxFileSize,
	}
	if s.cfg.RelayEnabled() {
		info["relay"] = map[string]any{"url": s.cfg.RelayURL}
	}
	writeJSON(w, http.StatusOK, info)
}

// handleRelayEnroll gives the calling (LAN-authenticated) device relay
// credentials so it keeps working away from home.
func (s *Server) handleRelayEnroll(w http.ResponseWriter, r *http.Request, a *Auth) error {
	if !s.cfg.RelayEnabled() {
		return errf(http.StatusNotFound, "relay_off", "未配置中转站")
	}
	b, err := s.enroll(a.User, a.Device.ID, nil)
	if err != nil {
		return err
	}
	s.db.Audit(a.User.ID, a.Device.ID, "relay_enrolled", a.Device.Name, s.clientIP(r))
	s.kickRelay()
	writeJSON(w, http.StatusOK, b)
	return nil
}

// handleRelayPair creates a pairing code from the LAN (always allowed here;
// FS_REMOTE_PAIRING only governs requests arriving through the relay).
func (s *Server) handleRelayPair(w http.ResponseWriter, r *http.Request, a *Auth) error {
	code, exp, err := s.newPairing(a.User.ID, a.Device.ID)
	if err != nil {
		return err
	}
	s.db.Audit(a.User.ID, a.Device.ID, "pairing_created", "lan", s.clientIP(r))
	writeJSON(w, http.StatusOK, map[string]any{"code": code, "expires": exp})
	return nil
}

// RunJanitor periodically purges expired trash, abandoned uploads and login
// throttling state. It returns when ctx is done.
func (s *Server) RunJanitor(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		s.janitor()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) janitor() {
	s.limiter.Sweep()
	now := time.Now()
	if s.cfg.TrashDays > 0 {
		blobs, err := s.db.PurgeExpiredTrash(now.AddDate(0, 0, -s.cfg.TrashDays).UnixMilli())
		if err != nil {
			s.log.Warn("purge trash", "err", err)
		}
		s.removeBlobs(blobs)
		if len(blobs) > 0 {
			s.log.Info("purged expired trash", "files", len(blobs))
		}
	}
	stale, err := s.db.StaleUploads(now.Add(-7 * 24 * time.Hour).UnixMilli())
	if err != nil {
		s.log.Warn("stale uploads", "err", err)
	}
	for _, id := range stale {
		s.db.DeleteUpload(id)
		s.blobs.RemoveTmp(id)
	}
	if keep, err := s.db.AllBlobs(); err == nil {
		s.blobs.SweepTmp(keep, 24*time.Hour)
	}
	s.db.PruneAudit(now.AddDate(0, -6, 0).UnixMilli())
}
