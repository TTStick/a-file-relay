package e2e

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

// TestWriteVectors writes interop vectors for the Dart client's test
// (client/test/e2e_test.dart). Run with FS_WRITE_VECTORS=path.
func TestWriteVectors(t *testing.T) {
	path := os.Getenv("FS_WRITE_VECTORS")
	if path == "" {
		t.Skip("set FS_WRITE_VECTORS to write vectors")
	}
	sk := bytes.Repeat([]byte{7}, 32)
	dk := bytes.Repeat([]byte{9}, 32)
	content := make([]byte, SegSize+123)
	for i := range content {
		content[i] = byte(i * 31)
	}
	var blob bytes.Buffer
	if err := EncryptBlob(&blob, bytes.NewReader(content), int64(len(content)), 5, sk); err != nil {
		t.Fatal(err)
	}
	env := SealEnvelope(dk, []byte(`{"t":"ping"}`), OpAAD("devdevdevdevdevdevdevdevde", "0123456789abcdef0123456789abcdef"))
	secret := []byte("0123456789abcdef")
	lookup, pkey := Pairing(secret)
	v := map[string]any{
		"space_key":   hex.EncodeToString(sk),
		"device_key":  hex.EncodeToString(dk),
		"kid":         5,
		"content_hex": hex.EncodeToString(content),
		"blob":        base64.StdEncoding.EncodeToString(blob.Bytes()),
		"envelope":    env,
		"device":      "devdevdevdevdevdevdevdevde",
		"op":          "0123456789abcdef0123456789abcdef",
		"snapshot":    base64.StdEncoding.EncodeToString(SealSnapshot([]byte(`{"hello":"世界"}`), 5, 77, "spacespacespacespacespaces", sk)),
		"space":       "spacespacespacespacespaces",
		"pair_secret": hex.EncodeToString(secret),
		"pair_lookup": lookup,
		"pair_key":    hex.EncodeToString(pkey),
		"cache_key":   CacheKey(sk, "nodeid", "abc"),
		"cipher_size": CipherSize(int64(len(content))),
	}
	b, _ := json.MarshalIndent(v, "", " ")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestReadDartVectors checks ciphertext produced by the Dart client
// (written by its test to FS_DART_VECTORS).
func TestReadDartVectors(t *testing.T) {
	path := os.Getenv("FS_DART_VECTORS")
	if path == "" {
		t.Skip("set FS_DART_VECTORS")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		SpaceKey string   `json:"space_key"`
		Size     int64    `json:"size"`
		Blob     string   `json:"blob"`
		Content  string   `json:"content_hex"`
		Envelope Envelope `json:"envelope"`
		DevKey   string   `json:"device_key"`
	}
	json.Unmarshal(raw, &v)
	sk, _ := hex.DecodeString(v.SpaceKey)
	blob, _ := base64.StdEncoding.DecodeString(v.Blob)
	r, err := DecryptBlob(bytes.NewReader(blob), v.Size, Keyring{5: sk}, HeaderNonce(blob))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if _, err := out.ReadFrom(r); err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(out.Bytes()) != v.Content {
		t.Fatal("Dart blob content mismatch")
	}
	dk, _ := hex.DecodeString(v.DevKey)
	p, err := OpenEnvelope(dk, v.Envelope, ReplyAAD("dev", "op"))
	if err != nil || string(p) != "from dart" {
		t.Fatalf("Dart envelope: %v %q", err, p)
	}
}
