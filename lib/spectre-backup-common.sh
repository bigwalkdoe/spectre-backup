#!/bin/bash
# ============================================================
# spectre-backup - Shared library
# Distro detection, package management, logging, config loading.
# ============================================================

# --- Colours (only when attached to a terminal) ---
# Respect the NO_COLOR standard (https://no-color.org) and an explicit
# NO_COLOR=true/1/yes.
RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
fi

info()  { [ "${QUIET:-false}" = true ] || echo -e "$(date '+%H:%M:%S') ${GREEN}[INFO]${NC}  $*"; }
warn()  { [ "${QUIET:-false}" = true ] || echo -e "$(date '+%H:%M:%S') ${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "$(date '+%H:%M:%S') ${RED}[ERROR]${NC} $*" >&2; }
header(){ [ "${QUIET:-false}" = true ] || echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

# --- Detect Linux distribution ---
# Sets: DISTRO_ID, DISTRO_ID_LIKE, DISTRO_VERSION_ID, PKG_MANAGER, PKG_INSTALL, PKG_REFRESH
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}"
        DISTRO_ID_LIKE="${ID_LIKE:-}"
        DISTRO_VERSION_ID="${VERSION_ID:-}"
    elif command -v lsb_release >/dev/null 2>&1; then
        DISTRO_ID=$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')
        # shellcheck disable=SC2034  # library API, read by the health output
        DISTRO_VERSION_ID=$(lsb_release -sr 2>/dev/null)
    else
        error "Cannot detect Linux distribution"
        return 1
    fi

    case "$DISTRO_ID" in
        fedora)
            PKG_MANAGER="dnf"
            PKG_INSTALL="dnf install -y"
            PKG_REFRESH="dnf makecache"
            ;;
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_INSTALL="apt-get install -y"
            PKG_REFRESH="apt-get update"
            ;;
        *)
            if echo "$DISTRO_ID_LIKE" | grep -qi "fedora"; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y"
                PKG_REFRESH="dnf makecache"
            elif echo "$DISTRO_ID_LIKE" | grep -qi "debian\|ubuntu"; then
                PKG_MANAGER="apt"
                PKG_INSTALL="apt-get install -y"
                PKG_REFRESH="apt-get update"
            else
                error "Unsupported distribution: $DISTRO_ID ($DISTRO_ID_LIKE)"
                return 1
            fi
            ;;
    esac
    return 0
}

# --- Install system packages, skipping ones already present ---
install_packages() {
    local pkgs=("$@")
    local missing=()
    for pkg in "${pkgs[@]}"; do
        case "$PKG_MANAGER" in
            dnf)
                if rpm -q "$pkg" &>/dev/null; then continue; fi ;;
            apt)
                if dpkg -s "$pkg" &>/dev/null; then continue; fi ;;
        esac
        missing+=("$pkg")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        info "All required packages already installed"
        return 0
    fi
    info "Installing: ${missing[*]}"
    $PKG_REFRESH >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    if [ "$(id -u)" -eq 0 ]; then
        $PKG_INSTALL "${missing[@]}"
    else
        sudo $PKG_INSTALL "${missing[@]}"
    fi
}

check_cmd() { command -v "$1" &>/dev/null; }

# --- Resolve config directories ---
# CONFIG_DIR:     ~/.config/spectre-backup  (or XDG_CONFIG_HOME)
# STATE_DIR:      ~/.local/state/spectre-backup (or XDG_STATE_HOME)
# BIN_DIR:        ~/.local/bin (or XDG_DATA_HOME/bin)
# SYSTEM_DIR:     /etc/spectre-backup  (system-wide config for servers)
resolve_dirs() {
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spectre-backup"
    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup"
    BIN_DIR="${XDG_DATA_HOME:-$HOME/.local}/bin"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR"
}

# --- Detect machine role: workstation or server ---
# Role precedence: SPECTRE_BACKUP_ROLE env var -> installer flag -> auto-detect
# Auto-detect: if a graphical session is present, treat as workstation.
detect_role() {
    if [ -n "${SPECTRE_BACKUP_ROLE:-}" ]; then
        echo "$SPECTRE_BACKUP_ROLE"
        return 0
    fi
    # Auto-detect: presence of a desktop session suggests workstation
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || \
       [ -n "${XDG_SESSION_TYPE:-}" ] || command -v notify-send >/dev/null 2>&1; then
        echo "workstation"
    else
        echo "server"
    fi
}

# --- Load environment from .env (user config dir or system dir) ---
load_env() {
    local env_file=""
    if [ -f "$CONFIG_DIR/.env" ]; then
        env_file="$CONFIG_DIR/.env"
    elif [ -f "/etc/spectre-backup/.env" ]; then
        env_file="/etc/spectre-backup/.env"
    elif [ -f "${PROJECT_DIR:-}/config/.env.example" ]; then
        env_file="${PROJECT_DIR}/config/.env.example"
    fi
    if [ -n "$env_file" ] && [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090  # config path is resolved at runtime
        source "$env_file"
        set +a
        return 0
    fi
    return 1
}

# --- Build a target list from an include file ---
# build_targets <include_file> -> populates TARGETS_OUT
build_targets() {
    local file="$1"
    local -n out_ref="$2"
    out_ref=()
    [ -f "$file" ] && [ -s "$file" ] || return 1
    local line
    while IFS= read -r line; do
        line="${line%%#*}"          # strip comments
        line="${line//\~/$HOME}"     # expand ~
        line="${line%/}"            # remove trailing slash
        [ -z "$line" ] && continue
        if [ -e "$line" ]; then
            out_ref+=("$line")
        else
            warn "Include path not found, skipping: $line"
        fi
    done < "$file"
    [ "${#out_ref[@]}" -gt 0 ]
}
