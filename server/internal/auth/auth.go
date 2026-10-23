// Package auth holds password hashing, device tokens and login throttling.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters (RFC 9106, memory-constrained profile), sized for NAS CPUs.
const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 2
	argonKeyLen  = 32
)

func HashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(pw), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

func VerifyPassword(encoded, pw string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var m uint32
	var t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(parts[4])
	want, err2 := base64.RawStdEncoding.DecodeString(parts[5])
	if err1 != nil || err2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pw), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

func ValidatePassword(pw string) error {
	if len([]rune(pw)) < 8 {
		return errors.New("密码至少 8 位")
	}
	if len(pw) > 256 {
		return errors.New("密码过长")
	}
	return nil
}

// NewToken returns a device token and the hash stored server-side. Only the
// hash is kept, so a leaked database doesn't leak working tokens.
func NewToken() (token, hash string) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	token = "fsw_" + base64.RawURLEncoding.EncodeToString(b)
	return token, HashToken(token)
}

func HashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

func RandomPassword() string {
	b := make([]byte, 12)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// Limiter throttles password guessing on three levels:
//   - per client IP: 20 failures in 15 minutes, for any account;
//   - per account and IP: a short lock after 5 failures, doubling up to 15 minutes;
//   - per account from all IPs: 50 failures in 15 minutes locks the account
//     for the rest of that window. This only stops distributed guessing; it is
//     high enough that one or two sources can't keep the owner locked out, and
//     it never lasts longer than 15 minutes after the guessing stops.
//
// Callers must pass the same normalized username to Allow, Fail and Success.
type Limiter struct {
	mu    sync.Mutex
	ips   map[string][]time.Time
	users map[string][]time.Time
	pairs map[string]*lockState
}

type lockState struct {
	fails       int
	last        time.Time
	lockedUntil time.Time
}

const (
	window       = 15 * time.Minute
	ipMaxFails   = 20
	userMaxFails = 50
	pairFree     = 5
	maxLock      = 15 * time.Minute
	// above this many tracked keys, stale entries are swept on the spot
	maxTracked = 50000
)

func NewLimiter() *Limiter {
	return &Limiter{ips: map[string][]time.Time{}, users: map[string][]time.Time{}, pairs: map[string]*lockState{}}
}

// NormalizeUsername is how login names are compared everywhere.
func NormalizeUsername(s string) string { return strings.TrimSpace(s) }

func pairKey(ip, user string) string { return strings.ToLower(user) + "\x00" + ip }

// Allow returns how long the caller must wait, or 0 if a login attempt may proceed.
func (l *Limiter) Allow(ip, user string) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	var wait time.Duration
	if f := recent(l.ips, ip, now); len(f) >= ipMaxFails {
		wait = max(wait, f[len(f)-ipMaxFails].Add(window).Sub(now))
	}
	if st := l.pairs[pairKey(ip, user)]; st != nil && now.Before(st.lockedUntil) {
		wait = max(wait, st.lockedUntil.Sub(now))
	}
	if f := recent(l.users, strings.ToLower(user), now); len(f) >= userMaxFails {
		wait = max(wait, f[len(f)-userMaxFails].Add(window).Sub(now))
	}
	return wait
}

// recent drops failures older than the window and returns the rest.
func recent(m map[string][]time.Time, key string, now time.Time) []time.Time {
	f := m[key]
	i := 0
	for i < len(f) && now.Sub(f[i]) > window {
		i++
	}
	if i == len(f) {
		delete(m, key)
		return nil
	}
	f = f[i:]
	m[key] = f
	return f
}

func (l *Limiter) Fail(ip, user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if len(l.ips)+len(l.users)+len(l.pairs) > maxTracked {
		l.sweep(now)
	}
	l.ips[ip] = append(recent(l.ips, ip, now), now)
	u := strings.ToLower(user)
	l.users[u] = append(recent(l.users, u, now), now)
	k := pairKey(ip, user)
	st := l.pairs[k]
	if st == nil || now.Sub(st.last) > window {
		st = &lockState{}
		l.pairs[k] = st
	}
	st.fails++
	st.last = now
	if st.fails >= pairFree {
		lock := 30 * time.Second << min(st.fails-pairFree, 10)
		st.lockedUntil = now.Add(min(lock, maxLock))
	}
}

// Success clears the lock for this account from this IP. Failures counted
// against the account as a whole stay until they age out of the window.
func (l *Limiter) Success(ip, user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.pairs, pairKey(ip, user))
}

// Sweep drops stale entries so the maps don't grow without bound.
func (l *Limiter) Sweep() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sweep(time.Now())
}

func (l *Limiter) sweep(now time.Time) {
	for k := range l.ips {
		recent(l.ips, k, now)
	}
	for k := range l.users {
		recent(l.users, k, now)
	}
	for k, st := range l.pairs {
		if now.After(st.lockedUntil) && now.Sub(st.last) > window {
			delete(l.pairs, k)
		}
	}
	// Still full: the IP table is flooded with fresh entries. Forget it rather
	// than run out of memory; the per-account limits keep working.
	if len(l.ips) > maxTracked/2 {
		l.ips = map[string][]time.Time{}
	}
}
