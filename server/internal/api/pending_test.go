package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"fileswitch/internal/e2e"
)

type pendingMeta struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	Nonce string `json:"nonce"`
}

// announce does what the apps do after an upload to the relay finishes.
func (c *rclient) announce(blob string, m pendingMeta) int {
	plain, _ := json.Marshal(m)
	env := e2e.SealEnvelope(c.ring[c.kid], plain, e2e.PendingAAD(c.space, blob))
	return c.jsonDo("PUT", "/r/v1/blobs/"+blob+"/announce", map[string]any{"kid": c.kid, "n": env.N, "c": env.C}, nil)
}

type pendingItem struct {
	ID     string       `json:"id"`
	Device string       `json:"device"`
	Kid    uint32       `json:"kid"`
	Meta   e2e.Envelope `json:"meta"`
	Size   int64        `json:"size"`
}

func (c *rclient) pending() []pendingItem {
	var res struct {
		Items []pendingItem `json:"items"`
	}
	if st := c.jsonDo("GET", "/r/v1/pending", nil, &res); st != 200 {
		c.e.t.Fatalf("pending: %d", st)
	}
	return res.Items
}

// Files that reached the relay but not yet the NAS can be fetched by the
// user's other devices straight from the relay.
func TestPendingUploadsFromRelay(t *testing.T) {
	e := setupRelay(t)
	e.lan.token = login(e.lan, "Mac")
	mac := e.clientFrom(enrollLAN(t, e))
	phoneLAN := &client{t: t, base: e.lan.base}
	phoneLAN.token = login(phoneLAN, "Phone")
	phone := e.clientFrom(enrollOn(t, phoneLAN))
	for _, c := range []*rclient{mac, phone} {
		waitUntil(t, "relay to accept the device", func() bool {
			st, _ := c.do("GET", "/r/v1/status", nil, nil)
			return st == 200
		})
	}

	content := []byte(strings.Repeat("会议录音-", 30000))
	blob, nonce := mac.upload(content)
	if st := mac.announce(blob, pendingMeta{Name: "录音.m4a", Path: "临时/录音.m4a", Size: int64(len(content)), Nonce: nonce}); st != 204 {
		t.Fatalf("announce: %d", st)
	}
	if st := phone.announce(blob, pendingMeta{Name: "x"}); st != 404 {
		t.Fatalf("another device announced the upload: %d", st)
	}

	items := phone.pending()
	if len(items) != 1 || items[0].ID != blob || items[0].Device != mac.device {
		t.Fatalf("pending: %+v", items)
	}
	plain, err := e2e.OpenEnvelope(phone.ring[items[0].Kid], items[0].Meta, e2e.PendingAAD(phone.space, blob))
	if err != nil {
		t.Fatal(err)
	}
	var m pendingMeta
	json.Unmarshal(plain, &m)
	if m.Name != "录音.m4a" || m.Path != "临时/录音.m4a" {
		t.Fatalf("meta: %+v", m)
	}
	st, ct := phone.do("GET", "/r/v1/pending/"+blob, nil, nil)
	if st != 200 {
		t.Fatalf("download: %d", st)
	}
	want, _ := base64.StdEncoding.DecodeString(m.Nonce)
	r, err := e2e.DecryptBlob(bytes.NewReader(ct), m.Size, phone.ring, want)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := io.ReadAll(r); err != nil || !bytes.Equal(got, content) {
		t.Fatalf("decrypted content differs (%v)", err)
	}
	if st, part := phone.do("GET", "/r/v1/pending/"+blob, nil, map[string]string{"Range": "bytes=100-"}); st != 206 || !bytes.Equal(part, ct[100:]) {
		t.Fatalf("resumed download: %d", st)
	}

	// The description is bound to its blob: moved to another upload it no longer opens.
	other, _ := mac.upload([]byte("x"))
	if _, err := e2e.OpenEnvelope(phone.ring[items[0].Kid], items[0].Meta, e2e.PendingAAD(phone.space, other)); err == nil {
		t.Fatal("description opened for a different blob")
	}

	// Unfinished uploads can't be announced.
	var created struct {
		ID string `json:"id"`
	}
	mac.jsonDo("POST", "/r/v1/blobs", map[string]int{"size": 1000}, &created)
	mac.do("PUT", "/r/v1/blobs/"+created.ID+"?offset=0", make([]byte, 10), nil)
	if st := mac.announce(created.ID, pendingMeta{Name: "half"}); st != 409 {
		t.Fatalf("unfinished upload announced: %d", st)
	}

	// Devices of another NAS see nothing.
	_, lanB := e.addNAS()
	lanB.token = login(lanB, "Mac")
	stranger := e.clientFrom(enrollOn(t, lanB))
	waitUntil(t, "relay to accept the other NAS's device", func() bool {
		st, _ := stranger.do("GET", "/r/v1/status", nil, nil)
		return st == 200
	})
	if len(stranger.pending()) != 0 {
		t.Fatal("pending uploads visible across spaces")
	}
	if st, _ := stranger.do("GET", "/r/v1/pending/"+blob, nil, nil); st != 404 {
		t.Fatalf("download across spaces: %d", st)
	}

	// Once the NAS has collected the file it's gone from the list.
	res := mac.await(mac.send(map[string]any{"t": "upload",
		"files": []map[string]any{{"rel": "录音.m4a", "blob": blob, "nonce": nonce, "size": len(content), "mtime": 1}}}))
	if !res.OK {
		t.Fatalf("upload op: %s", res.Error)
	}
	waitUntil(t, "pending entry to go away", func() bool { return len(phone.pending()) == 0 })
	if st, _ := phone.do("GET", "/r/v1/pending/"+blob, nil, nil); st != http.StatusNotFound {
		t.Fatalf("collected upload still downloadable: %d", st)
	}
}
