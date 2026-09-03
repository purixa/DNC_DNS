#!/usr/bin/env bash
#
# ============================================================
#        PDNC DNS PROXY — WEB PANEL INSTALLER
# ============================================================
#
# Installs a small web control panel for install.sh, so you can
# add/remove domains, apply game packs, and check service status
# from a browser instead of SSH.
#
# Prerequisites:
#   - install.sh has already been run at least once (Unbound,
#     AdGuard Home, HAProxy are installed and PDNC state exists
#     under /etc/pdnc/state).
#   - This script and the panel/ directory sit next to each other
#     (as shipped).
#
# Usage:
#   sudo bash panel-install.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDNC_OPT_DIR="/opt/pdnc"
PANEL_DIR="$PDNC_OPT_DIR/panel"
PANEL_CONFIG_DIR="/etc/pdnc/panel"
PANEL_CONFIG="$PANEL_CONFIG_DIR/config.json"
PANEL_CERTS_DIR="$PANEL_CONFIG_DIR/certs"
INSTALL_SCRIPT_DEST="$PDNC_OPT_DIR/install.sh"
SYSTEMD_UNIT="/etc/systemd/system/pdnc-panel.service"

C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'

ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
info()  { echo -e "  ${C_CYAN}[i]${C_RESET} $1"; }
warn()  { echo -e "  ${C_YELLOW}!${C_RESET} $1"; }
error() { echo -e "  ${C_RED}✗${C_RESET} $1"; }
die()   { error "$1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash panel-install.sh)."

echo -e "${C_CYAN}${C_BOLD}"
cat <<'EOF'
╔══════════════════════════════════════════════╗
║        PDNC DNS PROXY — WEB PANEL             ║
║             INSTALLER                         ║
╚══════════════════════════════════════════════╝
EOF
echo -e "${C_RESET}"

# ------------------------------------------------------------
# Locate install.sh
# ------------------------------------------------------------

SRC_INSTALL_SH=""
if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
    SRC_INSTALL_SH="$SCRIPT_DIR/install.sh"
elif [[ -f "$INSTALL_SCRIPT_DEST" ]]; then
    SRC_INSTALL_SH="$INSTALL_SCRIPT_DEST"
else
    die "Could not find install.sh next to this script or at $INSTALL_SCRIPT_DEST."
fi

mkdir -p "$PDNC_OPT_DIR"
if [[ "$SRC_INSTALL_SH" != "$INSTALL_SCRIPT_DEST" ]]; then
    cp -a "$SRC_INSTALL_SH" "$INSTALL_SCRIPT_DEST"
fi
chmod +x "$INSTALL_SCRIPT_DEST"
ok "install.sh is at $INSTALL_SCRIPT_DEST"

if [[ ! -f /etc/pdnc/state/server_ip ]]; then
    warn "PDNC does not look installed yet (no /etc/pdnc/state/server_ip)."
    warn "Run 'bash $INSTALL_SCRIPT_DEST' first, then re-run this installer."
    read -r -p "  Continue anyway? [y/N]: " cont </dev/tty
    [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi

# ------------------------------------------------------------
# Go toolchain
# ------------------------------------------------------------

if ! command -v go >/dev/null 2>&1; then
    info "Installing Go toolchain (golang-go)..."
    apt-get update -qq
    apt-get install -y golang-go
fi
ok "Go: $(go version)"

# ------------------------------------------------------------
# Build the panel binary
# ------------------------------------------------------------

info "Building the panel binary..."
mkdir -p "$PANEL_DIR"
cp -a "$SCRIPT_DIR/panel/." "$PANEL_DIR/"
( cd "$PANEL_DIR" && go build -o "$PANEL_DIR/pdnc-panel" . )
ok "Built $PANEL_DIR/pdnc-panel"

# ------------------------------------------------------------
# Credentials
# ------------------------------------------------------------

echo
echo -e "${C_BOLD}Admin account for the web panel${C_RESET}"
read -r -p "  Username [admin]: " PANEL_USER </dev/tty
PANEL_USER="${PANEL_USER:-admin}"

PANEL_PASS=""
while [[ -z "$PANEL_PASS" ]]; do
    read -r -s -p "  Password (leave empty to auto-generate a strong one): " PANEL_PASS </dev/tty
    echo
    if [[ -z "$PANEL_PASS" ]]; then
        PANEL_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        echo -e "  ${C_YELLOW}Generated password:${C_RESET} ${C_BOLD}$PANEL_PASS${C_RESET}"
        echo "  Save this now — it will not be shown again."
    fi
done

# ------------------------------------------------------------
# Port
# ------------------------------------------------------------

read -r -p "  Listen port [8443]: " PANEL_PORT </dev/tty
PANEL_PORT="${PANEL_PORT:-8443}"

# ------------------------------------------------------------
# TLS
# ------------------------------------------------------------

TLS_CERT=""
TLS_KEY=""
read -r -p "  Enable HTTPS with a self-signed certificate? [Y/n]: " use_tls </dev/tty
if [[ ! "$use_tls" =~ ^[Nn]$ ]]; then
    mkdir -p "$PANEL_CERTS_DIR"
    TLS_CERT="$PANEL_CERTS_DIR/panel.crt"
    TLS_KEY="$PANEL_CERTS_DIR/panel.key"

    if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
        SERVER_IP_FOR_CERT="$(cat /etc/pdnc/state/server_ip 2>/dev/null || echo 127.0.0.1)"
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$TLS_KEY" -out "$TLS_CERT" \
            -subj "/CN=$SERVER_IP_FOR_CERT" \
            -addext "subjectAltName=IP:$SERVER_IP_FOR_CERT" >/dev/null 2>&1
        chmod 600 "$TLS_KEY"
        ok "Self-signed certificate generated at $PANEL_CERTS_DIR"
        warn "Browsers will show a certificate warning (self-signed) — that's expected."
    fi
else
    warn "Running WITHOUT TLS. Traffic (including your login password) is unencrypted."
    warn "Only expose this on a trusted network / VPN, or put it behind your own reverse proxy with TLS."
fi

# ------------------------------------------------------------
# Write panel config (hashes the password via `pdnc-panel init`)
# ------------------------------------------------------------

mkdir -p "$PANEL_CONFIG_DIR"
"$PANEL_DIR/pdnc-panel" init \
    -username "$PANEL_USER" \
    -password "$PANEL_PASS" \
    -port "$PANEL_PORT" \
    -install-script "$INSTALL_SCRIPT_DEST" \
    -config "$PANEL_CONFIG" \
    -tls-cert "$TLS_CERT" \
    -tls-key "$TLS_KEY"

chmod 600 "$PANEL_CONFIG"
ok "Panel config written to $PANEL_CONFIG"

# ------------------------------------------------------------
# systemd service
# ------------------------------------------------------------

cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=PDNC DNS PROXY Web Panel
After=network.target

[Service]
Type=simple
ExecStart=$PANEL_DIR/pdnc-panel serve -config $PANEL_CONFIG
Restart=on-failure
RestartSec=3
# Runs as root: install.sh's api commands manage systemd units and
# edit /etc/unbound, /etc/haproxy, and AdGuard Home's config.
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pdnc-panel >/dev/null 2>&1
systemctl restart pdnc-panel

sleep 1
if ! systemctl is-active --quiet pdnc-panel; then
    error "pdnc-panel failed to start."
    journalctl -u pdnc-panel --no-pager -n 30
    exit 1
fi

ok "pdnc-panel is running."

SERVER_IP="$(cat /etc/pdnc/state/server_ip 2>/dev/null || echo YOUR_SERVER_IP)"
SCHEME="http"
[[ -n "$TLS_CERT" ]] && SCHEME="https"

echo
echo -e "${C_GREEN}${C_BOLD}Panel installed.${C_RESET}"
echo
echo "  URL      : ${SCHEME}://${SERVER_IP}:${PANEL_PORT}"
echo "  Username : $PANEL_USER"
echo "  Service  : systemctl status pdnc-panel"
echo "  Logs     : journalctl -u pdnc-panel -f"
echo
if [[ -z "$TLS_CERT" ]]; then
    warn "Remember: no TLS is configured. Restrict access with a firewall (e.g. ufw allow from your IP to port $PANEL_PORT) or a VPN."
fi
echo
