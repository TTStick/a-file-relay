package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strings"
	"unicode/utf8"
)

// Node is a file or folder in a user's exchange space.
type Node struct {
	ID         string `json:"id"`
	ParentID   string `json:"parent_id"`
	Name       string `json:"name"`
	IsDir      bool   `json:"is_dir"`
	Size       int64  `json:"size"`
	Mime       string `json:"mime,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	CategoryID string `json:"category_id,omitempty"`
	Timeline   bool   `json:"timeline"`
	DeviceID   string `json:"device_id,omitempty"`
	DeviceName string `json:"device_name,omitempty"`
	MTime      int64  `json:"mtime"`
	CreatedAt  int64  `json:"created_at"`
	UpdatedAt  int64  `json:"updated_at"`
	ChildCount int    `json:"child_count"`
	TrashedAt  int64  `json:"trashed_at,omitempty"`
	Location   string `json:"location,omitempty"`

	Blob    string `json:"-"`
	Enc     bool   `json:"-"`
	TrashID string `json:"-"`
}

// Meta describes who created a node and how it should be tagged.
type Meta struct {
	DeviceID   string
	DeviceName string
	CategoryID string
	Timeline   bool
	MTime      int64
}

type FileInfo struct {
	Size   int64
	Mime   string
	SHA256 string
	Blob   string
	Enc    bool
}

type Crumb struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type WalkEntry struct {
	Node
	RelPath string `json:"rel_path"`
}

type Stats struct {
	Files      int64 `json:"files"`
	Folders    int64 `json:"folders"`
	Bytes      int64 `json:"bytes"`
	TrashBytes int64 `json:"trash_bytes"`
}

// Conflict policies for names that already exist.
const (
	ConflictRename    = "rename"
	ConflictFail      = "fail"
	ConflictMerge     = "merge"     // folders only: reuse the existing folder
	ConflictOverwrite = "overwrite" // files only: move the existing file to trash
	ConflictSkip      = "skip"
)

var ErrSkipped = errors.New("skipped: name exists")

type querier interface {
	Exec(string, ...any) (sql.Result, error)
	Query(string, ...any) (*sql.Rows, error)
	QueryRow(string, ...any) *sql.Row
}

const nodeCols = `n.id, COALESCE(n.parent_id, ''), n.name, n.is_dir, n.size, n.mime, n.sha256, n.blob, n.enc,
	COALESCE(n.category_id, ''), n.timeline, n.device_id, n.device_name, n.mtime, n.created_at, n.updated_at,
	COALESCE(n.trash_id, ''), COALESCE(n.trashed_at, 0),
	(SELECT COUNT(*) FROM nodes c WHERE c.parent_id = n.id AND c.trash_id IS NULL)`

func scanNode(row interface{ Scan(...any) error }) (Node, error) {
	var n Node
	var isDir, enc, tl int
	err := row.Scan(&n.ID, &n.ParentID, &n.Name, &isDir, &n.Size, &n.Mime, &n.SHA256, &n.Blob, &enc,
		&n.CategoryID, &tl, &n.DeviceID, &n.DeviceName, &n.MTime, &n.CreatedAt, &n.UpdatedAt,
		&n.TrashID, &n.TrashedAt, &n.ChildCount)
	if errors.Is(err, sql.ErrNoRows) {
		return n, ErrNotFound
	}
	n.IsDir, n.Enc, n.Timeline = isDir == 1, enc == 1, tl == 1
	return n, err
}

func scanNodes(rows *sql.Rows, err error) ([]Node, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Node{}
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// ValidName reports whether name can be used for a file or folder.
func ValidName(name string) bool {
	if name == "" || name == "." || name == ".." || len(name) > 255 || !utf8.ValidString(name) {
		return false
	}
	for _, r := range name {
		if r < 0x20 || r == 0x7f || r == '/' || r == '\\' {
			return false
		}
	}
	// A name that turns into "." / ".." or gains a separator once it is
	// percent-decoded is never a real file name, and anything downstream that
	// decodes names (a browser, an unzip tool) could be misled by it.
	for d, i := name, 0; i < 3 && strings.Contains(d, "%"); i++ {
		u, err := url.PathUnescape(d)
		if err != nil || u == d {
			break
		}
		if u == "." || u == ".." || strings.ContainsAny(u, "/\\\x00") {
			return false
		}
		d = u
	}
	return true
}

// ValidMTime: 0 means unknown (stored as now); otherwise milliseconds since
// 1970 and at most a day ahead, to allow for clock skew.
func ValidMTime(ms int64) bool { return ms >= 0 && ms <= Now()+24*60*60*1000 }

// SplitRelPath validates a '/'-separated relative path and returns its components.
func SplitRelPath(rel string) ([]string, error) {
	if strings.HasPrefix(rel, "/") || strings.HasPrefix(rel, "\\") {
		return nil, fmt.Errorf("%w: path must be relative", ErrInvalid)
	}
	rel = strings.TrimSuffix(rel, "/")
	if rel == "" {
		return nil, ErrInvalid
	}
	comps := strings.Split(rel, "/")
	if len(comps) > 64 {
		return nil, ErrInvalid
	}
	for _, c := range comps {
		if !ValidName(c) {
			return nil, fmt.Errorf("%w: bad name %q", ErrInvalid, c)
		}
	}
	return comps, nil
}

func getNode(q querier, userID, id string, includeTrashed bool) (Node, error) {
	cond := ` AND n.trash_id IS NULL`
	if includeTrashed {
		cond = ``
	}
	return scanNode(q.QueryRow(`SELECT `+nodeCols+` FROM nodes n WHERE n.id = ? AND n.user_id = ?`+cond, id, userID))
}

func (db *DB) Node(userID, id string) (Node, error) { return getNode(db, userID, id, false) }

func (db *DB) Children(userID, parentID string, dirsOnly bool) ([]Node, error) {
	cond := ``
	if dirsOnly {
		cond = ` AND n.is_dir = 1`
	}
	return scanNodes(db.Query(`SELECT `+nodeCols+` FROM nodes n
		WHERE n.parent_id = ? AND n.user_id = ? AND n.trash_id IS NULL`+cond+`
		ORDER BY n.is_dir DESC, n.name COLLATE NOCASE`, parentID, userID))
}

// Path returns the chain of folders from the user's root down to id (inclusive).
func (db *DB) Path(userID, id string) ([]Crumb, error) {
	rows, err := db.Query(`WITH RECURSIVE p(id, parent_id, name, depth) AS (
			SELECT id, parent_id, name, 0 FROM nodes WHERE id = ? AND user_id = ?
			UNION ALL
			SELECT n.id, n.parent_id, n.name, p.depth + 1 FROM nodes n JOIN p ON n.id = p.parent_id
		) SELECT id, name FROM p ORDER BY depth DESC`, id, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Crumb{}
	for rows.Next() {
		var c Crumb
		if err := rows.Scan(&c.ID, &c.Name); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return nil, ErrNotFound
	}
	return out, rows.Err()
}

// FillLocations sets Location ("/a/b") on each node to the path of its parent folder.
func (db *DB) FillLocations(userID string, nodes []Node) {
	memo := map[string]string{}
	for i := range nodes {
		pid := nodes[i].ParentID
		if pid == "" {
			continue
		}
		loc, ok := memo[pid]
		if !ok {
			crumbs, err := db.Path(userID, pid)
			if err == nil {
				names := make([]string, 0, len(crumbs))
				for _, c := range crumbs[1:] {
					names = append(names, c.Name)
				}
				loc = "/" + strings.Join(names, "/")
			}
			memo[pid] = loc
		}
		nodes[i].Location = loc
	}
}

func lookupChild(q querier, parentID, name string) (id string, isDir bool, err error) {
	var d int
	err = q.QueryRow(`SELECT id, is_dir FROM nodes WHERE parent_id = ? AND name = ? COLLATE NOCASE AND trash_id IS NULL`,
		parentID, name).Scan(&id, &d)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return id, d == 1, err
}

func splitExt(name string, isDir bool) (string, string) {
	if isDir {
		return name, ""
	}
	ext := path.Ext(name)
	if ext == name || len(ext) > 16 || strings.ContainsRune(ext, ' ') {
		return name, ""
	}
	return strings.TrimSuffix(name, ext), ext
}

// uniqueName returns name, or "name (n).ext" if name is already taken in parentID.
func uniqueName(q querier, parentID, name string, isDir bool) (string, error) {
	id, _, err := lookupChild(q, parentID, name)
	if err != nil || id == "" {
		return name, err
	}
	base, ext := splitExt(name, isDir)
	for i := 1; i < 10000; i++ {
		cand := fmt.Sprintf("%s (%d)%s", base, i, ext)
		id, _, err := lookupChild(q, parentID, cand)
		if err != nil {
			return "", err
		}
		if id == "" {
			return cand, nil
		}
	}
	return "", ErrConflict
}

func requireDir(q querier, userID, id string) error {
	n, err := getNode(q, userID, id, false)
	if err != nil {
		return err
	}
	if !n.IsDir {
		return fmt.Errorf("%w: target is not a folder", ErrInvalid)
	}
	return nil
}

func insertNode(q querier, userID, parentID, name string, isDir bool, m Meta, f FileInfo) (string, error) {
	now := Now()
	id := NewID()
	if !ValidMTime(m.MTime) {
		return "", fmt.Errorf("%w: bad mtime", ErrInvalid)
	}
	mtime := m.MTime
	if mtime == 0 {
		mtime = now
	}
	var cat any
	if m.CategoryID != "" {
		cat = m.CategoryID
	}
	_, err := q.Exec(`INSERT INTO nodes(id, user_id, parent_id, name, is_dir, size, mime, sha256, blob, enc,
		category_id, timeline, device_id, device_name, mtime, created_at, updated_at)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		id, userID, parentID, name, boolInt(isDir), f.Size, f.Mime, f.SHA256, f.Blob, boolInt(f.Enc),
		cat, boolInt(m.Timeline), m.DeviceID, m.DeviceName, mtime, now, now)
	if isUniqueErr(err) {
		return "", ErrConflict
	}
	return id, err
}

// ensureDirs walks/creates the folder chain comps below parentID (like mkdir -p).
func ensureDirs(q querier, userID, parentID string, comps []string, m Meta) (string, error) {
	cur := parentID
	for _, c := range comps {
		id, isDir, err := lookupChild(q, cur, c)
		if err != nil {
			return "", err
		}
		if id != "" && isDir {
			cur = id
			continue
		}
		name := c
		if id != "" {
			if name, err = uniqueName(q, cur, c, true); err != nil {
				return "", err
			}
		}
		if cur, err = insertNode(q, userID, cur, name, true, Meta{DeviceID: m.DeviceID, DeviceName: m.DeviceName}, FileInfo{}); err != nil {
			return "", err
		}
	}
	return cur, nil
}

func (db *DB) checkCategory(q querier, userID, catID string) error {
	if catID == "" {
		return nil
	}
	var n int
	if err := q.QueryRow(`SELECT COUNT(*) FROM categories WHERE id = ? AND user_id = ?`, catID, userID).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("%w: unknown category", ErrInvalid)
	}
	return nil
}

// CreateDir creates a folder. With ConflictMerge an existing folder of the same
// name is returned instead.
func (db *DB) CreateDir(userID, parentID, name, conflict string, m Meta) (Node, error) {
	if !ValidName(name) {
		return Node{}, fmt.Errorf("%w: bad name", ErrInvalid)
	}
	var id string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		if err := requireDir(tx, userID, parentID); err != nil {
			return err
		}
		if err := db.checkCategory(tx, userID, m.CategoryID); err != nil {
			return err
		}
		existing, isDir, err := lookupChild(tx, parentID, name)
		if err != nil {
			return err
		}
		if existing != "" {
			switch {
			case conflict == ConflictMerge && isDir:
				id = existing
				return nil
			case conflict == ConflictRename || conflict == ConflictMerge:
				if name, err = uniqueName(tx, parentID, name, true); err != nil {
					return err
				}
			default:
				return ErrConflict
			}
		}
		id, err = insertNode(tx, userID, parentID, name, true, m, FileInfo{})
		return err
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

// InsertFile records a fully uploaded file at parentID/relPath, creating
// intermediate folders. replaced is set when an existing file was moved to trash.
func (db *DB) InsertFile(userID, parentID, relPath, conflict string, m Meta, f FileInfo) (node Node, replaced *Node, err error) {
	comps, err := SplitRelPath(relPath)
	if err != nil {
		return Node{}, nil, err
	}
	var id string
	err = db.tx(context.Background(), func(tx *sql.Tx) error {
		if err := requireDir(tx, userID, parentID); err != nil {
			return err
		}
		if err := db.checkCategory(tx, userID, m.CategoryID); err != nil {
			return err
		}
		dir, err := ensureDirs(tx, userID, parentID, comps[:len(comps)-1], m)
		if err != nil {
			return err
		}
		name := comps[len(comps)-1]
		existing, isDir, err := lookupChild(tx, dir, name)
		if err != nil {
			return err
		}
		if existing != "" {
			switch {
			case conflict == ConflictSkip:
				id = existing
				return ErrSkipped
			case conflict == ConflictOverwrite && !isDir:
				old, err := getNode(tx, userID, existing, false)
				if err != nil {
					return err
				}
				if err := trashTx(tx, userID, existing); err != nil {
					return err
				}
				replaced = &old
			case conflict == ConflictFail:
				return ErrConflict
			default:
				if name, err = uniqueName(tx, dir, name, false); err != nil {
					return err
				}
			}
		}
		id, err = insertNode(tx, userID, dir, name, false, m, f)
		return err
	})
	if errors.Is(err, ErrSkipped) {
		n, _ := db.Node(userID, id)
		return n, nil, ErrSkipped
	}
	if err != nil {
		return Node{}, nil, err
	}
	node, err = db.Node(userID, id)
	return node, replaced, err
}

// MkdirAll creates the folder chain relPath below parentID (existing folders are reused).
func (db *DB) MkdirAll(userID, parentID, relPath string, m Meta) (Node, error) {
	comps, err := SplitRelPath(relPath)
	if err != nil {
		return Node{}, err
	}
	var id string
	err = db.tx(context.Background(), func(tx *sql.Tx) error {
		if err := requireDir(tx, userID, parentID); err != nil {
			return err
		}
		id, err = ensureDirs(tx, userID, parentID, comps, m)
		return err
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

func isDescendant(q querier, ancestorID, id string) (bool, error) {
	var n int
	err := q.QueryRow(`WITH RECURSIVE p(id, parent_id) AS (
			SELECT id, parent_id FROM nodes WHERE id = ?
			UNION ALL
			SELECT n.id, n.parent_id FROM nodes n JOIN p ON n.id = p.parent_id
		) SELECT COUNT(*) FROM p WHERE id = ?`, id, ancestorID).Scan(&n)
	return n > 0, err
}

func (db *DB) Rename(userID, id, name string) (Node, error) {
	if !ValidName(name) {
		return Node{}, fmt.Errorf("%w: bad name", ErrInvalid)
	}
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		n, err := getNode(tx, userID, id, false)
		if err != nil {
			return err
		}
		if n.ParentID == "" {
			return fmt.Errorf("%w: cannot rename root", ErrInvalid)
		}
		if other, _, err := lookupChild(tx, n.ParentID, name); err != nil {
			return err
		} else if other != "" && other != id {
			return ErrConflict
		}
		_, err = tx.Exec(`UPDATE nodes SET name = ?, updated_at = ? WHERE id = ?`, name, Now(), id)
		return err
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

// Move puts id into newParentID; on a name clash it is renamed if rename is set.
func (db *DB) Move(userID, id, newParentID string, rename bool) (Node, error) {
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		n, err := getNode(tx, userID, id, false)
		if err != nil {
			return err
		}
		if n.ParentID == "" {
			return fmt.Errorf("%w: cannot move root", ErrInvalid)
		}
		if n.ParentID == newParentID {
			return nil
		}
		if err := requireDir(tx, userID, newParentID); err != nil {
			return err
		}
		if inside, err := isDescendant(tx, id, newParentID); err != nil {
			return err
		} else if inside {
			return fmt.Errorf("%w: cannot move a folder into itself", ErrInvalid)
		}
		name := n.Name
		if other, _, err := lookupChild(tx, newParentID, name); err != nil {
			return err
		} else if other != "" {
			if !rename {
				return ErrConflict
			}
			if name, err = uniqueName(tx, newParentID, name, n.IsDir); err != nil {
				return err
			}
		}
		_, err = tx.Exec(`UPDATE nodes SET parent_id = ?, name = ?, updated_at = ? WHERE id = ?`, newParentID, name, Now(), id)
		return err
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

func (db *DB) SetCategory(userID, id, catID string) (Node, error) {
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		if err := db.checkCategory(tx, userID, catID); err != nil {
			return err
		}
		var cat any
		if catID != "" {
			cat = catID
		}
		res, err := tx.Exec(`UPDATE nodes SET category_id = ?, updated_at = ?
			WHERE id = ? AND user_id = ? AND trash_id IS NULL AND parent_id IS NOT NULL`, cat, Now(), id, userID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrNotFound
		}
		return nil
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

func (db *DB) SetTimeline(userID, id string, on bool) error {
	_, err := db.Exec(`UPDATE nodes SET timeline = ? WHERE id = ? AND user_id = ?`, boolInt(on), id, userID)
	return err
}

func trashTx(q querier, userID, id string) error {
	_, err := q.Exec(`WITH RECURSIVE sub(id) AS (
			SELECT ?
			UNION ALL
			SELECT n.id FROM nodes n JOIN sub ON n.parent_id = sub.id WHERE n.trash_id IS NULL
		)
		UPDATE nodes SET trash_id = ?, trashed_at = ?, trash_root = (id = ?)
		WHERE user_id = ? AND trash_id IS NULL AND id IN (SELECT id FROM sub)`,
		id, NewID(), Now(), id, userID)
	return err
}

func isTrashRoot(q querier, id string) bool {
	var r int
	q.QueryRow(`SELECT trash_root FROM nodes WHERE id = ?`, id).Scan(&r)
	return r == 1
}

// Trash moves a node and everything below it to the trash.
func (db *DB) Trash(userID, id string) (Node, error) {
	var n Node
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		var err error
		if n, err = getNode(tx, userID, id, false); err != nil {
			return err
		}
		if n.ParentID == "" {
			return fmt.Errorf("%w: cannot delete root", ErrInvalid)
		}
		return trashTx(tx, userID, id)
	})
	return n, err
}

func (db *DB) ListTrash(userID string) ([]Node, error) {
	nodes, err := scanNodes(db.Query(`SELECT `+nodeCols+` FROM nodes n
		WHERE n.user_id = ? AND n.trash_root = 1 AND n.trash_id IS NOT NULL ORDER BY n.trashed_at DESC`, userID))
	if err != nil {
		return nil, err
	}
	for i := range nodes {
		// child counts are computed over live children; recount within the trash group
		if nodes[i].IsDir {
			db.QueryRow(`SELECT COUNT(*) FROM nodes WHERE parent_id = ? AND trash_id = ?`, nodes[i].ID, nodes[i].TrashID).
				Scan(&nodes[i].ChildCount)
		}
	}
	db.FillLocations(userID, nodes)
	return nodes, nil
}

// Restore brings a trashed item back to its old folder (or the root if that
// folder is gone), renaming it on a name clash.
func (db *DB) Restore(userID, id, rootID string) (Node, error) {
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		n, err := getNode(tx, userID, id, true)
		if err != nil {
			return err
		}
		if n.TrashID == "" {
			return nil
		}
		if !isTrashRoot(tx, id) {
			return fmt.Errorf("%w: restore the containing folder instead", ErrInvalid)
		}
		parent := n.ParentID
		if p, err := getNode(tx, userID, parent, false); err != nil || !p.IsDir {
			parent = rootID
		}
		name, err := uniqueName(tx, parent, n.Name, n.IsDir)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE nodes SET parent_id = ?, name = ?, updated_at = ? WHERE id = ?`, parent, name, Now(), id); err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE nodes SET trash_id = NULL, trashed_at = NULL, trash_root = 0 WHERE user_id = ? AND trash_id = ?`,
			userID, n.TrashID)
		return err
	})
	if err != nil {
		return Node{}, err
	}
	return db.Node(userID, id)
}

func purge(q querier, where string, args ...any) ([]string, error) {
	rows, err := q.Query(`SELECT blob FROM nodes WHERE blob != '' AND `+where, args...)
	if err != nil {
		return nil, err
	}
	var blobs []string
	for rows.Next() {
		var b string
		rows.Scan(&b)
		blobs = append(blobs, b)
	}
	rows.Close()
	_, err = q.Exec(`DELETE FROM nodes WHERE `+where, args...)
	return blobs, err
}

// PurgeTrash permanently deletes one trashed item (and its subtree).
func (db *DB) PurgeTrash(userID, id string) ([]string, error) {
	var blobs []string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		n, err := getNode(tx, userID, id, true)
		if err != nil {
			return err
		}
		if n.TrashID == "" || !isTrashRoot(tx, id) {
			return fmt.Errorf("%w: not a trash item", ErrInvalid)
		}
		blobs, err = purge(tx, `user_id = ? AND trash_id = ?`, userID, n.TrashID)
		return err
	})
	return blobs, err
}

func (db *DB) EmptyTrash(userID string) ([]string, error) {
	var blobs []string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		var err error
		blobs, err = purge(tx, `user_id = ? AND trash_id IS NOT NULL`, userID)
		return err
	})
	return blobs, err
}

// PurgeExpiredTrash deletes trash groups older than the given timestamp (all users).
func (db *DB) PurgeExpiredTrash(before int64) ([]string, error) {
	var blobs []string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		var err error
		blobs, err = purge(tx, `trash_id IN (SELECT trash_id FROM nodes WHERE trash_root = 1 AND trashed_at < ?)`, before)
		return err
	})
	return blobs, err
}

// Timeline lists dropped items (files and folders that were uploaded as a unit), newest first.
// catID "" means all, "none" means uncategorized.
func (db *DB) Timeline(userID string, before int64, limit int, catID string) ([]Node, error) {
	q := `SELECT ` + nodeCols + ` FROM nodes n WHERE n.user_id = ? AND n.timeline = 1 AND n.trash_id IS NULL AND n.created_at < ?`
	args := []any{userID, before}
	switch catID {
	case "":
	case "none":
		q += ` AND n.category_id IS NULL`
	default:
		q += ` AND n.category_id = ?`
		args = append(args, catID)
	}
	q += ` ORDER BY n.created_at DESC LIMIT ?`
	nodes, err := scanNodes(db.Query(q, append(args, limit)...))
	if err == nil {
		db.FillLocations(userID, nodes)
	}
	return nodes, err
}

// Tagged lists every live node carrying the category, newest first.
func (db *DB) Tagged(userID, catID string, before int64, limit int) ([]Node, error) {
	nodes, err := scanNodes(db.Query(`SELECT `+nodeCols+` FROM nodes n
		WHERE n.user_id = ? AND n.category_id = ? AND n.trash_id IS NULL AND n.created_at < ?
		ORDER BY n.created_at DESC LIMIT ?`, userID, catID, before, limit))
	if err == nil {
		db.FillLocations(userID, nodes)
	}
	return nodes, err
}

func (db *DB) Search(userID, query string, limit int) ([]Node, error) {
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(query)
	nodes, err := scanNodes(db.Query(`SELECT `+nodeCols+` FROM nodes n
		WHERE n.user_id = ? AND n.trash_id IS NULL AND n.parent_id IS NOT NULL AND n.name LIKE ? ESCAPE '\'
		ORDER BY n.created_at DESC LIMIT ?`, userID, "%"+esc+"%", limit))
	if err == nil {
		db.FillLocations(userID, nodes)
	}
	return nodes, err
}

// Walk lists id and all live descendants with paths relative to id's parent.
func (db *DB) Walk(userID, id string) ([]WalkEntry, error) {
	rows, err := db.Query(`WITH RECURSIVE w(id, rel, depth) AS (
			SELECT id, name, 0 FROM nodes WHERE id = ? AND user_id = ? AND trash_id IS NULL
			UNION ALL
			SELECT n.id, w.rel || '/' || n.name, w.depth + 1 FROM nodes n JOIN w ON n.parent_id = w.id
			WHERE n.trash_id IS NULL AND w.depth < 64
		) SELECT `+nodeCols+`, w.rel FROM w JOIN nodes n ON n.id = w.id ORDER BY w.depth, w.rel`, id, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []WalkEntry{}
	for rows.Next() {
		var e WalkEntry
		var isDir, enc, tl int
		n := &e.Node
		if err := rows.Scan(&n.ID, &n.ParentID, &n.Name, &isDir, &n.Size, &n.Mime, &n.SHA256, &n.Blob, &enc,
			&n.CategoryID, &tl, &n.DeviceID, &n.DeviceName, &n.MTime, &n.CreatedAt, &n.UpdatedAt,
			&n.TrashID, &n.TrashedAt, &n.ChildCount, &e.RelPath); err != nil {
			return nil, err
		}
		n.IsDir, n.Enc, n.Timeline = isDir == 1, enc == 1, tl == 1
		out = append(out, e)
	}
	if len(out) == 0 {
		return nil, ErrNotFound
	}
	return out, rows.Err()
}

func (db *DB) Stats(userID string) (Stats, error) {
	var s Stats
	err := db.QueryRow(`SELECT
			COALESCE(SUM(CASE WHEN is_dir = 0 AND trash_id IS NULL THEN 1 END), 0),
			COALESCE(SUM(CASE WHEN is_dir = 1 AND trash_id IS NULL AND parent_id IS NOT NULL THEN 1 END), 0),
			COALESCE(SUM(CASE WHEN trash_id IS NULL THEN size END), 0),
			COALESCE(SUM(CASE WHEN trash_id IS NOT NULL THEN size END), 0)
		FROM nodes WHERE user_id = ?`, userID).Scan(&s.Files, &s.Folders, &s.Bytes, &s.TrashBytes)
	return s, err
}

// Usage is what counts against a user's quota: stored files including the
// trash, plus the declared size of uploads still in progress.
func (db *DB) Usage(userID string) (int64, error) {
	var n int64
	err := db.QueryRow(`SELECT
			(SELECT COALESCE(SUM(size), 0) FROM nodes WHERE user_id = ? AND is_dir = 0) +
			(SELECT COALESCE(SUM(size), 0) FROM uploads WHERE user_id = ?)`, userID, userID).Scan(&n)
	return n, err
}

// AllBlobs returns every blob id referenced by the database (for orphan cleanup).
func (db *DB) AllBlobs() (map[string]bool, error) {
	rows, err := db.Query(`SELECT blob FROM nodes WHERE blob != '' UNION SELECT id FROM uploads`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var b string
		rows.Scan(&b)
		out[b] = true
	}
	return out, rows.Err()
}
