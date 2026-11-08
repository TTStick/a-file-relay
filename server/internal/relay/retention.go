package relay

import (
	"context"
	"os"
	"time"
)

// RunJanitor removes whatever has outlived the retention period, once a minute.
func (s *Server) RunJanitor(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		s.sweep(time.Now())
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) sweep(n time.Time) {
	cutoff := n.Add(-s.cfg.Retention).UnixMilli()
	var ids []string
	rows, err := s.db.Query(`SELECT id FROM blobs WHERE updated < ?`, cutoff)
	if err == nil {
		for rows.Next() {
			var id string
			rows.Scan(&id)
			ids = append(ids, id)
		}
		rows.Close()
	}
	for _, id := range ids {
		s.removeBlob(id)
	}
	s.db.Exec(`DELETE FROM replies WHERE created < ?`, cutoff)
	s.db.Exec(`DELETE FROM ops WHERE created < ?`, cutoff)
	s.db.Exec(`DELETE FROM pairs WHERE created < ?`, n.Add(-time.Hour).UnixMilli())
	s.wipeOrphans(n)
	s.db.truncateWAL()

	s.mu.Lock()
	for ip, ev := range s.limits {
		if len(ev) == 0 || n.Sub(ev[len(ev)-1]) > 10*time.Minute {
			delete(s.limits, ip)
		}
	}
	s.mu.Unlock()
}

// pin keeps a blob's file from being wiped while a transfer is using it.
func (s *Server) pin(id string) (unpin func()) {
	s.mu.Lock()
	s.pins[id]++
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		if s.pins[id]--; s.pins[id] == 0 {
			delete(s.pins, id)
		}
		s.mu.Unlock()
	}
}

// wipe overwrites a removed blob and unlinks it, so the ciphertext doesn't
// stay behind in free disk space. A file that's still being transferred is
// left alone; wipeOrphans comes back for it.
func (s *Server) wipe(id string) {
	s.wipeMu.Lock() // one at a time, so a burst of deletes can't saturate the disk
	defer s.wipeMu.Unlock()
	s.mu.Lock()
	inUse := s.pins[id] > 0
	s.mu.Unlock()
	if inUse {
		return
	}
	path := s.blobPath(id)
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return
	}
	if st, err := f.Stat(); err == nil {
		zeros := make([]byte, 1<<20)
		for left := st.Size(); left > 0; left -= int64(len(zeros)) {
			f.Write(zeros[:min(left, int64(len(zeros)))])
		}
		f.Sync() // unlinking drops dirty pages, so the zeros have to reach the disk first
	}
	f.Close()
	os.Remove(path)
}

// wipeOrphans finishes removals that couldn't complete at the time: files that
// were in use, or that a restart interrupted.
func (s *Server) wipeOrphans(n time.Time) {
	rows, err := s.db.Query(`SELECT id FROM blobs`)
	if err != nil {
		return
	}
	known := map[string]bool{}
	for rows.Next() {
		var id string
		rows.Scan(&id)
		known[id] = true
	}
	rows.Close()
	if rows.Err() != nil {
		return
	}
	entries, err := os.ReadDir(s.blobs)
	if err != nil {
		return
	}
	for _, e := range entries {
		info, err := e.Info()
		// the age check covers reserve(), which creates a file just before its row
		if err == nil && !known[e.Name()] && n.Sub(info.ModTime()) > time.Minute {
			s.wipe(e.Name())
		}
	}
}
