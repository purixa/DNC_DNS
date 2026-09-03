#!/usr/bin/env bash
#
# ============================================================
#              PDNC DNS PROXY — INSTALLER
# ============================================================
#
#   Client --DNS--> AdGuard Home :53 --rewrite--> SERVER_IP
#   Client --HTTPS-> HAProxy :443 --SNI routing--> Real Website
#   HAProxy resolves real destinations via Unbound :5353 ONLY
#   (AdGuard is never used to resolve HAProxy backends —
#    this avoids a DNS resolution loop)
#
#   Usage:
#       bash install.sh
#
#   Ubuntu 24.04, run as root.
# ============================================================

set -uo pipefail
# NOTE: we deliberately do NOT use `set -e` globally — this is an
# interactive, multi-step installer and we want to catch failures
# ourselves (per step), report them clearly, and offer rollback
# instead of dying on the first non-zero exit code anywhere.

# ------------------------------------------------------------
# Constants / paths
# ------------------------------------------------------------

PDNC_HOME="/etc/pdnc"
PDNC_STATE_DIR="$PDNC_HOME/state"
PDNC_DOMAINS_FILE="$PDNC_STATE_DIR/domains.list"
PDNC_SERVER_IP_FILE="$PDNC_STATE_DIR/server_ip"
PDNC_LOG="/var/log/pdnc-installer.log"

UNBOUND_PORT="5353"
UNBOUND_CONF_DIR="/etc/unbound/unbound.conf.d"
UNBOUND_CONF_FILE="$UNBOUND_CONF_DIR/pdnc.conf"

ADGUARD_DIR="/opt/AdGuardHome"
ADGUARD_BIN="$ADGUARD_DIR/AdGuardHome"
ADGUARD_CONFIG="$ADGUARD_DIR/AdGuardHome.yaml"
ADGUARD_SERVICE="AdGuardHome"

HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

BACKUP_ROOT="/root/pdnc-backups"

TOTAL_STEPS=8
CURRENT_STEP=0

# ------------------------------------------------------------
# Colors / symbols
# ------------------------------------------------------------

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_DIM='\033[2m'

CHECK="${C_GREEN}✓${C_RESET}"
CROSS="${C_RED}✗${C_RESET}"
WARN_SYM="${C_YELLOW}!${C_RESET}"

mkdir -p "$(dirname "$PDNC_LOG")" 2>/dev/null || true
touch "$PDNC_LOG" 2>/dev/null || true

log_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$PDNC_LOG" 2>/dev/null || true
}

info()  { echo -e "  ${C_CYAN}[i]${C_RESET} $1"; log_file "INFO: $1"; }
ok()    { echo -e "  ${CHECK} $1";                log_file "OK: $1"; }
warn()  { echo -e "  ${WARN_SYM} ${C_YELLOW}$1${C_RESET}"; log_file "WARN: $1"; }
error() { echo -e "  ${CROSS} ${C_RED}$1${C_RESET}"; log_file "ERROR: $1"; }

step_header() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf "\n${C_BOLD}${C_BLUE}[%02d/%02d]${C_RESET} ${C_BOLD}%s${C_RESET}\n" \
        "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
    log_file "==== STEP $CURRENT_STEP/$TOTAL_STEPS: $1 ===="
}

die() {
    error "$1"
    echo
    echo -e "${C_RED}Installation aborted. See $PDNC_LOG for details.${C_RESET}"
    exit 1
}

banner() {
    echo -e "${C_CYAN}"
    cat <<'EOF'
╔══════════════════════════════════════════════╗
║                                                ║
║   ██████╗ ██████╗ ███╗   ██╗ ██████╗          ║
║   ██╔══██╗██╔══██╗████╗  ██║██╔════╝          ║
║   ██████╔╝██║  ██║██╔██╗ ██║██║               ║
║   ██╔═══╝ ██║  ██║██║╚██╗██║██║               ║
║   ██║     ██████╔╝██║ ╚████║╚██████╗          ║
║   ╚═╝     ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝          ║
║                                                ║
║             PDNC DNS PROXY — INSTALLER        ║
║                                                ║
╚══════════════════════════════════════════════╝
EOF
    echo -e "${C_RESET}"
}

section() {
    echo
    echo -e "${C_BOLD}${C_CYAN}━━━ $1 ━━━${C_RESET}"
}

# ------------------------------------------------------------
# Root / OS checks
# ------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This installer must be run as root (use: sudo bash install.sh)."
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS (/etc/os-release missing)."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ${ID:-unknown}. This installer officially supports Ubuntu 24.04."
    fi

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Detected Ubuntu ${VERSION_ID:-unknown}. This installer is tested on 24.04 only."
        if ! confirm "Continue anyway?" "n"; then
            die "Installation cancelled by user."
        fi
    else
        ok "Ubuntu 24.04 detected."
    fi
}

# ------------------------------------------------------------
# Small interactive helpers
# ------------------------------------------------------------

# confirm "question" "default(y|n)"
confirm() {
    local question="$1"
    local default="${2:-y}"
    local prompt suffix reply

    if [[ "$default" == "y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    prompt="  ${question} ${suffix}: "

    while true; do
        read -r -p "$(echo -e "$prompt")" reply </dev/tty
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

ask() {
    local question="$1"
    local reply
    read -r -p "$(echo -e "  ${question}: ")" reply </dev/tty
    echo "$reply"
}

# ------------------------------------------------------------
# Domain normalization / validation
# ------------------------------------------------------------

normalize_domain() {
    local d="$1"
    d="${d,,}"                          # lowercase
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"                        # strip path
    d="${d%%:*}"                        # strip port
    d="${d%.}"                          # strip trailing dot
    d="$(echo "$d" | xargs)"            # trim whitespace
    echo "$d"
}

is_valid_domain() {
    local d="$1"
    # basic RFC-1035-ish hostname check
    if [[ ! "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        return 1
    fi
    return 0
}

safe_name() {
    # Turn a domain into a HAProxy-safe backend/ACL identifier
    echo "$1" | tr '.-' '__'
}

# ------------------------------------------------------------
# State helpers (idempotency)
# ------------------------------------------------------------

init_state() {
    mkdir -p "$PDNC_STATE_DIR"
    touch "$PDNC_DOMAINS_FILE"
}

state_add_domain() {
    local d="$1"
    if ! grep -qxF "$d" "$PDNC_DOMAINS_FILE" 2>/dev/null; then
        echo "$d" >>"$PDNC_DOMAINS_FILE"
    fi
}

state_remove_domain() {
    local d="$1"
    if [[ -f "$PDNC_DOMAINS_FILE" ]]; then
        grep -vxF "$d" "$PDNC_DOMAINS_FILE" >"$PDNC_DOMAINS_FILE.tmp" 2>/dev/null || true
        mv "$PDNC_DOMAINS_FILE.tmp" "$PDNC_DOMAINS_FILE"
    fi
}

state_list_domains() {
    if [[ -f "$PDNC_DOMAINS_FILE" ]]; then
        sort -u "$PDNC_DOMAINS_FILE"
    fi
}

save_server_ip() {
    echo "$1" >"$PDNC_SERVER_IP_FILE"
}

load_server_ip() {
    [[ -f "$PDNC_SERVER_IP_FILE" ]] && cat "$PDNC_SERVER_IP_FILE"
}

# ------------------------------------------------------------
# Backups
# ------------------------------------------------------------

new_backup_dir() {
    local dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dir"
    echo "$dir"
}

backup_file() {
    local src="$1" dest_dir="$2"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$dest_dir/$(basename "$src")"
    fi
}

# atomic_replace <target_file> <new_content_tmp_file>
atomic_replace() {
    local target="$1" newfile="$2"
    local tmp
    tmp="$(mktemp "${target}.XXXXXX")"
    cp -a "$newfile" "$tmp"
    mv -f "$tmp" "$target"
}

# ------------------------------------------------------------
# Server IP detection
# ------------------------------------------------------------

detect_server_ip() {
    local ip
    ip="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "$ip"
}

is_valid_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    read -r -a parts <<<"$ip"
    for p in "${parts[@]}"; do
        (( p >= 0 && p <= 255 )) || return 1
    done
    return 0
}

resolve_server_ip() {
    section "Server IP"
    local detected chosen

    detected="$(detect_server_ip)"

    if [[ -n "$detected" ]]; then
        echo -e "  Detected Server IP: ${C_BOLD}${detected}${C_RESET}"
        if confirm "Use this IP?" "y"; then
            SERVER_IP="$detected"
        fi
    else
        warn "Could not auto-detect a public IPv4 address."
    fi

    while [[ -z "${SERVER_IP:-}" ]]; do
        chosen="$(ask "Enter server IPv4")"
        if is_valid_ipv4 "$chosen"; then
            SERVER_IP="$chosen"
        else
            error "Invalid IPv4 address, try again."
        fi
    done

    save_server_ip "$SERVER_IP"
    ok "Using server IP: $SERVER_IP"
}

# ------------------------------------------------------------
# Game domain packs
#
# Curated, best-effort BASE domains for a handful of popular
# games' backend services (login / matchmaking API / store /
# CDN manifests — i.e. the TCP/HTTPS traffic that a TCP-mode,
# SNI-routed HAProxy like this one can actually proxy).
#
# IMPORTANT — read before relying on this:
#   * This proxy operates in TCP mode via SNI passthrough. It can
#     only route TCP/HTTPS traffic (login, matchmaking API, store,
#     patch/CDN manifests). The real-time UDP traffic that carries
#     actual gameplay (player positions, hit registration, etc.)
#     is NOT touched by this proxy at all — HAProxy here never
#     terminates or forwards UDP. So this pack is useful for
#     reaching a game's backend when it's geo-blocked or
#     unreachable, not for altering live match traffic.
#   * These are the publisher's own root/base domains, gathered
#     from public documentation (official support pages, Netify
#     app-domain records). Publishers rotate CDN/edge subdomains
#     and IPs frequently, so treat this as a solid starting point,
#     not a guaranteed-complete list. Use "Add domain" afterward
#     for any specific subdomain you find is still unreachable.
# ------------------------------------------------------------

GAME_PACK_ORDER=(cod_warzone fortnite pubg valorant cs2_dota steam apex_ea minecraft)

game_pack_label() {
    case "$1" in
        cod_warzone) echo "Call of Duty / Warzone (Activision · Demonware)" ;;
        fortnite)    echo "Fortnite (Epic Games)" ;;
        pubg)        echo "PUBG: BATTLEGROUNDS (KRAFTON)" ;;
        valorant)    echo "Valorant (Riot Games)" ;;
        cs2_dota)    echo "Counter-Strike 2 / Dota 2 (Valve)" ;;
        steam)       echo "Steam platform (Valve)" ;;
        apex_ea)     echo "Apex Legends / EA titles (Electronic Arts)" ;;
        minecraft)   echo "Minecraft (Mojang / Microsoft)" ;;
        *)           echo "Unknown" ;;
    esac
}

game_pack_domains() {
    case "$1" in
        cod_warzone) echo "activision.com callofduty.com demonware.net" ;;
        fortnite)    echo "epicgames.com fortnite.com unrealengine.com" ;;
        pubg)        echo "pubg.com krafton.com" ;;
        valorant)    echo "riotgames.com playvalorant.com" ;;
        cs2_dota)    echo "steampowered.com steamcommunity.com dota2.com" ;;
        steam)       echo "steampowered.com steamcommunity.com steamstatic.com" ;;
        apex_ea)     echo "ea.com easports.com" ;;
        minecraft)   echo "minecraft.net mojang.com" ;;
        *)           echo "" ;;
    esac
}

print_game_pack_menu() {
    local i=1
    for key in "${GAME_PACK_ORDER[@]}"; do
        printf "  %2d) %s\n" "$i" "$(game_pack_label "$key")"
        i=$((i + 1))
    done
    echo "   0) Done / back"
}

# add_game_pack_domains <key> — normalizes + registers a pack's
# domains into NEW_DOMAINS / state, skipping ones already present.
add_game_pack_domains() {
    local key="$1" d norm already
    for d in $(game_pack_domains "$key"); do
        norm="$(normalize_domain "$d")"
        [[ -z "$norm" ]] && continue

        already=0
        for existing in "${NEW_DOMAINS[@]:-}"; do
            [[ "$existing" == "$norm" ]] && already=1
        done
        if grep -qxF "$norm" "$PDNC_DOMAINS_FILE" 2>/dev/null; then
            already=1
        fi

        if [[ $already -eq 0 ]]; then
            NEW_DOMAINS+=("$norm")
            ok "Added: $norm  ${C_DIM}($(game_pack_label "$key"))${C_RESET}"
        else
            warn "'$norm' already configured — skipped."
        fi
    done
}

pick_game_packs_interactive() {
    section "Popular games"
    echo "  Select a game to auto-add its known backend domains."
    echo "  You can pick more than one, one at a time."
    echo
    print_game_pack_menu
    echo

    while true; do
        local choice idx=1 key=""
        choice="$(ask "Pick a number (0 to finish)")"
        [[ "$choice" == "0" || -z "$choice" ]] && break

        if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
            error "Enter a number from the list."
            continue
        fi

        for k in "${GAME_PACK_ORDER[@]}"; do
            if [[ "$idx" -eq "$choice" ]]; then
                key="$k"
                break
            fi
            idx=$((idx + 1))
        done

        if [[ -z "$key" ]]; then
            error "Invalid choice."
            continue
        fi

        echo
        info "Adding domains for: $(game_pack_label "$key")"
        add_game_pack_domains "$key"
        echo
    done
}

# ------------------------------------------------------------
# Domain collection (interactive)
# ------------------------------------------------------------

collect_domains() {
    section "Domains"
    NEW_DOMAINS=()

    echo "  How do you want to add domains?"
    echo "    1) Pick from a list of popular games"
    echo "    2) Enter custom domains manually"
    echo "    3) Both"
    local mode
    mode="$(ask "Select [1-3]")"

    if [[ "$mode" == "1" || "$mode" == "3" ]]; then
        pick_game_packs_interactive
    fi

    if [[ "$mode" == "2" || "$mode" == "3" || -z "$mode" ]]; then
        echo
        echo "  Enter domains to proxy, one at a time."
        echo "  Leave empty and press Enter when done."
        echo

        while true; do
            local raw norm
            raw="$(ask "Domain (or press Enter to finish)")"
            if [[ -z "$raw" ]]; then
                break
            fi

            norm="$(normalize_domain "$raw")"

            if [[ -z "$norm" ]] || ! is_valid_domain "$norm"; then
                error "'$raw' is not a valid domain. Skipped."
                continue
            fi

            local already=0
            for existing in "${NEW_DOMAINS[@]:-}"; do
                [[ "$existing" == "$norm" ]] && already=1
            done
            if grep -qxF "$norm" "$PDNC_DOMAINS_FILE" 2>/dev/null; then
                already=1
                warn "'$norm' is already configured — skipping duplicate."
            fi

            if [[ $already -eq 0 ]]; then
                NEW_DOMAINS+=("$norm")
                ok "Added: $norm"
            fi
        done
    fi

    if [[ ${#NEW_DOMAINS[@]} -eq 0 ]] && [[ ! -s "$PDNC_DOMAINS_FILE" ]]; then
        die "No domains configured. At least one domain is required."
    fi

    for d in "${NEW_DOMAINS[@]:-}"; do
        state_add_domain "$d"
    done
}

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

install_packages() {
    step_header "Installing base packages"
    export DEBIAN_FRONTEND=noninteractive

    info "Running apt-get update..."
    if ! apt-get update -qq >>"$PDNC_LOG" 2>&1; then
        die "apt-get update failed. Check $PDNC_LOG."
    fi

    info "Installing: unbound haproxy dnsutils curl jq ca-certificates"
    if ! apt-get install -y unbound haproxy dnsutils curl jq ca-certificates \
            >>"$PDNC_LOG" 2>&1; then
        die "Package installation failed. Check $PDNC_LOG."
    fi

    ok "Base packages installed."
}

# ------------------------------------------------------------
# Unbound
# ------------------------------------------------------------

setup_unbound() {
    step_header "Configuring Unbound resolver"

    local backup_dir
    backup_dir="$(new_backup_dir)"
    backup_file "$UNBOUND_CONF_FILE" "$backup_dir"

    mkdir -p "$UNBOUND_CONF_DIR"
    mkdir -p /var/lib/unbound

    local tmp
    tmp="$(mktemp)"

    cat >"$tmp" <<EOF
# Managed by PDNC DNS PROXY installer — do not edit by hand.
# Regenerate via: bash install.sh (menu) or re-run the installer.

server:
    interface: 127.0.0.1
    port: $UNBOUND_PORT

    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse

    prefetch: yes
    prefetch-key: yes

    cache-min-ttl: 60
    cache-max-ttl: 86400

    rrset-cache-size: 128m
    msg-cache-size: 64m

    num-threads: 2
    outgoing-range: 512
    num-queries-per-thread: 256

    qname-minimisation: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes

    hide-identity: yes
    hide-version: yes

    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800

    edns-buffer-size: 1232

    auto-trust-anchor-file: "/var/lib/unbound/root.key"
EOF

    if [[ ! -s /var/lib/unbound/root.key ]]; then
        info "Bootstrapping DNSSEC root trust anchor..."
        unbound-anchor -a /var/lib/unbound/root.key >>"$PDNC_LOG" 2>&1 || true
    fi

    if ! unbound-checkconf "$tmp" >>"$PDNC_LOG" 2>&1; then
        error "Generated Unbound config is invalid."
        unbound-checkconf "$tmp" || true
        die "Unbound configuration failed validation. Previous config left untouched."
    fi

    atomic_replace "$UNBOUND_CONF_FILE" "$tmp"
    rm -f "$tmp"

    systemctl enable unbound >>"$PDNC_LOG" 2>&1 || true
    if ! systemctl restart unbound; then
        error "Unbound failed to restart."
        journalctl -u unbound --no-pager -n 30
        die "Unbound restart failed. Backup saved at $backup_dir"
    fi

    sleep 1

    if ! systemctl is-active --quiet unbound; then
        error "Unbound is not active after restart."
        journalctl -u unbound --no-pager -n 30
        die "Unbound failed to start. Backup saved at $backup_dir"
    fi

    ok "Unbound is running on 127.0.0.1:$UNBOUND_PORT"
}

test_unbound_domain() {
    local d="$1"
    dig @127.0.0.1 -p "$UNBOUND_PORT" "$d" A +short 2>/dev/null | head -n1
}

# ------------------------------------------------------------
# AdGuard Home
# ------------------------------------------------------------

adguard_is_installed() {
    [[ -x "$ADGUARD_BIN" ]]
}

adguard_service_exists() {
    systemctl list-unit-files 2>/dev/null | grep -qi '^AdGuardHome\.service'
}

install_adguard() {
    step_header "Installing AdGuard Home"

    if adguard_is_installed && adguard_service_exists; then
        ok "AdGuard Home already installed at $ADGUARD_DIR — skipping installation."
        return 0
    fi

    info "Downloading and running the official AdGuard Home installer..."

    if ! curl -fsSL -o /tmp/adguard-install.sh \
        https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
        >>"$PDNC_LOG" 2>&1; then
        die "Failed to download the AdGuard Home installer. Check network connectivity."
    fi

    if ! sh /tmp/adguard-install.sh -v -c "$ADGUARD_DIR" >>"$PDNC_LOG" 2>&1; then
        error "AdGuard Home installer failed."
        die "See $PDNC_LOG for details."
    fi

    rm -f /tmp/adguard-install.sh

    sleep 2

    if ! adguard_is_installed; then
        die "AdGuard Home binary not found after installation."
    fi

    ok "AdGuard Home installed."

    if [[ ! -f "$ADGUARD_CONFIG" ]]; then
        warn "AdGuard Home has not been through first-run web setup yet."
        warn "Open http://$SERVER_IP:3000 to complete initial setup (admin user/pass, listen interfaces),"
        warn "then re-run this installer to apply DNS rewrites and upstream configuration."
        ADGUARD_NEEDS_SETUP=1
    fi
}

configure_adguard_upstream_and_rewrites() {
    step_header "Configuring AdGuard Home (upstream + rewrites)"

    if [[ ! -f "$ADGUARD_CONFIG" ]]; then
        warn "AdGuard Home config not found yet (first-run setup not completed)."
        warn "Skipping AdGuard configuration for now — run this installer again after"
        warn "completing setup at http://$SERVER_IP:3000"
        return 0
    fi

    local backup_dir
    backup_dir="$(new_backup_dir)"
    backup_file "$ADGUARD_CONFIG" "$backup_dir"

    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        info "Installing PyYAML (required to edit AdGuard config safely)..."
        apt-get install -y python3-yaml >>"$PDNC_LOG" 2>&1 || \
            die "Failed to install python3-yaml."
    fi

    local domains_csv
    domains_csv="$(state_list_domains | sed 's/^/"/; s/$/"/' | paste -sd, -)"

    PDNC_ADGUARD_CONFIG="$ADGUARD_CONFIG" \
    PDNC_UNBOUND_PORT="$UNBOUND_PORT" \
    PDNC_SERVER_IP="$SERVER_IP" \
    PDNC_DOMAINS_CSV="$domains_csv" \
    python3 <<'PYEOF'
import os
import sys
import yaml

config_file = os.environ["PDNC_ADGUARD_CONFIG"]
unbound_port = os.environ["PDNC_UNBOUND_PORT"]
server_ip = os.environ["PDNC_SERVER_IP"]
domains_csv = os.environ.get("PDNC_DOMAINS_CSV", "")

domains = [d for d in domains_csv.replace('"', "").split(",") if d]

with open(config_file, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

dns = data.setdefault("dns", {})

# --- upstream: force AdGuard to resolve everything else via Unbound only ---
dns["upstream_dns"] = [f"127.0.0.1:{unbound_port}"]
dns["bootstrap_dns"] = [f"127.0.0.1:{unbound_port}"]
# Do not let AdGuard fall back to its own default upstreams for
# HAProxy-relevant domains — those are handled purely by rewrites below.
dns.setdefault("upstream_mode", "load_balance")

rewrites = dns.setdefault("rewrites", [])
domain_set = set(domains)

# Keep any rewrite NOT owned by PDNC (i.e. not one of our domains) untouched.
kept = [r for r in rewrites if not (isinstance(r, dict) and r.get("domain") in domain_set)]

for d in domains:
    kept.append({"domain": d, "answer": server_ip})

dns["rewrites"] = kept

with open(config_file, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"AdGuard configured: upstream=127.0.0.1:{unbound_port}, {len(domains)} rewrite(s) applied", file=sys.stderr)
PYEOF

    if [[ $? -ne 0 ]]; then
        error "Failed to update AdGuard configuration."
        die "Backup available at $backup_dir/AdGuardHome.yaml — restore manually if needed."
    fi

    if adguard_service_exists; then
        systemctl enable "$ADGUARD_SERVICE" >>"$PDNC_LOG" 2>&1 || true
        if ! systemctl restart "$ADGUARD_SERVICE"; then
            error "AdGuard Home failed to restart."
            journalctl -u "$ADGUARD_SERVICE" --no-pager -n 30
            die "Restore backup from $backup_dir if needed."
        fi
        sleep 2
        if ! systemctl is-active --quiet "$ADGUARD_SERVICE"; then
            error "AdGuard Home is not active after restart."
            journalctl -u "$ADGUARD_SERVICE" --no-pager -n 30
            die "Restore backup from $backup_dir if needed."
        fi
        ok "AdGuard Home restarted with updated rewrites/upstream."
    else
        warn "AdGuardHome.service not found — restart it manually after setup."
    fi
}

# ------------------------------------------------------------
# HAProxy config generation (idempotent — regenerated from state)
# ------------------------------------------------------------

generate_haproxy_config() {
    local out_file="$1"

    cat >"$out_file" <<EOF
# ============================================================
# Managed by PDNC DNS PROXY installer — do not edit by hand.
# Regenerate via install.sh (menu option) instead.
# ============================================================

global
    log /dev/log local0
    log /dev/log local1 notice

    chroot /var/lib/haproxy

    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s

    user haproxy
    group haproxy

    daemon

    maxconn 20000


defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull

    timeout connect 10s
    timeout client  60s
    timeout server  60s


resolvers pdnc_unbound
    nameserver dns1 127.0.0.1:$UNBOUND_PORT

    resolve_retries 3
    timeout resolve 1s
    timeout retry   1s
    hold valid      10s


frontend https_in
    bind $SERVER_IP:443

    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

EOF

    local d name
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        name="$(safe_name "$d")"
        echo "    use_backend ${name}_backend if { req_ssl_sni -i $d }" >>"$out_file"
    done < <(state_list_domains)

    cat >>"$out_file" <<EOF

    # Anything not explicitly listed above is rejected —
    # PDNC never acts as an open/arbitrary-SNI proxy.
    default_backend reject_backend


EOF

    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        name="$(safe_name "$d")"
        cat >>"$out_file" <<EOF
backend ${name}_backend
    mode tcp
    server destination $d:443 resolvers pdnc_unbound resolve-prefer ipv4

EOF
    done < <(state_list_domains)

    cat >>"$out_file" <<EOF
# Reject anything not on the allow-list immediately instead of
# hanging until connect-timeout.
backend reject_backend
    mode tcp
    tcp-request content reject
EOF
}

setup_haproxy() {
    step_header "Configuring HAProxy (SNI routing)"

    local backup_dir
    backup_dir="$(new_backup_dir)"
    backup_file "$HAPROXY_CONFIG" "$backup_dir"

    local tmp
    tmp="$(mktemp)"
    generate_haproxy_config "$tmp"

    if ! haproxy -c -f "$tmp" >>"$PDNC_LOG" 2>&1; then
        error "Generated HAProxy configuration is invalid."
        haproxy -c -f "$tmp" || true
        rm -f "$tmp"
        die "HAProxy configuration failed validation. Previous config left untouched (backup at $backup_dir)."
    fi

    atomic_replace "$HAPROXY_CONFIG" "$tmp"
    rm -f "$tmp"

    systemctl enable haproxy >>"$PDNC_LOG" 2>&1 || true
    if ! systemctl restart haproxy; then
        error "HAProxy failed to restart."
        journalctl -u haproxy --no-pager -n 30
        die "HAProxy restart failed. Backup at $backup_dir — restore with: cp $backup_dir/haproxy.cfg $HAPROXY_CONFIG"
    fi

    sleep 1

    if ! systemctl is-active --quiet haproxy; then
        error "HAProxy is not active after restart."
        journalctl -u haproxy --no-pager -n 30
        die "HAProxy failed to start. Backup at $backup_dir"
    fi

    ok "HAProxy is running on $SERVER_IP:443"
}

# ------------------------------------------------------------
# Testing
# ------------------------------------------------------------

run_tests() {
    step_header "Running final tests"

    local d real_ip rewrite_ip pub_ip

    for d in $(state_list_domains); do
        echo
        echo -e "  ${C_BOLD}Domain: $d${C_RESET}"

        real_ip="$(test_unbound_domain "$d")"
        if [[ -n "$real_ip" ]]; then
            ok "Unbound (127.0.0.1:$UNBOUND_PORT) → $real_ip"
        else
            warn "Unbound did not return an IP for $d"
        fi

        if [[ -f "$ADGUARD_CONFIG" ]]; then
            rewrite_ip="$(dig @127.0.0.1 "$d" A +short +time=3 +tries=1 2>/dev/null | head -n1)"
            if [[ "$rewrite_ip" == "$SERVER_IP" ]]; then
                ok "AdGuard (127.0.0.1:53) → $rewrite_ip (matches server IP)"
            elif [[ -n "$rewrite_ip" ]]; then
                warn "AdGuard returned $rewrite_ip, expected $SERVER_IP"
            else
                warn "AdGuard did not respond on 127.0.0.1:53 (is it listening on that interface?)"
            fi

            pub_ip="$(dig @"$SERVER_IP" "$d" A +short +time=3 +tries=1 2>/dev/null | head -n1)"
            if [[ "$pub_ip" == "$SERVER_IP" ]]; then
                ok "Public DNS ($SERVER_IP) → $pub_ip"
            else
                warn "Public DNS test on $SERVER_IP did not return the expected IP (got: '${pub_ip:-timeout}')"
            fi
        fi

        if command -v curl >/dev/null 2>&1; then
            local http_result
            http_result="$(curl -4 -sk -o /dev/null -w '%{http_code}' --max-time 8 \
                --resolve "$d:443:$SERVER_IP" "https://$d/" 2>>"$PDNC_LOG" || echo "FAIL")"
            if [[ "$http_result" =~ ^[0-9]{3}$ ]]; then
                ok "HTTPS proxy test → HTTP $http_result"
            else
                warn "HTTPS proxy test failed for $d"
            fi
        fi
    done
}

# ------------------------------------------------------------
# Service status summary
# ------------------------------------------------------------

service_status_line() {
    local svc="$1" label="$2"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  ${CHECK} ${label}"
    else
        echo -e "  ${CROSS} ${label} ${C_DIM}(not running)${C_RESET}"
    fi
}

# ------------------------------------------------------------
# Final summary screen
# ------------------------------------------------------------

print_summary() {
    echo
    echo -e "${C_GREEN}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_GREEN}║${C_RESET}          ${C_BOLD}PDNC INSTALLATION COMPLETE ✓${C_RESET}          ${C_GREEN}║${C_RESET}"
    echo -e "${C_GREEN}╠══════════════════════════════════════════════╣${C_RESET}"
    printf "${C_GREEN}║${C_RESET} %-16s: %-28s${C_GREEN}║${C_RESET}\n" "Server IP" "$SERVER_IP"
    printf "${C_GREEN}║${C_RESET} %-16s: %-28s${C_GREEN}║${C_RESET}\n" "DNS Server" "AdGuard Home :53"
    printf "${C_GREEN}║${C_RESET} %-16s: %-28s${C_GREEN}║${C_RESET}\n" "Resolver" "Unbound :$UNBOUND_PORT"
    printf "${C_GREEN}║${C_RESET} %-16s: %-28s${C_GREEN}║${C_RESET}\n" "Proxy" "HAProxy :443"
    echo -e "${C_GREEN}╠══════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_GREEN}║${C_RESET} Domains:                                       ${C_GREEN}║${C_RESET}"
    for d in $(state_list_domains); do
        printf "${C_GREEN}║${C_RESET}   ✓ %-42s ${C_GREEN}║${C_RESET}\n" "$d"
    done
    echo -e "${C_GREEN}╚══════════════════════════════════════════════╝${C_RESET}"
    echo
    echo -e "${C_BOLD}Useful commands:${C_RESET}"
    echo "  systemctl status unbound"
    echo "  systemctl status AdGuardHome"
    echo "  systemctl status haproxy"
    echo "  journalctl -u haproxy -f"
    echo "  dig @127.0.0.1 -p $UNBOUND_PORT <domain>     # via Unbound (real IP)"
    echo "  dig @127.0.0.1 <domain>                      # via AdGuard (should be $SERVER_IP)"
    echo
    echo -e "${C_DIM}Backups: $BACKUP_ROOT   |   Log: $PDNC_LOG${C_RESET}"
    echo -e "${C_DIM}Re-run 'bash install.sh' anytime to manage domains (menu mode).${C_RESET}"
    echo
}

# ------------------------------------------------------------
# Post-install management menu
# ------------------------------------------------------------

menu_add_domain() {
    local raw norm
    raw="$(ask "Domain to add")"
    norm="$(normalize_domain "$raw")"

    if [[ -z "$norm" ]] || ! is_valid_domain "$norm"; then
        error "Invalid domain."
        return
    fi

    if grep -qxF "$norm" "$PDNC_DOMAINS_FILE" 2>/dev/null; then
        warn "$norm is already configured."
        return
    fi

    state_add_domain "$norm"
    SERVER_IP="$(load_server_ip)"

    configure_adguard_upstream_and_rewrites
    setup_haproxy

    ok "$norm added and applied."
}

menu_add_game_pack() {
    SERVER_IP="$(load_server_ip)"
    NEW_DOMAINS=()

    pick_game_packs_interactive

    if [[ ${#NEW_DOMAINS[@]} -eq 0 ]]; then
        info "No new domains to add."
        return
    fi

    for d in "${NEW_DOMAINS[@]}"; do
        state_add_domain "$d"
    done

    configure_adguard_upstream_and_rewrites
    setup_haproxy

    ok "Game pack domains added and applied."
}

menu_remove_domain() {
    local raw norm
    raw="$(ask "Domain to remove")"
    norm="$(normalize_domain "$raw")"

    if ! grep -qxF "$norm" "$PDNC_DOMAINS_FILE" 2>/dev/null; then
        warn "$norm is not managed by PDNC."
        return
    fi

    state_remove_domain "$norm"
    SERVER_IP="$(load_server_ip)"

    if [[ -f "$ADGUARD_CONFIG" ]]; then
        local backup_dir
        backup_dir="$(new_backup_dir)"
        backup_file "$ADGUARD_CONFIG" "$backup_dir"

        PDNC_ADGUARD_CONFIG="$ADGUARD_CONFIG" PDNC_DOMAIN="$norm" python3 <<'PYEOF'
import os, yaml
config_file = os.environ["PDNC_ADGUARD_CONFIG"]
domain = os.environ["PDNC_DOMAIN"]
with open(config_file) as f:
    data = yaml.safe_load(f) or {}
dns = data.setdefault("dns", {})
rewrites = dns.setdefault("rewrites", [])
dns["rewrites"] = [r for r in rewrites if not (isinstance(r, dict) and r.get("domain") == domain)]
with open(config_file, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
        if adguard_service_exists; then
            systemctl restart "$ADGUARD_SERVICE" || warn "Failed to restart AdGuard Home."
        fi
    fi

    setup_haproxy

    ok "$norm removed and applied."
}

menu_list_domains() {
    echo
    echo -e "${C_BOLD}Managed domains:${C_RESET}"
    local any=0
    for d in $(state_list_domains); do
        echo "  - $d"
        any=1
    done
    [[ $any -eq 0 ]] && echo "  (none)"
}

menu_test_domain() {
    local raw norm
    raw="$(ask "Domain to test")"
    norm="$(normalize_domain "$raw")"
    SERVER_IP="$(load_server_ip)"
    echo
    echo -e "  ${C_BOLD}Domain: $norm${C_RESET}"

    local real_ip rewrite_ip
    real_ip="$(test_unbound_domain "$norm")"
    [[ -n "$real_ip" ]] && ok "Unbound → $real_ip" || warn "Unbound: no answer"

    rewrite_ip="$(dig @127.0.0.1 "$norm" A +short +time=3 +tries=1 2>/dev/null | head -n1)"
    if [[ "$rewrite_ip" == "$SERVER_IP" ]]; then
        ok "AdGuard → $rewrite_ip"
    else
        warn "AdGuard → '${rewrite_ip:-no answer}' (expected $SERVER_IP)"
    fi

    local http_result
    http_result="$(curl -4 -sk -o /dev/null -w '%{http_code}' --max-time 8 \
        --resolve "$norm:443:$SERVER_IP" "https://$norm/" 2>>"$PDNC_LOG" || echo "FAIL")"
    [[ "$http_result" =~ ^[0-9]{3}$ ]] && ok "HAProxy HTTPS → HTTP $http_result" \
        || warn "HAProxy HTTPS test failed"
}

menu_status() {
    echo
    service_status_line unbound      "Unbound"
    service_status_line "$ADGUARD_SERVICE" "AdGuard Home"
    service_status_line haproxy      "HAProxy"
}

menu_restart_services() {
    systemctl restart unbound && ok "Unbound restarted" || error "Unbound restart failed"
    if adguard_service_exists; then
        systemctl restart "$ADGUARD_SERVICE" && ok "AdGuard Home restarted" || error "AdGuard Home restart failed"
    fi
    systemctl restart haproxy && ok "HAProxy restarted" || error "HAProxy restart failed"
}

management_menu() {
    while true; do
        echo
        echo -e "${C_BOLD}${C_CYAN}PDNC DNS PROXY — Management${C_RESET}"
        echo "  1) Add domain"
        echo "  2) Add game (from popular games list)"
        echo "  3) Remove domain"
        echo "  4) List domains"
        echo "  5) Test domain"
        echo "  6) Show status"
        echo "  7) Restart services"
        echo "  8) Exit"
        local choice
        choice="$(ask "Select an option [1-8]")"
        case "$choice" in
            1) menu_add_domain ;;
            2) menu_add_game_pack ;;
            3) menu_remove_domain ;;
            4) menu_list_domains ;;
            5) menu_test_domain ;;
            6) menu_status ;;
            7) menu_restart_services ;;
            8) echo "Bye."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ------------------------------------------------------------
# Main install flow
# ------------------------------------------------------------

run_fresh_or_update_install() {
    banner
    check_root
    check_os
    init_state

    section "Welcome"
    echo "  This installer sets up:"
    echo "    1. Unbound   — recursive DNS resolver (127.0.0.1:$UNBOUND_PORT)"
    echo "    2. AdGuard Home — DNS server with rewrites (:53)"
    echo "    3. HAProxy   — TLS-passthrough SNI reverse proxy (:443)"
    echo
    if ! confirm "Proceed with installation / update?" "y"; then
        echo "Cancelled."
        exit 0
    fi

    resolve_server_ip
    collect_domains

    install_packages
    setup_unbound
    install_adguard
    configure_adguard_upstream_and_rewrites
    setup_haproxy
    run_tests

    print_summary
}

main() {
    init_state
    mkdir -p "$BACKUP_ROOT"

    if [[ -f "$PDNC_DOMAINS_FILE" && -s "$PDNC_DOMAINS_FILE" && -f "$PDNC_SERVER_IP_FILE" ]] \
        && systemctl list-unit-files 2>/dev/null | grep -q '^haproxy\.service'; then
        banner
        echo -e "  Existing PDNC installation detected."
        echo
        echo "  1) Run management menu"
        echo "  2) Re-run full install / add more domains"
        local choice
        choice="$(ask "Select [1-2]")"
        if [[ "$choice" == "2" ]]; then
            SERVER_IP="$(load_server_ip)"
            run_fresh_or_update_install
        else
            SERVER_IP="$(load_server_ip)"
            management_menu
        fi
    else
        run_fresh_or_update_install
        management_menu
    fi
}

main "$@"
