package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"fileswitch/internal/auth"
	"fileswitch/internal/blob"
	"fileswitch/internal/config"
	"fileswitch/internal/e2e"
	"fileswitch/internal/relay"
	"fileswitch/internal/store"
)

// relayEnv is a NAS, a relay and plumbing for a protocol-level client.
type relayEnv struct {
	t        *testing.T
	nas      *Server
	lan      *client
	relayURL string
	relayDir string
	rc       *http.Client
}

const nasToken = "test-nas-token-0123456789abcdefghijklmnop"

func setupRelay(t *testing.T, opts ...func(*config.Config)) *relayEnv {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	relayDir := t.TempDir()
	rs, err := relay.New(&relay.Config{DataDir: relayDir, NASToken: nasToken, MaxFile: 1 << 30, Quota: 4 << 30,
		UploadTTL: time.Hour, CacheTTL: time.Hour}, log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { rs.Close() })
	rts := httptest.NewTLSServer(rs.Handler())
	t.Cleanup(rts.Close)
	sum := sha256.Sum256(rts.Certificate().Raw)

	dir := t.TempDir()
	cfg := &config.Config{DataDir: dir, TrashDays: 30, ServerName: "test-nas", LAN: true,
		RelayURL: rts.URL, RelayToken: nasToken, RelayFingerprint: hex.EncodeToString(sum[:]),
		RelayInterval: 50 * time.Millisecond, CacheDays: 7, CacheMaxFile: 64 << 20, CacheMaxTotal: 1 << 30,
		RemoteMaxFile: 1 << 30}
	for _, o := range opts {
		o(cfg)
	}
	db, err := store.Open(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	key := make([]byte, 32)
	rand.Read(key)
	blobs, _ := blob.New(dir, key)
	h, _ := auth.HashPassword("password123")
	db.CreateUser("alice", h, true)
	nas := New(cfg, db, blobs, log, false)
	lts := httptest.NewServer(nas.Handler())
	t.Cleanup(lts.Close)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if err := nas.StartRelay(ctx); err != nil {
		t.Fatal(err)
	}
	return &relayEnv{t: t, nas: nas, lan: &client{t: t, base: lts.URL}, relayURL: rts.URL, relayDir: relayDir,
		rc: rts.Client()}
}

// rclient speaks the client side of the relay protocol, like the apps do.
type rclient struct {
	e      *relayEnv
	token  string
	device string
	space  string
	dk     []byte
	ring   e2e.Keyring
	kid    uint32
}

func (e *relayEnv) clientFrom(b enrollBundle) *rclient {
	dk, _ := base64.StdEncoding.DecodeString(b.DeviceKey)
	ring, err := b.Keyring.Keyring()
	if err != nil {
		e.t.Fatal(err)
	}
	return &rclient{e: e, token: b.RelayToken, device: b.DeviceID, space: b.SpaceID, dk: dk, ring: ring, kid: b.Keyring.Current}
}

func (c *rclient) do(method, path string, body []byte, hdr map[string]string) (int, []byte) {
	req, _ := http.NewRequest(method, c.e.relayURL+path, bytes.NewReader(body))
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := c.e.rc.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func (c *rclient) jsonDo(method, path string, in any, out any) int {
	var body []byte
	if in != nil {
		body, _ = json.Marshal(in)
	}
	st, b := c.do(method, path, body, map[string]string{"Content-Type": "application/json"})
	if out != nil {
		json.Unmarshal(b, out)
	}
	return st
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(30 * time.Millisecond)
	}
}

func opID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// send seals an op with the device key and posts it; it returns the op id.
func (c *rclient) send(op map[string]any) string {
	id := opID()
	if _, ok := op["ts"]; !ok {
		op["ts"] = time.Now().UnixMilli()
	}
	plain, _ := json.Marshal(op)
	env := e2e.SealEnvelope(c.dk, plain, e2e.OpAAD(c.device, id))
	if st := c.jsonDo("POST", "/r/v1/ops", map[string]string{"id": id, "n": env.N, "c": env.C}, nil); st != 202 {
		c.e.t.Fatalf("post op: %d", st)
	}
	return id
}

type reply struct {
	OK    bool            `json:"ok"`
	Error string          `json:"error"`
	Data  json.RawMessage `json:"data"`
}

// await waits for the NAS's reply to op id, verifying it decrypts with our key.
func (c *rclient) await(id string) reply {
	c.e.t.Helper()
	var got *reply
	waitUntil(c.e.t, "reply to "+id, func() bool {
		var res struct {
			Replies []struct {
				Op   string       `json:"op"`
				Body e2e.Envelope `json:"body"`
			} `json:"replies"`
		}
		c.jsonDo("GET", "/r/v1/replies?after=0", nil, &res)
		for _, r := range res.Replies {
			if r.Op != id {
				continue
			}
			p, err := e2e.OpenEnvelope(c.dk, r.Body, e2e.ReplyAAD(c.device, id))
			if err != nil {
				c.e.t.Fatalf("reply does not authenticate: %v", err)
			}
			var rp reply
			json.Unmarshal(p, &rp)
			got = &rp
			return true
		}
		return false
	})
	return *got
}

func (c *rclient) snapshot() relaySnapshot {
	c.e.t.Helper()
	st, data := c.do("GET", "/r/v1/snapshot", nil, nil)
	if st != 200 {
		c.e.t.Fatalf("snapshot: %d", st)
	}
	plain, _, err := e2e.OpenSnapshot(data, c.space, c.ring)
	if err != nil {
		c.e.t.Fatalf("open snapshot: %v", err)
	}
	var s relaySnapshot
	json.Unmarshal(plain, &s)
	return s
}

// upload encrypts content, uploads the ciphertext and returns (blob id, header nonce).
func (c *rclient) upload(content []byte) (string, string) {
	var ct bytes.Buffer
	if err := e2e.EncryptBlob(&ct, bytes.NewReader(content), int64(len(content)), c.kid, c.ring[c.kid]); err != nil {
		c.e.t.Fatal(err)
	}
	var created struct {
		ID string `json:"id"`
	}
	if st := c.jsonDo("POST", "/r/v1/blobs", map[string]int{"size": ct.Len()}, &created); st != 201 {
		c.e.t.Fatalf("create blob: %d", st)
	}
	if st, b := c.do("PUT", "/r/v1/blobs/"+created.ID+"?offset=0", ct.Bytes(), nil); st != 200 {
		c.e.t.Fatalf("put blob: %d %s", st, b)
	}
	return created.ID, base64.StdEncoding.EncodeToString(e2e.HeaderNonce(ct.Bytes()))
}

// nodeByName waits for the node to show up: the NAS replies to an op before
// it publishes the snapshot that includes the change.
func (c *rclient) nodeByName(name string) store.Node {
	var found store.Node
	waitUntil(c.e.t, fmt.Sprintf("node %q in snapshot", name), func() bool {
		for _, n := range c.snapshot().Nodes {
			if n.Name == name {
				found = n
				return true
			}
		}
		return false
	})
	return found
}

func TestRelayEndToEnd(t *testing.T) {
	e := setupRelay(t)
	e.lan.token = login(e.lan, "Mac")

	// Enroll the LAN device for relay access.
	var bundle enrollBundle
	{
		req, _ := http.NewRequest("POST", e.lan.base+"/api/v1/relay/enroll", nil)
		req.Header.Set("Authorization", "Bearer "+e.lan.token)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		json.NewDecoder(resp.Body).Decode(&bundle)
		resp.Body.Close()
		if resp.StatusCode != 200 || bundle.RelayToken == "" {
			t.Fatalf("enroll: %d", resp.StatusCode)
		}
	}
	mac := e.clientFrom(bundle)
	waitUntil(t, "relay to accept the token and hold a snapshot", func() bool {
		st, _ := mac.do("GET", "/r/v1/snapshot", nil, nil)
		return st == 200
	})
	if s := mac.snapshot(); s.User.Username != "alice" || len(s.Nodes) != 1 {
		t.Fatalf("unexpected first snapshot: %+v", s.User)
	}

	// Category + upload through the relay.
	r := mac.await(mac.send(map[string]any{"t": "cat_create", "name": "照片", "color": "#2EAD6B"}))
	if !r.OK {
		t.Fatalf("cat_create: %s", r.Error)
	}
	var cat struct{ ID string }
	json.Unmarshal(r.Data, &cat)

	secretName := "绝密-报表-2026.txt"
	secretBody := []byte("TOP-SECRET-CONTENT-" + strings.Repeat("x", 200000))
	blobID, nonce := mac.upload(secretBody)
	r = mac.await(mac.send(map[string]any{"t": "upload", "category_id": cat.ID,
		"files": []map[string]any{{"rel": secretName, "blob": blobID, "nonce": nonce, "size": len(secretBody), "mtime": 1}}}))
	if !r.OK || !strings.Contains(string(r.Data), `"created":1`) {
		t.Fatalf("upload: %s %s", r.Error, r.Data)
	}
	n := mac.nodeByName(secretName)
	if n.CategoryID != cat.ID || n.SHA256 != fmt.Sprintf("%x", sha256.Sum256(secretBody)) {
		t.Fatal("uploaded node has wrong category or content hash")
	}
	if st, _ := mac.do("GET", "/r/v1/blobs/"+blobID, nil, nil); st != 404 {
		t.Fatal("relay still holds the upload after the NAS collected it")
	}

	// Folder upload with an empty dir.
	b1, n1 := mac.upload([]byte("one"))
	r = mac.await(mac.send(map[string]any{"t": "upload", "folder": map[string]any{"name": "项目", "mtime": 1},
		"dirs": []string{"空/更深"}, "files": []map[string]any{{"rel": "子/a.txt", "blob": b1, "nonce": n1, "size": 3}}}))
	if !r.OK {
		t.Fatalf("folder upload: %s", r.Error)
	}
	for _, name := range []string{"项目", "子", "a.txt", "空", "更深"} {
		mac.nodeByName(name)
	}

	// Download: recent files are pushed to the relay cache by the NAS.
	key := e2e.CacheKey(mac.ring[mac.kid], n.ID, n.SHA256)
	waitUntil(t, "file in relay cache", func() bool {
		var res struct {
			Present []struct{ Key string } `json:"present"`
		}
		mac.jsonDo("POST", "/r/v1/cache/lookup", map[string]any{"keys": []string{key}}, &res)
		return len(res.Present) == 1
	})
	st, ct := mac.do("GET", "/r/v1/cache/"+key, nil, nil)
	if st != 200 {
		t.Fatalf("cache get: %d", st)
	}
	plainR, err := e2e.DecryptBlob(bytes.NewReader(ct), n.Size, mac.ring, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(plainR)
	if err != nil || !bytes.Equal(got, secretBody) {
		t.Fatal("downloaded content differs")
	}

	// --- a malicious relay ---

	// 1. Forged op (relay doesn't have the device key): ignored, no reply.
	forged := opID()
	fake := e2e.SealEnvelope(e2e.NewKey(), []byte(`{"t":"batch","action":"trash","ids":["`+n.ID+`"],"ts":1}`), e2e.OpAAD(mac.device, forged))
	mac.jsonDo("POST", "/r/v1/ops", map[string]string{"id": forged, "n": fake.N, "c": fake.C}, nil)

	// 2. Replay of a valid op after it was processed: ignored.
	trashOp := map[string]any{"t": "batch", "action": "trash", "ids": []string{n.ID}, "ts": time.Now().UnixMilli()}
	plain, _ := json.Marshal(trashOp)
	rid := opID()
	env := e2e.SealEnvelope(mac.dk, plain, e2e.OpAAD(mac.device, rid))
	mac.jsonDo("POST", "/r/v1/ops", map[string]string{"id": rid, "n": env.N, "c": env.C}, nil)
	mac.await(rid)
	mac.await(mac.send(map[string]any{"t": "restore", "id": n.ID}))
	mac.jsonDo("POST", "/r/v1/ops", map[string]string{"id": rid, "n": env.N, "c": env.C}, nil) // replay
	time.Sleep(400 * time.Millisecond)
	if _, err := e.nas.db.Node(userID(t, e.nas.db, "alice"), n.ID); err != nil {
		t.Fatal("replayed op was applied (file trashed again)")
	}

	var res struct {
		Replies []struct{ Op string } `json:"replies"`
	}
	mac.jsonDo("GET", "/r/v1/replies?after=0", nil, &res)
	for _, rp := range res.Replies {
		if rp.Op == forged {
			t.Fatal("NAS answered a forged op")
		}
	}

	// 3. Blob substitution: op references blob A but the relay serves blob B.
	bA, nA := mac.upload([]byte("AAAA"))
	bB, _ := mac.upload([]byte("BBBB"))
	r = mac.await(mac.send(map[string]any{"t": "upload",
		"files": []map[string]any{{"rel": "swap.txt", "blob": bB, "nonce": nA, "size": 4}}}))
	if strings.Contains(string(r.Data), `"created":1`) {
		t.Fatal("substituted blob was accepted")
	}
	_ = bA

	// 4. Policy: remote devices can't purge.
	r = mac.await(mac.send(map[string]any{"t": "empty_trash"}))
	if r.OK {
		t.Fatal("remote purge allowed despite policy")
	}
	r = mac.await(mac.send(map[string]any{"t": "pair"}))
	if r.OK {
		t.Fatal("remote pairing allowed despite policy")
	}

	// 5. Unauthenticated / wrong-token access.
	anon := &rclient{e: e}
	if st, _ := anon.do("GET", "/r/v1/snapshot", nil, nil); st != 401 {
		t.Fatalf("anonymous snapshot: %d", st)
	}
	anon.token = "Bearer nope"
	if st, _ := anon.do("GET", "/n/v1/poll", nil, nil); st != 401 {
		t.Fatalf("fake NAS poll: %d", st)
	}

	// --- pairing a second device with a code ---
	code, _, err := e.nas.newPairing(userID(t, e.nas.db, "alice"), "test")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(code)
	secret, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(u.Query().Get("k"))
	lookup, pkey := e2e.Pairing(secret)
	req := e2e.SealEnvelope(pkey, []byte(`{"device_name":"Pixel","platform":"android"}`), e2e.PairReqAAD(lookup))
	if st := anon.jsonDo("POST", "/r/v1/pair/"+lookup, req, nil); st != 202 {
		t.Fatalf("pair request: %d", st)
	}
	var phoneBundle enrollBundle
	waitUntil(t, "pairing response", func() bool {
		var env e2e.Envelope
		if anon.jsonDo("GET", "/r/v1/pair/"+lookup, nil, &env) != 200 {
			return false
		}
		p, err := e2e.OpenEnvelope(pkey, env, e2e.PairRespAAD(lookup))
		if err != nil {
			t.Fatalf("pair response: %v", err)
		}
		json.Unmarshal(p, &phoneBundle)
		return true
	})
	phone := e.clientFrom(phoneBundle)
	if s := phone.snapshot(); len(s.Nodes) < 5 {
		t.Fatal("paired device can't read the snapshot")
	}
	// the code is single-use
	if st := anon.jsonDo("POST", "/r/v1/pair/"+lookup, req, nil); st == 202 {
		time.Sleep(300 * time.Millisecond)
		if anon.jsonDo("GET", "/r/v1/pair/"+lookup, nil, nil) == 200 {
			t.Fatal("pairing code worked twice")
		}
	}

	// --- revoking the phone rotates the space key ---
	oldKid := phone.kid
	r = mac.await(mac.send(map[string]any{"t": "device_revoke", "id": phone.device}))
	if !r.OK {
		t.Fatalf("revoke: %s", r.Error)
	}
	waitUntil(t, "relay to reject the revoked device", func() bool {
		st, _ := phone.do("GET", "/r/v1/status", nil, nil)
		return st == 401
	})
	waitUntil(t, "new space key for remaining devices", func() bool {
		var env e2e.Envelope
		if mac.jsonDo("GET", "/r/v1/keyring", nil, &env) != 200 {
			return false
		}
		p, err := e2e.OpenEnvelope(mac.dk, env, e2e.KeyringAAD(mac.device))
		if err != nil {
			t.Fatal(err)
		}
		var kj e2e.KeyringJSON
		json.Unmarshal(p, &kj)
		if kj.Current == oldKid {
			return false
		}
		mac.ring, _ = kj.Keyring()
		mac.kid = kj.Current
		return true
	})
	// The revoked device's keys can't open anything published from now on.
	// (The keyring goes out first; the snapshot under the new key follows.)
	var data []byte
	waitUntil(t, "snapshot under the new key", func() bool {
		st, b := mac.do("GET", "/r/v1/snapshot", nil, nil)
		data = b
		return st == 200 && len(b) >= 8 && binary.BigEndian.Uint32(b[4:8]) == mac.kid
	})
	if _, _, err := e2e.OpenSnapshot(data, phone.space, phone.ring); err == nil {
		t.Fatal("revoked device can still read new snapshots")
	}
	mac.snapshot() // current devices can

	// --- what the relay stores: no plaintext names or content ---
	time.Sleep(200 * time.Millisecond)
	filepath.Walk(e.relayDir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		b, _ := os.ReadFile(p)
		for _, needle := range []string{secretName, "TOP-SECRET-CONTENT", "照片", "项目", "alice", "password123"} {
			if bytes.Contains(b, []byte(needle)) {
				t.Errorf("relay file %s contains plaintext %q", filepath.Base(p), needle)
			}
		}
		return nil
	})
}

func userID(t *testing.T, db *store.DB, name string) string {
	u, err := db.UserByName(name)
	if err != nil {
		t.Fatal(err)
	}
	return u.ID
}
