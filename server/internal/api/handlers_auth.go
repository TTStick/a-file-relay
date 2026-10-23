package api

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"
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
		if user.ID != "" {
			s.db.Audit(user.ID, "", "login_failed", "", ip)
		}
		s.log.Warn("login failed", "user", uname, "ip", ip)
		s.writeErr(w, r, errf(http.StatusUnauthorized, "bad_credentials", "用户名或密码错误"))
		return
	}
	s.limiter.Success(ip, uname)
	name := cleanLabel(req.DeviceName, 64)
	if name == "" {
		name = "未命名设备"
	}
	token, th := auth.NewToken()
	dev, err := s.db.CreateDevice(user.ID, name, cleanLabel(req.Platform, 32), th, ip)
	if err != nil {
		s.writeErr(w, r, err)
		return
	}
	s.db.Audit(user.ID, dev.ID, "login", name, ip)
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "user": user, "device": dev})
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
		SignOutOther bool   `json:"sign_out_others"`
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
	if req.SignOutOther {
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
	name := cleanLabel(req.Name, 64)
	if name == "" {
		return errf(http.StatusBadRequest, "invalid", "名称不能为空")
	}
	if err := s.db.RenameDevice(a.User.ID, r.PathValue("id"), name); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
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

func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request, a *Auth) error {
	entries, err := s.db.ListAudit(a.User.ID, 200)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
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
