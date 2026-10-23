package store

import (
	"database/sql"
	"errors"
)

// Upload is a resumable upload session; its blob lives in the temp area under
// the same id until it is completed.
type Upload struct {
	ID         string `json:"id"`
	UserID     string `json:"-"`
	DeviceID   string `json:"-"`
	ParentID   string `json:"parent_id"`
	RelPath    string `json:"path"`
	Size       int64  `json:"size"`
	Received   int64  `json:"received"`
	HashState  []byte `json:"-"`
	Enc        bool   `json:"-"`
	CategoryID string `json:"category_id,omitempty"`
	Timeline   bool   `json:"timeline"`
	MTime      int64  `json:"mtime"`
	Conflict   string `json:"conflict"`
	CreatedAt  int64  `json:"created_at"`
	UpdatedAt  int64  `json:"updated_at"`
}

const uploadCols = `id, user_id, device_id, parent_id, rel_path, size, received, hash_state, enc,
	COALESCE(category_id, ''), timeline, mtime, conflict, created_at, updated_at`

func (db *DB) CreateUpload(u *Upload) error {
	now := Now()
	u.CreatedAt, u.UpdatedAt = now, now
	var cat any
	if u.CategoryID != "" {
		cat = u.CategoryID
	}
	_, err := db.Exec(`INSERT INTO uploads(id, user_id, device_id, parent_id, rel_path, size, received, hash_state, enc,
		category_id, timeline, mtime, conflict, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		u.ID, u.UserID, u.DeviceID, u.ParentID, u.RelPath, u.Size, u.Received, u.HashState, boolInt(u.Enc),
		cat, boolInt(u.Timeline), u.MTime, u.Conflict, now, now)
	return err
}

func (db *DB) Upload(userID, id string) (Upload, error) {
	var u Upload
	var enc, tl int
	err := db.QueryRow(`SELECT `+uploadCols+` FROM uploads WHERE id = ? AND user_id = ?`, id, userID).Scan(
		&u.ID, &u.UserID, &u.DeviceID, &u.ParentID, &u.RelPath, &u.Size, &u.Received, &u.HashState, &enc,
		&u.CategoryID, &tl, &u.MTime, &u.Conflict, &u.CreatedAt, &u.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	u.Enc, u.Timeline = enc == 1, tl == 1
	return u, err
}

// SetUploadProgress records progress; it only succeeds if received was still
// `from`, which keeps two concurrent PUTs for one upload from both applying.
func (db *DB) SetUploadProgress(id string, from, received int64, hashState []byte) error {
	res, err := db.Exec(`UPDATE uploads SET received = ?, hash_state = ?, updated_at = ? WHERE id = ? AND received = ?`,
		received, hashState, Now(), id, from)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrConflict
	}
	return nil
}

func (db *DB) DeleteUpload(id string) error {
	_, err := db.Exec(`DELETE FROM uploads WHERE id = ?`, id)
	return err
}

// StaleUploads returns uploads not touched since before.
func (db *DB) StaleUploads(before int64) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM uploads WHERE updated_at < ?`, before)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
