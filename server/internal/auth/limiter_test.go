package auth

import (
	"fmt"
	"testing"
	"time"
)

func TestLimiterLocksPairNotAccount(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < pairFree; i++ {
		l.Fail("10.0.0.9", "alice")
	}
	if l.Allow("10.0.0.9", "alice") == 0 {
		t.Fatal("guessing IP should be locked out of the account")
	}
	if w := l.Allow("10.0.0.2", "alice"); w != 0 {
		t.Fatalf("owner on another IP was locked out for %v", w)
	}
	if w := l.Allow("10.0.0.9", "bob"); w != 0 {
		t.Fatalf("other accounts from the same IP should still work, got %v", w)
	}
}

func TestLimiterLockIsBounded(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < 200; i++ {
		l.Fail("10.0.0.9", "alice")
	}
	if w := l.Allow("10.0.0.9", "alice"); w <= 0 || w > maxLock {
		t.Fatalf("lock %v, want (0, %v]", w, maxLock)
	}
}

func TestLimiterLockDoesNotRenewForever(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < 20; i++ {
		l.Fail("10.0.0.9", "alice")
	}
	// An hour later one more wrong guess must not bring back a long lock.
	st := l.pairs[pairKey("10.0.0.9", "alice")]
	st.last = time.Now().Add(-time.Hour)
	st.lockedUntil = time.Now().Add(-time.Minute)
	l.ips = map[string][]time.Time{}
	l.users = map[string][]time.Time{}
	l.Fail("10.0.0.9", "alice")
	if w := l.Allow("10.0.0.9", "alice"); w != 0 {
		t.Fatalf("one failure after a quiet hour locked the account for %v", w)
	}
}

func TestLimiterStopsDistributedGuessing(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < userMaxFails; i++ {
		l.Fail(fmt.Sprintf("203.0.113.%d", i), "alice")
	}
	w := l.Allow("198.51.100.1", "alice")
	if w <= 0 || w > window {
		t.Fatalf("account-wide lock %v, want (0, %v]", w, window)
	}
	if l.Allow("198.51.100.1", "bob") != 0 {
		t.Fatal("other accounts must not be affected")
	}
}

func TestLimiterSweep(t *testing.T) {
	l := NewLimiter()
	for i := 0; i < 1000; i++ {
		l.Fail(fmt.Sprintf("192.0.2.%d", i), "alice")
	}
	old := time.Now().Add(-time.Hour)
	for k := range l.ips {
		l.ips[k] = []time.Time{old}
	}
	for k := range l.users {
		l.users[k] = []time.Time{old}
	}
	for _, st := range l.pairs {
		st.last, st.lockedUntil = old, old
	}
	l.Sweep()
	if n := len(l.ips) + len(l.users) + len(l.pairs); n != 0 {
		t.Fatalf("%d stale entries left after sweep", n)
	}
}
