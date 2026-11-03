#!/bin/bash
# ============================================================
# spectre-backup - Installer
# Multi-distro (Fedora, Ubuntu), multi-role (workstation, server).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared library
# shellcheck source=../lib/spectre-backup-common.sh
. "$PROJECT_DIR/lib/spectre-backup-common.sh"
# Source migration library
# shellcheck source=../lib/migrate-legacy.sh
. "$PROJECT_DIR/lib/migrate-legacy.sh"

# --- Parse arguments ---
ROLE=""
INSTALL_BIN_ONLY=false
SKIP_TEST=false
NO_MIGRATE=false
FORCE_OVERWRITE=false
QUIET=false

for arg in "$@"; do
    case "$arg" in
        --role=*) ROLE="${arg#*=}" ;;
        --workstation) ROLE="workstation" ;;
        --server) ROLE="server" ;;
        --bin-only) INSTALL_BIN_ONLY=true ;;
        --skip-test) SKIP_TEST=true ;;
        --no-migrate) NO_MIGRATE=true ;;
        --force) FORCE_OVERWRITE=true ;;
        --quiet) QUIET=true ;;
        --help|-h)
            echo "Usage: $0 [--role=workstation|server] [--bin-only] [--skip-test]"
            echo ""
            echo "  --role=workstation  Install as a workstation (user systemd service, desktop notifications)"
            echo "  --role=server       Install as a server (system systemd service, no notifications)"
            echo "  --bin-only          Install scripts only, skip config and systemd"
            echo "  --skip-test         Skip the test backup prompt"
            echo "  --no-migrate        Skip legacy install migration"
            echo "  --force             Overwrite existing config files"
            echo "  --quiet             Suppress informational output"
            exit 0
            ;;
        --version)
            if git -C "$PROJECT_DIR" describe --tags --always >/dev/null 2>&1; then
                echo "spectre-backup installer $(git -C "$PROJECT_DIR" describe --tags --always 2>/dev/null)"
            else
                echo "spectre-backup installer (dev)"
            fi
            exit 0
            ;;
        *)
            error "Unknown argument: $arg"
            exit 2
            ;;
    esac
done

# --- Interactive mode ---
INTERACTIVE=true
[ -t 0 ] || INTERACTIVE=false

# --- Detect distro ---
detect_distro || exit 1
info "Detected: $DISTRO_ID $DISTRO_VERSION_ID ($PKG_MANAGER)"

# --- Detect role ---
if [ -z "$ROLE" ]; then
    ROLE=$(detect_role)
fi
info "Role: $ROLE"

# The server unit runs /root/.local/bin/spectre-backup.sh as root. A non-root
# install would put the scripts in another user's home and the unit would fail
# with 203/EXEC, so require root up front.
if [ "$ROLE" = "server" ] && [ "$(id -u)" -ne 0 ]; then
    error "Server installs must run as root (the system unit runs /root/.local/bin/spectre-backup.sh)"
    error "Re-run with: sudo $0 --role=server"
    exit 1
fi

# Legacy rename migration (before resolve_dirs so detection sees real state)
if [ "$INSTALL_BIN_ONLY" = true ]; then
    info "Skipping legacy migration (--bin-only)"
elif [ "$NO_MIGRATE" = true ]; then
    info "Skipping legacy migration (--no-migrate)"
else
    header "Step 0: Migrating legacy install (if any)"
    migrate_legacy_install
fi

# --- Resolve directories ---
resolve_dirs

# The system unit runs /root/.local/bin/spectre-backup.sh; pin the server
# install location so a preserved HOME cannot produce a 203/EXEC unit.
if [ "$ROLE" = "server" ]; then
    BIN_DIR="/root/.local/bin"
fi

# --- Determine config source path ---
CONFIG_SOURCE="$PROJECT_DIR/config/$ROLE/$DISTRO_ID"
if [ ! -d "$CONFIG_SOURCE" ]; then
    warn "No config for role=$ROLE distro=$DISTRO_ID; falling back to defaults"
    CONFIG_SOURCE="$PROJECT_DIR/config/defaults"
fi
info "Config source: $CONFIG_SOURCE"

# --- Where to install config ---
if [ "$ROLE" = "server" ]; then
    INSTALL_CONFIG_DIR="/etc/spectre-backup"
else
    INSTALL_CONFIG_DIR="$CONFIG_DIR"
fi

# ============================================================
# Step 1: Install system packages
# ============================================================
header "Step 1: Installing system packages"

PACKAGES=(restic rclone jq)
install_packages "${PACKAGES[@]}"

if check_cmd notify-send; then
    info "Desktop notifications available (libnotify)"
else
    if [ "$ROLE" = "workstation" ]; then
        warn "notify-send not found - desktop notifications disabled"
        warn "Install libnotify: sudo $PKG_INSTALL libnotify"
    fi
    info "Desktop notifications not required for $ROLE role"
fi

# ============================================================
# Step 2: Create directory structure
# ============================================================
if [ "$INSTALL_BIN_ONLY" = true ]; then
    header "Step 2: Skipping directory structure (--bin-only)"
else
    header "Step 2: Creating directory structure"

    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR"
    if [ "$ROLE" = "server" ]; then
        sudo mkdir -p "$INSTALL_CONFIG_DIR"
    fi
    info "Configuration: $INSTALL_CONFIG_DIR"
    info "State/logs:    $STATE_DIR"
    info "Scripts:       $BIN_DIR"
fi

# ============================================================
# Step 3: Install scripts
# ============================================================
header "Step 3: Installing scripts"

for script in spectre-backup.sh spectre-backup-restore.sh spectre-backup-verify.sh spectre-backup-prune.sh git-mirror.sh; do
    src="$PROJECT_DIR/scripts/$script"
    dest="$BIN_DIR/$script"
    if [ -f "$src" ]; then
        # Remove existing file or symlink (cp refuses to write through a
        # dangling symlink, and we always want to replace with our copy).
        rm -f "$dest"
        cp "$src" "$dest"
        chmod 755 "$dest"
        info "Installed: $dest"
    else
        warn "Not found: $src - skipping"
    fi
done

# Install shared library alongside scripts
lib_src="$PROJECT_DIR/lib/spectre-backup-common.sh"
lib_dest="$BIN_DIR/spectre-backup-common.sh"
if [ -f "$lib_src" ]; then
    rm -f "$lib_dest"
    cp "$lib_src" "$lib_dest"
    chmod 644 "$lib_dest"
    info "Installed: $lib_dest"
else
    warn "Not found: $lib_src - skipping"
fi

# Symlink for systemd and convenience
ln -sf "$BIN_DIR/spectre-backup.sh" "$BIN_DIR/spectre-backup"
info "Symlink: $BIN_DIR/spectre-backup -> $BIN_DIR/spectre-backup.sh"

# ============================================================
# Step 4: Create configuration
# ============================================================
header "Step 4: Creating configuration"

copy_config() {
    local name="$1"
    local src="$CONFIG_SOURCE/$name"
    local dest="$INSTALL_CONFIG_DIR/$name"
    if [ "$INSTALL_BIN_ONLY" = true ]; then
        info "Skipping: $name (--bin-only)"
        return 0
    fi
    if [ -f "$src" ]; then
        if [ -e "$dest" ] && [ "$FORCE_OVERWRITE" != true ] && [ ! "$INSTALL_BIN_ONLY" = true ]; then
            info "Exists:  $dest (not overwritten)"
        else
            # Remove existing file or symlink (cp refuses to write through a
            # dangling symlink).
            rm -f "$dest"
            if [ "$ROLE" = "server" ]; then
                sudo cp "$src" "$dest"
                sudo chmod 644 "$dest"
            else
                cp "$src" "$dest"
                chmod 644 "$dest"
            fi
            info "Created: $dest"
        fi
    else
        warn "Not found: $src - skipping"
    fi
}

copy_config "include.conf"
copy_config "exclude.conf"
copy_config "include-remote.conf"

if { [ ! -f "$INSTALL_CONFIG_DIR/.env" ] || [ "$FORCE_OVERWRITE" = true ]; } && [ ! "$INSTALL_BIN_ONLY" = true ]; then
    if [ "$ROLE" = "server" ]; then
        sudo cp "$PROJECT_DIR/config/.env.example" "$INSTALL_CONFIG_DIR/.env"
        sudo chmod 600 "$INSTALL_CONFIG_DIR/.env"
    else
        cp "$PROJECT_DIR/config/.env.example" "$INSTALL_CONFIG_DIR/.env"
        chmod 600 "$INSTALL_CONFIG_DIR/.env"
    fi
    info "Created: $INSTALL_CONFIG_DIR/.env (EDIT THIS FILE)"
else
    info "Exists:  $INSTALL_CONFIG_DIR/.env (not overwritten)"
fi

# ============================================================
# Step 5: Configure rclone
# ============================================================
header "Step 5: Configuring rclone for offsite storage"

if check_cmd rclone && rclone listremotes 2>/dev/null | grep -q "^spectre-backup:"; then
    info "rclone remote 'spectre-backup:' already configured"
else
    echo ""
    echo -e "${YELLOW}rclone remote 'spectre-backup:' not found.${NC}"
    echo -e "You need to authenticate rclone with your offsite storage (Google Drive, S3, etc.)."
    echo -e ""
    echo -e "When prompted:"
    echo -e "  1. Select ${BOLD}n${NC} for 'New remote'"
    echo -e "  2. Name: ${BOLD}spectre-backup${NC}"
    echo -e "  3. Type: choose your storage backend (drive, s3, etc.)"
    echo -e "  4. Follow the auth flow"
    echo -e ""
    if [ "$INTERACTIVE" = true ]; then
        read -rp "Launch rclone config now? [Y/n]: " answer
        case "${answer:-Y}" in
            [Yy]*)
                rclone config
                ;;
            *)
                warn "Skipping rclone config. Run 'rclone config' manually later."
                ;;
        esac
    else
        warn "Non-interactive mode: skipping rclone config. Run 'rclone config' manually later."
    fi
fi

# ============================================================
# Step 6: Validate offsite access (optional, non-fatal)
# ============================================================
header "Step 6: Validating offsite access"

if check_cmd rclone && rclone listremotes 2>/dev/null | grep -q "^spectre-backup:"; then
    info "Testing offsite access..."
    if timeout 30 rclone lsd "spectre-backup:" >/dev/null 2>&1; then
        info "Offsite remote 'spectre-backup:' is accessible"
    else
        warn "Offsite remote exists but is not usable (may need re-authorisation)"
        warn "Run: rclone config reconnect spectre-backup:"
    fi
else
    warn "No 'spectre-backup:' rclone remote configured. Offsite backups will be skipped."
    info "Run 'rclone config' to add one, then re-run the installer."
fi

# ============================================================
# Step 7: Set up Restic password
# ============================================================
if [ "$INSTALL_BIN_ONLY" = true ]; then
    header "Step 7: Skipping Restic password (--bin-only)"
else
    header "Step 7: Setting up Restic repository password"

    PASSWORD_FILE="$INSTALL_CONFIG_DIR/password"

    if [ -f "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
        info "Password file exists: $PASSWORD_FILE"
        if [ "$INTERACTIVE" = true ]; then
            read -rp "Replace password? [y/N]: " replace
            if [[ "$replace" =~ ^[Yy] ]]; then
                read -rsp "Enter new Restic repository password: " password; echo
                read -rsp "Confirm password: " password2; echo
                if [ "$password" != "$password2" ]; then
                    error "Passwords do not match"
                    exit 1
                fi
                if [ "$ROLE" = "server" ]; then
                    echo -n "$password" | sudo tee "$PASSWORD_FILE" >/dev/null
                    sudo chmod 600 "$PASSWORD_FILE"
                else
                    echo -n "$password" > "$PASSWORD_FILE"
                    chmod 600 "$PASSWORD_FILE"
                fi
                info "Password updated"
            else
                info "Keeping existing password"
            fi
        else
            info "Non-interactive mode: keeping existing password"
        fi
    else
        if [ "$INTERACTIVE" = true ]; then
            read -rsp "Enter Restic repository password: " password; echo
            read -rsp "Confirm password: " password2; echo
            if [ "$password" != "$password2" ]; then
                error "Passwords do not match"
                exit 1
            fi
        else
            error "Password file not found and non-interactive mode cannot create one"
            error "Create $PASSWORD_FILE manually (chmod 600) or run interactively."
            exit 1
        fi
        if [ "$ROLE" = "server" ]; then
            echo -n "$password" | sudo tee "$PASSWORD_FILE" >/dev/null
            sudo chmod 600 "$PASSWORD_FILE"
        else
            echo -n "$password" > "$PASSWORD_FILE"
            chmod 600 "$PASSWORD_FILE"
        fi
        info "Password stored in $PASSWORD_FILE (chmod 600)"
    fi
fi

# ============================================================
# Step 8: Initialize Restic repository
# ============================================================
if [ "$INSTALL_BIN_ONLY" = true ]; then
    header "Step 8: Skipping repository init (--bin-only)"
else
    header "Step 8: Initializing Restic repository"

    # Honour a repository already declared in .env (e.g. a custom remote or
    # local path) rather than always assuming the default rclone remote.
    REPO="rclone:spectre-backup:"
    if [ -f "$INSTALL_CONFIG_DIR/.env" ]; then
        # shellcheck disable=SC1090
        . "$INSTALL_CONFIG_DIR/.env" 2>/dev/null || true
        REPO="${RESTIC_REPOSITORY:-$REPO}"
    fi
    export RESTIC_PASSWORD_COMMAND="cat $PASSWORD_FILE"
    if restic -r "$REPO" snapshots >/dev/null 2>&1; then
        info "Restic repository already initialized"
    else
        info "Initializing new Restic repository..."
        if restic -r "$REPO" init; then
            info "Repository initialized"
        else
            warn "Repository initialization failed - you can retry later with: spectre-backup.sh"
        fi
    fi
fi

# ============================================================
# Step 9: Install systemd units
# ============================================================
if [ "$INSTALL_BIN_ONLY" = true ]; then
    header "Step 9: Skipping systemd (--bin-only)"
else
    header "Step 9: Installing systemd service and timer"

    if [ "$ROLE" = "server" ]; then
        # System service (runs as root, no user session needed)
        SYSTEMD_DIR="/etc/systemd/system"
        sudo mkdir -p "$SYSTEMD_DIR"
        sudo cp "$PROJECT_DIR/systemd/spectre-backup-system.service" "$SYSTEMD_DIR/spectre-backup.service"
        sudo cp "$PROJECT_DIR/systemd/spectre-backup.timer" "$SYSTEMD_DIR/"
        sudo systemctl daemon-reload

        if systemctl is-enabled spectre-backup.timer &>/dev/null 2>&1; then
            info "Timer already enabled"
        else
            sudo systemctl enable spectre-backup.timer
            info "Timer enabled"
        fi
        if systemctl is-active spectre-backup.timer &>/dev/null 2>&1; then
            info "Timer already active"
        else
            sudo systemctl start spectre-backup.timer
            info "Timer started"
        fi
        info "Timer status:"
        systemctl status spectre-backup.timer --no-pager 2>&1 | head -10 || true
    else
        # User service (runs as the logged-in user)
        SYSTEMD_USER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"
        cp "$PROJECT_DIR/systemd/spectre-backup.service" "$SYSTEMD_USER_DIR/"
        cp "$PROJECT_DIR/systemd/spectre-backup.timer" "$SYSTEMD_USER_DIR/"
        systemctl --user daemon-reload

        if systemctl --user is-enabled spectre-backup.timer &>/dev/null 2>&1; then
            info "Timer already enabled"
        else
            systemctl --user enable spectre-backup.timer
            info "Timer enabled"
        fi
        if systemctl --user is-active spectre-backup.timer &>/dev/null 2>&1; then
            info "Timer already active"
        else
            systemctl --user start spectre-backup.timer
            info "Timer started"
        fi
        info "Timer status:"
        systemctl --user status spectre-backup.timer --no-pager 2>&1 | head -10 || true
    fi
fi

# ============================================================
# Step 10: Test run
# ============================================================
if [ "$SKIP_TEST" = true ]; then
    header "Step 10: Skipping test run (--skip-test)"
elif [ "$INSTALL_BIN_ONLY" = true ]; then
    header "Step 10: Skipping test run (--bin-only)"
else
    header "Step 10: Performing test run"

    echo -e "${YELLOW}About to perform a test backup of small paths only.${NC}"
    if [ "$INTERACTIVE" = true ]; then
        read -rp "Run test backup now? [Y/n]: " testanswer
        case "${testanswer:-Y}" in
            [Yy]*)
                info "Running test backup..."
                RESTIC_PASSWORD_COMMAND="cat $PASSWORD_FILE" \
                restic -r "$REPO" \
                    --verbose \
                    backup \
                    "$HOME/.bashrc" \
                    "$HOME/.gitconfig" \
                    "$INSTALL_CONFIG_DIR" \
                    2>&1 | tail -20
                info "Test backup complete"
                ;;
            *)
                warn "Skipping test backup"
                ;;
        esac
    else
        warn "Non-interactive mode: skipping test backup. Run: $BIN_DIR/spectre-backup.sh"
    fi
fi

# ============================================================
# Done
# ============================================================
header "Installation Complete"

echo -e "${GREEN}${BOLD}spectre-backup installed!${NC}"
echo ""
echo -e "  Distro:        ${BOLD}$DISTRO_ID $DISTRO_VERSION_ID${NC}"
echo -e "  Role:          ${BOLD}$ROLE${NC}"
echo -e "  Config dir:    ${BOLD}$INSTALL_CONFIG_DIR${NC}"
echo -e "  State/logs:    ${BOLD}$STATE_DIR${NC}"
echo -e "  Scripts:       ${BOLD}$BIN_DIR${NC}"
echo -e "  Repository:    ${BOLD}${REPO:-rclone:spectre-backup:}${NC}"
echo ""
echo -e "Next steps:"
echo -e "  1. Edit ${BOLD}$INSTALL_CONFIG_DIR/.env${NC} if needed"
echo -e "  2. Edit ${BOLD}$INSTALL_CONFIG_DIR/include.conf${NC} to add/remove backup paths"
echo -e "  3. Edit ${BOLD}$INSTALL_CONFIG_DIR/exclude.conf${NC} to customize exclusions"
echo -e "  4. Run ${BOLD}$BIN_DIR/spectre-backup.sh${NC} for a full backup"
echo -e "  5. Run ${BOLD}$BIN_DIR/spectre-backup-restore.sh${NC} to test restoration"
echo ""
echo -e "  Timer runs daily at 04:00. Check with:"
if [ "$ROLE" = "server" ]; then
    echo -e "    ${BOLD}systemctl status spectre-backup.timer${NC}"
    echo -e "    ${BOLD}journalctl -u spectre-backup.service -f${NC}"
else
    echo -e "    ${BOLD}systemctl --user status spectre-backup.timer${NC}"
    echo -e "    ${BOLD}journalctl --user -u spectre-backup.service -f${NC}"
fi
