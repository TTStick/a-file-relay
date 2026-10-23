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

// Limiter throttles password guessing per client IP and per account.
type Limiter struct {
	mu    sync.Mutex
	ips   map[string][]time.Time
	users map[string]*userState
}

type userState struct {
	fails       int
	lockedUntil time.Time
}

const (
	ipWindow   = 15 * time.Minute
	ipMaxFails = 20
	userFree   = 5
	maxLock    = time.Hour
)

func NewLimiter() *Limiter {
	return &Limiter{ips: map[string][]time.Time{}, users: map[string]*userState{}}
}

// Allow returns how long the caller must wait, or 0 if a login attempt may proceed.
func (l *Limiter) Allow(ip, user string) time.Duration {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	fails := l.recentIP(ip, now)
	if len(fails) >= ipMaxFails {
		return fails[0].Add(ipWindow).Sub(now)
	}
	if st := l.users[strings.ToLower(user)]; st != nil && now.Before(st.lockedUntil) {
		return st.lockedUntil.Sub(now)
	}
	return 0
}

func (l *Limiter) recentIP(ip string, now time.Time) []time.Time {
	fails := l.ips[ip]
	i := 0
	for i < len(fails) && now.Sub(fails[i]) > ipWindow {
		i++
	}
	fails = fails[i:]
	l.ips[ip] = fails
	return fails
}

func (l *Limiter) Fail(ip, user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	l.ips[ip] = append(l.recentIP(ip, now), now)
	key := strings.ToLower(user)
	st := l.users[key]
	if st == nil {
		st = &userState{}
		l.users[key] = st
	}
	st.fails++
	if st.fails >= userFree {
		lock := 30 * time.Second << min(st.fails-userFree, 10)
		st.lockedUntil = now.Add(min(lock, maxLock))
	}
}

func (l *Limiter) Success(user string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.users, strings.ToLower(user))
}

// Sweep drops stale entries so the maps don't grow without bound.
func (l *Limiter) Sweep() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	for ip := range l.ips {
		if len(l.recentIP(ip, now)) == 0 {
			delete(l.ips, ip)
		}
	}
	for u, st := range l.users {
		if now.After(st.lockedUntil.Add(maxLock)) {
			delete(l.users, u)
		}
	}
}
