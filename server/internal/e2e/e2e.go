// Package e2e is the end-to-end encryption shared by the NAS and clients when
// they talk through a relay. The relay only ever stores and forwards what this
// package produces, so a compromised relay sees ciphertext, sizes and timing.
//
// All AEAD is XChaCha20-Poly1305 (fast in pure Dart on the clients).
//
//   - Space key  (per user, versioned by key id): encrypts blobs' file keys and snapshots.
//   - Device key (per enrolled device, shared only with the NAS): encrypts ops, replies, keyrings.
//   - File key   (random per blob): encrypts the blob's 64 KiB segments.
//
// See docs/relay-protocol.md for the wire formats.
package e2e

import (
	"bytes"
	"compress/gzip"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	KeySize    = 32
	NonceSize  = chacha20poly1305.NonceSizeX // 24
	TagSize    = 16
	SegSize    = 64 * 1024
	HeaderSize = 4 + 4 + 4 + NonceSize + KeySize + TagSize // 84
	blobMagic  = "FSE1"
	snapMagic  = "FSS1"
)

var ErrAuth = errors.New("e2e: authentication failed")

func NewKey() []byte {
	k := make([]byte, KeySize)
	if _, err := rand.Read(k); err != nil {
		panic(err)
	}
	return k
}

func nonce() []byte {
	n := make([]byte, NonceSize)
	if _, err := rand.Read(n); err != nil {
		panic(err)
	}
	return n
}

func seal(key, nonce, plain, aad []byte) []byte {
	a, err := chacha20poly1305.NewX(key)
	if err != nil {
		panic(err) // only on a wrong key size, which is a programming error
	}
	return a.Seal(nil, nonce, plain, aad)
}

func open(key, nonce, ct, aad []byte) ([]byte, error) {
	if len(key) != KeySize || len(nonce) != NonceSize {
		return nil, ErrAuth
	}
	a, _ := chacha20poly1305.NewX(key)
	p, err := a.Open(nil, nonce, ct, aad)
	if err != nil {
		return nil, ErrAuth
	}
	return p, nil
}

// Envelope is a small sealed message (ops, replies, keyrings, pairing).
type Envelope struct {
	N string `json:"n"` // base64 nonce
	C string `json:"c"` // base64 ciphertext
}

func SealEnvelope(key, plain []byte, aad string) Envelope {
	n := nonce()
	return Envelope{
		N: base64.StdEncoding.EncodeToString(n),
		C: base64.StdEncoding.EncodeToString(seal(key, n, plain, []byte(aad))),
	}
}

func OpenEnvelope(key []byte, e Envelope, aad string) ([]byte, error) {
	n, err1 := base64.StdEncoding.DecodeString(e.N)
	c, err2 := base64.StdEncoding.DecodeString(e.C)
	if err1 != nil || err2 != nil {
		return nil, ErrAuth
	}
	return open(key, n, c, []byte(aad))
}

// AAD labels bind each envelope to its purpose and identifiers, so a relay
// can't replay one kind of message as another or move it between devices.
func OpAAD(deviceID, opID string) string    { return "fsop1|" + deviceID + "|" + opID }
func ReplyAAD(deviceID, opID string) string { return "fsrp1|" + deviceID + "|" + opID }
func KeyringAAD(deviceID string) string     { return "fskr1|" + deviceID }
func PairReqAAD(lookup string) string       { return "fspq1|" + lookup }
func PairRespAAD(lookup string) string      { return "fsps1|" + lookup }

// Pairing derives the relay lookup id and the envelope key from the one-time
// pairing secret. The secret itself never reaches the relay.
func Pairing(secret []byte) (lookup string, key []byte) {
	l, err := hkdf.Key(sha256.New, secret, []byte("fileswitch-pair"), "lookup", 16)
	if err != nil {
		panic(err)
	}
	k, err := hkdf.Key(sha256.New, secret, []byte("fileswitch-pair"), "key", KeySize)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(l), k
}

// CacheKey is the relay-side name of a cached copy of a file; it reveals
// nothing about the file and changes whenever the space key rotates.
func CacheKey(spaceKey []byte, nodeID, sha string) string {
	m := hmac.New(sha256.New, spaceKey)
	m.Write([]byte("cache|" + nodeID + "|" + sha))
	return hex.EncodeToString(m.Sum(nil)[:16])
}

// --- blobs ---

// CipherSize is the size of an encrypted blob holding size plaintext bytes.
func CipherSize(size int64) int64 {
	n := max(1, (size+SegSize-1)/SegSize)
	return HeaderSize + size + n*TagSize
}

func segNonce(i int64) []byte {
	n := make([]byte, NonceSize)
	binary.BigEndian.PutUint64(n[16:], uint64(i))
	return n
}

func segAAD(final bool) []byte {
	if final {
		return []byte{1}
	}
	return []byte{0}
}

func blobHeaderAAD(kid uint32) []byte {
	b := []byte(blobMagic)
	return binary.BigEndian.AppendUint32(b, kid)
}

// HeaderNonce returns the random nonce identifying an encrypted blob.
func HeaderNonce(header []byte) []byte {
	if len(header) < 12+NonceSize {
		return nil
	}
	return header[12 : 12+NonceSize]
}

// EncryptBlob streams plaintext (exactly size bytes) from r to w as an FSE1 blob.
func EncryptBlob(w io.Writer, r io.Reader, size int64, kid uint32, spaceKey []byte) error {
	fk := NewKey()
	n := nonce()
	hdr := make([]byte, 0, HeaderSize)
	hdr = append(hdr, blobMagic...)
	hdr = append(hdr, 1, 0, 0, 0)
	hdr = binary.BigEndian.AppendUint32(hdr, kid)
	hdr = append(hdr, n...)
	hdr = append(hdr, seal(spaceKey, n, fk, blobHeaderAAD(kid))...)
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	a, _ := chacha20poly1305.NewX(fk)
	nseg := max(1, (size+SegSize-1)/SegSize)
	buf := make([]byte, SegSize)
	out := make([]byte, 0, SegSize+TagSize)
	for i := int64(0); i < nseg; i++ {
		want := min(int64(SegSize), size-i*SegSize)
		if _, err := io.ReadFull(r, buf[:want]); err != nil {
			return fmt.Errorf("e2e: read plaintext: %w", err)
		}
		out = a.Seal(out[:0], segNonce(i), buf[:want], segAAD(i == nseg-1))
		if _, err := w.Write(out); err != nil {
			return err
		}
	}
	return nil
}

// Keyring maps key ids to space keys.
type Keyring map[uint32][]byte

// DecryptBlob returns a reader of the plaintext of an FSE1 blob whose
// plaintext is expected to be size bytes. Any tampering, truncation or
// extension makes Read fail with ErrAuth. wantNonce, if set, must equal the
// blob's header nonce: it binds the blob to the operation that referenced it,
// so a relay can't substitute another valid blob.
func DecryptBlob(r io.Reader, size int64, keys Keyring, wantNonce []byte) (io.Reader, error) {
	hdr := make([]byte, HeaderSize)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return nil, ErrAuth
	}
	if string(hdr[:4]) != blobMagic || hdr[4] != 1 {
		return nil, ErrAuth
	}
	if wantNonce != nil && !bytes.Equal(wantNonce, hdr[12:12+NonceSize]) {
		return nil, ErrAuth
	}
	kid := binary.BigEndian.Uint32(hdr[8:12])
	sk := keys[kid]
	if sk == nil {
		return nil, fmt.Errorf("e2e: unknown key id %d", kid)
	}
	fk, err := open(sk, hdr[12:12+NonceSize], hdr[12+NonceSize:], blobHeaderAAD(kid))
	if err != nil {
		return nil, err
	}
	a, _ := chacha20poly1305.NewX(fk)
	return &blobReader{r: r, a: a, size: size, nseg: max(1, (size+SegSize-1)/SegSize)}, nil
}

type blobReader struct {
	r io.Reader
	a interface {
		Open(dst, nonce, ct, aad []byte) ([]byte, error)
	}
	size int64
	nseg int64
	i    int64
	ct   []byte
	pt   []byte
	err  error
}

func (b *blobReader) Read(p []byte) (int, error) {
	for len(b.pt) == 0 {
		if b.err != nil {
			return 0, b.err
		}
		if b.i == b.nseg {
			// the blob must end exactly here
			var one [1]byte
			if n, _ := b.r.Read(one[:]); n > 0 {
				b.err = ErrAuth
				return 0, b.err
			}
			b.err = io.EOF
			return 0, io.EOF
		}
		want := min(int64(SegSize), b.size-b.i*SegSize) + TagSize
		if cap(b.ct) < SegSize+TagSize {
			b.ct = make([]byte, SegSize+TagSize)
		}
		ct := b.ct[:want]
		if _, err := io.ReadFull(b.r, ct); err != nil {
			b.err = ErrAuth
			return 0, b.err
		}
		pt, err := b.a.Open(ct[:0], segNonce(b.i), ct, segAAD(b.i == b.nseg-1))
		if err != nil {
			b.err = ErrAuth
			return 0, b.err
		}
		b.pt = pt
		b.i++
	}
	n := copy(p, b.pt)
	b.pt = b.pt[n:]
	return n, nil
}

// --- snapshots ---

func snapAAD(kid uint32, version uint64, spaceID string) []byte {
	b := []byte(snapMagic)
	b = binary.BigEndian.AppendUint32(b, kid)
	b = binary.BigEndian.AppendUint64(b, version)
	return append(b, spaceID...)
}

// SealSnapshot gzips and encrypts a space's metadata snapshot.
func SealSnapshot(plainJSON []byte, kid uint32, version uint64, spaceID string, spaceKey []byte) []byte {
	var z bytes.Buffer
	zw := gzip.NewWriter(&z)
	zw.Write(plainJSON)
	zw.Close()
	n := nonce()
	out := []byte(snapMagic)
	out = binary.BigEndian.AppendUint32(out, kid)
	out = binary.BigEndian.AppendUint64(out, version)
	out = append(out, n...)
	return append(out, seal(spaceKey, n, z.Bytes(), snapAAD(kid, version, spaceID))...)
}

// OpenSnapshot reverses SealSnapshot (used by tests and Go clients).
func OpenSnapshot(data []byte, spaceID string, keys Keyring) (plain []byte, version uint64, err error) {
	if len(data) < 16+NonceSize || string(data[:4]) != snapMagic {
		return nil, 0, ErrAuth
	}
	kid := binary.BigEndian.Uint32(data[4:8])
	version = binary.BigEndian.Uint64(data[8:16])
	sk := keys[kid]
	if sk == nil {
		return nil, 0, fmt.Errorf("e2e: unknown key id %d", kid)
	}
	z, err := open(sk, data[16:16+NonceSize], data[16+NonceSize:], snapAAD(kid, version, spaceID))
	if err != nil {
		return nil, 0, err
	}
	zr, err := gzip.NewReader(bytes.NewReader(z))
	if err != nil {
		return nil, 0, ErrAuth
	}
	plain, err = io.ReadAll(io.LimitReader(zr, 256<<20))
	return plain, version, err
}

// KeyringJSON is how keyrings travel inside envelopes: {"current":2,"keys":{"1":"b64",...}}.
type KeyringJSON struct {
	Current uint32            `json:"current"`
	Keys    map[string]string `json:"keys"`
}

func (k Keyring) JSON(current uint32) KeyringJSON {
	out := KeyringJSON{Current: current, Keys: map[string]string{}}
	for id, key := range k {
		out.Keys[strconv.FormatUint(uint64(id), 10)] = base64.StdEncoding.EncodeToString(key)
	}
	return out
}

func (j KeyringJSON) Keyring() (Keyring, error) {
	out := Keyring{}
	for id, b := range j.Keys {
		n, err := strconv.ParseUint(id, 10, 32)
		if err != nil {
			return nil, err
		}
		k, err := base64.StdEncoding.DecodeString(b)
		if err != nil || len(k) != KeySize {
			return nil, ErrAuth
		}
		out[uint32(n)] = k
	}
	return out, nil
}
