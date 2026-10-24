package api

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"fileswitch/internal/auth"
	"fileswitch/internal/store"
)

func cleanLabel(s string, max int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s))
	if utf8.RuneCountInString(s) > max {
		s = string([]rune(s)[:max])
	}
	return s
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	if err := readJSON(r, &req); err != nil {
		s.writeErr(w, r, err)
		return
	}
	ip := s.clientIP(r)
	uname := auth.NormalizeUsername(req.Username)
	name, err := deviceName(req.DeviceName)
	if err != nil {
		s.writeErr(w, r, err)
		return
	}
	platform, err := platformName(req.Platform)
	if err != nil {
		s.writeErr(w, r, err)
		return
	}
	if wait := s.limiter.Allow(ip, uname); wait > 0 {
		secs := int(math.Ceil(wait.Seconds()))
		w.Header().Set("Retry-After", fmt.Sprint(secs))
		later := fmt.Sprintf("%d 秒", secs)
		if secs > 90 {
			later = fmt.Sprintf("%d 分钟", (secs+59)/60)
		}
		s.writeErr(w, r, errf(http.StatusTooManyRequests, "throttled", "尝试次数过多，请 %s后再试", later))
		return
	}
	user, err := s.db.UserByName(uname)
	hash := s.dummyHash
	if err == nil {
		hash = user.PasswordHash
	} else if !errors.Is(err, store.ErrNotFound) {
		s.writeErr(w, r, err)
		return
	}
	if !auth.VerifyPassword(hash, req.Password) || err != nil {
		s.limiter.Fail(ip, uname)
		// Logged with the name that was tried; attempts on accounts that
		// don't exist go in without a user, where admins see them.
		s.db.Audit(user.ID, "", "login_failed", cleanLabel(uname, 64), ip)
		s.log.Warn("login failed", "user", uname, "ip", ip)
		s.writeErr(w, r, errf(http.StatusUnauthorized, "bad_credentials", "用户名或密码错误"))
		return
	}
	s.limiter.Success(ip, uname)
	if name == "" {
		name = "未命名设备"
	}
	name = s.uniqueDeviceName(user.ID, name)
	token, th := auth.NewToken()
	dev, err := s.db.CreateDevice(user.ID, name, platform, th, ip)
	if err != nil {
		s.writeErr(w, r, err)
		return
	}
	s.db.Audit(user.ID, dev.ID, "login", name, ip)
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "user": user, "device": dev})
}

// deviceName drops control characters and trims; a name over 64 characters
// is refused instead of being cut short behind the user's back.
func deviceName(raw string) (string, error) {
	name := cleanLabel(raw, 1024)
	if utf8.RuneCountInString(name) > 64 {
		return "", errf(http.StatusBadRequest, "invalid", "设备名称太长（最多 64 个字符）")
	}
	return name, nil
}

var platforms = []string{"macos", "ios", "android", "windows", "linux", "cli"}

func platformName(raw string) (string, error) {
	p := strings.ToLower(strings.TrimSpace(raw))
	if p != "" && !slices.Contains(platforms, p) {
		return "", errf(http.StatusBadRequest, "invalid", "不支持的平台")
	}
	return p, nil
}

// uniqueDeviceName keeps entries in the device list apart: logging in twice
// as "iPhone" gives "iPhone" and "iPhone (2)".
func (s *Server) uniqueDeviceName(userID, name string) string {
	devs, err := s.db.ListDevices(userID)
	if err != nil {
		return name
	}
	taken := map[string]bool{}
	for _, d := range devs {
		taken[d.Name] = true
	}
	base := []rune(name)
	for i := 2; taken[name] && i < 1000; i++ {
		suffix := fmt.Sprintf(" (%d)", i)
		b := base[:min(len(base), 64-utf8.RuneCountInString(suffix))]
		name = string(b) + suffix
	}
	return name
}

// freeText checks a search term: no control characters (SQLite would stop
// reading a LIKE pattern at NUL) and a sane length.
func freeText(raw string, max int) (string, error) {
	s := strings.TrimSpace(raw)
	if !utf8.ValidString(s) || strings.ContainsFunc(s, unicode.IsControl) {
		return "", errf(http.StatusBadRequest, "bad_query", "搜索词含有无效字符")
	}
	if utf8.RuneCountInString(s) > max {
		return "", errf(http.StatusBadRequest, "bad_query", "搜索词太长（最多 %d 个字符）", max)
	}
	return s, nil
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, a *Auth) error {
	if err := s.db.DeleteDevice(a.User.ID, a.Device.ID); err != nil {
		return err
	}
	s.db.Audit(a.User.ID, a.Device.ID, "logout", a.Device.Name, s.clientIP(r))
	s.kickRelay() // no event is published for this, so wake the agent ourselves
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request, a *Auth) error {
	writeJSON(w, http.StatusOK, map[string]any{"user": a.User, "device": a.Device})
	return nil
}

func (s *Server) handleChangePassword(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Old          string `json:"old_password"`
		New          string `json:"new_password"`
		SignOutOther *bool  `json:"sign_out_others"` // default: yes
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if !auth.VerifyPassword(a.User.PasswordHash, req.Old) {
		return errf(http.StatusForbidden, "bad_credentials", "原密码错误")
	}
	if err := auth.ValidatePassword(req.New); err != nil {
		return errf(http.StatusBadRequest, "weak_password", "%v", err)
	}
	h, err := auth.HashPassword(req.New)
	if err != nil {
		return err
	}
	if err := s.db.SetPassword(a.User.ID, h); err != nil {
		return err
	}
	if req.SignOutOther == nil || *req.SignOutOther {
		ids, err := s.db.DeleteDevicesExcept(a.User.ID, a.Device.ID)
		if err != nil {
			return err
		}
		for _, id := range ids {
			s.hub.Publish(a.User.ID, Event{Type: "device.revoked", Target: id})
		}
	}
	s.db.Audit(a.User.ID, a.Device.ID, "password_changed", "", s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request, a *Auth) error {
	devs, err := s.db.ListDevices(a.User.ID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs, "current": a.Device.ID})
	return nil
}

func (s *Server) handleRenameDevice(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Name string `json:"name"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if err := s.renameDevice(a, r.PathValue("id"), req.Name); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) renameDevice(a *Auth, id, raw string) error {
	name, err := deviceName(raw)
	if err != nil {
		return err
	}
	if name == "" {
		return errf(http.StatusBadRequest, "invalid", "名称不能为空")
	}
	devs, err := s.db.ListDevices(a.User.ID)
	if err != nil {
		return err
	}
	i := slices.IndexFunc(devs, func(d store.Device) bool { return d.ID == id })
	if i < 0 {
		return store.ErrNotFound
	}
	if err := s.db.RenameDevice(a.User.ID, id, name); err != nil {
		return err
	}
	s.audit(a, "device_renamed", devs[i].Name+" → "+name)
	return nil
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request, a *Auth) error {
	id := r.PathValue("id")
	if err := s.db.DeleteDevice(a.User.ID, id); err != nil {
		return err
	}
	s.db.Audit(a.User.ID, a.Device.ID, "device_revoked", id, s.clientIP(r))
	s.hub.Publish(a.User.ID, Event{Type: "device.revoked", Target: id})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// handleAudit pages through the security log, newest first:
//
//	?limit=1..500 (200) &before=<id> &action=<action> &q=<text>
//	&all=1   admins only: every user, plus failed logins for unknown names
func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request, a *Auth) error {
	qv := r.URL.Query()
	q := store.AuditQuery{UserID: a.User.ID, Action: qv.Get("action"), Limit: 200}
	var err error
	if q.Text, err = freeText(qv.Get("q"), 100); err != nil {
		return err
	}
	switch qv.Get("all") {
	case "", "0":
	case "1":
		if !a.User.IsAdmin {
			return errForbidden
		}
		q.All = true
	default:
		return errf(http.StatusBadRequest, "bad_query", "all 只能是 0 或 1")
	}
	if v := qv.Get("before"); v != "" {
		if q.Before, err = strconv.ParseInt(v, 10, 64); err != nil || q.Before <= 0 {
			return errf(http.StatusBadRequest, "bad_query", "before 参数无效")
		}
	}
	if v := qv.Get("limit"); v != "" {
		if q.Limit, err = strconv.Atoi(v); err != nil || q.Limit < 1 || q.Limit > 500 {
			return errf(http.StatusBadRequest, "bad_query", "limit 必须在 1 到 500 之间")
		}
	}
	entries, total, more, err := s.db.ListAudit(q)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "total": total, "has_more": more})
	return nil
}

// --- admin ---

func (s *Server) handleListUsers(w http.ResponseWriter, r *http.Request, a *Auth) error {
	users, err := s.db.ListUsers()
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
	return nil
}

func validUsername(u string) bool {
	if u == "" || len(u) > 32 {
		return false
	}
	for _, r := range u {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.') {
			return false
		}
	}
	return true
}

func (s *Server) handleCreateUser(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		IsAdmin  bool   `json:"is_admin"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if !validUsername(req.Username) {
		return errf(http.StatusBadRequest, "invalid", "用户名只能包含字母、数字、_ - .，最长 32 位")
	}
	if err := auth.ValidatePassword(req.Password); err != nil {
		return errf(http.StatusBadRequest, "weak_password", "%v", err)
	}
	h, err := auth.HashPassword(req.Password)
	if err != nil {
		return err
	}
	u, err := s.db.CreateUser(req.Username, h, req.IsAdmin)
	if errors.Is(err, store.ErrConflict) {
		return errf(http.StatusConflict, "user_exists", "用户名已存在")
	}
	if err != nil {
		return err
	}
	s.db.Audit(a.User.ID, a.Device.ID, "user_created", u.Username, s.clientIP(r))
	writeJSON(w, http.StatusCreated, u)
	return nil
}

func (s *Server) handleDeleteUser(w http.ResponseWriter, r *http.Request, a *Auth) error {
	id := r.PathValue("id")
	if id == a.User.ID {
		return errf(http.StatusBadRequest, "invalid", "不能删除自己")
	}
	blobs, err := s.db.DeleteUser(id)
	if err != nil {
		return err
	}
	s.removeBlobs(blobs)
	s.db.Audit(a.User.ID, a.Device.ID, "user_deleted", id, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) handleResetPassword(w http.ResponseWriter, r *http.Request, a *Auth) error {
	var req struct {
		Password string `json:"password"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if err := auth.ValidatePassword(req.Password); err != nil {
		return errf(http.StatusBadRequest, "weak_password", "%v", err)
	}
	h, err := auth.HashPassword(req.Password)
	if err != nil {
		return err
	}
	id := r.PathValue("id")
	if err := s.db.SetPassword(id, h); err != nil {
		return err
	}
	// A reset password means the old sessions are no longer trusted.
	if id != a.User.ID {
		s.db.DeleteDevicesExcept(id, "")
	}
	s.db.Audit(a.User.ID, a.Device.ID, "password_reset", id, s.clientIP(r))
	w.WriteHeader(http.StatusNoContent)
	return nil
}
