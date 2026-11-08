package api

import (
	"bytes"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"fileswitch/internal/e2e"
)

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func debugLog(w *lockedBuffer) *slog.Logger {
	return slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

func (e *relayEnv) enroll(lan *client) *rclient {
	e.t.Helper()
	c := e.clientFrom(enrollOn(e.t, lan))
	waitUntil(e.t, "relay to hold a snapshot", func() bool {
		st, _ := c.do("GET", "/r/v1/snapshot", nil, nil)
		return st == 200
	})
	return c
}

// Working with files leaves their names in neither the process log nor the
// security log.
func TestLogsNameNoFiles(t *testing.T) {
	var logs lockedBuffer
	c, _ := setupLogged(t, debugLog(&logs))
	c.token = login(c, "Mac")
	const secret = "绝密工资单"
	cat := c.do("POST", "/api/v1/categories", map[string]any{"name": secret + "分类", "color": "#2EAD6B"}, 201)
	folder := c.do("POST", "/api/v1/nodes/folder", map[string]any{"name": secret + "文件夹"}, 201)
	file := c.do("PUT", "/api/v1/files?size=1&path="+secret+".txt", []byte("x"), 200)["node"].(map[string]any)
	fid := file["id"].(string)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]any{"name": secret + "2.txt"}, 200)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]any{"parent_id": folder["id"]}, 200)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]any{"category_id": cat["id"]}, 200)
	c.do("DELETE", "/api/v1/nodes/"+fid, nil, 204)
	c.do("POST", "/api/v1/trash/"+fid+"/restore", nil, 200)
	c.do("GET", "/api/v1/nodes/"+fid, nil, 200)
	c.do("DELETE", "/api/v1/categories/"+cat["id"].(string), nil, 204)

	if s := logs.String(); strings.Contains(s, secret) || strings.Contains(s, fid) || strings.Contains(s, "/api/v1/") {
		t.Fatalf("file activity reached the log:\n%s", s)
	}
	entries := c.do("GET", "/api/v1/audit?limit=500", nil, 200)["entries"].([]any)
	if len(entries) < 8 {
		t.Fatalf("security log lost its entries: %d", len(entries))
	}
	for _, e := range entries {
		m := e.(map[string]any)
		if m["action"] != "login" && m["detail"] != "" {
			t.Fatalf("security log names something: %v", m)
		}
	}
}

// A rejected upload arriving through the relay doesn't put its path in the log.
func TestRejectedRelayUploadIsNotNamed(t *testing.T) {
	var logs lockedBuffer
	e := setupRelay(t)
	e.log = debugLog(&logs)
	_, lan := e.addNAS()
	lan.token = login(lan, "Mac")
	mac := e.enroll(lan)
	const secret = "绝密名单.txt"
	blob, _ := mac.upload([]byte("abc"))
	r := mac.await(mac.send(map[string]any{"t": "upload",
		"files": []map[string]any{{"rel": secret, "blob": blob, "nonce": "not-a-nonce", "size": 3}}}))
	if !r.OK || !strings.Contains(string(r.Data), secret) {
		t.Fatalf("the uploader should still be told which file failed: %s %s", r.Error, r.Data)
	}
	waitUntil(t, "the rejection to be logged", func() bool { return strings.Contains(logs.String(), "upload rejected") })
	if s := logs.String(); strings.Contains(s, secret) {
		t.Fatalf("file name in the log:\n%s", s)
	}
}

// The NAS only pushes what the relay may keep. Anything older would expire
// there and be sent again on every reconcile.
func TestNASPushesOnlyWithinRetention(t *testing.T) {
	e := setupRelay(t)
	e.lan.token = login(e.lan, "Mac")
	mac := e.enroll(e.lan)
	e.lan.do("PUT", "/api/v1/files?size=3&path=old.txt", []byte("old"), 200)
	e.lan.do("PUT", "/api/v1/files?size=3&path=new.txt", []byte("new"), 200)
	oldN, newN := mac.nodeByName("old.txt"), mac.nodeByName("new.txt")
	oldKey := e2e.CacheKey(mac.ring[mac.kid], oldN.ID, oldN.SHA256)
	newKey := e2e.CacheKey(mac.ring[mac.kid], newN.ID, newN.SHA256)
	if _, err := e.nas.db.Exec(`UPDATE nodes SET created_at = ? WHERE id = ?`,
		time.Now().Add(-e2e.Retention-time.Minute).UnixMilli(), oldN.ID); err != nil {
		t.Fatal(err)
	}
	present := func(key string) bool {
		var res struct {
			Present []struct{ Key string } `json:"present"`
		}
		mac.jsonDo("POST", "/r/v1/cache/lookup", map[string]any{"keys": []string{key}}, &res)
		return len(res.Present) == 1
	}
	waitUntil(t, "only the recent file on the relay", func() bool { return present(newKey) && !present(oldKey) })

	// asking for an older file still works, for one retention period
	if r := mac.await(mac.send(map[string]any{"t": "fetch", "ids": []string{oldN.ID}})); !r.OK {
		t.Fatalf("fetch: %s", r.Error)
	}
	waitUntil(t, "the requested file on the relay", func() bool { return present(oldKey) })
	uid := e.nas.mustUserID(t)
	pins, err := e.nas.db.RelayCache(uid)
	if err != nil {
		t.Fatal(err)
	}
	limit := time.Now().Add(e2e.Retention).UnixMilli()
	if p, ok := pins[oldKey]; !ok || p.PinnedUntil > limit {
		t.Fatalf("pin: %+v (limit %d)", p, limit)
	}
}

func (s *Server) mustUserID(t *testing.T) string {
	t.Helper()
	u, err := s.db.UserByName("alice")
	if err != nil {
		t.Fatal(err)
	}
	return u.ID
}
