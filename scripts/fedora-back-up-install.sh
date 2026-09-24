#!/bin/bash
# ============================================================
# fedora-back-up - Installer
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-back-up"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
BIN_DIR="${XDG_DATA_HOME:-$HOME/.local}/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

check_cmd() { command -v "$1" &>/dev/null; }

# --- Step 1: Install system packages ---
header "Step 1: Installing system packages"

PACKAGES=(restic rclone jq)
FEDORA_PKGS=()
for pkg in "${PACKAGES[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        FEDORA_PKGS+=("$pkg")
    fi
done

if [ ${#FEDORA_PKGS[@]} -gt 0 ]; then
    info "Installing: ${FEDORA_PKGS[*]}"
    sudo dnf install -y "${FEDORA_PKGS[@]}"
else
    info "All required packages already installed"
fi

# Check for optional notification utilities
if check_cmd notify-send; then
    info "Desktop notifications available (libnotify)"
else
    warn "notify-send not found - desktop notifications disabled"
    warn "Install libnotify: sudo dnf install -y libnotify"
fi

# --- Step 2: Create directory structure ---
header "Step 2: Creating directory structure"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR"
info "Configuration: $CONFIG_DIR"
info "State/logs:    $STATE_DIR"

# --- Step 3: Install scripts ---
header "Step 3: Installing scripts"

for script in fedora-back-up.sh fedora-back-up-restore.sh fedora-back-up-verify.sh fedora-back-up-prune.sh; do
    src="$PROJECT_DIR/scripts/$script"
    dest="$BIN_DIR/$script"
    if [ -f "$src" ]; then
        cp "$src" "$dest"
        chmod 755 "$dest"
        info "Installed: $dest"
    else
        warn "Not found: $src - skipping"
    fi
done

# Install symlink to main backup script for systemd
ln -sf "$BIN_DIR/fedora-back-up.sh" "$BIN_DIR/fedora-back-up"
info "Symlink: $BIN_DIR/fedora-back-up -> $BIN_DIR/fedora-back-up.sh"

# --- Step 4: Copy default config files ---
header "Step 4: Creating configuration"

if [ ! -f "$CONFIG_DIR/include.conf" ]; then
    cp "$PROJECT_DIR/config/include.conf" "$CONFIG_DIR/include.conf"
    info "Created: $CONFIG_DIR/include.conf"
else
    info "Exists:  $CONFIG_DIR/include.conf (not overwritten)"
fi

if [ ! -f "$CONFIG_DIR/exclude.conf" ]; then
    cp "$PROJECT_DIR/config/exclude.conf" "$CONFIG_DIR/exclude.conf"
    info "Created: $CONFIG_DIR/exclude.conf"
else
    info "Exists:  $CONFIG_DIR/exclude.conf (not overwritten)"
fi

if [ ! -f "$CONFIG_DIR/.env" ]; then
    cp "$PROJECT_DIR/config/.env.example" "$CONFIG_DIR/.env"
    chmod 600 "$CONFIG_DIR/.env"
    info "Created: $CONFIG_DIR/.env (EDIT THIS FILE)"
else
    info "Exists:  $CONFIG_DIR/.env (not overwritten)"
fi

# --- Step 5: Configure rclone ---
header "Step 5: Configuring rclone for Google Drive"

if check_cmd rclone && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    info "rclone remote 'gdrive:' already configured"
else
    echo ""
    echo -e "${YELLOW}rclone remote 'gdrive:' not found.${NC}"
    echo -e "You need to authenticate rclone with Google Drive."
    echo -e ""
    echo -e "When prompted:"
    echo -e "  1. Select ${BOLD}n${NC} for 'New remote'"
    echo -e "  2. Name: ${BOLD}gdrive${NC}"
    echo -e "  3. Type: ${BOLD}drive${NC}"
    echo -e "  4. Follow the OAuth flow in your browser"
    echo -e ""
    read -rp "Launch rclone config now? [Y/n]: " answer
    case "${answer:-Y}" in
        [Yy]*)
            rclone config
            ;;
        *)
            warn "Skipping rclone config. Run 'rclone config' manually later."
            ;;
    esac
fi

# --- Step 6: Create test folder and validate ---
header "Step 6: Validating Google Drive access"

if check_cmd rclone && rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    info "Testing Google Drive access..."
    if rclone mkdir "gdrive:ModelinkBackups" 2>/dev/null; then
        info "Created/verified: gdrive:ModelinkBackups"
        if rclone mkdir "gdrive:ModelinkBackups/workstation" 2>/dev/null; then
            info "Created/verified: gdrive:ModelinkBackups/workstation"
        fi
        info "Upload test: writing test file..."
        echo "test-$(date)" | rclone rcat "gdrive:ModelinkBackups/workstation/.write-test" 2>/dev/null
        rclone delete "gdrive:ModelinkBackups/workstation/.write-test" 2>/dev/null
        info "Upload test passed"
    else
        error "Cannot access Google Drive. Check rclone configuration."
        exit 1
    fi
else
    error "rclone not configured. Run 'rclone config' first, then re-run this installer."
    exit 1
fi

# --- Step 7: Set up Restic password ---
header "Step 7: Setting up Restic repository password"

if [ -f "$CONFIG_DIR/password" ] && [ -s "$CONFIG_DIR/password" ]; then
    info "Password file exists: $CONFIG_DIR/password"
    read -rp "Replace password? [y/N]: " replace
    if [[ "$replace" =~ ^[Yy] ]]; then
        read -rsp "Enter new Restic repository password: " password; echo
        read -rsp "Confirm password: " password2; echo
        if [ "$password" != "$password2" ]; then
            error "Passwords do not match"
            exit 1
        fi
        echo -n "$password" > "$CONFIG_DIR/password"
        chmod 600 "$CONFIG_DIR/password"
        info "Password updated"
    fi
else
    read -rsp "Enter Restic repository password: " password; echo
    read -rsp "Confirm password: " password2; echo
    if [ "$password" != "$password2" ]; then
        error "Passwords do not match"
        exit 1
    fi
    echo -n "$password" > "$CONFIG_DIR/password"
    chmod 600 "$CONFIG_DIR/password"
    info "Password stored in $CONFIG_DIR/password (chmod 600)"
fi

# --- Step 8: Initialize Restic repository ---
header "Step 8: Initializing Restic repository"

REPO="rclone:gdrive:ModelinkBackups/workstation"
if RESTIC_PASSWORD_COMMAND="cat $CONFIG_DIR/password" restic -r "$REPO" snapshots 2>/dev/null; then
    info "Restic repository already initialized"
else
    info "Initializing new Restic repository..."
    RESTIC_PASSWORD_COMMAND="cat $CONFIG_DIR/password" restic -r "$REPO" init
    info "Repository initialized"
fi

# --- Step 9: Install systemd units ---
header "Step 9: Installing systemd service and timer"

SYSTEMD_USER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cp "$PROJECT_DIR/systemd/fedora-back-up.service" "$SYSTEMD_USER_DIR/"
cp "$PROJECT_DIR/systemd/fedora-back-up.timer" "$SYSTEMD_USER_DIR/"
systemctl --user daemon-reload

if systemctl --user is-enabled fedora-back-up.timer &>/dev/null 2>&1; then
    info "Timer already enabled"
else
    systemctl --user enable fedora-back-up.timer
    info "Timer enabled"
fi

if systemctl --user is-active fedora-back-up.timer &>/dev/null 2>&1; then
    info "Timer already active"
else
    systemctl --user start fedora-back-up.timer
    info "Timer started"
fi

info "Timer status:"
systemctl --user status fedora-back-up.timer --no-pager 2>&1 | head -10

# --- Step 10: Test run ---
header "Step 10: Performing test run"

echo -e "${YELLOW}About to perform a test backup of small paths only.${NC}"
read -rp "Run test backup now? [Y/n]: " testanswer
case "${testanswer:-Y}" in
    [Yy]*)
        info "Running test backup..."
        RESTIC_PASSWORD_COMMAND="cat $CONFIG_DIR/password" \
        restic -r "$REPO" \
            --verbose \
            backup \
            "$HOME/.bashrc" \
            "$HOME/.gitconfig" \
            "$HOME/.config/fedora-back-up" \
            2>&1 | tail -20
        info "Test backup complete"
        ;;
    *)
        warn "Skipping test backup"
        ;;
esac

# --- Done ---
header "Installation Complete"

echo -e "${GREEN}${BOLD}fedora-back-up installed!${NC}"
echo ""
echo -e "  Config directory:  ${BOLD}$CONFIG_DIR${NC}"
echo -e "  Log directory:     ${BOLD}$STATE_DIR${NC}"
echo -e "  Scripts:           ${BOLD}$BIN_DIR${NC}"
echo -e "  Repository:        ${BOLD}$REPO${NC}"
echo ""
echo -e "Next steps:"
echo -e "  1. Edit ${BOLD}$CONFIG_DIR/.env${NC} if needed"
echo -e "  2. Edit ${BOLD}$CONFIG_DIR/include.conf${NC} to add/remove backup paths"
echo -e "  3. Edit ${BOLD}$CONFIG_DIR/exclude.conf${NC} to customize exclusions"
echo -e "  4. Run ${BOLD}$BIN_DIR/fedora-back-up.sh${NC} for a full backup"
echo -e "  5. Run ${BOLD}$BIN_DIR/fedora-back-up-restore.sh${NC} to test restoration"
echo ""
echo -e "  Timer runs daily at 04:00. Check with:"
echo -e "    ${BOLD}systemctl --user status fedora-back-up.timer${NC}"
echo -e "    ${BOLD}journalctl --user -u fedora-back-up.service -f${NC}"
