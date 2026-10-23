// Command fileswitch is the FileSwitch exchange server.
//
//	fileswitch [serve]                    run the server (on the NAS)
//	fileswitch relay                      run the public relay (on an internet server)
//	fileswitch pair <user>                print a one-time code to add a device through the relay
//	fileswitch user add <name> [--admin] [--password PW]
//	fileswitch user passwd <name> [--password PW]
//	fileswitch user list | del <name> | admin <name> on|off
//	fileswitch fingerprint                print the TLS certificate fingerprint
//	fileswitch export <user> <dir>        write a user's files (decrypted) to dir
//	fileswitch healthcheck                used by the Docker HEALTHCHECK
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"fileswitch/internal/api"
	"fileswitch/internal/auth"
	"fileswitch/internal/blob"
	"fileswitch/internal/config"
	"fileswitch/internal/relay"
	"fileswitch/internal/store"
	"fileswitch/internal/tlsutil"
)

func main() {
	args := os.Args[1:]
	cmd := "serve"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve()
	case "relay":
		err = runRelay()
	case "pair":
		err = pair(args)
	case "user":
		err = userCmd(args)
	case "fingerprint":
		err = fingerprint()
	case "export":
		err = export(args)
	case "healthcheck":
		err = healthcheck()
	case "version":
		fmt.Println("fileswitch", api.Version)
	default:
		fmt.Fprintln(os.Stderr, "usage: fileswitch [serve|relay|pair|user|fingerprint|export|healthcheck|version]")
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type env struct {
	cfg   *config.Config
	db    *store.DB
	blobs *blob.Store
}

// open loads config, database and blob store, refusing to run with a master
// key that doesn't match the one the data was written with.
func open(log *slog.Logger) (*env, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	db, err := store.Open(filepath.Join(cfg.DataDir, "fileswitch.db"))
	if err != nil {
		return nil, err
	}
	key, generated, err := cfg.LoadMasterKey()
	if err != nil {
		return nil, err
	}
	if generated && log != nil {
		log.Warn("已生成新的主密钥 data/keys/master.key —— 请务必备份；更安全的做法是用 FS_MASTER_KEY_FILE 把密钥放在数据卷之外")
	}
	check, err := db.Meta("key_check")
	if err != nil {
		return nil, err
	}
	if key == nil {
		var n int
		db.QueryRow(`SELECT COUNT(*) FROM nodes WHERE enc = 1`).Scan(&n)
		if n > 0 {
			return nil, errors.New("存在加密文件，但 FS_ENCRYPT=false 或未提供主密钥")
		}
	} else if check == "" {
		if err := db.SetMeta("key_check", blob.KeyCheck(key)); err != nil {
			return nil, err
		}
	} else if check != blob.KeyCheck(key) {
		return nil, errors.New("主密钥与现有数据不匹配（是否更换了 FS_MASTER_KEY？）")
	}
	blobs, err := blob.New(cfg.DataDir, key)
	if err != nil {
		return nil, err
	}
	return &env{cfg, db, blobs}, nil
}

func serve() error {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	e, err := open(log)
	if err != nil {
		return err
	}
	defer e.db.Close()
	cfg := e.cfg

	if n, err := e.db.CountUsers(); err != nil {
		return err
	} else if n == 0 {
		pw, shown := cfg.AdminPass, false
		if pw == "" {
			pw, shown = auth.RandomPassword(), true
		}
		h, err := auth.HashPassword(pw)
		if err != nil {
			return err
		}
		if _, err := e.db.CreateUser(cfg.AdminUser, h, true); err != nil {
			return err
		}
		log.Info("已创建管理员账号", "user", cfg.AdminUser)
		if shown {
			fmt.Printf("\n================ 初始管理员 ================\n用户名: %s\n密码:   %s\n请登录后立即修改密码。\n============================================\n\n", cfg.AdminUser, pw)
		}
	}

	tlsOn := cfg.TLS != "off"
	srv := api.New(cfg, e.db, e.blobs, log, tlsOn)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go srv.RunJanitor(ctx)
	if err := srv.StartRelay(ctx); err != nil {
		return fmt.Errorf("relay: %w", err)
	}
	if !cfg.LAN {
		log.Info("FileSwitch 已启动（FS_LAN=false：不监听任何端口，只通过中转站访问）", "version", api.Version,
			"encrypt_at_rest", e.blobs.Encrypted(), "data", cfg.DataDir)
		<-ctx.Done()
		return nil
	}
	return listen(ctx, log, cfg, srv.Handler(), "FileSwitch 已启动", "encrypt_at_rest", e.blobs.Encrypted(), "relay", cfg.RelayEnabled())
}

// listen serves h on cfg.Listen (TLS unless FS_TLS=off) until ctx ends.
func listen(ctx context.Context, log *slog.Logger, cfg *config.Config, h http.Handler, msg string, attrs ...any) error {
	tlsOn := cfg.TLS != "off"
	hs := &http.Server{
		Addr:              cfg.Listen,
		Handler:           h,
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelDebug),
	}
	if tlsOn {
		cert, err := tlsutil.Load(filepath.Join(cfg.DataDir, "tls"), cfg.TLSCert, cfg.TLSKey, cfg.TLSHosts)
		if err != nil {
			return fmt.Errorf("tls: %w", err)
		}
		hs.TLSConfig = tlsutil.Config(cert)
		log.Info("TLS 证书指纹 (SHA-256)，客户端首次连接时请核对", "fingerprint", tlsutil.Fingerprint(cert))
	} else {
		log.Warn("FS_TLS=off：仅在前面有 HTTPS 反向代理时使用")
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	log.Info(msg, append([]any{"version", api.Version, "listen", cfg.Listen, "tls", tlsOn, "data", cfg.DataDir}, attrs...)...)
	errc := make(chan error, 1)
	go func() {
		if tlsOn {
			errc <- hs.ServeTLS(ln, "", "")
		} else {
			errc <- hs.Serve(ln)
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("正在关闭…")
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return hs.Shutdown(sctx)
}

func runRelay() error {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	rc, err := relay.LoadConfig(cfg.DataDir, cfg.TrustProxy)
	if err != nil {
		return err
	}
	srv, err := relay.New(rc, log)
	if err != nil {
		return err
	}
	defer srv.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go srv.RunJanitor(ctx)
	log.Info("中转站只存放加密数据，无法读取文件内容或文件名", "max_file", rc.MaxFile, "quota_per_space", rc.Quota)
	return listen(ctx, log, cfg, srv.Handler(), "FileSwitch 中转站已启动")
}

func pair(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: fileswitch pair <user>")
	}
	e, err := open(nil)
	if err != nil {
		return err
	}
	defer e.db.Close()
	if !e.cfg.RelayEnabled() {
		return errors.New("FS_RELAY_URL is not configured")
	}
	u, err := e.db.UserByName(args[0])
	if err != nil {
		return err
	}
	srv := api.New(e.cfg, e.db, e.blobs, slog.New(slog.NewTextHandler(io.Discard, nil)), false)
	code, exp, err := srv.NewPairing(u.ID, "cli")
	if err != nil {
		return err
	}
	e.db.Audit(u.ID, "", "pairing_created", "cli", "local")
	fmt.Printf("\n在新设备的 FileSwitch 中选择「使用配对码」，粘贴下面整行（%s 前有效，只能使用一次）：\n\n%s\n\n",
		time.UnixMilli(exp).Format("15:04"), code)
	return nil
}

func flagValue(args []string, name string) (string, []string) {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1], append(append([]string{}, args[:i]...), args[i+2:]...)
		}
		if v, ok := strings.CutPrefix(a, name+"="); ok {
			return v, append(append([]string{}, args[:i]...), args[i+1:]...)
		}
	}
	return "", args
}

func hasFlag(args []string, name string) (bool, []string) {
	for i, a := range args {
		if a == name {
			return true, append(append([]string{}, args[:i]...), args[i+1:]...)
		}
	}
	return false, args
}

func userCmd(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: fileswitch user add|passwd|list|del|admin ...")
	}
	e, err := open(nil)
	if err != nil {
		return err
	}
	defer e.db.Close()
	sub, args := args[0], args[1:]
	pw, args := flagValue(args, "--password")
	admin, args := hasFlag(args, "--admin")
	needName := func() (store.User, string, error) {
		if len(args) < 1 {
			return store.User{}, "", errors.New("missing user name")
		}
		u, err := e.db.UserByName(args[0])
		return u, args[0], err
	}
	setPw := func() (string, string, error) {
		gen := pw == ""
		if gen {
			pw = auth.RandomPassword()
		} else if err := auth.ValidatePassword(pw); err != nil {
			return "", "", err
		}
		h, err := auth.HashPassword(pw)
		if gen {
			return h, pw, err
		}
		return h, "", err
	}
	switch sub {
	case "add":
		if len(args) < 1 {
			return errors.New("usage: fileswitch user add <name> [--admin] [--password PW]")
		}
		h, shown, err := setPw()
		if err != nil {
			return err
		}
		if _, err := e.db.CreateUser(args[0], h, admin); err != nil {
			return err
		}
		fmt.Println("created user", args[0])
		if shown != "" {
			fmt.Println("password:", shown)
		}
	case "passwd":
		u, _, err := needName()
		if err != nil {
			return err
		}
		h, shown, err := setPw()
		if err != nil {
			return err
		}
		if err := e.db.SetPassword(u.ID, h); err != nil {
			return err
		}
		e.db.DeleteDevicesExcept(u.ID, "")
		fmt.Println("password updated; all devices signed out")
		if shown != "" {
			fmt.Println("password:", shown)
		}
	case "list":
		users, err := e.db.ListUsers()
		if err != nil {
			return err
		}
		for _, u := range users {
			role := "user"
			if u.IsAdmin {
				role = "admin"
			}
			fmt.Printf("%-24s %-6s created %s\n", u.Username, role, time.UnixMilli(u.CreatedAt).Format(time.DateTime))
		}
	case "del":
		u, _, err := needName()
		if err != nil {
			return err
		}
		blobs, err := e.db.DeleteUser(u.ID)
		if err != nil {
			return err
		}
		for _, b := range blobs {
			e.blobs.Remove(b)
		}
		fmt.Println("deleted user", u.Username)
	case "admin":
		u, _, err := needName()
		if err != nil {
			return err
		}
		if len(args) < 2 || (args[1] != "on" && args[1] != "off") {
			return errors.New("usage: fileswitch user admin <name> on|off")
		}
		if err := e.db.SetAdmin(u.ID, args[1] == "on"); err != nil {
			return err
		}
		fmt.Println("ok")
	default:
		return fmt.Errorf("unknown user command %q", sub)
	}
	return nil
}

func fingerprint() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if cfg.TLS == "off" {
		return errors.New("TLS is off")
	}
	cert, err := tlsutil.Load(filepath.Join(cfg.DataDir, "tls"), cfg.TLSCert, cfg.TLSKey, cfg.TLSHosts)
	if err != nil {
		return err
	}
	fmt.Println(tlsutil.Fingerprint(cert))
	return nil
}

func export(args []string) error {
	if len(args) != 2 {
		return errors.New("usage: fileswitch export <user> <dir>")
	}
	e, err := open(nil)
	if err != nil {
		return err
	}
	defer e.db.Close()
	u, err := e.db.UserByName(args[0])
	if err != nil {
		return err
	}
	out := args[1]
	children, err := e.db.Children(u.ID, u.RootID, false)
	if err != nil {
		return err
	}
	files := 0
	for _, c := range children {
		entries, err := e.db.Walk(u.ID, c.ID)
		if err != nil {
			return err
		}
		for _, en := range entries {
			dst := filepath.Join(out, filepath.FromSlash(en.RelPath))
			if en.IsDir {
				if err := os.MkdirAll(dst, 0o755); err != nil {
					return err
				}
				continue
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			src, err := e.blobs.Open(en.Blob, en.Size, en.Enc)
			if err != nil {
				return fmt.Errorf("%s: %w", en.RelPath, err)
			}
			f, err := os.Create(dst)
			if err != nil {
				src.Close()
				return err
			}
			_, err = io.Copy(f, src)
			src.Close()
			f.Close()
			if err != nil {
				return fmt.Errorf("%s: %w", en.RelPath, err)
			}
			mt := time.UnixMilli(en.MTime)
			os.Chtimes(dst, mt, mt)
			files++
		}
	}
	fmt.Printf("exported %d files to %s\n", files, out)
	return nil
}

func healthcheck() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return err
	}
	scheme := "https"
	if cfg.TLS == "off" {
		scheme = "http"
	}
	c := &http.Client{
		Timeout: 5 * time.Second,
		// Loopback only, so certificate verification adds nothing here.
		Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
	}
	resp, err := c.Get(scheme + "://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}
