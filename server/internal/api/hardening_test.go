package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"fileswitch/internal/config"
)

// Padding the username used to land in a different throttle bucket while
// still matching the real account.
func TestLoginThrottleIgnoresPadding(t *testing.T) {
	c, _ := setup(t)
	for _, name := range []string{" alice", "alice ", "\talice", " alice ", "alice\n"} {
		c.do("POST", "/api/v1/auth/login", map[string]string{"username": name, "password": "nope"}, 401)
	}
	c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "password123"}, 429)
}

func TestLoginThrottleSaysHowLong(t *testing.T) {
	c, _ := setup(t)
	for i := 0; i < 5; i++ {
		c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "nope"}, 401)
	}
	res := c.do("POST", "/api/v1/auth/login", map[string]string{"username": "alice", "password": "password123"}, 429)
	if msg := res["error"].(map[string]any)["message"].(string); !strings.Contains(msg, "30 秒后再试") {
		t.Fatalf("message %q doesn't say how long to wait", msg)
	}
}

func TestLastHop(t *testing.T) {
	for in, want := range map[string]string{
		"203.0.113.7":                  "203.0.113.7",
		"1.2.3.4, 203.0.113.7":         "203.0.113.7",
		" 6.6.6.6 ,1.2.3.4,  10.0.0.5": "10.0.0.5",
	} {
		if got := lastHop(in); got != want {
			t.Errorf("lastHop(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUserQuota(t *testing.T) {
	c, s := setup(t)
	s.cfg.UserQuota = 1000
	c.token = login(c, "Mac")
	c.do("PUT", "/api/v1/files?path=a.bin&size=600", make([]byte, 600), 200)
	c.do("PUT", "/api/v1/files?path=b.bin&size=600", make([]byte, 600), 507)
	// open resumable uploads count too
	c.do("POST", "/api/v1/uploads", map[string]any{"path": "c.bin", "size": 300}, 201)
	c.do("POST", "/api/v1/uploads", map[string]any{"path": "d.bin", "size": 300}, 507)
}

// Parallel uploads used to pass the quota check before any of them was counted.
func TestRelayQuotaIsAtomic(t *testing.T) {
	e := setupRelay(t)
	e.lan.token = login(e.lan, "Mac")
	mac := e.clientFrom(enrollLAN(t, e))
	waitUntil(t, "relay to accept the token", func() bool {
		st, _ := mac.do("GET", "/r/v1/status", nil, nil)
		return st == 200
	})
	var mu sync.Mutex
	var wg sync.WaitGroup
	ok := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, _ := json.Marshal(map[string]int64{"size": 1 << 30})
			if st, _ := mac.do("POST", "/r/v1/blobs", body, nil); st == 201 {
				mu.Lock()
				ok++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if ok != 4 { // 4 GiB quota, 1 GiB each
		t.Fatalf("%d reservations of 1 GiB went through a 4 GiB quota", ok)
	}
}

// Revoking on the LAN should reach the relay right away, not on the next poll.
func TestLANRevokeReachesRelayQuickly(t *testing.T) {
	e := setupRelay(t, func(c *config.Config) { c.RelayInterval = time.Hour })
	e.lan.token = login(e.lan, "Mac")
	b := enrollLAN(t, e)
	mac := e.clientFrom(b)
	waitUntil(t, "relay to accept the token", func() bool {
		st, _ := mac.do("GET", "/r/v1/status", nil, nil)
		return st == 200
	})
	admin := &client{t: t, base: e.lan.base}
	admin.token = login(admin, "Admin")
	// let the fast-poll period from the enrollment run out of the picture:
	// whatever the agent does next must come from the revoke itself
	time.Sleep(100 * time.Millisecond)
	admin.do("DELETE", "/api/v1/devices/"+mac.device, nil, 204)
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if st, _ := mac.do("GET", "/r/v1/status", nil, nil); st == http.StatusUnauthorized {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("relay still accepts the revoked device's token")
}

func enrollLAN(t *testing.T, e *relayEnv) enrollBundle {
	t.Helper()
	req, _ := http.NewRequest("POST", e.lan.base+"/api/v1/relay/enroll", nil)
	req.Header.Set("Authorization", "Bearer "+e.lan.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var b enrollBundle
	json.NewDecoder(resp.Body).Decode(&b)
	if resp.StatusCode != 200 || b.RelayToken == "" {
		t.Fatal(fmt.Sprintf("enroll: %d", resp.StatusCode))
	}
	return b
}
