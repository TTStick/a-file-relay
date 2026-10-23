package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"fileswitch/internal/auth"
	"fileswitch/internal/e2e"
	"fileswitch/internal/store"
)

// relayAgent is the NAS half of relay mode. It never listens: every exchange
// is a request the NAS makes to the relay, on its own schedule. Everything the
// relay returns is treated as hostile — envelopes are authenticated before
// anything inside is parsed, sizes and rates are bounded, and the only things
// a valid operation can do are the exchange-space actions listed in apply.
type relayAgent struct {
	s    *Server
	base string
	api  *http.Client // small JSON calls
	bulk *http.Client // blob transfers

	mu        sync.Mutex
	opTimes   map[string][]time.Time // device id -> recent op times
	fastUntil time.Time
	reconcile map[string]time.Time // user id -> last cache reconcile
	lastErr   string
}

var (
	reRelayID = regexp.MustCompile(`^[a-z2-7]{26}$`)
	reOpHex   = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

const (
	pairTTL        = 15 * time.Minute
	opMaxAge       = 3 * 24 * time.Hour
	opsPerMinute   = 120
	maxFilesPerOp  = 20000
	fastPollWindow = 2 * time.Minute
	fastPoll       = 2 * time.Second
	chunk          = 8 << 20
)

func pinnedTLS(fingerprint string) (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if fingerprint == "" {
		return cfg, nil
	}
	want := strings.ToLower(strings.ReplaceAll(fingerprint, ":", ""))
	if len(want) != 64 {
		return nil, errors.New("FS_RELAY_FINGERPRINT must be a SHA-256 fingerprint")
	}
	// The certificate is pinned instead of chain-verified (self-signed relay).
	cfg.InsecureSkipVerify = true
	cfg.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
		if len(raw) == 0 {
			return errors.New("relay presented no certificate")
		}
		sum := sha256.Sum256(raw[0])
		if hex.EncodeToString(sum[:]) != want {
			return errors.New("relay certificate does not match FS_RELAY_FINGERPRINT")
		}
		return nil
	}
	return cfg, nil
}

// StartRelay launches the relay agent (if configured). It returns when ctx ends.
func (s *Server) StartRelay(ctx context.Context) error {
	if !s.cfg.RelayEnabled() {
		return nil
	}
	if !s.blobs.Encrypted() {
		return errors.New("relay mode requires FS_ENCRYPT=true")
	}
	tc, err := pinnedTLS(s.cfg.RelayFingerprint)
	if err != nil {
		return err
	}
	tr := &http.Transport{TLSClientConfig: tc, IdleConnTimeout: time.Minute, ResponseHeaderTimeout: time.Minute,
		Proxy: http.ProxyFromEnvironment, ForceAttemptHTTP2: true}
	a := &relayAgent{
		s: s, base: s.cfg.RelayURL,
		api:     &http.Client{Transport: tr, Timeout: time.Minute},
		bulk:    &http.Client{Transport: tr},
		opTimes: map[string][]time.Time{}, reconcile: map[string]time.Time{},
	}
	s.relay = a
	s.log.Info("中转模式已启用：NAS 只主动连接中转站，不接受任何入站连接", "relay", s.cfg.RelayURL,
		"interval", s.cfg.RelayInterval.String(), "remote_purge", s.cfg.RemotePurge, "remote_pairing", s.cfg.RemotePairing)
	go a.run(ctx)
	return nil
}

// NewPairing creates a pairing code (used by the CLI).
func (s *Server) NewPairing(userID, by string) (string, int64, error) {
	return s.newPairing(userID, by)
}

// kick asks the agent to sync soon (after a local change or enrollment).
func (s *Server) kickRelay() {
	select {
	case s.relayKick <- struct{}{}:
	default:
	}
}

func (a *relayAgent) run(ctx context.Context) {
	for {
		worked, err := a.cycle(ctx)
		a.mu.Lock()
		if err != nil {
			if msg := err.Error(); msg != a.lastErr {
				a.s.log.Warn("relay sync failed", "err", err)
				a.lastErr = msg
			}
		} else if a.lastErr != "" {
			a.s.log.Info("relay sync recovered")
			a.lastErr = ""
		}
		if worked {
			a.fastUntil = time.Now().Add(fastPollWindow)
		}
		wait := a.s.cfg.RelayInterval
		if time.Now().Before(a.fastUntil) && fastPoll < wait {
			wait = fastPoll
		}
		a.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		case <-a.s.relayKick:
		}
	}
}

// --- HTTP helpers ---

func (a *relayAgent) req(ctx context.Context, method, path string, body io.Reader, hdr map[string]string) (*http.Request, error) {
	r, err := http.NewRequestWithContext(ctx, method, a.base+path, body)
	if err != nil {
		return nil, err
	}
	r.Header.Set("Authorization", "Bearer "+a.s.cfg.RelayToken)
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	return r, nil
}

// call does a JSON request; out (if any) is decoded from a body of at most limit bytes.
func (a *relayAgent) call(ctx context.Context, method, path string, in, out any, limit int64) error {
	var body io.Reader
	hdr := map[string]string{}
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
		hdr["Content-Type"] = "application/json"
	}
	r, err := a.req(ctx, method, path, body, hdr)
	if err != nil {
		return err
	}
	resp, err := a.api.Do(r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("relay %s %s: %d %s", method, path, resp.StatusCode, bytes.TrimSpace(msg))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, limit)).Decode(out)
}

func (a *relayAgent) put(ctx context.Context, path string, data []byte, hdr map[string]string) error {
	r, err := a.req(ctx, http.MethodPut, path, bytes.NewReader(data), hdr)
	if err != nil {
		return err
	}
	resp, err := a.api.Do(r)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("relay PUT %s: %d", path, resp.StatusCode)
	}
	return nil
}

// --- the sync cycle ---

type pollOp struct {
	Seq    int64           `json:"seq"`
	Space  string          `json:"space"`
	Device string          `json:"device"`
	ID     string          `json:"id"`
	Body   json.RawMessage `json:"body"`
}

type pollPair struct {
	Lookup string          `json:"lookup"`
	Body   json.RawMessage `json:"body"`
}

func (a *relayAgent) cycle(ctx context.Context) (bool, error) {
	var poll struct {
		Ops   []pollOp   `json:"ops"`
		Pairs []pollPair `json:"pairs"`
	}
	if err := a.call(ctx, http.MethodGet, "/n/v1/poll", nil, &poll, 64<<20); err != nil {
		return false, err
	}
	worked := len(poll.Ops) > 0 || len(poll.Pairs) > 0
	var ack struct {
		Ops   []int64  `json:"ops"`
		Pairs []string `json:"pairs"`
	}
	for _, p := range poll.Pairs {
		if err := a.handlePair(ctx, p); err != nil {
			a.s.log.Warn("relay: pairing request rejected", "err", err)
		}
		ack.Pairs = append(ack.Pairs, p.Lookup)
	}
	for _, o := range poll.Ops {
		a.handleOp(ctx, o)
		ack.Ops = append(ack.Ops, o.Seq)
	}
	if worked {
		if err := a.call(ctx, http.MethodPost, "/n/v1/ack", ack, nil, 0); err != nil {
			return true, err
		}
	}
	spaces, err := a.s.db.RelaySpaces()
	if err != nil {
		return worked, err
	}
	for sp, u := range spaces {
		changed, err := a.syncSpace(ctx, sp, u)
		if err != nil {
			return worked, err
		}
		worked = worked || changed
	}
	if err := a.forgetDeletedSpaces(ctx, spaces); err != nil {
		return worked, err
	}
	a.s.db.PruneSeen(time.Now().Add(-opMaxAge - 24*time.Hour).UnixMilli())
	a.s.db.PrunePairings()
	return worked, nil
}

// --- keys ---

// spaceKeyring loads (creating if needed) all space keys of a user.
func (s *Server) spaceKeyring(userID string) (e2e.Keyring, uint32, error) {
	keys, err := s.db.SpaceKeys(userID)
	if err != nil {
		return nil, 0, err
	}
	if len(keys) == 0 {
		if err := s.rotateSpaceKey(userID); err != nil {
			return nil, 0, err
		}
		if keys, err = s.db.SpaceKeys(userID); err != nil {
			return nil, 0, err
		}
	}
	ring := e2e.Keyring{}
	var cur uint32
	for _, k := range keys {
		p, err := s.blobs.OpenSecret(k.Sealed, fmt.Sprintf("space:%s:%d", userID, k.Kid))
		if err != nil {
			return nil, 0, fmt.Errorf("unseal space key: %w", err)
		}
		ring[k.Kid] = p
		cur = max(cur, k.Kid)
	}
	return ring, cur, nil
}

func (s *Server) rotateSpaceKey(userID string) error {
	keys, err := s.db.SpaceKeys(userID)
	if err != nil {
		return err
	}
	var kid uint32 = 1
	if len(keys) > 0 {
		kid = keys[len(keys)-1].Kid + 1
	}
	sealed, err := s.blobs.SealSecret(e2e.NewKey(), fmt.Sprintf("space:%s:%d", userID, kid))
	if err != nil {
		return err
	}
	return s.db.AddSpaceKey(userID, kid, sealed)
}

func (a *relayAgent) deviceKey(d store.RelayDevice) ([]byte, error) {
	return a.s.blobs.OpenSecret(d.SealedKey, "device:"+d.ID)
}

// --- pairing & enrollment ---

var pairEnc = base32.StdEncoding.WithPadding(base32.NoPadding)

// newPairing creates a single-use code that lets a new device enroll through
// the relay. The code carries the secret; the relay only ever sees values
// derived from it.
func (s *Server) newPairing(userID, by string) (code string, expires int64, err error) {
	if !s.cfg.RelayEnabled() {
		return "", 0, errf(http.StatusNotFound, "relay_off", "未配置中转站")
	}
	secret := make([]byte, 16)
	if _, err := rand.Read(secret); err != nil {
		return "", 0, err
	}
	lookup, key := e2e.Pairing(secret)
	sealed, err := s.blobs.SealSecret(key, "pairing:"+lookup)
	if err != nil {
		return "", 0, err
	}
	expires = time.Now().Add(pairTTL).UnixMilli()
	if err := s.db.CreatePairing(lookup, userID, sealed, expires, by); err != nil {
		return "", 0, err
	}
	q := url.Values{"k": {pairEnc.EncodeToString(secret)}, "r": {s.cfg.RelayURL}}
	if s.cfg.RelayFingerprint != "" {
		q.Set("f", strings.ToUpper(strings.ReplaceAll(s.cfg.RelayFingerprint, ":", "")))
	}
	return "fileswitch://pair?" + q.Encode(), expires, nil
}

type enrollBundle struct {
	Relay      map[string]string `json:"relay"`
	SpaceID    string            `json:"space_id"`
	DeviceID   string            `json:"device_id"`
	DeviceKey  string            `json:"device_key"`
	RelayToken string            `json:"relay_token"`
	Keyring    e2e.KeyringJSON   `json:"keyring"`
	User       store.User        `json:"user"`
	ServerName string            `json:"server_name"`
}

// enroll gives a device its relay credentials (new device key and token).
func (s *Server) enroll(u store.User, deviceID string, create func(sealed []byte, tokenHash string) (string, error)) (enrollBundle, error) {
	dk := e2e.NewKey()
	token, th := auth.NewToken()
	space, err := s.db.EnsureRelaySpace(u.ID)
	if err != nil {
		return enrollBundle{}, err
	}
	ring, cur, err := s.spaceKeyring(u.ID)
	if err != nil {
		return enrollBundle{}, err
	}
	if deviceID == "" {
		// new remote device: the key is sealed under its id, which create assigns
		var sealedErr error
		deviceID, sealedErr = create(nil, th)
		if sealedErr != nil {
			return enrollBundle{}, sealedErr
		}
	}
	sealed, err := s.blobs.SealSecret(dk, "device:"+deviceID)
	if err != nil {
		return enrollBundle{}, err
	}
	if err := s.db.SetDeviceRelay(deviceID, sealed, th); err != nil {
		return enrollBundle{}, err
	}
	relay := map[string]string{"url": s.cfg.RelayURL}
	if s.cfg.RelayFingerprint != "" {
		relay["fingerprint"] = strings.ToUpper(strings.ReplaceAll(s.cfg.RelayFingerprint, ":", ""))
	}
	u.PasswordHash = ""
	return enrollBundle{Relay: relay, SpaceID: space, DeviceID: deviceID, DeviceKey: base64.StdEncoding.EncodeToString(dk),
		RelayToken: token, Keyring: ring.JSON(cur), User: u, ServerName: s.cfg.ServerName}, nil
}

func (a *relayAgent) handlePair(ctx context.Context, p pollPair) error {
	if !reOpHex.MatchString(p.Lookup) {
		return errors.New("bad lookup")
	}
	userID, sealedKey, err := a.s.db.TakePairing(p.Lookup)
	if err != nil {
		return errors.New("unknown or expired pairing code")
	}
	key, err := a.s.blobs.OpenSecret(sealedKey, "pairing:"+p.Lookup)
	if err != nil {
		return err
	}
	var env e2e.Envelope
	if json.Unmarshal(p.Body, &env) != nil {
		return errors.New("bad envelope")
	}
	plain, err := e2e.OpenEnvelope(key, env, e2e.PairReqAAD(p.Lookup))
	if err != nil {
		return err
	}
	var req struct {
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	dec := json.NewDecoder(bytes.NewReader(plain))
	dec.DisallowUnknownFields()
	if dec.Decode(&req) != nil {
		return errors.New("bad pairing request")
	}
	u, err := a.s.db.User(userID)
	if err != nil {
		return err
	}
	name := cleanLabel(req.DeviceName, 64)
	if name == "" {
		name = "新设备"
	}
	bundle, err := a.s.enroll(u, "", func(_ []byte, th string) (string, error) {
		d, err := a.s.db.CreateRemoteDevice(u.ID, name, cleanLabel(req.Platform, 32), []byte{0}, th)
		return d.ID, err
	})
	if err != nil {
		return err
	}
	// Make the new token valid on the relay before the device learns it.
	if _, err := a.syncSpace(ctx, bundle.SpaceID, u); err != nil {
		return err
	}
	b, _ := json.Marshal(bundle)
	resp := e2e.SealEnvelope(key, b, e2e.PairRespAAD(p.Lookup))
	if err := a.call(ctx, http.MethodPut, "/n/v1/pair/"+p.Lookup, resp, nil, 0); err != nil {
		return err
	}
	a.s.db.Audit(u.ID, bundle.DeviceID, "device_paired", name, "relay")
	a.s.log.Info("新设备已通过配对码加入", "user", u.Username, "device", name)
	return nil
}

// --- operations ---

// relayOp is the decrypted body of a client operation. Unknown fields are
// rejected; each type uses only the fields it needs.
type relayOp struct {
	T          string   `json:"t"`
	TS         int64    `json:"ts"`
	ID         string   `json:"id,omitempty"`
	IDs        []string `json:"ids,omitempty"`
	ParentID   *string  `json:"parent_id,omitempty"`
	CategoryID *string  `json:"category_id,omitempty"`
	Name       *string  `json:"name,omitempty"`
	Path       string   `json:"path,omitempty"`
	Action     string   `json:"action,omitempty"`
	Color      *string  `json:"color,omitempty"`
	Icon       *string  `json:"icon,omitempty"`
	FolderID   *string  `json:"folder_id,omitempty"`
	Folder     *struct {
		Name  string `json:"name"`
		MTime int64  `json:"mtime"`
	} `json:"folder,omitempty"`
	Nested bool     `json:"nested,omitempty"` // upload continues a folder created by an earlier op
	Dirs   []string `json:"dirs,omitempty"`
	Files  []struct {
		Rel   string `json:"rel"`
		Blob  string `json:"blob"`
		Nonce string `json:"nonce"`
		Size  int64  `json:"size"`
		MTime int64  `json:"mtime"`
	} `json:"files,omitempty"`
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func (a *relayAgent) allowOp(deviceID string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	t := time.Now()
	ev := a.opTimes[deviceID]
	i := 0
	for i < len(ev) && t.Sub(ev[i]) > time.Minute {
		i++
	}
	ev = ev[i:]
	if len(ev) >= opsPerMinute {
		a.opTimes[deviceID] = ev
		return false
	}
	a.opTimes[deviceID] = append(ev, t)
	return true
}

func (a *relayAgent) handleOp(ctx context.Context, o pollOp) {
	if !reRelayID.MatchString(o.Space) || !reRelayID.MatchString(o.Device) || !reOpHex.MatchString(o.ID) {
		return
	}
	u, err := a.s.db.UserBySpace(o.Space)
	if err != nil {
		return
	}
	rd, err := a.s.db.RelayDevice(o.Device)
	if err != nil || rd.UserID != u.ID {
		return // revoked or unknown device
	}
	dk, err := a.deviceKey(rd)
	if err != nil {
		return
	}
	var env e2e.Envelope
	if json.Unmarshal(o.Body, &env) != nil {
		return
	}
	plain, err := e2e.OpenEnvelope(dk, env, e2e.OpAAD(rd.ID, o.ID))
	if err != nil {
		a.s.log.Warn("relay: dropped an operation that failed authentication (forged or corrupted)", "device", rd.ID)
		return
	}
	// Record before applying: a crash mid-way may lose an op but never replays one.
	if fresh, err := a.s.db.MarkOpSeen(rd.ID, o.ID); err != nil || !fresh {
		return
	}
	var data any
	var opErr error
	var op relayOp
	dec := json.NewDecoder(bytes.NewReader(plain))
	dec.DisallowUnknownFields()
	switch {
	case dec.Decode(&op) != nil:
		opErr = errf(400, "invalid", "无效的操作")
	case time.Since(time.UnixMilli(op.TS)) > opMaxAge || time.Until(time.UnixMilli(op.TS)) > 10*time.Minute:
		opErr = errf(400, "stale", "操作已过期")
	case !a.allowOp(rd.ID):
		opErr = errf(429, "throttled", "操作过于频繁")
	default:
		a.s.touch(rd.ID, "relay")
		data, opErr = a.apply(ctx, &Auth{User: u, Device: rd.Device}, o.Space, op)
	}
	reply := map[string]any{"op": o.ID, "ok": opErr == nil}
	if opErr != nil {
		reply["error"] = userMessage(opErr)
	} else if data != nil {
		reply["data"] = data
	}
	b, _ := json.Marshal(reply)
	e := e2e.SealEnvelope(dk, b, e2e.ReplyAAD(rd.ID, o.ID))
	if err := a.call(ctx, http.MethodPost, "/n/v1/spaces/"+o.Space+"/replies",
		map[string]any{"device": rd.ID, "op": o.ID, "n": e.N, "c": e.C}, nil, 0); err != nil {
		a.s.log.Warn("relay: could not deliver reply", "err", err)
	}
}

func userMessage(err error) string {
	var ae *apiError
	switch {
	case errors.As(err, &ae):
		return ae.msg
	case errors.Is(err, store.ErrNotFound):
		return "文件或对象不存在"
	case errors.Is(err, store.ErrConflict):
		return "同名项目已存在"
	case errors.Is(err, store.ErrInvalid):
		return err.Error()
	}
	return "NAS 处理失败"
}

func (a *relayAgent) apply(ctx context.Context, au *Auth, space string, op relayOp) (any, error) {
	s := a.s
	uid := au.User.ID
	switch op.T {
	case "ping":
		return nil, nil
	case "mkdir":
		parent, err := s.resolveParent(au, str(op.ParentID), str(op.CategoryID))
		if err != nil {
			return nil, err
		}
		var n store.Node
		if op.Path != "" {
			n, err = s.db.MkdirAll(uid, parent, op.Path, store.Meta{DeviceID: au.Device.ID, DeviceName: au.Device.Name})
		} else {
			n, err = s.db.CreateDir(uid, parent, strings.TrimSpace(str(op.Name)), store.ConflictRename,
				store.Meta{DeviceID: au.Device.ID, DeviceName: au.Device.Name})
		}
		if err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "node.created", Node: &n, ParentID: n.ParentID, DeviceID: au.Device.ID})
		return map[string]string{"id": n.ID}, nil
	case "patch":
		_, err := s.patchNode(au, op.ID, nodePatch{Name: op.Name, ParentID: op.ParentID, CategoryID: op.CategoryID})
		return nil, err
	case "batch":
		if len(op.IDs) > 1000 {
			return nil, errf(400, "invalid", "一次最多操作 1000 项")
		}
		failed := map[string]string{}
		for _, id := range op.IDs {
			var err error
			switch op.Action {
			case "move":
				_, err = s.patchNode(au, id, nodePatch{ParentID: op.ParentID})
			case "categorize":
				_, err = s.patchNode(au, id, nodePatch{CategoryID: op.CategoryID})
			case "trash":
				err = s.trashNode(au, id)
			default:
				return nil, errf(400, "invalid", "未知操作")
			}
			if err != nil {
				failed[id] = userMessage(err)
			}
		}
		return map[string]any{"failed": failed}, nil
	case "restore":
		n, err := s.db.Restore(uid, op.ID, au.User.RootID)
		if err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "node.created", Node: &n, ParentID: n.ParentID, DeviceID: au.Device.ID})
		return nil, nil
	case "purge", "empty_trash":
		if !s.cfg.RemotePurge {
			return nil, errf(403, "policy", "NAS 设置不允许远程彻底删除，请在局域网内操作（已删除的文件仍在回收站中）")
		}
		var blobs []string
		var err error
		if op.T == "purge" {
			blobs, err = s.db.PurgeTrash(uid, op.ID)
		} else {
			blobs, err = s.db.EmptyTrash(uid)
		}
		if err != nil {
			return nil, err
		}
		s.removeBlobs(blobs)
		s.db.Audit(uid, au.Device.ID, "trash_purged", "relay", "relay")
		s.hub.Publish(uid, Event{Type: "trash.changed", DeviceID: au.Device.ID})
		return nil, nil
	case "cat_create":
		c, err := s.db.CreateCategory(uid, str(op.Name), str(op.Color), str(op.Icon))
		if err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "category.changed", DeviceID: au.Device.ID})
		return map[string]string{"id": c.ID}, nil
	case "cat_update":
		if _, err := s.db.UpdateCategory(uid, op.ID, store.CategoryPatch{Name: op.Name, Color: op.Color, Icon: op.Icon, FolderID: op.FolderID}); err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "category.changed", DeviceID: au.Device.ID})
		return nil, nil
	case "cat_delete":
		if err := s.db.DeleteCategory(uid, op.ID); err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "category.changed", DeviceID: au.Device.ID})
		return nil, nil
	case "cat_reorder":
		if len(op.IDs) > 1000 {
			return nil, errf(400, "invalid", "分类过多")
		}
		if err := s.db.ReorderCategories(uid, op.IDs); err != nil {
			return nil, err
		}
		s.hub.Publish(uid, Event{Type: "category.changed", DeviceID: au.Device.ID})
		return nil, nil
	case "upload":
		return a.ingest(ctx, au, op)
	case "fetch":
		return a.fetch(au, op.IDs)
	case "device_rename":
		name := cleanLabel(str(op.Name), 64)
		if name == "" {
			return nil, errf(400, "invalid", "名称不能为空")
		}
		return nil, s.db.RenameDevice(uid, op.ID, name)
	case "device_revoke":
		if err := s.db.DeleteDevice(uid, op.ID); err != nil {
			return nil, err
		}
		s.db.Audit(uid, au.Device.ID, "device_revoked", op.ID, "relay")
		s.hub.Publish(uid, Event{Type: "device.revoked", Target: op.ID})
		return nil, nil
	case "pair":
		if !s.cfg.RemotePairing {
			return nil, errf(403, "policy", "NAS 设置不允许远程添加设备；请在局域网内添加，或在 NAS 上执行 fileswitch pair")
		}
		code, exp, err := s.newPairing(uid, au.Device.ID)
		if err != nil {
			return nil, err
		}
		s.db.Audit(uid, au.Device.ID, "pairing_created", "relay", "relay")
		return map[string]any{"code": code, "expires": exp}, nil
	}
	return nil, errf(400, "invalid", "不支持的操作")
}

// ingest pulls client uploads from the relay, verifies and decrypts them, and
// stores them like any other upload (re-encrypted with the NAS master key).
func (a *relayAgent) ingest(ctx context.Context, au *Auth, op relayOp) (any, error) {
	s := a.s
	if len(op.Files) > maxFilesPerOp || len(op.Dirs) > maxFilesPerOp || (len(op.Files) == 0 && op.Folder == nil) {
		return nil, errf(400, "invalid", "无效的上传")
	}
	for _, f := range op.Files {
		if _, err := store.SplitRelPath(f.Rel); err != nil || !reRelayID.MatchString(f.Blob) || f.Size < 0 || f.Size > s.cfg.RemoteMaxFile {
			return nil, errf(400, "invalid", "无效的上传条目")
		}
	}
	parent, err := s.resolveParent(au, str(op.ParentID), str(op.CategoryID))
	if err != nil {
		return nil, err
	}
	base, timeline, cat := parent, true, str(op.CategoryID)
	result := map[string]any{}
	if op.Folder != nil {
		top, err := s.db.CreateDir(au.User.ID, parent, strings.TrimSpace(op.Folder.Name), store.ConflictRename, store.Meta{
			DeviceID: au.Device.ID, DeviceName: au.Device.Name, CategoryID: cat, Timeline: true, MTime: op.Folder.MTime})
		if err != nil {
			return nil, err
		}
		s.hub.Publish(au.User.ID, Event{Type: "node.created", Node: &top, ParentID: top.ParentID, DeviceID: au.Device.ID})
		base, timeline, cat = top.ID, false, ""
		result["folder_id"] = top.ID
	} else if op.Nested {
		timeline, cat = false, ""
	}
	for _, d := range op.Dirs {
		if _, err := s.db.MkdirAll(au.User.ID, base, d, store.Meta{DeviceID: au.Device.ID, DeviceName: au.Device.Name}); err != nil {
			return nil, err
		}
	}
	ring, _, err := s.spaceKeyring(au.User.ID)
	if err != nil {
		return nil, err
	}
	failed := map[string]string{}
	created := 0
	for _, f := range op.Files {
		nonce, err := base64.StdEncoding.DecodeString(f.Nonce)
		if err == nil && len(nonce) == e2e.NonceSize {
			err = a.ingestFile(ctx, au, ring, nonce, base, cat, timeline, f.Rel, f.Blob, f.Size, f.MTime)
		} else {
			err = errors.New("bad nonce")
		}
		if err != nil {
			failed[f.Rel] = userMessage(err)
			a.s.log.Warn("relay: upload rejected", "file", f.Rel, "err", err)
			continue
		}
		created++
	}
	result["created"] = created
	result["failed"] = failed
	return result, nil
}

func (a *relayAgent) ingestFile(ctx context.Context, au *Auth, ring e2e.Keyring, nonce []byte, parent, cat string,
	timeline bool, rel, blobID string, size, mtime int64) error {
	s := a.s
	want := e2e.CipherSize(size)
	r, err := a.req(ctx, http.MethodGet, "/n/v1/blobs/"+blobID, nil, nil)
	if err != nil {
		return err
	}
	resp, err := a.bulk.Do(r)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("relay blob: %d", resp.StatusCode)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != want {
		return errors.New("blob size does not match the operation")
	}
	plain, err := e2e.DecryptBlob(io.LimitReader(resp.Body, want), size, ring, nonce)
	if err != nil {
		return err
	}
	localID := store.NewID()
	w, err := s.blobs.Create(localID, size)
	if err != nil {
		return err
	}
	fillErr := w.Fill(plain)
	w.Close()
	if fillErr != nil || !w.Done() {
		s.blobs.RemoveTmp(localID)
		if fillErr == nil {
			fillErr = errors.New("incomplete")
		}
		return fmt.Errorf("verify upload: %w", fillErr)
	}
	if _, _, err := s.finish(au, localID, s.blobs.Encrypted(), w.SHA256(), uploadParams{
		ParentID: parent, CategoryID: cat, Path: rel, Size: size, MTime: mtime, Timeline: timeline, Conflict: store.ConflictRename,
	}); err != nil {
		return err
	}
	if r, err := a.req(ctx, http.MethodDelete, "/n/v1/blobs/"+blobID, nil, nil); err == nil {
		if resp, err := a.api.Do(r); err == nil {
			resp.Body.Close()
		}
	}
	return nil
}

// fetch pins files so the next reconcile puts encrypted copies on the relay.
func (a *relayAgent) fetch(au *Auth, ids []string) (any, error) {
	if len(ids) > 5000 {
		return nil, errf(400, "invalid", "一次请求的文件过多")
	}
	ring, cur, err := a.s.spaceKeyring(au.User.ID)
	if err != nil {
		return nil, err
	}
	until := time.Now().Add(3 * 24 * time.Hour).UnixMilli()
	n := 0
	for _, id := range ids {
		node, err := a.s.db.Node(au.User.ID, id)
		if err != nil || node.IsDir {
			continue
		}
		if node.Size > a.s.cfg.RemoteMaxFile {
			return nil, errf(413, "too_large", "文件超过 NAS 允许远程获取的大小")
		}
		a.s.db.PutRelayCache(au.User.ID, store.CacheEntry{Key: e2e.CacheKey(ring[cur], node.ID, node.SHA256), NodeID: node.ID,
			Kid: cur, Size: e2e.CipherSize(node.Size), PinnedUntil: until})
		n++
	}
	a.mu.Lock()
	delete(a.reconcile, au.User.ID) // reconcile this space now
	a.mu.Unlock()
	return map[string]int{"queued": n}, nil
}

// --- per-space publishing ---

type relaySnapshot struct {
	V          int              `json:"v"`
	Kid        uint32           `json:"kid"`
	Server     map[string]any   `json:"server"`
	User       store.User       `json:"user"`
	Nodes      []store.Node     `json:"nodes"`
	Trash      []store.Node     `json:"trash"`
	Categories []store.Category `json:"categories"`
	Devices    []store.Device   `json:"devices"`
	Stats      store.Stats      `json:"stats"`
	Policy     map[string]any   `json:"policy"`
}

func hashOf(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// syncSpace brings the relay's view of one user up to date: allowed device
// tokens, keyrings, the encrypted snapshot and the file cache.
func (a *relayAgent) syncSpace(ctx context.Context, space string, u store.User) (bool, error) {
	s := a.s
	devs, err := s.db.RelayDevices(u.ID)
	if err != nil {
		return false, err
	}
	ids := make([]string, 0, len(devs))
	tokens := make([]map[string]string, 0, len(devs))
	for _, d := range devs {
		ids = append(ids, d.ID)
		tokens = append(tokens, map[string]string{"id": d.ID, "token_hash": d.TokenHash})
	}
	sort.Strings(ids)

	// A device that was enrolled before and is gone now has been revoked:
	// rotate the space key so nothing published from now on is readable by it.
	prev, _ := s.db.Meta("relay_devs:" + u.ID)
	if prev != "" {
		cur := map[string]bool{}
		for _, id := range ids {
			cur[id] = true
		}
		for _, id := range strings.Split(prev, ",") {
			if id != "" && !cur[id] {
				if err := s.rotateSpaceKey(u.ID); err != nil {
					return false, err
				}
				s.db.Audit(u.ID, "", "space_key_rotated", id, "relay")
				s.log.Info("设备授权已撤销，已轮换该用户的中转加密密钥", "user", u.Username)
				break
			}
		}
	}
	ring, kid, err := s.spaceKeyring(u.ID)
	if err != nil {
		return false, err
	}
	changed := false

	tokHash := hashOf(fmt.Sprint(tokens))
	if old, _ := s.db.Meta("relay_tok:" + u.ID); old != tokHash {
		if err := a.call(ctx, http.MethodPut, "/n/v1/spaces/"+space+"/devices", map[string]any{"devices": tokens}, nil, 0); err != nil {
			return false, err
		}
		s.db.SetMeta("relay_tok:"+u.ID, tokHash)
		changed = true
	}
	krHash := hashOf(strings.Join(ids, ","), strconv.Itoa(int(kid)), strconv.Itoa(len(ring)), tokHash)
	if old, _ := s.db.Meta("relay_kr:" + u.ID); old != krHash {
		kj, _ := json.Marshal(ring.JSON(kid))
		for _, d := range devs {
			dk, err := a.deviceKey(d)
			if err != nil {
				continue
			}
			e := e2e.SealEnvelope(dk, kj, e2e.KeyringAAD(d.ID))
			if err := a.call(ctx, http.MethodPut, "/n/v1/spaces/"+space+"/keyrings/"+d.ID, e, nil, 0); err != nil {
				return false, err
			}
		}
		s.db.SetMeta("relay_kr:"+u.ID, krHash)
		changed = true
	}
	s.db.SetMeta("relay_devs:"+u.ID, strings.Join(ids, ","))
	if len(devs) == 0 {
		return changed, nil
	}

	snap, err := a.snapshot(u, kid)
	if err != nil {
		return changed, err
	}
	snapHash := hashOf(string(snap), strconv.Itoa(int(kid)))
	snapChanged := false
	if old, _ := s.db.Meta("relay_snap:" + u.ID); old != snapHash {
		vs, _ := s.db.Meta("relay_ver:" + u.ID)
		v, _ := strconv.ParseUint(vs, 10, 64)
		v++
		data := e2e.SealSnapshot(snap, kid, v, space, ring[kid])
		if err := a.put(ctx, "/n/v1/spaces/"+space+"/snapshot", data,
			map[string]string{"X-Snapshot-Version": strconv.FormatUint(v, 10), "Content-Type": "application/octet-stream"}); err != nil {
			return changed, err
		}
		s.db.SetMeta("relay_ver:"+u.ID, strconv.FormatUint(v, 10))
		s.db.SetMeta("relay_snap:"+u.ID, snapHash)
		changed, snapChanged = true, true
	}

	a.mu.Lock()
	last, ok := a.reconcile[u.ID]
	due := !ok || snapChanged || time.Since(last) > 10*time.Minute
	a.mu.Unlock()
	if due {
		uploaded, err := a.reconcileCache(ctx, space, u, ring, kid)
		if err != nil {
			return changed, err
		}
		a.mu.Lock()
		a.reconcile[u.ID] = time.Now()
		a.mu.Unlock()
		changed = changed || uploaded
	}
	return changed, nil
}

func (a *relayAgent) snapshot(u store.User, kid uint32) ([]byte, error) {
	s := a.s
	nodes, err := s.db.AllNodes(u.ID)
	if err != nil {
		return nil, err
	}
	trash, err := s.db.ListTrash(u.ID)
	if err != nil {
		return nil, err
	}
	cats, err := s.db.Categories(u.ID)
	if err != nil {
		return nil, err
	}
	devs, err := s.db.ListDevices(u.ID)
	if err != nil {
		return nil, err
	}
	for i := range devs {
		// coarse activity time keeps the snapshot from changing every minute
		devs[i].LastSeenAt -= devs[i].LastSeenAt % (5 * 60 * 1000)
	}
	st, err := s.db.Stats(u.ID)
	if err != nil {
		return nil, err
	}
	u.PasswordHash = ""
	return json.Marshal(relaySnapshot{
		V: 1, Kid: kid, User: u, Nodes: nodes, Trash: trash, Categories: cats, Devices: devs, Stats: st,
		Server: map[string]any{"name": s.cfg.ServerName, "version": Version, "encrypted_at_rest": s.blobs.Encrypted()},
		Policy: map[string]any{"remote_purge": s.cfg.RemotePurge, "remote_pairing": s.cfg.RemotePairing,
			"remote_max_file": s.cfg.RemoteMaxFile, "cache_days": s.cfg.CacheDays},
	})
}

// reconcileCache makes the relay hold encrypted copies of exactly the files
// that should be there: recent ones (within the configured limits) plus any a
// device asked for. Everything else is removed from the relay.
func (a *relayAgent) reconcileCache(ctx context.Context, space string, u store.User, ring e2e.Keyring, kid uint32) (bool, error) {
	s := a.s
	nodes, err := s.db.AllNodes(u.ID)
	if err != nil {
		return false, err
	}
	pinned, err := s.db.RelayCache(u.ID)
	if err != nil {
		return false, err
	}
	byID := map[string]store.Node{}
	var files []store.Node
	for _, n := range nodes {
		if !n.IsDir {
			byID[n.ID] = n
			files = append(files, n)
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].CreatedAt > files[j].CreatedAt })
	desired := map[string]store.Node{}
	cutoff := time.Now().AddDate(0, 0, -s.cfg.CacheDays).UnixMilli()
	var total int64
	for _, n := range files {
		if n.CreatedAt < cutoff {
			break
		}
		if n.Size <= s.cfg.CacheMaxFile && total+n.Size <= s.cfg.CacheMaxTotal {
			desired[e2e.CacheKey(ring[kid], n.ID, n.SHA256)] = n
			total += n.Size
		}
	}
	nowMs := time.Now().UnixMilli()
	for key, e := range pinned {
		n, ok := byID[e.NodeID]
		if !ok || e.PinnedUntil < nowMs {
			s.db.DeleteRelayCache(u.ID, key)
			continue
		}
		if e.Kid != kid { // re-pin under the current space key
			s.db.DeleteRelayCache(u.ID, key)
			key = e2e.CacheKey(ring[kid], n.ID, n.SHA256)
			s.db.PutRelayCache(u.ID, store.CacheEntry{Key: key, NodeID: n.ID, Kid: kid, Size: e2e.CipherSize(n.Size), PinnedUntil: e.PinnedUntil})
		}
		desired[key] = n
	}
	var remote struct {
		Entries []struct {
			Key      string `json:"key"`
			Size     int64  `json:"size"`
			Complete bool   `json:"complete"`
		} `json:"entries"`
	}
	if err := a.call(ctx, http.MethodGet, "/n/v1/spaces/"+space+"/cache", nil, &remote, 32<<20); err != nil {
		return false, err
	}
	have := map[string]bool{}
	for _, e := range remote.Entries {
		if _, want := desired[e.Key]; !want || !e.Complete {
			r, err := a.req(ctx, http.MethodDelete, "/n/v1/spaces/"+space+"/cache/"+e.Key, nil, nil)
			if err == nil {
				if resp, err := a.api.Do(r); err == nil {
					resp.Body.Close()
				}
			}
			continue
		}
		have[e.Key] = true
	}
	uploaded := false
	for key, n := range desired {
		if have[key] {
			continue
		}
		if err := a.uploadCache(ctx, space, key, n, kid, ring[kid]); err != nil {
			return uploaded, fmt.Errorf("cache %s: %w", n.Name, err)
		}
		uploaded = true
	}
	return uploaded, nil
}

func (a *relayAgent) uploadCache(ctx context.Context, space, key string, n store.Node, kid uint32, sk []byte) error {
	src, err := a.s.blobs.Open(n.Blob, n.Size, n.Enc)
	if err != nil {
		return err
	}
	defer src.Close()
	size := e2e.CipherSize(n.Size)
	pr, pw := io.Pipe()
	go func() { pw.CloseWithError(e2e.EncryptBlob(pw, src, n.Size, kid, sk)) }()
	defer pr.Close()
	buf := make([]byte, chunk)
	var off int64
	for off < size {
		m, err := io.ReadFull(pr, buf[:min(int64(chunk), size-off)])
		if err != nil {
			return err
		}
		q := url.Values{"offset": {strconv.FormatInt(off, 10)}, "size": {strconv.FormatInt(size, 10)}}
		r, err := a.req(ctx, http.MethodPut, "/n/v1/spaces/"+space+"/cache/"+key+"?"+q.Encode(), bytes.NewReader(buf[:m]), nil)
		if err != nil {
			return err
		}
		r.ContentLength = int64(m)
		resp, err := a.bulk.Do(r)
		if err != nil {
			return err
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("relay cache upload: %d", resp.StatusCode)
		}
		off += int64(m)
	}
	return nil
}

// forgetDeletedSpaces removes relay data of users deleted on the NAS.
func (a *relayAgent) forgetDeletedSpaces(ctx context.Context, spaces map[string]store.User) error {
	known, _ := a.s.db.Meta("relay_spaces")
	cur := make([]string, 0, len(spaces))
	for sp := range spaces {
		cur = append(cur, sp)
	}
	sort.Strings(cur)
	for _, sp := range strings.Split(known, ",") {
		if _, ok := spaces[sp]; sp != "" && !ok {
			r, err := a.req(ctx, http.MethodDelete, "/n/v1/spaces/"+sp, nil, nil)
			if err != nil {
				return err
			}
			resp, err := a.api.Do(r)
			if err != nil {
				return err
			}
			resp.Body.Close()
		}
	}
	return a.s.db.SetMeta("relay_spaces", strings.Join(cur, ","))
}
