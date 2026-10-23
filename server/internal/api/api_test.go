package api

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"fileswitch/internal/auth"
	"fileswitch/internal/blob"
	"fileswitch/internal/config"
	"fileswitch/internal/store"
)

type client struct {
	t     *testing.T
	base  string
	token string
}

func (c *client) do(method, path string, body any, want int) map[string]any {
	c.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	default:
		j, _ := json.Marshal(b)
		rd = bytes.NewReader(j)
	}
	req, _ := http.NewRequest(method, c.base+path, rd)
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != want {
		c.t.Fatalf("%s %s: status %d, want %d: %s", method, path, resp.StatusCode, want, raw)
	}
	out := map[string]any{}
	json.Unmarshal(raw, &out)
	return out
}

func setup(t *testing.T) (*client, *Server) {
	dir := t.TempDir()
	cfg := &config.Config{DataDir: dir, TrashDays: 30, ServerName: "test"}
	db, err := store.Open(dir + "/test.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	key := make([]byte, 32)
	rand.Read(key)
	blobs, err := blob.New(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	h, _ := auth.HashPassword("password123")
	if _, err := db.CreateUser("alice", h, true); err != nil {
		t.Fatal(err)
	}
	s := New(cfg, db, blobs, slog.New(slog.NewTextHandler(io.Discard, nil)), false)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return &client{t: t, base: ts.URL}, s
}

func login(c *client, device string) string {
	res := c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "password123", "device_name": device, "platform": "test"}, 200)
	return res["token"].(string)
}

func names(res map[string]any, key string) []string {
	var out []string
	for _, it := range res[key].([]any) {
		out = append(out, it.(map[string]any)["name"].(string))
	}
	return out
}

func TestEndToEnd(t *testing.T) {
	c, _ := setup(t)

	c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "wrong"}, 401)
	c.do("GET", "/api/v1/auth/me", nil, 401)
	c.token = login(c, "Mac")
	me := c.do("GET", "/api/v1/auth/me", nil, 200)
	if me["device"].(map[string]any)["name"] != "Mac" {
		t.Fatal("device name")
	}

	cat := c.do("POST", "/api/v1/categories", map[string]string{"name": "照片", "color": "#FF8800"}, 201)
	catID := cat["id"].(string)
	c.do("POST", "/api/v1/categories", map[string]string{"name": "照片"}, 409)

	// Direct upload into the category: lands in /照片 and is tagged.
	small := []byte("hello world")
	res := c.do("PUT", "/api/v1/files?path=a.txt&timeline=1&size=11&category_id="+catID, small, 200)
	a := res["node"].(map[string]any)
	if a["category_id"] != catID {
		t.Fatal("category not set")
	}
	n := c.do("GET", "/api/v1/nodes/"+a["id"].(string), nil, 200)
	path := n["path"].([]any)
	if len(path) != 3 || path[1].(map[string]any)["name"] != "照片" {
		t.Fatalf("unexpected path %v", path)
	}
	// same name again → renamed
	res = c.do("PUT", "/api/v1/files?path=a.txt&size=11&category_id="+catID, small, 200)
	if res["node"].(map[string]any)["name"] != "a (1).txt" {
		t.Fatalf("conflict rename: %v", res["node"])
	}

	// Resumable upload of ~20 MiB with a wrong offset and a resume.
	big := make([]byte, 20<<20+12345)
	rand.Read(big)
	sum := sha256.Sum256(big)
	up := c.do("POST", "/api/v1/uploads", map[string]any{"path": "big.bin", "size": len(big), "timeline": true}, 201)
	uid := up["upload"].(map[string]any)["id"].(string)
	chunk := int(up["chunk_size"].(float64))
	c.do("PUT", "/api/v1/uploads/"+uid+"?offset=5", big[:10], 409)
	// a chunk that is cut off mid-segment keeps only whole segments
	r := c.do("PUT", "/api/v1/uploads/"+uid+"?offset=0", big[:blob.SegSize*3+100], 200)
	off := int(r["received"].(float64))
	if off != blob.SegSize*3 {
		t.Fatalf("received %d", off)
	}
	for off < len(big) {
		end := min(off+chunk, len(big))
		r = c.do("PUT", fmt.Sprintf("/api/v1/uploads/%s?offset=%d", uid, off), big[off:end], 200)
		off = int(r["received"].(float64))
	}
	done := c.do("POST", "/api/v1/uploads/"+uid+"/complete", map[string]string{"sha256": hex.EncodeToString(sum[:])}, 200)
	bigID := done["node"].(map[string]any)["id"].(string)

	// Range read of the encrypted blob.
	req, _ := http.NewRequest("GET", c.base+"/api/v1/nodes/"+bigID+"/content", nil)
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Range", "bytes=1000000-1000999")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	part, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 206 || !bytes.Equal(part, big[1000000:1001000]) {
		t.Fatalf("range read failed: %d", resp.StatusCode)
	}

	// Folder upload: create the dropped folder, then files by relative path.
	folder := c.do("POST", "/api/v1/nodes/folder", map[string]any{"name": "Docs", "timeline": true, "conflict": "rename"}, 201)
	fid := folder["id"].(string)
	c.do("PUT", "/api/v1/files?path="+url.QueryEscape("sub/b.txt")+"&size=3&parent_id="+fid, []byte("bbb"), 200)
	c.do("PUT", "/api/v1/files?path="+url.QueryEscape("sub/c.txt")+"&size=0&parent_id="+fid, []byte{}, 200)
	c.do("POST", "/api/v1/nodes/folder", map[string]any{"parent_id": fid, "path": "empty/deeper"}, 201)
	c.do("POST", "/api/v1/nodes/folder", map[string]any{"parent_id": fid, "path": "empty/deeper"}, 201)
	walk := c.do("GET", "/api/v1/nodes/"+fid+"/walk", nil, 200)
	var rels []string
	for _, e := range walk["entries"].([]any) {
		rels = append(rels, e.(map[string]any)["rel_path"].(string))
	}
	if strings.Join(rels, ",") != "Docs,Docs/empty,Docs/sub,Docs/empty/deeper,Docs/sub/b.txt,Docs/sub/c.txt" {
		t.Fatalf("walk: %v", rels)
	}

	tl := c.do("GET", "/api/v1/timeline", nil, 200)
	if got := strings.Join(names(tl, "items"), ","); got != "Docs,big.bin,a.txt" {
		t.Fatalf("timeline: %s", got)
	}
	tl = c.do("GET", "/api/v1/timeline?category="+catID, nil, 200)
	if got := strings.Join(names(tl, "items"), ","); got != "a.txt" {
		t.Fatalf("timeline by category: %s", got)
	}

	// Zip download of the folder.
	req, _ = http.NewRequest("GET", c.base+"/api/v1/nodes/"+fid+"/zip", nil)
	req.Header.Set("Authorization", "Bearer "+c.token)
	resp, _ = http.DefaultClient.Do(req)
	zb, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	zr, err := zip.NewReader(bytes.NewReader(zb), int64(len(zb)))
	if err != nil {
		t.Fatal(err)
	}
	if len(zr.File) != 6 {
		t.Fatalf("zip entries: %d", len(zr.File))
	}

	// Rename / move / conflict.
	aid := a["id"].(string)
	c.do("PATCH", "/api/v1/nodes/"+aid, map[string]string{"name": "a (1).txt"}, 409)
	c.do("PATCH", "/api/v1/nodes/"+aid, map[string]string{"name": "A.TXT"}, 200)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]string{"parent_id": fid}, 400)
	moved := c.do("PATCH", "/api/v1/nodes/"+aid, map[string]string{"parent_id": ""}, 200)
	if moved["parent_id"] == a["parent_id"] {
		t.Fatal("not moved")
	}

	// Trash, restore, purge.
	c.do("DELETE", "/api/v1/nodes/"+fid, nil, 204)
	root := c.do("GET", "/api/v1/nodes", nil, 200)
	for _, nm := range names(root, "children") {
		if nm == "Docs" {
			t.Fatal("trashed folder still listed")
		}
	}
	trash := c.do("GET", "/api/v1/trash", nil, 200)
	if got := strings.Join(names(trash, "items"), ","); got != "Docs" {
		t.Fatalf("trash: %s", got)
	}
	c.do("POST", "/api/v1/trash/"+fid+"/restore", nil, 200)
	walk = c.do("GET", "/api/v1/nodes/"+fid+"/walk", nil, 200)
	if len(walk["entries"].([]any)) != 6 {
		t.Fatal("restore lost children")
	}
	c.do("DELETE", "/api/v1/nodes/"+fid, nil, 204)
	c.do("DELETE", "/api/v1/trash/"+fid, nil, 204)
	c.do("GET", "/api/v1/nodes/"+fid, nil, 404)

	sr := c.do("GET", "/api/v1/search?q=big", nil, 200)
	if got := strings.Join(names(sr, "items"), ","); got != "big.bin" {
		t.Fatalf("search: %s", got)
	}
	cats := c.do("GET", "/api/v1/categories", nil, 200)
	if cnt := cats["categories"].([]any)[0].(map[string]any)["count"].(float64); cnt != 2 {
		t.Fatalf("category count %v", cnt)
	}
}

func TestEventsAndRevoke(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	phone := &client{t: t, base: c.base, token: login(c, "Phone")}

	req, _ := http.NewRequest("GET", c.base+"/api/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+phone.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	lines := make(chan string, 16)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	c.do("PUT", "/api/v1/files?path=x.txt&size=1&timeline=1", []byte("x"), 200)
	deadline := time.After(3 * time.Second)
	for got := false; !got; {
		select {
		case l := <-lines:
			if strings.HasPrefix(l, "data: ") && strings.Contains(l, `"node.created"`) && strings.Contains(l, "x.txt") {
				got = true
			}
		case <-deadline:
			t.Fatal("no event received")
		}
	}

	devs := c.do("GET", "/api/v1/devices", nil, 200)
	var phoneID string
	for _, d := range devs["devices"].([]any) {
		if d.(map[string]any)["name"] == "Phone" {
			phoneID = d.(map[string]any)["id"].(string)
		}
	}
	c.do("DELETE", "/api/v1/devices/"+phoneID, nil, 204)
	phone.do("GET", "/api/v1/nodes", nil, 401)
}

func TestLoginThrottle(t *testing.T) {
	c, _ := setup(t)
	for i := 0; i < 5; i++ {
		c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "nope"}, 401)
	}
	c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "password123"}, 429)
	// unknown users are throttled the same way and don't reveal existence
	c.do("POST", "/api/v1/auth/login", map[string]string{"username": "bob", "password": "x"}, 401)
}
