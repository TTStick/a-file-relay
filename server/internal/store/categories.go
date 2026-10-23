package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Category is a user-defined label. Items dropped onto a category land in its
// folder (created on demand at the root) and are tagged with it.
type Category struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color"`
	Icon      string `json:"icon"`
	Sort      int    `json:"sort"`
	FolderID  string `json:"folder_id,omitempty"`
	CreatedAt int64  `json:"created_at"`
	Count     int    `json:"count"`
}

const catCols = `c.id, c.name, c.color, c.icon, c.sort, COALESCE(c.folder_id, ''), c.created_at,
	(SELECT COUNT(*) FROM nodes n WHERE n.category_id = c.id AND n.trash_id IS NULL)`

func scanCategory(row interface{ Scan(...any) error }) (Category, error) {
	var c Category
	err := row.Scan(&c.ID, &c.Name, &c.Color, &c.Icon, &c.Sort, &c.FolderID, &c.CreatedAt, &c.Count)
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func validCategoryName(name string) bool {
	name = strings.TrimSpace(name)
	return name != "" && utf8.RuneCountInString(name) <= 64 && ValidName(name)
}

func validColor(c string) bool {
	if len(c) != 7 || c[0] != '#' {
		return false
	}
	for _, r := range c[1:] {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return false
		}
	}
	return true
}

func (db *DB) Categories(userID string) ([]Category, error) {
	rows, err := db.Query(`SELECT `+catCols+` FROM categories c WHERE c.user_id = ? ORDER BY c.sort, c.created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Category{}
	for rows.Next() {
		c, err := scanCategory(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (db *DB) Category(userID, id string) (Category, error) {
	return scanCategory(db.QueryRow(`SELECT `+catCols+` FROM categories c WHERE c.id = ? AND c.user_id = ?`, id, userID))
}

func nameTaken(q querier, userID, name, exceptID string) (bool, error) {
	var n int
	err := q.QueryRow(`SELECT COUNT(*) FROM categories WHERE user_id = ? AND name = ? COLLATE NOCASE AND id != ?`,
		userID, name, exceptID).Scan(&n)
	return n > 0, err
}

func (db *DB) CreateCategory(userID, name, color, icon string) (Category, error) {
	name = strings.TrimSpace(name)
	if !validCategoryName(name) {
		return Category{}, fmt.Errorf("%w: bad category name", ErrInvalid)
	}
	if color == "" {
		color = "#4F7CFF"
	}
	if !validColor(color) {
		return Category{}, fmt.Errorf("%w: color must be #RRGGBB", ErrInvalid)
	}
	if utf8.RuneCountInString(icon) > 8 {
		return Category{}, fmt.Errorf("%w: icon too long", ErrInvalid)
	}
	id := NewID()
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		if taken, err := nameTaken(tx, userID, name, ""); err != nil {
			return err
		} else if taken {
			return ErrConflict
		}
		_, err := tx.Exec(`INSERT INTO categories(id, user_id, name, color, icon, sort, created_at)
			VALUES(?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort), 0) + 1 FROM categories WHERE user_id = ?), ?)`,
			id, userID, name, color, icon, userID, Now())
		return err
	})
	if err != nil {
		return Category{}, err
	}
	return db.Category(userID, id)
}

type CategoryPatch struct {
	Name     *string `json:"name"`
	Color    *string `json:"color"`
	Icon     *string `json:"icon"`
	FolderID *string `json:"folder_id"`
}

func (db *DB) UpdateCategory(userID, id string, p CategoryPatch) (Category, error) {
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		c, err := scanCategory(tx.QueryRow(`SELECT `+catCols+` FROM categories c WHERE c.id = ? AND c.user_id = ?`, id, userID))
		if err != nil {
			return err
		}
		if p.Name != nil {
			name := strings.TrimSpace(*p.Name)
			if !validCategoryName(name) {
				return fmt.Errorf("%w: bad category name", ErrInvalid)
			}
			if taken, err := nameTaken(tx, userID, name, id); err != nil {
				return err
			} else if taken {
				return ErrConflict
			}
			// Keep the auto-created folder in step with the category name.
			if c.FolderID != "" && name != c.Name {
				if f, err := getNode(tx, userID, c.FolderID, false); err == nil && f.Name == c.Name {
					if other, _, _ := lookupChild(tx, f.ParentID, name); other == "" {
						tx.Exec(`UPDATE nodes SET name = ?, updated_at = ? WHERE id = ?`, name, Now(), f.ID)
					}
				}
			}
			c.Name = name
		}
		if p.Color != nil {
			if !validColor(*p.Color) {
				return fmt.Errorf("%w: color must be #RRGGBB", ErrInvalid)
			}
			c.Color = *p.Color
		}
		if p.Icon != nil {
			if utf8.RuneCountInString(*p.Icon) > 8 {
				return fmt.Errorf("%w: icon too long", ErrInvalid)
			}
			c.Icon = *p.Icon
		}
		var folder any
		if c.FolderID != "" {
			folder = c.FolderID
		}
		if p.FolderID != nil {
			folder = nil
			if *p.FolderID != "" {
				if err := requireDir(tx, userID, *p.FolderID); err != nil {
					return err
				}
				folder = *p.FolderID
			}
		}
		_, err = tx.Exec(`UPDATE categories SET name = ?, color = ?, icon = ?, folder_id = ? WHERE id = ?`,
			c.Name, c.Color, c.Icon, folder, id)
		return err
	})
	if err != nil {
		return Category{}, err
	}
	return db.Category(userID, id)
}

func (db *DB) DeleteCategory(userID, id string) error {
	return db.tx(context.Background(), func(tx *sql.Tx) error {
		res, err := tx.Exec(`DELETE FROM categories WHERE id = ? AND user_id = ?`, id, userID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrNotFound
		}
		if _, err := tx.Exec(`UPDATE nodes SET category_id = NULL WHERE category_id = ? AND user_id = ?`, id, userID); err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE uploads SET category_id = NULL WHERE category_id = ? AND user_id = ?`, id, userID)
		return err
	})
}

func (db *DB) ReorderCategories(userID string, ids []string) error {
	return db.tx(context.Background(), func(tx *sql.Tx) error {
		for i, id := range ids {
			if _, err := tx.Exec(`UPDATE categories SET sort = ? WHERE id = ? AND user_id = ?`, i+1, id, userID); err != nil {
				return err
			}
		}
		return nil
	})
}

// CategoryFolder returns the folder that items dropped onto the category go to,
// creating "/<category name>" if the category has none (or it was deleted).
func (db *DB) CategoryFolder(userID, catID, rootID string) (string, error) {
	var folder string
	err := db.tx(context.Background(), func(tx *sql.Tx) error {
		c, err := scanCategory(tx.QueryRow(`SELECT `+catCols+` FROM categories c WHERE c.id = ? AND c.user_id = ?`, catID, userID))
		if err != nil {
			return err
		}
		if c.FolderID != "" {
			if n, err := getNode(tx, userID, c.FolderID, false); err == nil && n.IsDir {
				folder = n.ID
				return nil
			}
		}
		if folder, err = ensureDirs(tx, userID, rootID, []string{c.Name}, Meta{}); err != nil {
			return err
		}
		_, err = tx.Exec(`UPDATE categories SET folder_id = ? WHERE id = ?`, folder, catID)
		return err
	})
	return folder, err
}
