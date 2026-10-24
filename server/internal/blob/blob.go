// Package blob stores file contents on disk, optionally encrypted at rest.
//
// Encrypted blob layout:
//
//	header (68 bytes): "FSW1" | version(1) | reserved(3) | nonce(12) | AES-GCM(master, DEK)(48)
//	segments: AES-256-GCM(DEK, plaintext[i*64KiB:(i+1)*64KiB]) each with a 16-byte tag
//
// Every file has its own random data key (DEK). Segment i uses nonce = 0^4 || BE64(i)
// and AAD = {final}, so segments can't be reordered, dropped or truncated undetected.
// Fixed-size segments allow random access, which gives us HTTP Range support and
// resumable uploads.
package blob

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	SegSize    = 64 * 1024
	tagSize    = 16
	headerSize = 4 + 1 + 3 + 12 + 32 + tagSize
	magic      = "FSW1"
	version    = 1
)

var (
	ErrTooLarge = errors.New("blob: more data than declared size")
	ErrCorrupt  = errors.New("blob: data corrupted or wrong key")
)

type Store struct {
	dir    string
	tmp    string
	master cipher.AEAD // nil when encryption at rest is disabled
}

func New(dataDir string, masterKey []byte) (*Store, error) {
	s := &Store{dir: filepath.Join(dataDir, "blobs"), tmp: filepath.Join(dataDir, "tmp")}
	for _, d := range []string{s.dir, s.tmp} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	if masterKey != nil {
		a, err := newAEAD(masterKey)
		if err != nil {
			return nil, err
		}
		s.master = a
	}
	return s, nil
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("blob: key must be 32 bytes, got %d", len(key))
	}
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

func (s *Store) Encrypted() bool { return s.master != nil }

func (s *Store) TmpPath(id string) string { return filepath.Join(s.tmp, id) }

func (s *Store) FinalPath(id string) string {
	return filepath.Join(s.dir, id[:2], id)
}

// KeyCheck returns a value derived from the master key so a restart with a
// different key is detected before it silently produces unreadable files.
func KeyCheck(key []byte) string {
	h := sha256.Sum256(append([]byte("fileswitch-key-check:"), key...))
	return hex.EncodeToString(h[:8])
}

// Writer receives the contents of one blob, possibly over several requests.
type Writer struct {
	f        *os.File
	aead     cipher.AEAD
	size     int64
	received int64
	h        hash.Hash
	buf      []byte
	dropped  int
}

// Create starts a new blob in the temp area.
func (s *Store) Create(id string, size int64) (*Writer, error) {
	f, err := os.OpenFile(s.TmpPath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	w := &Writer{f: f, size: size, h: sha256.New()}
	if s.master != nil {
		dek := make([]byte, 32)
		if _, err := rand.Read(dek); err != nil {
			f.Close()
			return nil, err
		}
		hdr := make([]byte, 0, headerSize)
		hdr = append(hdr, magic...)
		hdr = append(hdr, version, 0, 0, 0)
		nonce := make([]byte, 12)
		if _, err := rand.Read(nonce); err != nil {
			f.Close()
			return nil, err
		}
		hdr = append(hdr, nonce...)
		hdr = s.master.Seal(hdr, nonce, dek, []byte(magic))
		if _, err := f.Write(hdr); err != nil {
			f.Close()
			return nil, err
		}
		if w.aead, err = newAEAD(dek); err != nil {
			f.Close()
			return nil, err
		}
	}
	if size == 0 {
		// An empty file is still one (empty, final) segment.
		if err := w.writeSeg(nil); err != nil {
			w.Close()
			return nil, err
		}
	}
	return w, nil
}

// Resume reopens a partially received blob. Bytes past `received` are discarded.
func (s *Store) Resume(id string, size, received int64, hashState []byte, enc bool) (*Writer, error) {
	f, err := os.OpenFile(s.TmpPath(id), os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	w := &Writer{f: f, size: size, received: received, h: sha256.New()}
	if len(hashState) > 0 {
		if err := w.h.(encoding.BinaryUnmarshaler).UnmarshalBinary(hashState); err != nil {
			f.Close()
			return nil, err
		}
	}
	off := received
	if enc {
		if s.master == nil {
			f.Close()
			return nil, errors.New("blob: encrypted upload but no master key")
		}
		dek, err := s.readDEK(f)
		if err != nil {
			f.Close()
			return nil, err
		}
		if w.aead, err = newAEAD(dek); err != nil {
			f.Close()
			return nil, err
		}
		off = headerSize + (received/SegSize)*(SegSize+tagSize)
	}
	if err := f.Truncate(off); err != nil {
		f.Close()
		return nil, err
	}
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		f.Close()
		return nil, err
	}
	return w, nil
}

func (s *Store) readDEK(f *os.File) ([]byte, error) {
	hdr := make([]byte, headerSize)
	if _, err := f.ReadAt(hdr, 0); err != nil {
		return nil, ErrCorrupt
	}
	if string(hdr[:4]) != magic || hdr[4] != version {
		return nil, ErrCorrupt
	}
	dek, err := s.master.Open(nil, hdr[8:20], hdr[20:], []byte(magic))
	if err != nil {
		return nil, ErrCorrupt
	}
	return dek, nil
}

func (w *Writer) Received() int64 { return w.received }

func (w *Writer) Done() bool { return w.received == w.size }

// Dropped is how many bytes at the end of the last Fill were thrown away
// because they didn't make up a whole segment.
func (w *Writer) Dropped() int { return w.dropped }

func (w *Writer) HashState() []byte {
	b, _ := w.h.(encoding.BinaryMarshaler).MarshalBinary()
	return b
}

func (w *Writer) SHA256() string { return hex.EncodeToString(w.h.Sum(nil)) }

// Fill consumes r segment by segment. A trailing partial segment that doesn't
// complete the file is dropped (the client resumes from Received()), so a broken
// connection never leaves half a segment behind. The file is synced before
// returning so Received() is always durable.
func (w *Writer) Fill(r io.Reader) error {
	if w.buf == nil {
		w.buf = make([]byte, SegSize)
	}
	w.dropped = 0
	var readErr error
	for w.received < w.size {
		want := min(int64(SegSize), w.size-w.received)
		n, err := io.ReadFull(r, w.buf[:want])
		if int64(n) == want {
			if err := w.writeSeg(w.buf[:n]); err != nil {
				return err
			}
			continue
		}
		if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
			readErr = err
		}
		w.dropped = n
		break
	}
	if err := w.f.Sync(); err != nil {
		return err
	}
	if readErr != nil {
		return readErr
	}
	if w.received == w.size {
		var one [1]byte
		if n, _ := r.Read(one[:]); n > 0 {
			return ErrTooLarge
		}
	}
	return nil
}

func (w *Writer) writeSeg(p []byte) error {
	idx := w.received / SegSize
	final := w.received+int64(len(p)) == w.size
	if w.aead != nil {
		ct := w.aead.Seal(nil, segNonce(idx), p, segAAD(final))
		if _, err := w.f.Write(ct); err != nil {
			return err
		}
	} else if len(p) > 0 {
		if _, err := w.f.Write(p); err != nil {
			return err
		}
	}
	w.h.Write(p)
	w.received += int64(len(p))
	return nil
}

func (w *Writer) Close() error { return w.f.Close() }

// Commit moves a fully received blob from the temp area into the store.
func (s *Store) Commit(id string) error {
	dst := s.FinalPath(id)
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	return os.Rename(s.TmpPath(id), dst)
}

func (s *Store) RemoveTmp(id string) { os.Remove(s.TmpPath(id)) }

func (s *Store) Remove(id string) error {
	if id == "" {
		return nil
	}
	err := os.Remove(s.FinalPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func segNonce(idx int64) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[4:], uint64(idx))
	return n
}

func segAAD(final bool) []byte {
	if final {
		return []byte{1}
	}
	return []byte{0}
}

// Open returns a seekable reader of a committed blob's plaintext.
func (s *Store) Open(id string, size int64, enc bool) (io.ReadSeekCloser, error) {
	f, err := os.Open(s.FinalPath(id))
	if err != nil {
		return nil, err
	}
	if !enc {
		return f, nil
	}
	if s.master == nil {
		f.Close()
		return nil, errors.New("blob: file is encrypted but no master key configured")
	}
	dek, err := s.readDEK(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	a, err := newAEAD(dek)
	if err != nil {
		f.Close()
		return nil, err
	}
	nseg := max(1, (size+SegSize-1)/SegSize)
	return &reader{f: f, aead: a, size: size, nseg: nseg, cur: -1}, nil
}

type reader struct {
	f    *os.File
	aead cipher.AEAD
	size int64
	nseg int64
	pos  int64
	cur  int64
	seg  []byte
	ct   []byte
}

func (r *reader) load(idx int64) error {
	plainLen := min(int64(SegSize), r.size-idx*SegSize)
	if cap(r.ct) < SegSize+tagSize {
		r.ct = make([]byte, SegSize+tagSize)
	}
	ct := r.ct[:plainLen+tagSize]
	if _, err := r.f.ReadAt(ct, headerSize+idx*(SegSize+tagSize)); err != nil {
		return ErrCorrupt
	}
	pt, err := r.aead.Open(r.seg[:0], segNonce(idx), ct, segAAD(idx == r.nseg-1))
	if err != nil {
		return ErrCorrupt
	}
	r.seg, r.cur = pt, idx
	return nil
}

func (r *reader) Read(p []byte) (int, error) {
	if r.pos >= r.size {
		return 0, io.EOF
	}
	idx := r.pos / SegSize
	if idx != r.cur {
		if err := r.load(idx); err != nil {
			return 0, err
		}
	}
	n := copy(p, r.seg[r.pos-idx*SegSize:])
	r.pos += int64(n)
	return n, nil
}

func (r *reader) Seek(off int64, whence int) (int64, error) {
	var abs int64
	switch whence {
	case io.SeekStart:
		abs = off
	case io.SeekCurrent:
		abs = r.pos + off
	case io.SeekEnd:
		abs = r.size + off
	default:
		return 0, errors.New("blob: invalid whence")
	}
	if abs < 0 {
		return 0, errors.New("blob: negative position")
	}
	r.pos = abs
	return abs, nil
}

func (r *reader) Close() error { return r.f.Close() }

// SumFromState finishes a SHA-256 from a state saved by Writer.HashState.
func SumFromState(state []byte) (string, error) {
	h := sha256.New()
	if err := h.(encoding.BinaryUnmarshaler).UnmarshalBinary(state); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// SweepTmp removes temp files older than maxAge that aren't in keep (abandoned
// direct uploads, or sessions whose record is gone).
func (s *Store) SweepTmp(keep map[string]bool, maxAge time.Duration) int {
	entries, err := os.ReadDir(s.tmp)
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || keep[e.Name()] || time.Since(info.ModTime()) < maxAge {
			continue
		}
		if os.Remove(filepath.Join(s.tmp, e.Name())) == nil {
			n++
		}
	}
	return n
}

// SealSecret encrypts a small secret (relay space/device keys) with the master
// key; label binds it to its purpose so sealed values can't be swapped.
func (s *Store) SealSecret(plain []byte, label string) ([]byte, error) {
	if s.master == nil {
		return nil, errors.New("blob: relay mode requires encryption at rest (FS_ENCRYPT=true)")
	}
	n := make([]byte, s.master.NonceSize())
	if _, err := rand.Read(n); err != nil {
		return nil, err
	}
	return s.master.Seal(n, n, plain, []byte("secret:"+label)), nil
}

func (s *Store) OpenSecret(sealed []byte, label string) ([]byte, error) {
	if s.master == nil || len(sealed) < s.master.NonceSize() {
		return nil, ErrCorrupt
	}
	ns := s.master.NonceSize()
	p, err := s.master.Open(nil, sealed[:ns], sealed[ns:], []byte("secret:"+label))
	if err != nil {
		return nil, ErrCorrupt
	}
	return p, nil
}
