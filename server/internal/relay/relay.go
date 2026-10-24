// Package relay is the public-facing half of FileSwitch's relay mode: a blind
// store-and-forward service on an internet server. Clients leave encrypted
// operations and uploads here; the NAS (which never accepts inbound
// connections) collects them on its own schedule and leaves encrypted
// snapshots, replies and file copies for the clients.
//
// The relay can't read or forge any of it (see package e2e). If this server
// is compromised the attacker gets ciphertext, sizes and timing, and can
// delay or drop traffic — nothing on the NAS is reachable from here.
package relay

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"fileswitch/internal/store"
)

type Config struct {
	DataDir    string
	NASToken   string        // FS_RELAY_NAS_TOKEN
	MaxFile    int64         // FS_RELAY_MAX_FILE
	Quota      int64         // FS_RELAY_QUOTA (per space: pending uploads + cache)
	UploadTTL  time.Duration // FS_RELAY_UPLOAD_TTL
	CacheTTL   time.Duration // FS_RELAY_CACHE_TTL
	TrustProxy bool          // FS_TRUST_PROXY
}

func envDur(key string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	if d, err := strconv.Atoi(v); err == nil {
		return time.Duration(d) * time.Hour, nil // bare number = hours
	}
	return time.ParseDuration(v)
}

func envSize(key string, def int64) (int64, error) {
	v := strings.ToUpper(strings.TrimSpace(os.Getenv(key)))
	if v == "" {
		return def, nil
	}
	mult := int64(1)
	for suf, m := range map[string]int64{"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40} {
		if strings.HasSuffix(v, suf) || strings.HasSuffix(v, suf+"B") {
			v = strings.TrimSuffix(strings.TrimSuffix(v, "B"), suf)
			mult = m
			break
		}
	}
	n, err := strconv.ParseInt(v, 10, 64)
	return n * mult, err
}

func LoadConfig(dataDir string, trustProxy bool) (*Config, error) {
	c := &Config{DataDir: dataDir, NASToken: os.Getenv("FS_RELAY_NAS_TOKEN"), TrustProxy: trustProxy}
	if len(c.NASToken) < 32 {
		return nil, errors.New("FS_RELAY_NAS_TOKEN must be set to a random string of at least 32 characters (the NAS uses the same value)")
	}
	var err error
	if c.MaxFile, err = envSize("FS_RELAY_MAX_FILE", 16<<30); err != nil {
		return nil, fmt.Errorf("FS_RELAY_MAX_FILE: %w", err)
	}
	if c.Quota, err = envSize("FS_RELAY_QUOTA", 50<<30); err != nil {
		return nil, fmt.Errorf("FS_RELAY_QUOTA: %w", err)
	}
	if c.UploadTTL, err = envDur("FS_RELAY_UPLOAD_TTL", 7*24*time.Hour); err != nil {
		return nil, fmt.Errorf("FS_RELAY_UPLOAD_TTL: %w", err)
	}
	if c.CacheTTL, err = envDur("FS_RELAY_CACHE_TTL", 14*24*time.Hour); err != nil {
		return nil, fmt.Errorf("FS_RELAY_CACHE_TTL: %w", err)
	}
	return c, nil
}

type Server struct {
	cfg   *Config
	db    *db
	blobs string
	log   *slog.Logger

	mu      sync.Mutex
	quotaMu sync.Mutex                   // check-and-reserve of relay space must not interleave
	subs    map[string]map[*sub]struct{} // space -> SSE subscribers
	nasSeen time.Time
	busy    map[string]bool
	limits  map[string][]time.Time // ip -> recent unauthenticated/failed requests
}

type sub struct {
	device string
	ch     chan []byte
}

func New(cfg *Config, log *slog.Logger) (*Server, error) {
	if err := os.MkdirAll(filepath.Join(cfg.DataDir, "blobs"), 0o700); err != nil {
		return nil, err
	}
	d, err := openDB(filepath.Join(cfg.DataDir, "relay.db"))
	if err != nil {
		return nil, err
	}
	return &Server{cfg: cfg, db: d, blobs: filepath.Join(cfg.DataDir, "blobs"), log: log,
		subs: map[string]map[*sub]struct{}{}, busy: map[string]bool{}, limits: map[string][]time.Time{}}, nil
}

func (s *Server) Close() error { return s.db.Close() }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	c, n := s.client, s.nas
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("GET /r/v1/info", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"relay": 1, "name": "FileSwitch relay"})
	})

	mux.Handle("GET /r/v1/status", c(s.status))
	mux.Handle("GET /r/v1/snapshot", c(s.getSnapshot))
	mux.Handle("GET /r/v1/keyring", c(s.getKeyring))
	mux.Handle("POST /r/v1/ops", c(s.postOp))
	mux.Handle("GET /r/v1/replies", c(s.getReplies))
	mux.Handle("POST /r/v1/blobs", c(s.createBlob))
	mux.Handle("GET /r/v1/blobs/{id}", c(s.blobStatus))
	mux.Handle("PUT /r/v1/blobs/{id}", c(s.putBlob))
	mux.Handle("DELETE /r/v1/blobs/{id}", c(s.deleteOwnBlob))
	mux.Handle("POST /r/v1/cache/lookup", c(s.cacheLookup))
	mux.Handle("GET /r/v1/cache/{key}", c(s.getCache))
	mux.Handle("GET /r/v1/events", c(s.events))
	mux.HandleFunc("POST /r/v1/pair/{lookup}", s.pairRequest)
	mux.HandleFunc("GET /r/v1/pair/{lookup}", s.pairResponse)

	mux.Handle("GET /n/v1/poll", n(s.poll))
	mux.Handle("POST /n/v1/ack", n(s.ack))
	mux.Handle("PUT /n/v1/spaces/{space}/devices", n(s.putDevices))
	mux.Handle("PUT /n/v1/spaces/{space}/snapshot", n(s.putSnapshot))
	mux.Handle("PUT /n/v1/spaces/{space}/keyrings/{device}", n(s.putKeyring))
	mux.Handle("POST /n/v1/spaces/{space}/replies", n(s.postReply))
	mux.Handle("GET /n/v1/spaces/{space}/cache", n(s.listCache))
	mux.Handle("PUT /n/v1/spaces/{space}/cache/{key}", n(s.putCache))
	mux.Handle("DELETE /n/v1/spaces/{space}/cache/{key}", n(s.deleteCache))
	mux.Handle("DELETE /n/v1/spaces/{space}", n(s.deleteSpace))
	mux.Handle("GET /n/v1/blobs/{id}", n(s.nasGetBlob))
	mux.Handle("DELETE /n/v1/blobs/{id}", n(s.nasDeleteBlob))
	mux.Handle("PUT /n/v1/pair/{lookup}", n(s.pairRespond))

	return s.middleware(s.gate(mux))
}

// gate checks credentials before routing, so an anonymous caller gets the
// same 401 for every path and can't map the API through 404/405 answers.
func (s *Server) gate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// see the API server: bodies must state their length
		if r.ProtoMajor == 1 && len(r.TransferEncoding) > 0 {
			s.fail(w, r, errf(411, "length required"))
			return
		}
		if _, err := url.ParseQuery(r.URL.RawQuery); err != nil {
			s.fail(w, r, errf(400, "bad query string"))
			return
		}
		p := r.URL.Path
		switch {
		case p == "/healthz" || p == "/r/v1/info" || strings.HasPrefix(p, "/r/v1/pair/"):
		case strings.HasPrefix(p, "/n/v1/"):
			if !s.nasToken(r) {
				s.log.Warn("rejected NAS request with bad token", "ip", s.ip(r))
				s.reject(w, r, 20)
				return
			}
		default:
			if _, ok := s.device(r); !ok {
				s.reject(w, r, 60)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) reject(w http.ResponseWriter, r *http.Request, perTenMinutes int) {
	if !s.throttle(s.ip(r), perTenMinutes, 10*time.Minute) {
		s.fail(w, r, errf(429, "too many requests"))
		return
	}
	s.fail(w, r, errf(401, "unauthorized"))
}

func (s *Server) nasToken(r *http.Request) bool {
	return subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.cfg.NASToken)) == 1
}

func (s *Server) device(r *http.Request) (devCtx, bool) {
	var d devCtx
	tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || tok == "" {
		return d, false
	}
	err := s.db.QueryRow(`SELECT space, device_id FROM devices WHERE token_hash = ?`, tokenHash(tok)).Scan(&d.space, &d.device)
	return d, err == nil
}

// --- plumbing ---

type httpErr struct {
	status int
	msg    string
}

func (e *httpErr) Error() string { return e.msg }

func errf(status int, format string, a ...any) error {
	return &httpErr{status, fmt.Sprintf(format, a...)}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, err error) {
	var he *httpErr
	if errors.As(err, &he) {
		writeJSON(w, he.status, map[string]any{"error": map[string]string{"code": "relay", "message": he.msg}})
		return
	}
	if errors.Is(err, errNotFound) {
		writeJSON(w, 404, map[string]any{"error": map[string]string{"code": "not_found", "message": "not found"}})
		return
	}
	s.log.Error("relay request failed", "path", r.URL.Path, "err", err)
	writeJSON(w, 500, map[string]any{"error": map[string]string{"code": "internal", "message": "internal error"}})
}

func readJSON(r *http.Request, v any, limit int64) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, limit))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return errf(400, "bad request body")
	}
	return nil
}

func (s *Server) ip(r *http.Request) string {
	if s.cfg.TrustProxy {
		// last entry: the one added by our proxy, not by the client
		if x := r.Header.Get("X-Forwarded-For"); x != "" {
			parts := strings.Split(x, ",")
			return strings.TrimSpace(parts[len(parts)-1])
		}
	}
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

// throttle allows max events per window per IP.
func (s *Server) throttle(ip string, max int, window time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := time.Now()
	ev := s.limits[ip]
	i := 0
	for i < len(ev) && t.Sub(ev[i]) > window {
		i++
	}
	ev = ev[i:]
	if len(ev) >= max {
		s.limits[ip] = ev
		return false
	}
	s.limits[ip] = append(ev, t)
	return true
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Referrer-Policy", "no-referrer")
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path != "/healthz" && r.URL.Path != "/r/v1/events" && r.URL.Path != "/n/v1/poll" {
			s.log.Debug("http", "method", r.Method, "path", r.URL.Path, "ms", time.Since(start).Milliseconds())
		}
	})
}

type devCtx struct{ space, device string }

func tokenHash(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}

func (s *Server) client(h func(http.ResponseWriter, *http.Request, devCtx) error) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d, ok := s.device(r)
		if !ok {
			s.reject(w, r, 60)
			return
		}
		if err := h(w, r, d); err != nil {
			s.fail(w, r, err)
		}
	})
}

func (s *Server) nas(h func(http.ResponseWriter, *http.Request) error) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.nasToken(r) {
			s.reject(w, r, 20)
			return
		}
		s.mu.Lock()
		s.nasSeen = time.Now()
		s.mu.Unlock()
		if err := h(w, r); err != nil {
			s.fail(w, r, err)
		}
	})
}

var (
	reID     = regexp.MustCompile(`^[a-z2-7]{26}$`) // store.NewID
	reOpID   = regexp.MustCompile(`^[0-9a-f]{32}$`) // client op ids
	reLookup = regexp.MustCompile(`^[0-9a-f]{32}$`) // pairing lookup
	reKey    = regexp.MustCompile(`^[0-9a-f]{32}$`) // cache keys
	reHash   = regexp.MustCompile(`^[0-9a-f]{64}$`) // token hashes
)

func (s *Server) publish(space, device string, ev map[string]any) {
	b, _ := json.Marshal(ev)
	s.mu.Lock()
	defer s.mu.Unlock()
	for sb := range s.subs[space] {
		if device != "" && sb.device != device {
			continue
		}
		select {
		case sb.ch <- b:
		default:
		}
	}
}

func (s *Server) lock(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.busy[id] {
		return false
	}
	s.busy[id] = true
	return true
}

func (s *Server) unlock(id string) {
	s.mu.Lock()
	delete(s.busy, id)
	s.mu.Unlock()
}

func (s *Server) blobPath(id string) string { return filepath.Join(s.blobs, id) }

// --- client endpoints ---

func (s *Server) status(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var version int64
	s.db.QueryRow(`SELECT version FROM snapshots WHERE space = ?`, d.space).Scan(&version)
	s.mu.Lock()
	seen := s.nasSeen
	s.mu.Unlock()
	var seenMs int64
	if !seen.IsZero() {
		seenMs = seen.UnixMilli()
	}
	writeJSON(w, 200, map[string]any{"space": d.space, "device": d.device, "snapshot_version": version,
		"nas_seen": seenMs, "now": now()})
	return nil
}

func (s *Server) getSnapshot(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var version int64
	var data []byte
	err := s.db.QueryRow(`SELECT version, data FROM snapshots WHERE space = ?`, d.space).Scan(&version, &data)
	if err != nil {
		return errNotFound
	}
	if r.URL.Query().Get("have") == strconv.FormatInt(version, 10) {
		w.WriteHeader(http.StatusNotModified)
		return nil
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Snapshot-Version", strconv.FormatInt(version, 10))
	w.Write(data)
	return nil
}

func (s *Server) getKeyring(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var body string
	if err := s.db.QueryRow(`SELECT body FROM keyrings WHERE space = ? AND device_id = ?`, d.space, d.device).Scan(&body); err != nil {
		return errNotFound
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(body))
	return nil
}

type envelope struct {
	N string `json:"n"`
	C string `json:"c"`
}

func (e envelope) valid(maxLen int) bool {
	return e.N != "" && e.C != "" && len(e.N) < 64 && len(e.C) <= maxLen
}

func (s *Server) postOp(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var req struct {
		ID string `json:"id"`
		envelope
	}
	if err := readJSON(r, &req, 512<<10); err != nil {
		return err
	}
	if !reOpID.MatchString(req.ID) || !req.valid(400<<10) {
		return errf(400, "bad op")
	}
	var pending int
	s.db.QueryRow(`SELECT COUNT(*) FROM ops WHERE space = ?`, d.space).Scan(&pending)
	if pending >= 2000 {
		return errf(429, "too many pending operations; is the NAS online?")
	}
	body, _ := json.Marshal(req.envelope)
	_, err := s.db.Exec(`INSERT INTO ops(space, device_id, op_id, body, created) VALUES(?,?,?,?,?)
		ON CONFLICT(space, device_id, op_id) DO NOTHING`, d.space, d.device, req.ID, string(body), now())
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusAccepted)
	return nil
}

func (s *Server) getReplies(w http.ResponseWriter, r *http.Request, d devCtx) error {
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	rows, err := s.db.Query(`SELECT seq, op_id, body FROM replies WHERE space = ? AND device_id = ? AND seq > ?
		ORDER BY seq LIMIT 500`, d.space, d.device, after)
	if err != nil {
		return err
	}
	defer rows.Close()
	type reply struct {
		Seq  int64           `json:"seq"`
		Op   string          `json:"op"`
		Body json.RawMessage `json:"body"`
	}
	out := []reply{}
	for rows.Next() {
		var rp reply
		var body string
		rows.Scan(&rp.Seq, &rp.Op, &body)
		rp.Body = json.RawMessage(body)
		out = append(out, rp)
	}
	writeJSON(w, 200, map[string]any{"replies": out})
	return nil
}

func (s *Server) createBlob(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var req struct {
		Size int64 `json:"size"`
	}
	if err := readJSON(r, &req, 1024); err != nil {
		return err
	}
	if req.Size <= 0 || req.Size > s.cfg.MaxFile {
		return errf(413, "file too large for this relay")
	}
	id, err := s.reserve(d.space, d.device, "up", "", req.Size)
	if err != nil {
		return err
	}
	writeJSON(w, 201, map[string]any{"id": id, "size": req.Size, "received": 0})
	return nil
}

// reserve checks the space's quota and records an empty blob in one step, so
// parallel uploads can't all pass the check before any of them is counted.
func (s *Server) reserve(space, device, kind, key string, size int64) (string, error) {
	s.quotaMu.Lock()
	defer s.quotaMu.Unlock()
	if s.db.spaceUsage(space)+size > s.cfg.Quota {
		return "", errf(507, "relay quota exceeded; wait for the NAS to collect pending uploads")
	}
	id := store.NewID()
	f, err := os.OpenFile(s.blobPath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	f.Close()
	t := now()
	if _, err := s.db.Exec(`INSERT INTO blobs(`+blobCols+`) VALUES(?,?,?,?,?,?,?,?,?)`,
		id, space, device, kind, key, size, 0, t, t); err != nil {
		os.Remove(s.blobPath(id))
		return "", err
	}
	return id, nil
}

func (s *Server) ownBlob(d devCtx, id string) (blobRow, error) {
	if !reID.MatchString(id) {
		return blobRow{}, errNotFound
	}
	b, err := s.db.blob(id)
	if err != nil || b.Space != d.space || b.Device != d.device || b.Kind != "up" {
		return blobRow{}, errNotFound
	}
	return b, nil
}

func (s *Server) blobStatus(w http.ResponseWriter, r *http.Request, d devCtx) error {
	b, err := s.ownBlob(d, r.PathValue("id"))
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]any{"id": b.ID, "size": b.Size, "received": b.Received})
	return nil
}

// writeAt appends the request body at offset (which must equal what has been
// received so far) and records how much actually arrived.
func (s *Server) writeAt(b blobRow, r *http.Request) (int64, error) {
	if !s.lock(b.ID) {
		return 0, errf(409, "busy")
	}
	defer s.unlock(b.ID)
	off, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || off != b.Received {
		return b.Received, errf(409, "offset mismatch: have %d", b.Received)
	}
	f, err := os.OpenFile(s.blobPath(b.ID), os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return 0, err
	}
	n, copyErr := io.Copy(f, io.LimitReader(r.Body, b.Size-off))
	got := off + n
	if _, err := s.db.Exec(`UPDATE blobs SET received = ?, updated = ? WHERE id = ?`, got, now(), b.ID); err != nil {
		return got, err
	}
	if copyErr != nil {
		return got, nil // client resumes from got
	}
	var extra [1]byte
	if got == b.Size {
		if m, _ := r.Body.Read(extra[:]); m > 0 {
			return got, errf(400, "more data than declared")
		}
	}
	return got, nil
}

func (s *Server) putBlob(w http.ResponseWriter, r *http.Request, d devCtx) error {
	b, err := s.ownBlob(d, r.PathValue("id"))
	if err != nil {
		return err
	}
	got, err := s.writeAt(b, r)
	var he *httpErr
	if errors.As(err, &he) && he.status == 409 {
		writeJSON(w, 409, map[string]any{"error": map[string]string{"code": "offset_mismatch", "message": he.msg}, "received": got})
		return nil
	}
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]any{"received": got, "size": b.Size})
	return nil
}

func (s *Server) deleteOwnBlob(w http.ResponseWriter, r *http.Request, d devCtx) error {
	b, err := s.ownBlob(d, r.PathValue("id"))
	if err != nil {
		return err
	}
	s.removeBlob(b.ID)
	w.WriteHeader(204)
	return nil
}

func (s *Server) removeBlob(id string) {
	s.db.Exec(`DELETE FROM blobs WHERE id = ?`, id)
	os.Remove(s.blobPath(id))
}

func (s *Server) cacheLookup(w http.ResponseWriter, r *http.Request, d devCtx) error {
	var req struct {
		Keys []string `json:"keys"`
	}
	if err := readJSON(r, &req, 256<<10); err != nil {
		return err
	}
	type hit struct {
		Key  string `json:"key"`
		Size int64  `json:"size"`
	}
	out := []hit{}
	for _, k := range req.Keys[:min(len(req.Keys), 2000)] {
		if !reKey.MatchString(k) {
			continue
		}
		if b, err := s.db.cacheBlob(d.space, k); err == nil && b.Received == b.Size {
			out = append(out, hit{k, b.Size})
		}
	}
	writeJSON(w, 200, map[string]any{"present": out})
	return nil
}

func (s *Server) getCache(w http.ResponseWriter, r *http.Request, d devCtx) error {
	key := r.PathValue("key")
	if !reKey.MatchString(key) {
		return errNotFound
	}
	b, err := s.db.cacheBlob(d.space, key)
	if err != nil || b.Received != b.Size {
		return errNotFound
	}
	f, err := os.Open(s.blobPath(b.ID))
	if err != nil {
		return errNotFound
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeContent(w, r, "", time.UnixMilli(b.Updated), f)
	return nil
}

func (s *Server) events(w http.ResponseWriter, r *http.Request, d devCtx) error {
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	sb := &sub{device: d.device, ch: make(chan []byte, 64)}
	s.mu.Lock()
	if s.subs[d.space] == nil {
		s.subs[d.space] = map[*sub]struct{}{}
	}
	s.subs[d.space][sb] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.subs[d.space], sb)
		s.mu.Unlock()
	}()
	fmt.Fprint(w, "data: {\"type\":\"hello\"}\n\n")
	rc.Flush()
	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return nil
		case b := <-sb.ch:
			fmt.Fprintf(w, "data: %s\n\n", b)
		case <-ping.C:
			var n int
			if s.db.QueryRow(`SELECT COUNT(*) FROM devices WHERE space = ? AND device_id = ?`, d.space, d.device).Scan(&n); n == 0 {
				return nil // revoked
			}
			fmt.Fprint(w, ": ping\n\n")
		}
		if err := rc.Flush(); err != nil {
			return nil
		}
	}
}

// Pairing endpoints are unauthenticated (the new device has no token yet) and
// rate limited; their content is sealed with a key derived from the pairing
// code, which the relay never sees.
func (s *Server) pairRequest(w http.ResponseWriter, r *http.Request) {
	lookup := r.PathValue("lookup")
	if !s.throttle(s.ip(r), 30, 10*time.Minute) {
		s.fail(w, r, errf(429, "too many requests"))
		return
	}
	var e envelope
	if !reLookup.MatchString(lookup) || readJSON(r, &e, 16<<10) != nil || !e.valid(8<<10) {
		s.fail(w, r, errf(400, "bad request"))
		return
	}
	body, _ := json.Marshal(e)
	var n int
	s.db.QueryRow(`SELECT COUNT(*) FROM pairs WHERE resp = ''`).Scan(&n)
	if n > 200 {
		s.fail(w, r, errf(429, "too many pending pairings"))
		return
	}
	s.db.Exec(`INSERT INTO pairs(lookup, req, created) VALUES(?,?,?) ON CONFLICT(lookup) DO NOTHING`, lookup, string(body), now())
	w.WriteHeader(202)
}

func (s *Server) pairResponse(w http.ResponseWriter, r *http.Request) {
	lookup := r.PathValue("lookup")
	if !s.throttle(s.ip(r), 120, 10*time.Minute) {
		s.fail(w, r, errf(429, "too many requests"))
		return
	}
	var resp string
	if !reLookup.MatchString(lookup) || s.db.QueryRow(`SELECT resp FROM pairs WHERE lookup = ?`, lookup).Scan(&resp) != nil || resp == "" {
		s.fail(w, r, errNotFound)
		return
	}
	s.db.Exec(`DELETE FROM pairs WHERE lookup = ?`, lookup) // one-shot
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(resp))
}

// --- NAS endpoints ---

func (s *Server) poll(w http.ResponseWriter, r *http.Request) error {
	type op struct {
		Seq    int64           `json:"seq"`
		Space  string          `json:"space"`
		Device string          `json:"device"`
		ID     string          `json:"id"`
		Body   json.RawMessage `json:"body"`
	}
	type pair struct {
		Lookup string          `json:"lookup"`
		Body   json.RawMessage `json:"body"`
	}
	ops := []op{}
	// Oldest first, but at most 50 per space per poll so one busy space
	// can't starve the others.
	rows, err := s.db.Query(`SELECT seq, space, device_id, op_id, body FROM (
			SELECT *, ROW_NUMBER() OVER (PARTITION BY space ORDER BY seq) AS n FROM ops
		) WHERE n <= 50 ORDER BY seq LIMIT 200`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var o op
		var body string
		rows.Scan(&o.Seq, &o.Space, &o.Device, &o.ID, &body)
		o.Body = json.RawMessage(body)
		ops = append(ops, o)
	}
	rows.Close()
	pairs := []pair{}
	rows, err = s.db.Query(`SELECT lookup, req FROM pairs WHERE resp = '' AND req != '' LIMIT 50`)
	if err != nil {
		return err
	}
	for rows.Next() {
		var p pair
		var body string
		rows.Scan(&p.Lookup, &body)
		p.Body = json.RawMessage(body)
		pairs = append(pairs, p)
	}
	rows.Close()
	writeJSON(w, 200, map[string]any{"ops": ops, "pairs": pairs, "now": now()})
	return nil
}

func (s *Server) ack(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Ops   []int64  `json:"ops"`
		Pairs []string `json:"pairs"`
	}
	if err := readJSON(r, &req, 1<<20); err != nil {
		return err
	}
	for _, seq := range req.Ops {
		s.db.Exec(`DELETE FROM ops WHERE seq = ?`, seq)
	}
	for _, l := range req.Pairs {
		// ignored pairing requests (unknown/expired codes) are dropped
		s.db.Exec(`DELETE FROM pairs WHERE lookup = ? AND resp = ''`, l)
	}
	w.WriteHeader(204)
	return nil
}

func spaceOK(r *http.Request) (string, error) {
	sp := r.PathValue("space")
	if !reID.MatchString(sp) {
		return "", errf(400, "bad space")
	}
	return sp, nil
}

func (s *Server) putDevices(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	var req struct {
		Devices []struct {
			ID        string `json:"id"`
			TokenHash string `json:"token_hash"`
		} `json:"devices"`
	}
	if err := readJSON(r, &req, 1<<20); err != nil {
		return err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	tx.Exec(`DELETE FROM devices WHERE space = ?`, space)
	keep := map[string]bool{}
	for _, d := range req.Devices {
		if !reID.MatchString(d.ID) || !reHash.MatchString(d.TokenHash) {
			return errf(400, "bad device")
		}
		keep[d.ID] = true
		if _, err := tx.Exec(`INSERT OR REPLACE INTO devices(token_hash, space, device_id) VALUES(?,?,?)`, d.TokenHash, space, d.ID); err != nil {
			return err
		}
	}
	// drop state belonging to devices that are gone
	rows, _ := tx.Query(`SELECT DISTINCT device_id FROM keyrings WHERE space = ?`, space)
	var gone []string
	for rows != nil && rows.Next() {
		var id string
		rows.Scan(&id)
		if !keep[id] {
			gone = append(gone, id)
		}
	}
	if rows != nil {
		rows.Close()
	}
	for _, id := range gone {
		tx.Exec(`DELETE FROM keyrings WHERE space = ? AND device_id = ?`, space, id)
		tx.Exec(`DELETE FROM replies WHERE space = ? AND device_id = ?`, space, id)
		tx.Exec(`DELETE FROM ops WHERE space = ? AND device_id = ?`, space, id)
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	w.WriteHeader(204)
	return nil
}

func (s *Server) putSnapshot(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	version, err := strconv.ParseInt(r.Header.Get("X-Snapshot-Version"), 10, 64)
	if err != nil || version <= 0 {
		return errf(400, "bad version")
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, 64<<20))
	if err != nil {
		return err
	}
	if _, err := s.db.Exec(`INSERT INTO snapshots(space, version, data, updated) VALUES(?,?,?,?)
		ON CONFLICT(space) DO UPDATE SET version = excluded.version, data = excluded.data, updated = excluded.updated`,
		space, version, data, now()); err != nil {
		return err
	}
	s.publish(space, "", map[string]any{"type": "snapshot", "version": version})
	w.WriteHeader(204)
	return nil
}

func (s *Server) putKeyring(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	dev := r.PathValue("device")
	var e envelope
	if !reID.MatchString(dev) || readJSON(r, &e, 64<<10) != nil || !e.valid(32<<10) {
		return errf(400, "bad keyring")
	}
	body, _ := json.Marshal(e)
	if _, err := s.db.Exec(`INSERT INTO keyrings(space, device_id, body) VALUES(?,?,?)
		ON CONFLICT(space, device_id) DO UPDATE SET body = excluded.body`, space, dev, string(body)); err != nil {
		return err
	}
	s.publish(space, dev, map[string]any{"type": "keyring"})
	w.WriteHeader(204)
	return nil
}

func (s *Server) postReply(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	var req struct {
		Device string `json:"device"`
		Op     string `json:"op"`
		envelope
	}
	if err := readJSON(r, &req, 1<<20); err != nil {
		return err
	}
	if !reID.MatchString(req.Device) || !reOpID.MatchString(req.Op) || !req.valid(800<<10) {
		return errf(400, "bad reply")
	}
	body, _ := json.Marshal(req.envelope)
	res, err := s.db.Exec(`INSERT INTO replies(space, device_id, op_id, body, created) VALUES(?,?,?,?,?)`,
		space, req.Device, req.Op, string(body), now())
	if err != nil {
		return err
	}
	seq, _ := res.LastInsertId()
	s.publish(space, req.Device, map[string]any{"type": "reply", "seq": seq})
	w.WriteHeader(204)
	return nil
}

func (s *Server) listCache(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	rows, err := s.db.Query(`SELECT cache_key, size, received FROM blobs WHERE space = ? AND kind = 'cache'`, space)
	if err != nil {
		return err
	}
	defer rows.Close()
	type entry struct {
		Key      string `json:"key"`
		Size     int64  `json:"size"`
		Complete bool   `json:"complete"`
	}
	out := []entry{}
	for rows.Next() {
		var e entry
		var got int64
		rows.Scan(&e.Key, &e.Size, &got)
		e.Complete = got == e.Size
		out = append(out, e)
	}
	writeJSON(w, 200, map[string]any{"entries": out})
	return nil
}

func (s *Server) putCache(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	key := r.PathValue("key")
	size, err := strconv.ParseInt(r.URL.Query().Get("size"), 10, 64)
	if !reKey.MatchString(key) || err != nil || size <= 0 || size > s.cfg.MaxFile {
		return errf(400, "bad cache upload")
	}
	b, err := s.db.cacheBlob(space, key)
	if errors.Is(err, errNotFound) || (err == nil && b.Size != size) {
		if err == nil {
			s.removeBlob(b.ID)
		}
		id, err := s.reserve(space, "", "cache", key, size)
		if err != nil {
			return err
		}
		b, _ = s.db.blob(id)
	} else if err != nil {
		return err
	}
	got, err := s.writeAt(b, r)
	var he *httpErr
	if errors.As(err, &he) && he.status == 409 {
		writeJSON(w, 409, map[string]any{"error": map[string]string{"code": "offset_mismatch", "message": he.msg}, "received": got})
		return nil
	}
	if err != nil {
		return err
	}
	if got == size {
		s.publish(space, "", map[string]any{"type": "cache", "key": key})
	}
	writeJSON(w, 200, map[string]any{"received": got, "size": size})
	return nil
}

func (s *Server) deleteCache(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	if b, err := s.db.cacheBlob(space, r.PathValue("key")); err == nil {
		s.removeBlob(b.ID)
	}
	w.WriteHeader(204)
	return nil
}

func (s *Server) deleteSpace(w http.ResponseWriter, r *http.Request) error {
	space, err := spaceOK(r)
	if err != nil {
		return err
	}
	rows, _ := s.db.Query(`SELECT id FROM blobs WHERE space = ?`, space)
	var ids []string
	for rows != nil && rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	if rows != nil {
		rows.Close()
	}
	for _, id := range ids {
		s.removeBlob(id)
	}
	for _, t := range []string{"devices", "ops", "replies", "snapshots", "keyrings"} {
		s.db.Exec(`DELETE FROM `+t+` WHERE space = ?`, space)
	}
	w.WriteHeader(204)
	return nil
}

func (s *Server) nasGetBlob(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if !reID.MatchString(id) {
		return errNotFound
	}
	b, err := s.db.blob(id)
	if err != nil || b.Kind != "up" {
		return errNotFound
	}
	if b.Received != b.Size {
		return errf(409, "upload incomplete")
	}
	f, err := os.Open(s.blobPath(id))
	if err != nil {
		return errNotFound
	}
	defer f.Close()
	w.Header().Set("X-Blob-Space", b.Space)
	w.Header().Set("X-Blob-Device", b.Device)
	http.ServeContent(w, r, "", time.UnixMilli(b.Updated), f)
	return nil
}

func (s *Server) nasDeleteBlob(w http.ResponseWriter, r *http.Request) error {
	if id := r.PathValue("id"); reID.MatchString(id) {
		s.removeBlob(id)
	}
	w.WriteHeader(204)
	return nil
}

func (s *Server) pairRespond(w http.ResponseWriter, r *http.Request) error {
	lookup := r.PathValue("lookup")
	var e envelope
	if !reLookup.MatchString(lookup) || readJSON(r, &e, 64<<10) != nil || !e.valid(32<<10) {
		return errf(400, "bad pairing response")
	}
	body, _ := json.Marshal(e)
	res, err := s.db.Exec(`UPDATE pairs SET resp = ? WHERE lookup = ?`, string(body), lookup)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errNotFound
	}
	w.WriteHeader(204)
	return nil
}

// RunJanitor expires abandoned uploads, stale cache copies, old replies and pairings.
func (s *Server) RunJanitor(ctx context.Context) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		n := time.Now()
		var ids []string
		rows, err := s.db.Query(`SELECT id FROM blobs WHERE (kind = 'up' AND updated < ?) OR (kind = 'cache' AND updated < ?)`,
			n.Add(-s.cfg.UploadTTL).UnixMilli(), n.Add(-s.cfg.CacheTTL).UnixMilli())
		if err == nil {
			for rows.Next() {
				var id string
				rows.Scan(&id)
				ids = append(ids, id)
			}
			rows.Close()
		}
		for _, id := range ids {
			s.removeBlob(id)
		}
		s.db.Exec(`DELETE FROM replies WHERE created < ?`, n.Add(-7*24*time.Hour).UnixMilli())
		s.db.Exec(`DELETE FROM ops WHERE created < ?`, n.Add(-14*24*time.Hour).UnixMilli())
		s.db.Exec(`DELETE FROM pairs WHERE created < ?`, n.Add(-time.Hour).UnixMilli())
		s.mu.Lock()
		for ip, ev := range s.limits {
			if len(ev) == 0 || n.Sub(ev[len(ev)-1]) > time.Hour {
				delete(s.limits, ip)
			}
		}
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
