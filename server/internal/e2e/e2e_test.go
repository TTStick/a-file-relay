package e2e

import (
	"bytes"
	"crypto/rand"
	"io"
	"testing"
)

func TestBlobRoundTrip(t *testing.T) {
	sk := NewKey()
	keys := Keyring{7: sk}
	for _, size := range []int{0, 1, SegSize - 1, SegSize, SegSize + 1, 3*SegSize + 5} {
		data := make([]byte, size)
		rand.Read(data)
		var buf bytes.Buffer
		if err := EncryptBlob(&buf, bytes.NewReader(data), int64(size), 7, sk); err != nil {
			t.Fatal(err)
		}
		if int64(buf.Len()) != CipherSize(int64(size)) {
			t.Fatalf("size %d: cipher %d want %d", size, buf.Len(), CipherSize(int64(size)))
		}
		r, err := DecryptBlob(bytes.NewReader(buf.Bytes()), int64(size), keys, HeaderNonce(buf.Bytes()))
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(r)
		if err != nil || !bytes.Equal(got, data) {
			t.Fatalf("size %d: mismatch %v", size, err)
		}
		// a different (valid) blob than the one the op referenced → must fail
		if _, err := DecryptBlob(bytes.NewReader(buf.Bytes()), int64(size), keys, make([]byte, NonceSize)); err != ErrAuth {
			t.Fatalf("blob substitution not detected: %v", err)
		}
		// flip a bit anywhere → must fail
		if size > 0 {
			bad := bytes.Clone(buf.Bytes())
			bad[len(bad)-3] ^= 1
			r, _ := DecryptBlob(bytes.NewReader(bad), int64(size), keys, nil)
			if _, err := io.ReadAll(r); err != ErrAuth {
				t.Fatalf("tamper not detected: %v", err)
			}
		}
		// trailing garbage → must fail
		r, _ = DecryptBlob(io.MultiReader(bytes.NewReader(buf.Bytes()), bytes.NewReader([]byte{1})), int64(size), keys, nil)
		if _, err := io.ReadAll(r); err != ErrAuth {
			t.Fatalf("extension not detected: %v", err)
		}
	}
}

func TestEnvelopeBinding(t *testing.T) {
	k := NewKey()
	e := SealEnvelope(k, []byte("hello"), OpAAD("dev1", "op1"))
	if p, err := OpenEnvelope(k, e, OpAAD("dev1", "op1")); err != nil || string(p) != "hello" {
		t.Fatal("open failed")
	}
	if _, err := OpenEnvelope(k, e, OpAAD("dev2", "op1")); err == nil {
		t.Fatal("envelope accepted for another device")
	}
	if _, err := OpenEnvelope(k, e, ReplyAAD("dev1", "op1")); err == nil {
		t.Fatal("op accepted as reply")
	}
}

func TestSnapshot(t *testing.T) {
	k := NewKey()
	s := SealSnapshot([]byte(`{"a":1}`), 3, 42, "space", k)
	p, v, err := OpenSnapshot(s, "space", Keyring{3: k})
	if err != nil || v != 42 || string(p) != `{"a":1}` {
		t.Fatalf("snapshot: %v %d %s", err, v, p)
	}
	if _, _, err := OpenSnapshot(s, "other", Keyring{3: k}); err == nil {
		t.Fatal("snapshot accepted for another space")
	}
}
