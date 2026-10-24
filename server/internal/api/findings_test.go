package api

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"fileswitch/internal/blob"
)

// Regression tests for the issues from the October 2026 penetration test.

func rawDo(t *testing.T, c *client, method, path, rawQuery string, body []byte) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, c.base+path, bytes.NewReader(body))
	req.URL.RawQuery = rawQuery
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// rawConn sends bytes as they are and returns the parsed response.
func rawConn(t *testing.T, base, request string) *http.Response {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(base, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte(request))
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func errMsg(res map[string]any) string {
	e, _ := res["error"].(map[string]any)
	m, _ := e["message"].(string)
	return m
}

func myID(c *client) (user, device string) {
	me := c.do("GET", "/api/v1/auth/me", nil, 200)
	return me["user"].(map[string]any)["id"].(string), me["device"].(map[string]any)["id"].(string)
}

// #16, #1: names that only become traversal after decoding, and absolute paths.
func TestPathsAreCheckedBeforeStoring(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	for _, p := range []string{"..%2f..%2fx.txt", "%2e%2e/x.txt", "%252e%252e%252fx.txt", "a/..%252f/x.txt", "/tmp/x.txt", "a//b.txt"} {
		c.do("PUT", "/api/v1/files?size=1&path="+url.QueryEscape(p), []byte("x"), 400)
		c.do("POST", "/api/v1/uploads", map[string]any{"path": p, "size": 1}, 400)
	}
	c.do("POST", "/api/v1/nodes/folder", map[string]any{"name": "%2e%2e"}, 400)
	// percent signs in ordinary names are fine
	for _, p := range []string{"50%折扣.txt", "100% done.txt", "a%zz.txt"} {
		c.do("PUT", "/api/v1/files?size=1&path="+url.QueryEscape(p), []byte("x"), 200)
	}
}

// #18, #19: a chunk that can't be stored as sent leaves no trace.
func TestBadChunksStoreNothing(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	received := func(id string) int {
		return int(c.do("GET", "/api/v1/uploads/"+id, nil, 200)["upload"].(map[string]any)["received"].(float64))
	}
	up := c.do("POST", "/api/v1/uploads", map[string]any{"path": "a.bin", "size": 20}, 201)
	id := up["upload"].(map[string]any)["id"].(string)
	c.do("PUT", "/api/v1/uploads/"+id+"?offset=0", make([]byte, 50), 400)
	if n := received(id); n != 0 {
		t.Fatalf("oversized chunk advanced progress to %d", n)
	}
	c.do("PUT", "/api/v1/uploads/"+id+"?offset=0", make([]byte, 20), 200)

	up = c.do("POST", "/api/v1/uploads", map[string]any{"path": "b.bin", "size": 100}, 201)
	id = up["upload"].(map[string]any)["id"].(string)
	res := c.do("PUT", "/api/v1/uploads/"+id+"?offset=0", make([]byte, 10), 400)
	if !strings.Contains(errMsg(res), "64 KiB") {
		t.Fatalf("short chunk: %v", res)
	}
	if n := received(id); n != 0 {
		t.Fatalf("short chunk advanced progress to %d", n)
	}
}

// A body that stops arriving fails with 408 instead of holding the connection.
func TestStalledBodyTimesOut(t *testing.T) {
	c, s := setup(t)
	c.token = login(c, "Mac")
	s.bodyIdle = 300 * time.Millisecond
	up := c.do("POST", "/api/v1/uploads", map[string]any{"path": "slow.bin", "size": 2 * blob.SegSize}, 201)
	id := up["upload"].(map[string]any)["id"].(string)
	req := fmt.Sprintf("PUT /api/v1/uploads/%s?offset=0 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n",
		id, c.token, 2*blob.SegSize) + string(make([]byte, blob.SegSize))
	start := time.Now()
	resp := rawConn(t, c.base, req)
	if resp.StatusCode != http.StatusRequestTimeout || time.Since(start) > 3*time.Second {
		t.Fatalf("status %d after %v", resp.StatusCode, time.Since(start))
	}
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	if out["received"].(float64) != blob.SegSize {
		t.Fatalf("the whole segment that arrived should be kept: %v", out)
	}
}

// #29, #30: chunked request bodies (alone or next to Content-Length) are refused.
func TestChunkedBodiesRefused(t *testing.T) {
	c, _ := setup(t)
	body := `{"username":"alice","password":"password123"}`
	for _, extra := range []string{"", fmt.Sprintf("Content-Length: %d\r\n", len(body))} {
		req := "POST /api/v1/auth/login HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" + extra + "\r\n" +
			fmt.Sprintf("%x\r\n%s\r\n0\r\n\r\n", len(body), body)
		if st := rawConn(t, c.base, req).StatusCode; st != http.StatusLengthRequired {
			t.Fatalf("chunked body (%q): status %d", extra, st)
		}
	}
}

// #2, #17: changing the password signs out other devices unless told not to.
func TestPasswordChangeSignsOutOthersByDefault(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	other := &client{t: t, base: c.base}
	other.token = login(other, "Phone")
	c.do("POST", "/api/v1/auth/password", map[string]any{"old_password": "password123", "new_password": "another-pass-1"}, 204)
	other.do("GET", "/api/v1/auth/me", nil, 401)

	other = &client{t: t, base: c.base}
	res := other.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "another-pass-1", "device_name": "Pad", "platform": "ios"}, 200)
	other.token = res["token"].(string)
	c.do("POST", "/api/v1/auth/password", map[string]any{"old_password": "another-pass-1", "new_password": "third-pass-22", "sign_out_others": false}, 204)
	other.do("GET", "/api/v1/auth/me", nil, 200)
}

// #3, #9: control characters and very long search terms are refused.
func TestSearchTermIsChecked(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	c.do("PUT", "/api/v1/files?size=1&path=seed.txt", []byte("x"), 200)
	if st, _ := rawDo(t, c, "GET", "/api/v1/search", "q=%00", nil); st != 400 {
		t.Fatalf("NUL search term: %d", st)
	}
	c.do("GET", "/api/v1/search?q="+strings.Repeat("a", 101), nil, 400)
	if items := c.do("GET", "/api/v1/search?q=seed", nil, 200)["items"].([]any); len(items) != 1 {
		t.Fatalf("search: %v", items)
	}
}

// #8, #21, #25, #26: a malformed query string is an error, never "no parameters".
func TestMalformedQueryRefused(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	for _, q := range []string{"parent=abc;x=1", "parent=abc%", "parent=%zz"} {
		if st, _ := rawDo(t, c, "GET", "/api/v1/nodes", q, nil); st != 400 {
			t.Fatalf("query %q: status %d", q, st)
		}
	}
	if st, _ := rawDo(t, c, "PUT", "/api/v1/files", "parent_id=someone-else%&path=a.txt&size=1", []byte("x")); st != 400 {
		t.Fatalf("write with broken parent_id: %d", st)
	}
	if kids := c.do("GET", "/api/v1/nodes", nil, 200)["children"].([]any); len(kids) != 0 {
		t.Fatal("the file landed in the root anyway")
	}
}

// #20, #22: parameters an endpoint doesn't understand are refused, not ignored.
func TestUnknownParametersRefused(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	c.do("GET", "/api/v1/admin/users?page=-1&limit=999999999", nil, 400)
	c.do("GET", "/api/v1/audit?zzz=1", nil, 400)
	c.do("GET", "/api/v1/timeline?limit=-1", nil, 400)
	c.do("GET", "/api/v1/timeline?limit=501", nil, 400)
	c.do("GET", "/api/v1/info?x=1", nil, 400)
	c.do("GET", "/api/v1/nodes?dirs=1", nil, 200)
	c.do("GET", "/api/v1/timeline?limit=300", nil, 200)
}

// #7: tagged/timeline with a category that doesn't exist is a 404.
func TestUnknownCategory404(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	c.do("GET", "/api/v1/tagged/not-a-category", nil, 404)
	c.do("GET", "/api/v1/timeline?category=not-a-category", nil, 404)
	c.do("GET", "/api/v1/timeline?category=none", nil, 200)
}

// #5, #23: modification times have to be plausible.
func TestMTimeRange(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	c.do("POST", "/api/v1/uploads", map[string]any{"path": "m.bin", "size": 1, "mtime": -99999999999999}, 400)
	c.do("POST", "/api/v1/nodes/folder", map[string]any{"name": "f", "mtime": 4102444800000}, 400)
	c.do("PUT", "/api/v1/files?size=1&path=a.txt&mtime=-1", []byte("x"), 400)
	c.do("PUT", "/api/v1/files?size=1&path=a.txt&mtime=abc", []byte("x"), 400)
	c.do("PUT", "/api/v1/files?size=1&path=a.txt&mtime=0", []byte("x"), 200)
	c.do("PUT", fmt.Sprintf("/api/v1/files?size=1&path=b.txt&mtime=%d", time.Now().UnixMilli()), []byte("x"), 200)
}

// #4, #13, #31: device names and platforms.
func TestDeviceNamesAndPlatforms(t *testing.T) {
	c, _ := setup(t)
	loginAs := func(name, platform string, want int) map[string]any {
		return c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "password123",
			"device_name": name, "platform": platform}, want)
	}
	first := loginAs("iPhone", "ios", 200)
	second := loginAs("iPhone", "ios", 200)
	if n := second["device"].(map[string]any)["name"]; n != "iPhone (2)" {
		t.Fatalf("second device with the same name: %v", n)
	}
	loginAs(strings.Repeat("长", 65), "ios", 400)
	loginAs(strings.Repeat("长", 64), "ios", 200)
	loginAs("Box", "zzz_invalid_platform", 400)
	c.token = first["token"].(string)
	_, dev := myID(c)
	c.do("PATCH", "/api/v1/devices/"+dev, map[string]string{"name": strings.Repeat("x", 1028)}, 400)
	c.do("PATCH", "/api/v1/devices/"+dev, map[string]string{"name": "My iPhone"}, 204)
}

// #14: decoding errors don't echo Go's type names.
func TestJSONErrorsAreGeneric(t *testing.T) {
	c, _ := setup(t)
	res := c.do("POST", "/api/v1/auth/login", map[string]any{"username": 1}, 400)
	if m := errMsg(res); strings.Contains(m, "Go") || strings.Contains(m, "struct") || !strings.Contains(m, "username") {
		t.Fatalf("message: %q", m)
	}
	c.token = login(c, "Mac")
	res = c.do("POST", "/api/v1/uploads", []byte(`{"size":"x"}`), 400)
	if m := errMsg(res); strings.Contains(m, "uploadParams") || strings.Contains(m, "api.") {
		t.Fatalf("message: %q", m)
	}
}

// #10, #12, #32: without a token every path looks the same.
func TestAnonymousCannotMapRoutes(t *testing.T) {
	c, s := setup(t)
	for _, r := range [][2]string{{"GET", "/api/v1/nodes"}, {"GET", "/api/v1/no-such-thing"}, {"OPTIONS", "/api/v1/admin/users"},
		{"DELETE", "/api/v1/info"}, {"GET", "/"}} {
		if st, _ := rawDo(t, c, r[0], r[1], "", nil); st != 401 {
			t.Fatalf("%s %s: %d", r[0], r[1], st)
		}
	}
	c.token = login(c, "Mac")
	c.do("GET", "/api/v1/no-such-thing", nil, 404)

	// "OPTIONS *" goes through the same checks (main sets this option too).
	ts := httptest.NewUnstartedServer(s.Handler())
	ts.Config.DisableGeneralOptionsHandler = true
	ts.Start()
	t.Cleanup(ts.Close)
	resp := rawConn(t, ts.URL, "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n")
	if resp.StatusCode != 401 || resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("OPTIONS *: %d %v", resp.StatusCode, resp.Header)
	}
}

// #24, #27, #22: failed logins are attributable, the log can be paged and filtered.
func TestAuditLog(t *testing.T) {
	c, s := setup(t)
	c.token = login(c, "Mac")
	uid, _ := myID(c)

	c.do("POST", "/api/v1/auth/login", map[string]string{"username": "ghost", "password": "x"}, 401)
	c.do("POST", "/api/v1/auth/login", map[string]string{"username": " alice", "password": "wrong"}, 401)
	all := c.do("GET", "/api/v1/audit?all=1&action=login_failed", nil, 200)["entries"].([]any)
	var sawGhost, sawAlice bool
	for _, e := range all {
		m := e.(map[string]any)
		user, _ := m["user"].(string)
		sawGhost = sawGhost || (m["detail"] == "ghost" && user == "")
		sawAlice = sawAlice || (m["detail"] == "alice" && user == "alice")
	}
	if !sawGhost || !sawAlice {
		t.Fatalf("failed logins in the admin view: %v", all)
	}

	for i := range 450 {
		s.db.Audit(uid, "", "probe", fmt.Sprintf("entry %d", i), "203.0.113.9")
	}
	s.db.Audit(uid, "", "probe", "needle", "203.0.113.9")
	page := c.do("GET", "/api/v1/audit", nil, 200)
	entries := page["entries"].([]any)
	if len(entries) != 200 || page["has_more"] != true || page["total"].(float64) < 451 {
		t.Fatalf("first page: %d entries, has_more %v, total %v", len(entries), page["has_more"], page["total"])
	}
	seen := len(entries)
	before := int(entries[len(entries)-1].(map[string]any)["id"].(float64))
	for page["has_more"] == true {
		page = c.do("GET", fmt.Sprintf("/api/v1/audit?limit=500&before=%d", before), nil, 200)
		entries = page["entries"].([]any)
		seen += len(entries)
		if len(entries) > 0 {
			before = int(entries[len(entries)-1].(map[string]any)["id"].(float64))
		}
	}
	if seen != int(page["total"].(float64)) {
		t.Fatalf("paged through %d of %v entries", seen, page["total"])
	}
	if n := len(c.do("GET", "/api/v1/audit?action=probe&limit=500", nil, 200)["entries"].([]any)); n != 451 {
		t.Fatalf("action filter: %d", n)
	}
	if got := c.do("GET", "/api/v1/audit?q=needle", nil, 200)["entries"].([]any); len(got) != 1 {
		t.Fatalf("text filter: %v", got)
	}

	c.do("POST", "/api/v1/admin/users", map[string]any{"username": "bob", "password": "bob-password-1"}, 201)
	bob := &client{t: t, base: c.base}
	bob.token = bob.do("POST", "/api/v1/auth/login", map[string]string{"username": "bob", "password": "bob-password-1", "platform": "android"}, 200)["token"].(string)
	bob.do("GET", "/api/v1/audit?all=1", nil, 403)
}

// #28: what devices do to files ends up in the log, LAN and relay alike.
func TestDataOperationsAreAudited(t *testing.T) {
	c, _ := setup(t)
	c.token = login(c, "Mac")
	_, dev := myID(c)
	c.do("POST", "/api/v1/categories", map[string]string{"name": "工作", "color": "#E5534B"}, 201)
	folder := c.do("POST", "/api/v1/nodes/folder", map[string]any{"name": "项目"}, 201)
	file := c.do("PUT", "/api/v1/files?size=1&path=a.txt", []byte("x"), 200)["node"].(map[string]any)
	fid := file["id"].(string)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]any{"name": "b.txt"}, 200)
	c.do("PATCH", "/api/v1/nodes/"+fid, map[string]any{"parent_id": folder["id"]}, 200)
	c.do("DELETE", "/api/v1/nodes/"+fid, nil, 204)
	c.do("POST", "/api/v1/trash/"+fid+"/restore", nil, 200)
	c.do("PATCH", "/api/v1/devices/"+dev, map[string]string{"name": "工作 Mac"}, 204)

	var got []string
	details := map[string]string{}
	for _, e := range c.do("GET", "/api/v1/audit", nil, 200)["entries"].([]any) {
		m := e.(map[string]any)
		got = append(got, m["action"].(string))
		details[m["action"].(string)] = m["detail"].(string)
		if m["device_id"] != dev && m["action"] != "login" {
			t.Fatalf("%s not attributed to the device: %v", m["action"], m)
		}
	}
	for _, want := range []string{"category_created", "folder_created", "file_uploaded", "renamed", "moved", "trashed", "restored", "device_renamed"} {
		if !slices.Contains(got, want) {
			t.Fatalf("%s missing from the audit log: %v", want, got)
		}
	}
	if details["renamed"] != "a.txt → b.txt" || details["moved"] != "/项目/b.txt" || details["device_renamed"] != "Mac → 工作 Mac" {
		t.Fatalf("details: %v", details)
	}
}

// The relay applies the same before-routing checks.
func TestRelayGate(t *testing.T) {
	e := setupRelay(t)
	get := func(path, auth string) int {
		req, _ := http.NewRequest("GET", e.relayURL+path, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		resp, err := e.rc.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp.StatusCode
	}
	for path, want := range map[string]int{"/r/v1/info": 200, "/r/v1/no-such-thing": 401, "/n/v1/poll": 401, "/whatever": 401} {
		if st := get(path, ""); st != want {
			t.Fatalf("%s: %d, want %d", path, st, want)
		}
	}
	if st := get("/n/v1/poll", nasToken); st != 200 {
		t.Fatalf("NAS poll with the token: %d", st)
	}
	req, _ := http.NewRequest("GET", e.relayURL+"/r/v1/info", nil)
	req.URL.RawQuery = "a=%zz"
	resp, err := e.rc.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("bad query: %d", resp.StatusCode)
	}
}

// Two NAS on one relay token (a test box next to the real one) must not
// acknowledge, and so delete, each other's operations.
func TestSecondNASKeepsItsOps(t *testing.T) {
	e := setupRelay(t)
	_, lanB := e.addNAS()
	lanB.token = login(lanB, "Mac")
	b := e.clientFrom(enrollOn(t, lanB))
	waitUntil(t, "relay to accept the second NAS's device", func() bool {
		st, _ := b.do("GET", "/r/v1/status", nil, nil)
		return st == 200
	})
	for i := range 10 {
		if r := b.await(b.send(map[string]any{"t": "ping"})); !r.OK {
			t.Fatalf("ping %d: %s", i, r.Error)
		}
	}
}
