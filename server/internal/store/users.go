package store

import (
	"context"
	"database/sql"
	"errors"
)

type User struct {
	ID           string `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"`
	IsAdmin      bool   `json:"is_admin"`
	RootID       string `json:"root_id"`
	CreatedAt    int64  `json:"created_at"`
}

type Device struct {
	ID         string `json:"id"`
	UserID     string `json:"-"`
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	CreatedAt  int64  `json:"created_at"`
	LastSeenAt int64  `json:"last_seen_at"`
	LastIP     string `json:"last_ip"`
	Relay      bool   `json:"relay"`  // enrolled for access through the relay
	Remote     bool   `json:"remote"` // relay only (paired with a code, no LAN login)
}

const userCols = `id, username, password_hash, is_admin, root_id, created_at`

func scanUser(row interface{ Scan(...any) error }) (User, error) {
	var u User
	var admin int
	err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &admin, &u.RootID, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	u.IsAdmin = admin == 1
	return u, err
}

func (db *DB) CountUsers() (int, error) {
	var n int
	err := db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

// CreateUser creates the user together with the root folder of their space.
func (db *DB) CreateUser(username, passwordHash string, admin bool) (User, error) {
	now := Now()
	u := User{ID: NewID(), Username: username, PasswordHash: passwordHash, IsAdmin: admin, RootID: NewID(), CreatedAt: now}
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO users(`+userCols+`) VALUES(?,?,?,?,?,?)`,
			u.ID, u.Username, u.PasswordHash, boolInt(admin), u.RootID, now); err != nil {
			if isUniqueErr(err) {
				return ErrConflict
			}
			return err
		}
		_, err := tx.Exec(`INSERT INTO nodes(id, user_id, parent_id, name, is_dir, mtime, created_at, updated_at)
			VALUES(?, ?, NULL, '', 1, ?, ?, ?)`, u.RootID, u.ID, now, now, now)
		return err
	})
	return u, err
}

func (db *DB) UserByName(name string) (User, error) {
	return scanUser(db.QueryRow(`SELECT `+userCols+` FROM users WHERE username = ?`, name))
}

func (db *DB) User(id string) (User, error) {
	return scanUser(db.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
}

func (db *DB) ListUsers() ([]User, error) {
	rows, err := db.Query(`SELECT ` + userCols + ` FROM users ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (db *DB) SetPassword(userID, hash string) error {
	res, err := db.Exec(`UPDATE users SET password_hash = ? WHERE id = ?`, hash, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (db *DB) SetAdmin(userID string, admin bool) error {
	_, err := db.Exec(`UPDATE users SET is_admin = ? WHERE id = ?`, boolInt(admin), userID)
	return err
}

// DeleteUser removes the user and everything they own; it returns the blob ids
// that must be removed from disk.
func (db *DB) DeleteUser(userID string) ([]string, error) {
	var blobs []string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		rows, err := tx.Query(`SELECT blob FROM nodes WHERE user_id = ? AND blob != ''`, userID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var b string
			rows.Scan(&b)
			blobs = append(blobs, b)
		}
		rows.Close()
		for _, q := range []string{
			`DELETE FROM nodes WHERE user_id = ?`,
			`DELETE FROM uploads WHERE user_id = ?`,
			`DELETE FROM categories WHERE user_id = ?`,
			`DELETE FROM devices WHERE user_id = ?`,
		} {
			if _, err := tx.Exec(q, userID); err != nil {
				return err
			}
		}
		res, err := tx.Exec(`DELETE FROM users WHERE id = ?`, userID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrNotFound
		}
		return nil
	})
	return blobs, err
}

// --- devices ---

const deviceCols = `id, user_id, name, platform, created_at, last_seen_at, last_ip, (relay_key IS NOT NULL), remote`

func scanDevice(row interface{ Scan(...any) error }) (Device, error) {
	var d Device
	var relay, remote int
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &d.LastIP, &relay, &remote)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrNotFound
	}
	d.Relay, d.Remote = relay == 1, remote == 1
	return d, err
}

func (db *DB) CreateDevice(userID, name, platform, tokenHash, ip string) (Device, error) {
	now := Now()
	d := Device{ID: NewID(), UserID: userID, Name: name, Platform: platform, CreatedAt: now, LastSeenAt: now, LastIP: ip}
	_, err := db.Exec(`INSERT INTO devices(id, user_id, name, platform, token_hash, created_at, last_seen_at, last_ip)
		VALUES(?,?,?,?,?,?,?,?)`, d.ID, userID, name, platform, tokenHash, now, now, ip)
	return d, err
}

func (db *DB) DeviceByToken(tokenHash string) (Device, error) {
	return scanDevice(db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE token_hash = ?`, tokenHash))
}

func (db *DB) Device(id string) (Device, error) {
	return scanDevice(db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE id = ?`, id))
}

func (db *DB) TouchDevice(id, ip string) {
	db.Exec(`UPDATE devices SET last_seen_at = ?, last_ip = ? WHERE id = ?`, Now(), ip, id)
}

func (db *DB) ListDevices(userID string) ([]Device, error) {
	rows, err := db.Query(`SELECT `+deviceCols+` FROM devices WHERE user_id = ? ORDER BY last_seen_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (db *DB) RenameDevice(userID, id, name string) error {
	res, err := db.Exec(`UPDATE devices SET name = ? WHERE id = ? AND user_id = ?`, name, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

func (db *DB) DeleteDevice(userID, id string) error {
	res, err := db.Exec(`DELETE FROM devices WHERE id = ? AND user_id = ?`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteDevicesExcept signs out every device of the user except keepID.
func (db *DB) DeleteDevicesExcept(userID, keepID string) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM devices WHERE user_id = ? AND id != ?`, userID, keepID)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	rows.Close()
	_, err = db.Exec(`DELETE FROM devices WHERE user_id = ? AND id != ?`, userID, keepID)
	return ids, err
}
