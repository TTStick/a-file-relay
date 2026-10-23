// Package config reads server settings from FS_* environment variables.
package config

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	DataDir      string   // FS_DATA_DIR
	Listen       string   // FS_LISTEN
	ServerName   string   // FS_SERVER_NAME
	TLS          string   // FS_TLS: auto (self-signed), off (behind a TLS-terminating proxy)
	TLSCert      string   // FS_TLS_CERT (with FS_TLS_KEY: use your own certificate)
	TLSKey       string   // FS_TLS_KEY
	TLSHosts     []string // FS_TLS_HOSTS: extra DNS names / IPs for the self-signed cert
	Encrypt      bool     // FS_ENCRYPT: encrypt file contents at rest
	MasterKey    string   // FS_MASTER_KEY (base64 or hex, 32 bytes)
	MasterKeyFil string   // FS_MASTER_KEY_FILE
	AdminUser    string   // FS_ADMIN_USER (first start only)
	AdminPass    string   // FS_ADMIN_PASSWORD (first start only)
	TrashDays    int      // FS_TRASH_DAYS
	MaxFileSize  int64    // FS_MAX_FILE_SIZE (bytes, 0 = unlimited)
	UserQuota    int64    // FS_USER_QUOTA: per-user storage incl. trash, e.g. 500G (0 = unlimited)
	TrustProxy   bool     // FS_TRUST_PROXY: take client IP from X-Forwarded-For

	// LAN: serve the HTTPS API on the local network. Turn off for a NAS that
	// is reached only through the relay (then nothing listens at all).
	LAN bool // FS_LAN

	// Relay mode: the NAS dials out to a public relay on its own schedule.
	RelayURL         string        // FS_RELAY_URL
	RelayToken       string        // FS_RELAY_TOKEN (same as the relay's FS_RELAY_NAS_TOKEN)
	RelayFingerprint string        // FS_RELAY_FINGERPRINT (pin a self-signed relay certificate)
	RelayInterval    time.Duration // FS_RELAY_INTERVAL: idle poll interval
	CacheDays        int           // FS_RELAY_CACHE_DAYS: push files newer than this to the relay cache
	CacheMaxFile     int64         // FS_RELAY_CACHE_MAX_FILE
	CacheMaxTotal    int64         // FS_RELAY_CACHE_MAX_TOTAL
	RemoteMaxFile    int64         // FS_REMOTE_MAX_FILE: largest file a remote device may upload or fetch
	RemotePurge      bool          // FS_REMOTE_PURGE: remote devices may delete permanently
	RemotePairing    bool          // FS_REMOTE_PAIRING: remote devices may create pairing codes
}

func (c *Config) RelayEnabled() bool { return c.RelayURL != "" }

// ParseSize accepts plain bytes or K/M/G/T suffixes ("512M", "4G").
func ParseSize(v string) (int64, error) {
	v = strings.ToUpper(strings.TrimSpace(v))
	mult := int64(1)
	for _, u := range []struct {
		s string
		m int64
	}{{"T", 1 << 40}, {"G", 1 << 30}, {"M", 1 << 20}, {"K", 1 << 10}} {
		t := strings.TrimSuffix(v, "B")
		if strings.HasSuffix(t, u.s) {
			v, mult = strings.TrimSuffix(t, u.s), u.m
			break
		}
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid size %q", v)
	}
	return n * mult, nil
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v := strings.ToLower(env(key, ""))
	switch v {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

func Load() (*Config, error) {
	c := &Config{
		DataDir:      env("FS_DATA_DIR", "./data"),
		Listen:       env("FS_LISTEN", ":8443"),
		ServerName:   env("FS_SERVER_NAME", "FileSwitch"),
		TLS:          strings.ToLower(env("FS_TLS", "auto")),
		TLSCert:      env("FS_TLS_CERT", ""),
		TLSKey:       env("FS_TLS_KEY", ""),
		Encrypt:      envBool("FS_ENCRYPT", true),
		MasterKey:    env("FS_MASTER_KEY", ""),
		MasterKeyFil: env("FS_MASTER_KEY_FILE", ""),
		AdminUser:    env("FS_ADMIN_USER", "admin"),
		AdminPass:    env("FS_ADMIN_PASSWORD", ""),
		TrustProxy:   envBool("FS_TRUST_PROXY", false),

		LAN:              envBool("FS_LAN", true),
		RelayURL:         strings.TrimRight(env("FS_RELAY_URL", ""), "/"),
		RelayToken:       env("FS_RELAY_TOKEN", ""),
		RelayFingerprint: env("FS_RELAY_FINGERPRINT", ""),
		RemotePurge:      envBool("FS_REMOTE_PURGE", false),
		RemotePairing:    envBool("FS_REMOTE_PAIRING", false),
	}
	for _, h := range strings.Split(env("FS_TLS_HOSTS", ""), ",") {
		if h = strings.TrimSpace(h); h != "" {
			c.TLSHosts = append(c.TLSHosts, h)
		}
	}
	var err error
	if c.TrashDays, err = strconv.Atoi(env("FS_TRASH_DAYS", "30")); err != nil {
		return nil, fmt.Errorf("FS_TRASH_DAYS: %w", err)
	}
	if c.MaxFileSize, err = strconv.ParseInt(env("FS_MAX_FILE_SIZE", "0"), 10, 64); err != nil {
		return nil, fmt.Errorf("FS_MAX_FILE_SIZE: %w", err)
	}
	if c.RelayInterval, err = time.ParseDuration(env("FS_RELAY_INTERVAL", "20s")); err != nil || c.RelayInterval < time.Second {
		return nil, errors.New("FS_RELAY_INTERVAL must be a duration like 20s or 5m")
	}
	if c.CacheDays, err = strconv.Atoi(env("FS_RELAY_CACHE_DAYS", "7")); err != nil {
		return nil, fmt.Errorf("FS_RELAY_CACHE_DAYS: %w", err)
	}
	for _, x := range []struct {
		key, def string
		dst      *int64
	}{
		{"FS_RELAY_CACHE_MAX_FILE", "256M", &c.CacheMaxFile},
		{"FS_RELAY_CACHE_MAX_TOTAL", "4G", &c.CacheMaxTotal},
		{"FS_REMOTE_MAX_FILE", "8G", &c.RemoteMaxFile},
		{"FS_USER_QUOTA", "0", &c.UserQuota},
	} {
		if *x.dst, err = ParseSize(env(x.key, x.def)); err != nil {
			return nil, fmt.Errorf("%s: %w", x.key, err)
		}
	}
	if c.RelayURL != "" {
		if !strings.HasPrefix(c.RelayURL, "https://") {
			return nil, errors.New("FS_RELAY_URL must be an https:// URL")
		}
		if len(c.RelayToken) < 32 {
			return nil, errors.New("FS_RELAY_TOKEN must be the relay's FS_RELAY_NAS_TOKEN (32+ characters)")
		}
		if !c.Encrypt {
			return nil, errors.New("relay mode requires FS_ENCRYPT=true")
		}
	}
	if !c.LAN && c.RelayURL == "" {
		return nil, errors.New("FS_LAN=false requires FS_RELAY_URL (otherwise nothing could reach the NAS)")
	}
	if c.TLS != "auto" && c.TLS != "off" {
		return nil, errors.New("FS_TLS must be auto or off")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return nil, errors.New("FS_TLS_CERT and FS_TLS_KEY must be set together")
	}
	if c.DataDir, err = filepath.Abs(c.DataDir); err != nil {
		return nil, err
	}
	return c, os.MkdirAll(c.DataDir, 0o700)
}

func decodeKey(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if b, err := hex.DecodeString(s); err == nil && len(b) == 32 {
		return b, nil
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil && len(b) == 32 {
			return b, nil
		}
	}
	return nil, errors.New("master key must be 32 bytes, hex or base64 encoded")
}

// LoadMasterKey returns the at-rest encryption key, or nil if encryption is off.
// generated reports that a new key file was written inside the data directory.
func (c *Config) LoadMasterKey() (key []byte, generated bool, err error) {
	if !c.Encrypt {
		return nil, false, nil
	}
	if c.MasterKey != "" {
		key, err = decodeKey(c.MasterKey)
		return key, false, err
	}
	path := c.MasterKeyFil
	if path == "" {
		path = filepath.Join(c.DataDir, "keys", "master.key")
	}
	if b, err := os.ReadFile(path); err == nil {
		key, err = decodeKey(string(b))
		return key, false, err
	} else if !errors.Is(err, os.ErrNotExist) || c.MasterKeyFil != "" {
		return nil, false, fmt.Errorf("read master key: %w", err)
	}
	key = make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, false, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, false, err
	}
	if err := os.WriteFile(path, []byte(base64.StdEncoding.EncodeToString(key)+"\n"), 0o600); err != nil {
		return nil, false, err
	}
	return key, true, nil
}
