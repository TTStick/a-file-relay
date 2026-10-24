// Package store keeps all metadata (users, devices, categories, the file tree,
// in-flight uploads) in SQLite. File contents live in package blob.
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("name already exists")
	ErrInvalid  = errors.New("invalid argument")
)

type DB struct {
	*sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS users (
	id            TEXT PRIMARY KEY,
	username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
	password_hash TEXT NOT NULL,
	is_admin      INTEGER NOT NULL DEFAULT 0,
	root_id       TEXT NOT NULL,
	created_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
	id           TEXT PRIMARY KEY,
	user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	name         TEXT NOT NULL,
	platform     TEXT NOT NULL DEFAULT '',
	token_hash   TEXT NOT NULL UNIQUE,
	created_at   INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL,
	last_ip      TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS categories (
	id         TEXT PRIMARY KEY,
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	name       TEXT NOT NULL,
	color      TEXT NOT NULL DEFAULT '#4F7CFF',
	icon       TEXT NOT NULL DEFAULT '',
	sort       INTEGER NOT NULL DEFAULT 0,
	folder_id  TEXT,
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS categories_user ON categories(user_id, sort);

CREATE TABLE IF NOT EXISTS nodes (
	id          TEXT PRIMARY KEY,
	user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	parent_id   TEXT,
	name        TEXT NOT NULL,
	is_dir      INTEGER NOT NULL,
	size        INTEGER NOT NULL DEFAULT 0,
	mime        TEXT NOT NULL DEFAULT '',
	sha256      TEXT NOT NULL DEFAULT '',
	blob        TEXT NOT NULL DEFAULT '',
	enc         INTEGER NOT NULL DEFAULT 0,
	category_id TEXT,
	timeline    INTEGER NOT NULL DEFAULT 0,
	device_id   TEXT NOT NULL DEFAULT '',
	device_name TEXT NOT NULL DEFAULT '',
	mtime       INTEGER NOT NULL,
	created_at  INTEGER NOT NULL,
	updated_at  INTEGER NOT NULL,
	trash_id    TEXT,
	trashed_at  INTEGER,
	trash_root  INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS nodes_unique_name ON nodes(parent_id, name COLLATE NOCASE) WHERE trash_id IS NULL;
CREATE INDEX IF NOT EXISTS nodes_parent   ON nodes(parent_id);
CREATE INDEX IF NOT EXISTS nodes_timeline ON nodes(user_id, created_at) WHERE timeline = 1 AND trash_id IS NULL;
CREATE INDEX IF NOT EXISTS nodes_category ON nodes(category_id, created_at) WHERE trash_id IS NULL;
CREATE INDEX IF NOT EXISTS nodes_trash    ON nodes(user_id, trash_id);

CREATE TABLE IF NOT EXISTS uploads (
	id          TEXT PRIMARY KEY,
	user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	device_id   TEXT NOT NULL,
	parent_id   TEXT NOT NULL,
	rel_path    TEXT NOT NULL,
	size        INTEGER NOT NULL,
	received    INTEGER NOT NULL DEFAULT 0,
	hash_state  BLOB,
	enc         INTEGER NOT NULL,
	category_id TEXT,
	timeline    INTEGER NOT NULL,
	mtime       INTEGER NOT NULL,
	conflict    TEXT NOT NULL,
	created_at  INTEGER NOT NULL,
	updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audit (
	id        INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id   TEXT NOT NULL DEFAULT '',
	device_id TEXT NOT NULL DEFAULT '',
	action    TEXT NOT NULL,
	detail    TEXT NOT NULL DEFAULT '',
	ip        TEXT NOT NULL DEFAULT '',
	at        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_user ON audit(user_id, at);
`

func Open(path string) (*DB, error) {
	dsn := "file:" + path +
		"?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)" +
		"&_pragma=synchronous(NORMAL)&_txlock=immediate"
	sdb, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	sdb.SetMaxOpenConns(8)
	if _, err := sdb.Exec(schema); err != nil {
		sdb.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	db := &DB{sdb}
	if err := db.migrateRelay(); err != nil {
		sdb.Close()
		return nil, fmt.Errorf("migrate relay: %w", err)
	}
	return db, nil
}

var idEnc = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

// NewID returns a random 128-bit identifier (26 chars).
func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return idEnc.EncodeToString(b)
}

func Now() int64 { return time.Now().UnixMilli() }

func (db *DB) Meta(key string) (string, error) {
	var v string
	err := db.QueryRow(`SELECT v FROM meta WHERE k = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

func (db *DB) SetMeta(key, val string) error {
	_, err := db.Exec(`INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v`, key, val)
	return err
}

func (db *DB) tx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

func isUniqueErr(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// --- audit ---

type AuditEntry struct {
	ID       int64  `json:"id"`
	User     string `json:"user,omitempty"` // only in the all-users view; "" = no account matched
	DeviceID string `json:"device_id"`
	Action   string `json:"action"`
	Detail   string `json:"detail"`
	IP       string `json:"ip"`
	At       int64  `json:"at"`
}

func (db *DB) Audit(userID, deviceID, action, detail, ip string) {
	db.Exec(`INSERT INTO audit(user_id, device_id, action, detail, ip, at) VALUES(?,?,?,?,?,?)`,
		userID, deviceID, action, detail, ip, Now())
}

// AuditQuery picks audit entries, newest first.
type AuditQuery struct {
	UserID string
	All    bool   // every user, plus entries that matched no account (admins)
	Action string // exact action
	Text   string // substring of the action, detail or IP
	Before int64  // only entries with a smaller id (paging); 0 = from the newest
	Limit  int
}

// ListAudit returns one page of entries, the number of entries matching the
// filter in total, and whether there are older ones after this page.
func (db *DB) ListAudit(q AuditQuery) ([]AuditEntry, int, bool, error) {
	var where []string
	var args []any
	if !q.All {
		where = append(where, "a.user_id = ?")
		args = append(args, q.UserID)
	}
	if q.Action != "" {
		where = append(where, "a.action = ?")
		args = append(args, q.Action)
	}
	if q.Text != "" {
		like := "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q.Text) + "%"
		where = append(where, `(a.action LIKE ? ESCAPE '\' OR a.detail LIKE ? ESCAPE '\' OR a.ip LIKE ? ESCAPE '\')`)
		args = append(args, like, like, like)
	}
	cond := ""
	if len(where) > 0 {
		cond = " WHERE " + strings.Join(where, " AND ")
	}
	var total int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit a`+cond, args...).Scan(&total); err != nil {
		return nil, 0, false, err
	}
	if q.Before > 0 {
		if cond == "" {
			cond = " WHERE a.id < ?"
		} else {
			cond += " AND a.id < ?"
		}
		args = append(args, q.Before)
	}
	rows, err := db.Query(`SELECT a.id, COALESCE(u.username, ''), a.device_id, a.action, a.detail, a.ip, a.at
		FROM audit a LEFT JOIN users u ON u.id = a.user_id`+cond+` ORDER BY a.id DESC LIMIT ?`, append(args, q.Limit+1)...)
	if err != nil {
		return nil, 0, false, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.ID, &e.User, &e.DeviceID, &e.Action, &e.Detail, &e.IP, &e.At); err != nil {
			return nil, 0, false, err
		}
		if !q.All {
			e.User = ""
		}
		out = append(out, e)
	}
	more := len(out) > q.Limit
	if more {
		out = out[:q.Limit]
	}
	return out, total, more, rows.Err()
}

func (db *DB) PruneAudit(olderThan int64) {
	db.Exec(`DELETE FROM audit WHERE at < ?`, olderThan)
}
