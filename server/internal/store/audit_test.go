package store

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func onDisk(dir, needle string) bool {
	found := false
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if b, err := os.ReadFile(p); err == nil && bytes.Contains(b, []byte(needle)) {
				found = true
			}
		}
		return nil
	})
	return found
}

// A database written by an older version loses the file names in its security
// log on upgrade, including the copies in free pages.
func TestUpgradeScrubsNamesFromAuditLog(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "t.db")
	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	const name = "工资单-绝密-2026.xlsx"
	db.Audit("u", "d", "file_uploaded", "/财务/"+name, "192.0.2.1")
	db.Audit("u", "d", "renamed", "a → "+name, "192.0.2.1")
	db.Audit("u", "d", "login", "MacBook", "192.0.2.1")
	db.Exec(`DELETE FROM meta WHERE k = 'audit_scrubbed'`)
	db.TruncateWAL()
	if !onDisk(dir, name) {
		t.Fatal("test is broken: the name never reached the disk")
	}
	db.Close()

	if db, err = Open(path); err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	entries, _, _, err := db.ListAudit(AuditQuery{UserID: "u", Limit: 10})
	if err != nil || len(entries) != 3 {
		t.Fatalf("entries: %v %v", entries, err)
	}
	for _, e := range entries {
		if want := map[string]string{"login": "MacBook"}[e.Action]; e.Detail != want {
			t.Fatalf("%s: detail %q", e.Action, e.Detail)
		}
	}
	if onDisk(dir, name) {
		t.Fatal("the file name is still readable in the database files")
	}
}
