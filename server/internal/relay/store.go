package relay

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// The relay's database holds only opaque data: envelopes, encrypted
// snapshots, token hashes and blob bookkeeping.
const schema = `
CREATE TABLE IF NOT EXISTS devices (
	token_hash TEXT PRIMARY KEY,
	space      TEXT NOT NULL,
	device_id  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_space ON devices(space);

CREATE TABLE IF NOT EXISTS ops (
	seq       INTEGER PRIMARY KEY AUTOINCREMENT,
	space     TEXT NOT NULL,
	device_id TEXT NOT NULL,
	op_id     TEXT NOT NULL,
	body      TEXT NOT NULL,
	created   INTEGER NOT NULL,
	UNIQUE(space, device_id, op_id)
);

CREATE TABLE IF NOT EXISTS replies (
	seq       INTEGER PRIMARY KEY AUTOINCREMENT,
	space     TEXT NOT NULL,
	device_id TEXT NOT NULL,
	op_id     TEXT NOT NULL,
	body      TEXT NOT NULL,
	created   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS replies_dev ON replies(space, device_id, seq);

CREATE TABLE IF NOT EXISTS snapshots (
	space   TEXT PRIMARY KEY,
	version INTEGER NOT NULL,
	data    BLOB NOT NULL,
	updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS keyrings (
	space     TEXT NOT NULL,
	device_id TEXT NOT NULL,
	body      TEXT NOT NULL,
	PRIMARY KEY(space, device_id)
);

CREATE TABLE IF NOT EXISTS blobs (
	id        TEXT PRIMARY KEY,
	space     TEXT NOT NULL,
	device_id TEXT NOT NULL DEFAULT '',
	kind      TEXT NOT NULL,          -- 'up' (client → NAS) or 'cache' (NAS → clients)
	cache_key TEXT NOT NULL DEFAULT '',
	size      INTEGER NOT NULL,
	received  INTEGER NOT NULL DEFAULT 0,
	created   INTEGER NOT NULL,
	updated   INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS blobs_cache ON blobs(space, cache_key) WHERE kind = 'cache';

CREATE TABLE IF NOT EXISTS pairs (
	lookup  TEXT PRIMARY KEY,
	req     TEXT NOT NULL DEFAULT '',
	resp    TEXT NOT NULL DEFAULT '',
	created INTEGER NOT NULL
);
`

var errNotFound = errors.New("not found")

type db struct{ *sql.DB }

func openDB(path string) (*db, error) {
	s, err := sql.Open("sqlite", "file:"+path+
		"?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_txlock=immediate")
	if err != nil {
		return nil, err
	}
	s.SetMaxOpenConns(8)
	if _, err := s.Exec(schema); err != nil {
		s.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &db{s}, nil
}

func now() int64 { return time.Now().UnixMilli() }

type blobRow struct {
	ID, Space, Device, Kind, CacheKey string
	Size, Received, Created, Updated  int64
}

const blobCols = `id, space, device_id, kind, cache_key, size, received, created, updated`

func scanBlob(row interface{ Scan(...any) error }) (blobRow, error) {
	var b blobRow
	err := row.Scan(&b.ID, &b.Space, &b.Device, &b.Kind, &b.CacheKey, &b.Size, &b.Received, &b.Created, &b.Updated)
	if errors.Is(err, sql.ErrNoRows) {
		return b, errNotFound
	}
	return b, err
}

func (d *db) blob(id string) (blobRow, error) {
	return scanBlob(d.QueryRow(`SELECT `+blobCols+` FROM blobs WHERE id = ?`, id))
}

func (d *db) cacheBlob(space, key string) (blobRow, error) {
	return scanBlob(d.QueryRow(`SELECT `+blobCols+` FROM blobs WHERE space = ? AND kind = 'cache' AND cache_key = ?`, space, key))
}

func (d *db) spaceUsage(space string) int64 {
	var n int64
	d.QueryRow(`SELECT COALESCE(SUM(size), 0) FROM blobs WHERE space = ?`, space).Scan(&n)
	return n
}
