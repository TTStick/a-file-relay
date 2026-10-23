package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// Relay-mode state. Secret keys are stored sealed by the caller (with the
// at-rest master key); this layer only keeps bytes.

const relaySchema = `
CREATE TABLE IF NOT EXISTS space_keys (
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kid        INTEGER NOT NULL,
	key        BLOB NOT NULL,
	created_at INTEGER NOT NULL,
	PRIMARY KEY(user_id, kid)
);
CREATE TABLE IF NOT EXISTS pairings (
	lookup     TEXT PRIMARY KEY,
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	key        BLOB NOT NULL,
	expires_at INTEGER NOT NULL,
	created_by TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS relay_seen (
	device_id TEXT NOT NULL,
	op_id     TEXT NOT NULL,
	at        INTEGER NOT NULL,
	PRIMARY KEY(device_id, op_id)
);
CREATE TABLE IF NOT EXISTS relay_cache (
	user_id      TEXT NOT NULL,
	cache_key    TEXT NOT NULL,
	node_id      TEXT NOT NULL,
	kid          INTEGER NOT NULL,
	size         INTEGER NOT NULL,
	pinned_until INTEGER NOT NULL DEFAULT 0,
	at           INTEGER NOT NULL,
	PRIMARY KEY(user_id, cache_key)
);
`

func (db *DB) addColumn(table, col, def string) error {
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?`, table, col).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	_, err := db.Exec(fmt.Sprintf(`ALTER TABLE %s ADD COLUMN %s %s`, table, col, def))
	return err
}

func (db *DB) migrateRelay() error {
	for _, c := range [][3]string{
		{"users", "relay_space", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "relay_key", "BLOB"},
		{"devices", "relay_token_hash", "TEXT NOT NULL DEFAULT ''"},
		{"devices", "remote", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := db.addColumn(c[0], c[1], c[2]); err != nil {
			return err
		}
	}
	_, err := db.Exec(relaySchema)
	return err
}

// EnsureRelaySpace returns the user's opaque relay space id, creating it once.
func (db *DB) EnsureRelaySpace(userID string) (string, error) {
	var sp string
	if err := db.QueryRow(`SELECT relay_space FROM users WHERE id = ?`, userID).Scan(&sp); err != nil {
		return "", ErrNotFound
	}
	if sp != "" {
		return sp, nil
	}
	sp = NewID()
	_, err := db.Exec(`UPDATE users SET relay_space = ? WHERE id = ? AND relay_space = ''`, sp, userID)
	if err != nil {
		return "", err
	}
	return db.relaySpace(userID)
}

func (db *DB) relaySpace(userID string) (string, error) {
	var sp string
	err := db.QueryRow(`SELECT relay_space FROM users WHERE id = ?`, userID).Scan(&sp)
	return sp, err
}

func (db *DB) UserBySpace(space string) (User, error) {
	if space == "" {
		return User{}, ErrNotFound
	}
	return scanUser(db.QueryRow(`SELECT `+userCols+` FROM users WHERE relay_space = ?`, space))
}

// RelaySpaces maps relay space id → user for every user that has one.
func (db *DB) RelaySpaces() (map[string]User, error) {
	rows, err := db.Query(`SELECT relay_space, ` + userCols + ` FROM users WHERE relay_space != ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]User{}
	for rows.Next() {
		var sp string
		var u User
		var admin int
		if err := rows.Scan(&sp, &u.ID, &u.Username, &u.PasswordHash, &admin, &u.RootID, &u.CreatedAt); err != nil {
			return nil, err
		}
		u.IsAdmin = admin == 1
		out[sp] = u
	}
	return out, rows.Err()
}

type SpaceKey struct {
	Kid    uint32
	Sealed []byte
}

func (db *DB) SpaceKeys(userID string) ([]SpaceKey, error) {
	rows, err := db.Query(`SELECT kid, key FROM space_keys WHERE user_id = ? ORDER BY kid`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SpaceKey
	for rows.Next() {
		var k SpaceKey
		if err := rows.Scan(&k.Kid, &k.Sealed); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (db *DB) AddSpaceKey(userID string, kid uint32, sealed []byte) error {
	_, err := db.Exec(`INSERT INTO space_keys(user_id, kid, key, created_at) VALUES(?,?,?,?)`, userID, kid, sealed, Now())
	return err
}

// RelayDevice is a device enrolled for relay access.
type RelayDevice struct {
	Device
	SealedKey []byte
	TokenHash string
}

func (db *DB) RelayDevices(userID string) ([]RelayDevice, error) {
	rows, err := db.Query(`SELECT `+deviceCols+`, relay_key, relay_token_hash FROM devices
		WHERE user_id = ? AND relay_key IS NOT NULL ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RelayDevice
	for rows.Next() {
		var d RelayDevice
		var relay, remote int
		if err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &d.LastIP, &relay, &remote,
			&d.SealedKey, &d.TokenHash); err != nil {
			return nil, err
		}
		d.Relay, d.Remote = relay == 1, remote == 1
		out = append(out, d)
	}
	return out, rows.Err()
}

func (db *DB) RelayDevice(id string) (RelayDevice, error) {
	var d RelayDevice
	var relay, remote int
	err := db.QueryRow(`SELECT `+deviceCols+`, relay_key, relay_token_hash FROM devices WHERE id = ? AND relay_key IS NOT NULL`, id).
		Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &d.LastIP, &relay, &remote, &d.SealedKey, &d.TokenHash)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrNotFound
	}
	d.Relay, d.Remote = relay == 1, remote == 1
	return d, err
}

func (db *DB) SetDeviceRelay(deviceID string, sealedKey []byte, tokenHash string) error {
	res, err := db.Exec(`UPDATE devices SET relay_key = ?, relay_token_hash = ? WHERE id = ?`, sealedKey, tokenHash, deviceID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// CreateRemoteDevice adds a device that exists only through the relay (paired
// with a code); it has no LAN token.
func (db *DB) CreateRemoteDevice(userID, name, platform string, sealedKey []byte, tokenHash string) (Device, error) {
	t := Now()
	d := Device{ID: NewID(), UserID: userID, Name: name, Platform: platform, CreatedAt: t, LastSeenAt: t, Relay: true, Remote: true}
	_, err := db.Exec(`INSERT INTO devices(id, user_id, name, platform, token_hash, created_at, last_seen_at, last_ip,
		relay_key, relay_token_hash, remote) VALUES(?,?,?,?,?,?,?,?,?,?,1)`,
		d.ID, userID, name, platform, "remote:"+NewID(), t, t, "relay", sealedKey, tokenHash)
	return d, err
}

func (db *DB) CreatePairing(lookup, userID string, sealedKey []byte, expires int64, by string) error {
	_, err := db.Exec(`INSERT INTO pairings(lookup, user_id, key, expires_at, created_by) VALUES(?,?,?,?,?)`,
		lookup, userID, sealedKey, expires, by)
	return err
}

// TakePairing consumes a pairing (single use). Expired pairings are not found.
func (db *DB) TakePairing(lookup string) (userID string, sealedKey []byte, err error) {
	err = db.tx(context.Background(), func(tx *sql.Tx) error {
		var exp int64
		if err := tx.QueryRow(`SELECT user_id, key, expires_at FROM pairings WHERE lookup = ?`, lookup).Scan(&userID, &sealedKey, &exp); err != nil {
			return ErrNotFound
		}
		if _, err := tx.Exec(`DELETE FROM pairings WHERE lookup = ?`, lookup); err != nil {
			return err
		}
		if exp < Now() {
			return ErrNotFound
		}
		return nil
	})
	return
}

func (db *DB) PrunePairings() {
	db.Exec(`DELETE FROM pairings WHERE expires_at < ?`, Now())
}

// MarkOpSeen records an op id; it reports false if the op was already seen (replay).
func (db *DB) MarkOpSeen(deviceID, opID string) (bool, error) {
	res, err := db.Exec(`INSERT INTO relay_seen(device_id, op_id, at) VALUES(?,?,?) ON CONFLICT DO NOTHING`, deviceID, opID, Now())
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n == 1, nil
}

func (db *DB) PruneSeen(before int64) {
	db.Exec(`DELETE FROM relay_seen WHERE at < ?`, before)
}

type CacheEntry struct {
	Key         string
	NodeID      string
	Kid         uint32
	Size        int64
	PinnedUntil int64
}

func (db *DB) RelayCache(userID string) (map[string]CacheEntry, error) {
	rows, err := db.Query(`SELECT cache_key, node_id, kid, size, pinned_until FROM relay_cache WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]CacheEntry{}
	for rows.Next() {
		var e CacheEntry
		if err := rows.Scan(&e.Key, &e.NodeID, &e.Kid, &e.Size, &e.PinnedUntil); err != nil {
			return nil, err
		}
		out[e.Key] = e
	}
	return out, rows.Err()
}

func (db *DB) PutRelayCache(userID string, e CacheEntry) error {
	_, err := db.Exec(`INSERT INTO relay_cache(user_id, cache_key, node_id, kid, size, pinned_until, at) VALUES(?,?,?,?,?,?,?)
		ON CONFLICT(user_id, cache_key) DO UPDATE SET pinned_until = MAX(pinned_until, excluded.pinned_until), at = excluded.at`,
		userID, e.Key, e.NodeID, e.Kid, e.Size, e.PinnedUntil, Now())
	return err
}

func (db *DB) DeleteRelayCache(userID, key string) error {
	_, err := db.Exec(`DELETE FROM relay_cache WHERE user_id = ? AND cache_key = ?`, userID, key)
	return err
}

// AllNodes lists every live node of the user (including the root).
func (db *DB) AllNodes(userID string) ([]Node, error) {
	return scanNodes(db.Query(`SELECT `+nodeCols+` FROM nodes n WHERE n.user_id = ? AND n.trash_id IS NULL
		ORDER BY n.parent_id, n.name`, userID))
}
