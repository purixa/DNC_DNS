// PDNC DNS PROXY — Web Panel
//
// A small, dependency-free (stdlib only) web control panel for the
// PDNC DNS PROXY installer (install.sh). It authenticates an admin
// user, then drives install.sh's headless `api` subcommands to
// manage domains, game packs, and service status/restarts.
//
// Usage:
//
//	pdnc-panel init  -username admin -password 'xxxx' -port 8443 \
//	            -install-script /opt/pdnc/install.sh \
//	            -config /etc/pdnc/panel/config.json
//
//	pdnc-panel serve -config /etc/pdnc/panel/config.json
//
// The panel must run as root (or with sudo/systemd), because
// install.sh's api commands manage systemd services and edit
// /etc/unbound, /etc/haproxy, and AdGuard's config.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

//go:embed static/*
var staticFiles embed.FS

// ------------------------------------------------------------
// Config
// ------------------------------------------------------------

type Config struct {
	Username      string `json:"username"`
	PasswordHash  string `json:"password_hash"` // "saltHex:hashHex"
	Port          int    `json:"port"`
	InstallScript string `json:"install_script"`
	TLSCert       string `json:"tls_cert,omitempty"`
	TLSKey        string `json:"tls_key,omitempty"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

func saveConfig(path string, c *Config) error {
	if err := os.MkdirAll(dirOf(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func dirOf(path string) string {
	idx := strings.LastIndex(path, "/")
	if idx <= 0 {
		return "."
	}
	return path[:idx]
}

// ------------------------------------------------------------
// Password hashing (stdlib only — salted, iterated SHA-256).
// Not bcrypt/argon2, but combined with rate limiting and a
// long random admin password this is adequate for a
// single-admin LAN/VPN-facing control panel.
// ------------------------------------------------------------

const hashIterations = 200_000

func hashPassword(password string, salt []byte) []byte {
	sum := sha256.Sum256(append(append([]byte{}, salt...), []byte(password)...))
	for i := 0; i < hashIterations; i++ {
		sum = sha256.Sum256(sum[:])
	}
	return sum[:]
}

func newSalt() []byte {
	s := make([]byte, 16)
	if _, err := rand.Read(s); err != nil {
		log.Fatalf("failed to generate salt: %v", err)
	}
	return s
}

func encodePasswordHash(password string) string {
	salt := newSalt()
	h := hashPassword(password, salt)
	return hex.EncodeToString(salt) + ":" + hex.EncodeToString(h)
}

func verifyPassword(password, stored string) bool {
	parts := strings.SplitN(stored, ":", 2)
	if len(parts) != 2 {
		return false
	}
	salt, err := hex.DecodeString(parts[0])
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(parts[1])
	if err != nil {
		return false
	}
	got := hashPassword(password, salt)
	return subtle.ConstantTimeCompare(got, want) == 1
}

// ------------------------------------------------------------
// Sessions (in-memory)
// ------------------------------------------------------------

const sessionTTL = 12 * time.Hour
const sessionCookieName = "pdnc_session"

type sessionStore struct {
	mu       sync.Mutex
	sessions map[string]time.Time
}

func newSessionStore() *sessionStore {
	return &sessionStore{sessions: make(map[string]time.Time)}
}

func (s *sessionStore) create() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token := base64.RawURLEncoding.EncodeToString(b)
	s.mu.Lock()
	s.sessions[token] = time.Now().Add(sessionTTL)
	s.mu.Unlock()
	return token
}

func (s *sessionStore) valid(token string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.sessions[token]
	if !ok {
		return false
	}
	if time.Now().After(exp) {
		delete(s.sessions, token)
		return false
	}
	return true
}

func (s *sessionStore) revoke(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
}

// ------------------------------------------------------------
// Simple login rate limiting
// ------------------------------------------------------------

type limiter struct {
	mu     sync.Mutex
	fails  map[string]int
	locked map[string]time.Time
}

func newLimiter() *limiter {
	return &limiter{fails: map[string]int{}, locked: map[string]time.Time{}}
}

func (l *limiter) allowed(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if until, ok := l.locked[ip]; ok {
		if time.Now().Before(until) {
			return false
		}
		delete(l.locked, ip)
		l.fails[ip] = 0
	}
	return true
}

func (l *limiter) recordFailure(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fails[ip]++
	if l.fails[ip] >= 5 {
		l.locked[ip] = time.Now().Add(5 * time.Minute)
	}
}

func (l *limiter) recordSuccess(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.fails[ip] = 0
	delete(l.locked, ip)
}

// ------------------------------------------------------------
// install.sh API bridge
// ------------------------------------------------------------

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func stripANSI(s string) string {
	return ansiRe.ReplaceAllString(s, "")
}

type apiError struct {
	Output string
}

func (e *apiError) Error() string { return e.Output }

// runInstallAPI executes: <install_script> api <args...>
// and returns the last JSON line of stdout on success (exit 0).
// On failure it returns an *apiError carrying the cleaned combined
// output for display in the UI.
func runInstallAPI(scriptPath string, args ...string) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	fullArgs := append([]string{"api"}, args...)
	cmd := exec.CommandContext(ctx, "bash", append([]string{scriptPath}, fullArgs...)...)

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	err := cmd.Run()
	output := stripANSI(buf.String())

	if err != nil {
		msg := strings.TrimSpace(output)
		if msg == "" {
			msg = err.Error()
		}
		return nil, &apiError{Output: msg}
	}

	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	last := strings.TrimSpace(lines[len(lines)-1])
	if !json.Valid([]byte(last)) {
		return nil, &apiError{Output: strings.TrimSpace(output)}
	}
	return json.RawMessage(last), nil
}

// ------------------------------------------------------------
// HTTP server
// ------------------------------------------------------------

type server struct {
	cfg      *Config
	sessions *sessionStore
	limiter  *limiter
}

func clientIP(r *http.Request) string {
	// Behind a reverse proxy this would need X-Forwarded-For handling;
	// kept simple/safe by default (trusts RemoteAddr only).
	return r.RemoteAddr
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]interface{}{"ok": false, "error": msg})
}

func (s *server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie(sessionCookieName)
		if err != nil || !s.sessions.valid(c.Value) {
			writeErr(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		next(w, r)
	}
}

func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !s.limiter.allowed(ip) {
		writeErr(w, http.StatusTooManyRequests, "too many failed attempts, try again later")
		return
	}

	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request")
		return
	}

	okUser := subtle.ConstantTimeCompare([]byte(body.Username), []byte(s.cfg.Username)) == 1
	okPass := verifyPassword(body.Password, s.cfg.PasswordHash)

	if !okUser || !okPass {
		s.limiter.recordFailure(ip)
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	s.limiter.recordSuccess(ip)
	token := s.sessions.create()
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   s.cfg.TLSCert != "",
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(sessionTTL.Seconds()),
	})
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookieName); err == nil {
		s.sessions.revoke(c.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: sessionCookieName, Value: "", Path: "/", MaxAge: -1})
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true})
}

func (s *server) proxyAPI(w http.ResponseWriter, args ...string) {
	raw, err := runInstallAPI(s.cfg.InstallScript, args...)
	if err != nil {
		var ae *apiError
		if ok := AsApiError(err, &ae); ok {
			writeErr(w, http.StatusInternalServerError, ae.Output)
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

// AsApiError is a tiny errors.As helper kept local to avoid an extra import block surprise.
func AsApiError(err error, target **apiError) bool {
	if ae, ok := err.(*apiError); ok {
		*target = ae
		return true
	}
	return false
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	s.proxyAPI(w, "status")
}

func (s *server) handleDomainsList(w http.ResponseWriter, r *http.Request) {
	s.proxyAPI(w, "list-domains")
}

func (s *server) handleDomainsAdd(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Domain string `json:"domain"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Domain) == "" {
		writeErr(w, http.StatusBadRequest, "domain is required")
		return
	}
	s.proxyAPI(w, "add-domain", body.Domain)
}

func (s *server) handleDomainsDelete(w http.ResponseWriter, r *http.Request) {
	domain := r.PathValue("domain")
	if strings.TrimSpace(domain) == "" {
		writeErr(w, http.StatusBadRequest, "domain is required")
		return
	}
	s.proxyAPI(w, "remove-domain", domain)
}

func (s *server) handleGamepacksList(w http.ResponseWriter, r *http.Request) {
	s.proxyAPI(w, "list-gamepacks")
}

func (s *server) handleGamepackAdd(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if strings.TrimSpace(key) == "" {
		writeErr(w, http.StatusBadRequest, "key is required")
		return
	}
	s.proxyAPI(w, "add-gamepack", key)
}

func (s *server) handleRestart(w http.ResponseWriter, r *http.Request) {
	s.proxyAPI(w, "restart")
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /api/login", s.handleLogin)
	mux.HandleFunc("POST /api/logout", s.requireAuth(s.handleLogout))

	mux.HandleFunc("GET /api/status", s.requireAuth(s.handleStatus))
	mux.HandleFunc("GET /api/domains", s.requireAuth(s.handleDomainsList))
	mux.HandleFunc("POST /api/domains", s.requireAuth(s.handleDomainsAdd))
	mux.HandleFunc("DELETE /api/domains/{domain}", s.requireAuth(s.handleDomainsDelete))
	mux.HandleFunc("GET /api/gamepacks", s.requireAuth(s.handleGamepacksList))
	mux.HandleFunc("POST /api/gamepacks/{key}", s.requireAuth(s.handleGamepackAdd))
	mux.HandleFunc("POST /api/restart", s.requireAuth(s.handleRestart))

	sub, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatal(err)
	}
	mux.Handle("/", http.FileServer(http.FS(sub)))

	return mux
}

// ------------------------------------------------------------
// CLI entrypoints
// ------------------------------------------------------------

func cmdInit(args []string) {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	username := fs.String("username", "admin", "admin username")
	password := fs.String("password", "", "admin password (required)")
	port := fs.Int("port", 8443, "listen port")
	installScript := fs.String("install-script", "/opt/pdnc/install.sh", "path to install.sh")
	configPath := fs.String("config", "/etc/pdnc/panel/config.json", "path to write config.json")
	tlsCert := fs.String("tls-cert", "", "optional TLS certificate path")
	tlsKey := fs.String("tls-key", "", "optional TLS key path")
	_ = fs.Parse(args)

	if strings.TrimSpace(*password) == "" {
		fmt.Fprintln(os.Stderr, "error: -password is required")
		os.Exit(1)
	}

	cfg := &Config{
		Username:      *username,
		PasswordHash:  encodePasswordHash(*password),
		Port:          *port,
		InstallScript: *installScript,
		TLSCert:       *tlsCert,
		TLSKey:        *tlsKey,
	}

	if err := saveConfig(*configPath, cfg); err != nil {
		fmt.Fprintf(os.Stderr, "error: failed to write config: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Config written to %s\n", *configPath)
}

func cmdServe(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	configPath := fs.String("config", "/etc/pdnc/panel/config.json", "path to config.json")
	_ = fs.Parse(args)

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatalf("failed to load config %s: %v", *configPath, err)
	}

	srv := &server{cfg: cfg, sessions: newSessionStore(), limiter: newLimiter()}
	addr := fmt.Sprintf(":%d", cfg.Port)

	httpServer := &http.Server{
		Addr:         addr,
		Handler:      srv.routes(),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	if cfg.TLSCert != "" && cfg.TLSKey != "" {
		log.Printf("PDNC panel listening on https://0.0.0.0%s", addr)
		log.Fatal(httpServer.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey))
	} else {
		log.Printf("PDNC panel listening on http://0.0.0.0%s (no TLS configured — put this behind a firewall/VPN/reverse proxy)", addr)
		log.Fatal(httpServer.ListenAndServe())
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: pdnc-panel <init|serve> [flags]")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "init":
		cmdInit(os.Args[2:])
	case "serve":
		cmdServe(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
