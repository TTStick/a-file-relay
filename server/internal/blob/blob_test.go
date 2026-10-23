package blob

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"testing"
)

func roundTrip(t *testing.T, key []byte, size int) {
	t.Helper()
	s, err := New(t.TempDir(), key)
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, size)
	rand.Read(data)
	w, err := s.Create("abcdef", int64(size))
	if err != nil {
		t.Fatal(err)
	}
	// Send the first half, "lose the connection" mid-segment, then resume.
	half := size / 2
	if err := w.Fill(bytes.NewReader(data[:half])); err != nil {
		t.Fatal(err)
	}
	got := w.Received()
	if got%SegSize != 0 && got != int64(size) {
		t.Fatalf("received %d not aligned", got)
	}
	state := w.HashState()
	w.Close()
	w, err = s.Resume("abcdef", int64(size), got, state, key != nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Fill(bytes.NewReader(data[got:])); err != nil {
		t.Fatal(err)
	}
	if !w.Done() {
		t.Fatalf("not done: %d/%d", w.Received(), size)
	}
	sum := sha256.Sum256(data)
	if w.SHA256() != hex.EncodeToString(sum[:]) {
		t.Fatal("hash mismatch")
	}
	w.Close()
	if err := s.Commit("abcdef"); err != nil {
		t.Fatal(err)
	}
	r, err := s.Open("abcdef", int64(size), key != nil)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	all, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(all, data) {
		t.Fatal("content mismatch")
	}
	// random access
	for _, off := range []int{0, 1, SegSize - 1, SegSize, size / 3, size - 1} {
		if off < 0 || off >= size {
			continue
		}
		if _, err := r.Seek(int64(off), io.SeekStart); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, min(1000, size-off))
		if _, err := io.ReadFull(r, buf); err != nil {
			t.Fatalf("read at %d: %v", off, err)
		}
		if !bytes.Equal(buf, data[off:off+len(buf)]) {
			t.Fatalf("mismatch at %d", off)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	key := make([]byte, 32)
	rand.Read(key)
	for _, size := range []int{0, 1, SegSize - 1, SegSize, SegSize + 1, 3*SegSize + 17, 5 * SegSize} {
		roundTrip(t, key, size)
		roundTrip(t, nil, size)
	}
}

func TestTamperDetected(t *testing.T) {
	key := make([]byte, 32)
	rand.Read(key)
	dir := t.TempDir()
	s, _ := New(dir, key)
	data := bytes.Repeat([]byte("x"), 2*SegSize+5)
	w, _ := s.Create("zzzzzz", int64(len(data)))
	w.Fill(bytes.NewReader(data))
	w.Close()
	s.Commit("zzzzzz")
	f, _ := os.OpenFile(s.FinalPath("zzzzzz"), os.O_RDWR, 0)
	b := make([]byte, 1)
	f.ReadAt(b, headerSize+SegSize+100)
	f.WriteAt([]byte{b[0] ^ 1}, headerSize+SegSize+100)
	f.Close()
	r, _ := s.Open("zzzzzz", int64(len(data)), true)
	if _, err := io.ReadAll(r); err != ErrCorrupt {
		t.Fatalf("want ErrCorrupt, got %v", err)
	}
	// truncation: an intact blob read as if it were one segment shorter
	w, _ = s.Create("yyyyyy", int64(len(data)))
	w.Fill(bytes.NewReader(data))
	w.Close()
	s.Commit("yyyyyy")
	r2, _ := s.Open("yyyyyy", int64(2*SegSize), true)
	if _, err := io.ReadAll(r2); err != ErrCorrupt {
		t.Fatalf("truncation not detected: %v", err)
	}
	// wrong key
	other := make([]byte, 32)
	rand.Read(other)
	s3, _ := New(dir, other)
	if _, err := s3.Open("zzzzzz", int64(len(data)), true); err != ErrCorrupt {
		t.Fatalf("wrong key not detected: %v", err)
	}
}
