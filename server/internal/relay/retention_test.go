package relay

import (
	"bytes"
	"io/fs"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const nasToken = "test-nas-token-0123456789abcdefghijklmnop"

func testRelay(t *testing.T) (*Server, *bytes.Buffer) {
	t.Helper()
	var logs bytes.Buffer
	log := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	s, err := New(&Config{DataDir: t.TempDir(), NASToken: nasToken, MaxFile: 1 << 20, Quota: 1 << 30, Retention: time.Hour}, log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	logs.Reset()
	return s, &logs
}

// onDisk reports whether any file of the relay's data directory contains needle.
func onDisk(t *testing.T, s *Server, needle string) bool {
	t.Helper()
	found := false
	filepath.WalkDir(s.cfg.DataDir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if b, err := os.ReadFile(p); err == nil && bytes.Contains(b, []byte(needle)) {
				t.Logf("found in %s", p)
				found = true
			}
		}
		return nil
	})
	return found
}

func TestDeletedRowsLeaveNothingOnDisk(t *testing.T) {
	s, _ := testRelay(t)
	const needle = "ENVELOPE-THAT-MUST-NOT-SURVIVE"
	body := strings.Repeat(needle, 40)
	for _, q := range []string{
		`INSERT INTO ops(space, device_id, op_id, body, created) VALUES('sp','dev','op1',?,1)`,
		`INSERT INTO replies(space, device_id, op_id, body, created) VALUES('sp','dev','op1',?,1)`,
		`INSERT INTO pending(blob_id, space, device_id, kid, meta, created) VALUES('b','sp','dev',1,?,1)`,
	} {
		if _, err := s.db.Exec(q, body); err != nil {
			t.Fatal(err)
		}
	}
	s.db.truncateWAL() // force it into the main file first: that's the harder case
	if !onDisk(t, s, needle) {
		t.Fatal("test is broken: the rows never reached the disk")
	}
	for _, q := range []string{`DELETE FROM ops`, `DELETE FROM replies`, `DELETE FROM pending`} {
		s.db.Exec(q)
	}
	s.sweep(time.Now())
	if onDisk(t, s, needle) {
		t.Fatal("deleted rows are still readable in the database files")
	}
	if st, err := os.Stat(filepath.Join(s.cfg.DataDir, "relay.db-wal")); err == nil && st.Size() != 0 {
		t.Fatalf("write-ahead log not emptied: %d bytes", st.Size())
	}
}

func TestEverythingInTransitExpires(t *testing.T) {
	s, _ := testRelay(t)
	s.db.Exec(`INSERT INTO devices(token_hash, space, device_id) VALUES(?, 'sp', 'dev')`, tokenHash("tok"))
	h := s.Handler()
	put := func(id, offset, data string) int {
		req := httptest.NewRequest("PUT", "/r/v1/blobs/"+id+"?offset="+offset, strings.NewReader(data))
		req.Header.Set("Authorization", "Bearer tok")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	old, err := s.reserve("sp", "dev", "up", "", 4)
	if err != nil {
		t.Fatal(err)
	}
	fresh, _ := s.reserve("sp", "dev", "up", "", 4)
	cache, _ := s.reserve("sp", "", "cache", "k", 4)
	for _, id := range []string{old, fresh} {
		if c := put(id, "0", "abcd"); c != 200 {
			t.Fatalf("put: %d", c)
		}
	}
	stale := time.Now().Add(-2 * time.Hour).UnixMilli()
	s.db.Exec(`UPDATE blobs SET updated = ? WHERE id IN (?, ?)`, stale, old, cache)

	// a client can't keep a finished upload alive by re-sending nothing
	if c := put(old, "4", ""); c != 200 {
		t.Fatalf("empty put: %d", c)
	}
	if b, _ := s.db.blob(old); b.Updated != stale {
		t.Fatal("empty write restarted the retention clock")
	}

	for _, q := range []string{
		`INSERT INTO ops(space, device_id, op_id, body, created) VALUES('sp','dev','o','{}',?)`,
		`INSERT INTO replies(space, device_id, op_id, body, created) VALUES('sp','dev','o','{}',?)`,
	} {
		s.db.Exec(q, stale)
	}
	s.db.Exec(`INSERT INTO pending(blob_id, space, device_id, kid, meta, created) VALUES(?,'sp','dev',1,'{}',?)`, old, stale)
	s.sweep(time.Now())

	for _, id := range []string{old, cache} {
		if _, err := s.db.blob(id); err == nil {
			t.Fatalf("blob %s outlived the retention period", id)
		}
	}
	for _, table := range []string{"ops", "replies", "pending"} {
		var n int
		s.db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n)
		if n != 0 {
			t.Fatalf("%s: %d rows left", table, n)
		}
	}
	if _, err := s.db.blob(fresh); err != nil {
		t.Fatal("a fresh upload was removed")
	}
	s.wipeMu.Lock() // wait for the background wipes
	s.wipeMu.Unlock()
}

func TestWipeOverwritesAndWaitsForTransfers(t *testing.T) {
	s, _ := testRelay(t)
	id := "aaaaaaaaaaaaaaaaaaaaaaaaaa"
	path := s.blobPath(id)
	content := bytes.Repeat([]byte("ciphertext"), 300000)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
	// a second name for the same inode lets us look at the bytes after the unlink
	if err := os.Link(path, path+".inode"); err != nil {
		t.Fatal(err)
	}
	unpin := s.pin(id)
	s.wipe(id)
	if b, _ := os.ReadFile(path); !bytes.Equal(b, content) {
		t.Fatal("wiped a file that was still being transferred")
	}
	unpin()
	s.wipe(id)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("file still there after the wipe")
	}
	b, _ := os.ReadFile(path + ".inode")
	if len(b) != len(content) || bytes.Count(b, []byte{0}) != len(b) {
		t.Fatal("bytes were not overwritten")
	}
}

func TestOrphanFilesAreWiped(t *testing.T) {
	s, _ := testRelay(t)
	orphan, young := s.blobPath("orphan"), s.blobPath("young")
	os.WriteFile(orphan, []byte("x"), 0o600)
	os.WriteFile(young, []byte("x"), 0o600)
	kept, err := s.reserve("sp", "dev", "up", "", 4)
	if err != nil {
		t.Fatal(err)
	}
	long := time.Now().Add(-5 * time.Minute)
	os.Chtimes(orphan, long, long)
	os.Chtimes(s.blobPath(kept), long, long)
	s.sweep(time.Now())
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatal("orphan left on disk")
	}
	if _, err := os.Stat(young); err != nil {
		t.Fatal("a file that may be mid-reservation was removed")
	}
	if _, err := os.Stat(s.blobPath(kept)); err != nil {
		t.Fatal("a live blob was removed")
	}
}

// The relay writes nothing per request: no paths, ids or addresses, whatever happens.
func TestRequestsLeaveNoLogLines(t *testing.T) {
	s, logs := testRelay(t)
	h := s.Handler()
	for _, tc := range []struct{ method, path, auth string }{
		{"GET", "/n/v1/poll", "Bearer wrong"},
		{"GET", "/n/v1/blobs/aaaaaaaaaaaaaaaaaaaaaaaaaa", "Bearer " + nasToken},
		{"GET", "/r/v1/pending", ""},
		{"GET", "/r/v1/info", ""},
		{"GET", "/no/such/path", "Bearer " + nasToken},
	} {
		req := httptest.NewRequest(tc.method, tc.path, nil)
		req.RemoteAddr = "203.0.113.7:4242"
		if tc.auth != "" {
			req.Header.Set("Authorization", tc.auth)
		}
		h.ServeHTTP(httptest.NewRecorder(), req)
	}
	if logs.Len() != 0 {
		t.Fatalf("requests were logged:\n%s", logs)
	}

	// an internal failure says what broke, not which request or blob
	req := httptest.NewRequest("GET", "/r/v1/pending/secretblobid", nil)
	s.fail(httptest.NewRecorder(), req, &os.PathError{Op: "open", Path: "/data/blobs/secretblobid", Err: syscall.ENOSPC})
	if out := logs.String(); strings.Contains(out, "secretblobid") || !strings.Contains(out, "no space left") {
		t.Fatalf("failure log: %s", out)
	}
}
