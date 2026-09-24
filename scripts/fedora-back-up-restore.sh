#!/bin/bash
# ============================================================
# fedora-back-up - Restore / Disaster Recovery
#
# Usage:
#   fedora-back-up-restore.sh                    # Restore latest snapshot
#   fedora-back-up-restore.sh --list             # List snapshots
#   fedora-back-up-restore.sh --snapshot <id>    # Restore specific snapshot
#   fedora-back-up-restore.sh --dry-run          # Preview restore
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-back-up"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

check_cmd() { command -v "$1" &>/dev/null; }

# --- Parse arguments ---
RESTORE_SNAPSHOT="latest"
DRY_RUN=false
JUST_LIST=false

for arg in "$@"; do
    case "$arg" in
        --list|--snapshots) JUST_LIST=true ;;
        --snapshot=*) RESTORE_SNAPSHOT="${arg#*=}" ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--list] [--snapshot=<id>] [--dry-run]"
            echo ""
            echo "  --list         List all snapshots"
            echo "  --snapshot=<id> Restore specific snapshot (default: latest)"
            echo "  --dry-run      Show what would be restored without doing it"
            exit 0
            ;;
    esac
done

# --- Load config ---
if [ -f "$CONFIG_DIR/.env" ]; then
    set -a; source "$CONFIG_DIR/.env"; set +a
fi
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:gdrive:ModelinkBackups/workstation}"
export RESTIC_PASSWORD_COMMAND="cat $RESTIC_PASSWORD_FILE"
LOG_DIR="${LOG_DIR:-$STATE_DIR}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/restore-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

# --- Pre-flight checks ---
header "Pre-flight checks"

if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    error "Restic password file not found: $RESTIC_PASSWORD_FILE"
    exit 1
fi

for cmd in restic rclone; do
    if ! check_cmd "$cmd"; then
        error "Required command not found: $cmd"
        echo "Install: sudo dnf install -y $cmd"
        exit 1
    fi
done

if ! rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    error "rclone remote 'gdrive:' not found"
    echo "Run: rclone config"
    exit 1
fi

# --- Test repository access ---
info "Testing repository access..."
if ! restic -r "$RESTIC_REPOSITORY" snapshots 2>/dev/null > /dev/null; then
    error "Cannot access Restic repository at: $RESTIC_REPOSITORY"
    echo "Check your network connection and rclone configuration."
    exit 1
fi
info "Repository accessible"

# --- List snapshots (if requested) ---
if [ "$JUST_LIST" = true ]; then
    header "Available Snapshots"
    restic -r "$RESTIC_REPOSITORY" snapshots \
        --group-by "host,tags" \
        --format "  ${GREEN}%(short_id)${NC}  %(time)  %(host)  [%(tags)]" 2>/dev/null
    echo ""
    info "To restore: $0 --snapshot=<id>"
    info "Paths in snapshot: restic -r $RESTIC_REPOSITORY ls <id> | head -50"
    exit 0
fi

# --- Determine snapshot to restore ---
if [ "$RESTORE_SNAPSHOT" = "latest" ]; then
    SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --latest 1 --compact 2>/dev/null \
        | grep -v "^ID\|^──\|^$" | awk '{print $1}' || echo "")
    if [ -z "$SNAPSHOT_ID" ]; then
        error "No snapshots found in repository"
        exit 1
    fi
    info "Selected latest snapshot: $SNAPSHOT_ID"
else
    SNAPSHOT_ID="$RESTORE_SNAPSHOT"
    info "Selected snapshot: $SNAPSHOT_ID"
fi

# --- Preview ---
header "Restore Plan"

echo -e "  ${BOLD}Snapshot:${NC}     $SNAPSHOT_ID"
echo -e "  ${BOLD}Repository:${NC}   $RESTIC_REPOSITORY"
echo -e "  ${BOLD}Restore to:${NC}   / (system root equivalent)"
echo -e "  ${BOLD}Dry run:${NC}      $DRY_RUN"
echo ""

restic -r "$RESTIC_REPOSITORY" ls "$SNAPSHOT_ID" 2>/dev/null | head -30
echo "  ..."
echo ""

if [ "$DRY_RUN" = true ]; then
    info "Dry run mode - no changes made"
    info "To restore: $0 (without --dry-run)"
    exit 0
fi

# --- Confirmation ---
echo -e "${YELLOW}${BOLD}WARNING:${NC} This will restore files to their original locations."
echo -e "${YELLOW}Existing files may be overwritten.${NC}"
echo ""
read -rp "Continue with restore? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Restore cancelled"
    exit 0
fi

# ============================================================
# Full Restore
# ============================================================
header "Step 1: Restoring filesystem from snapshot"
echo "This may take a while depending on repository size..."

restic -r "$RESTIC_REPOSITORY" restore "$SNAPSHOT_ID" --target / 2>&1
info "Filesystem restore complete"

# ============================================================
header "Step 2: Restoring SSH keys"
if [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; then
    info "SSH keys already exist - skipping"
else
    # SSH keys should be restored by the restic restore above
    if [ -d "$HOME/.ssh" ]; then
        chmod 700 "$HOME/.ssh"
        find "$HOME/.ssh" -type f -name "id_*" -exec chmod 600 {} \; 2>/dev/null || true
        find "$HOME/.ssh" -type f -name "*.pub" -exec chmod 644 {} \; 2>/dev/null || true
        info "SSH permissions fixed"
    fi
fi

# ============================================================
header "Step 3: Restoring GPG keys"
if [ -d "$HOME/.gnupg" ]; then
    chmod 700 "$HOME/.gnupg"
    find "$HOME/.gnupg" -type f -exec chmod 600 {} \; 2>/dev/null || true
    info "GPG directory permissions fixed"
fi

# ============================================================
header "Step 4: Restoring PostgreSQL dumps"
PG_DUMPS=$(find "/home" -path "*/dumps/*/postgres.sql.gz" 2>/dev/null | head -5 || true)
if [ -n "$PG_DUMPS" ] && check_cmd pg_restore; then
    info "PostgreSQL dumps found in backup"
    echo "To restore databases manually:"
    echo "  gunzip -c <dump-file> | psql -U postgres"
else
    info "No PostgreSQL dumps found in restored files (or psql not available)"
fi

# ============================================================
header "Step 5: Restoring container definitions"
if [ -d "$HOME/.config/containers" ]; then
    info "Podman container configs restored"
fi
if [ -d "$HOME/.docker" ]; then
    info "Docker configs restored"
fi

# ============================================================
header "Restore Summary"

echo -e "  ${GREEN}${BOLD}✓ Restore Complete${NC}"
echo -e "  ${BOLD}Snapshot:${NC}     $SNAPSHOT_ID"
echo -e "  ${BOLD}Repository:${NC}   $RESTIC_REPOSITORY"
echo -e "  ${BOLD}Log file:${NC}     $LOG_FILE"
echo ""
echo -e "Next steps:"
echo -e "  1. Verify your SSH keys: ${BOLD}ssh -T git@github.com${NC}"
echo -e "  2. Re-import GPG keys:   ${BOLD}gpg --list-secret-keys${NC}"
echo -e "  3. Restore PostgreSQL:   ${BOLD}gunzip -c ~/path/to/dump.sql.gz | psql${NC}"
echo -e "  4. Rebuild projects:     ${BOLD}cd ~/Projects && ls${NC}"
echo -e "  5. Verify dotfiles:      ${BOLD}ls -la ~/.bashrc ~/.zshrc ~/.gitconfig${NC}"
echo ""
echo -e "Full recovery time target: ${BOLD}< 2 hours${NC}"
