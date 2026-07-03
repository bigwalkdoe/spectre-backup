#!/bin/bash
# ============================================================
# Modelink Backup - Snapshot Pruning
#
# Enforces retention policy:
#   Hourly:    last 24
#   Daily:     last 30
#   Weekly:    last 12
#   Monthly:   last 12
#   Yearly:    keep all (no limit specified)
#
# Usage:
#   modelink-prune.sh           # Prune and notify
#   modelink-prune.sh --dry-run # Preview only
#   modelink-prune.sh --no-notify # Silent (for automated runs)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/modelink-backup"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/modelink-backup"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

DRY_RUN=false
SEND_NOTIFY=true

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-notify) SEND_NOTIFY=false ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--no-notify]"
            echo ""
            echo "  --dry-run    Preview pruning without deleting"
            echo "  --no-notify  Suppress desktop notifications"
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

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cleanup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Pre-flight ---
if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    error "Password file not found: $RESTIC_PASSWORD_FILE"
    exit 1
fi

info "Repository: $RESTIC_REPOSITORY"

# --- Retention policy ---
header "Retention Policy"

echo -e "  Hourly:    keep last ${BOLD}24${NC}"
echo -e "  Daily:     keep last ${BOLD}30${NC}"
echo -e "  Weekly:    keep last ${BOLD}12${NC}"
echo -e "  Monthly:   keep last ${BOLD}12${NC}"
echo -e "  Yearly:    ${BOLD}keep all${NC}"
echo ""

# --- List current snapshots ---
header "Current snapshots before pruning"

restic -r "$RESTIC_REPOSITORY" snapshots \
    --group-by "host,tags" \
    --format "  ${GREEN}%(short_id)${NC}  %(time)  %(host)  [%(tags)]" 2>/dev/null || {
    warn "No snapshots found - nothing to prune"
    exit 0
}

# --- Build forget command ---
FORGET_ARGS=()
FORGET_ARGS+=(-r "$RESTIC_REPOSITORY")
FORGET_ARGS+=(--keep-hourly 24)
FORGET_ARGS+=(--keep-daily 30)
FORGET_ARGS+=(--keep-weekly 12)
FORGET_ARGS+=(--keep-monthly 12)
# No --keep-yearly means keep all yearly snapshots
FORGET_ARGS+=(--keep-last 1)  # always keep most recent

if [ "$DRY_RUN" = true ]; then
    FORGET_ARGS+=(--dry-run)
    info "DRY RUN - no changes will be made"
    echo ""
fi

# --- Find and keep dumps-related snapshots (tagged) ---
# We apply forget to all snapshots; restic's policy is per-group
info "Applying retention policy..."

set +e
restic "${FORGET_ARGS[@]}" 2>&1
FORGET_EXIT=$?
set -e

if [ $FORGET_EXIT -ne 0 ]; then
    error "Restic forget command failed (exit $FORGET_EXIT)"
    exit 1
fi

# --- Prune (remove unreferenced data) ---
if [ "$DRY_RUN" = false ]; then
    header "Removing unreferenced data (prune)"

    info "Running restic prune (this may take a while)..."
    set +e
    restic -r "$RESTIC_REPOSITORY" prune 2>&1
    PRUNE_EXIT=$?
    set -e

    if [ $PRUNE_EXIT -ne 0 ]; then
        error "Restic prune failed (exit $PRUNE_EXIT)"
        exit 1
    fi

    info "Prune complete - unreferenced data removed"
fi

# --- Summary ---
header "Pruning Summary"

if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}${BOLD}DRY RUN - no changes made${NC}"
    echo -e "  Run without --dry-run to apply."
else
    echo -e "  ${GREEN}${BOLD}✓ Pruning complete${NC}"
fi

echo -e "  ${BOLD}Log file:${NC}    $LOG_FILE"
echo ""

# --- Post-prune stats ---
info "Repository state after pruning:"
restic -r "$RESTIC_REPOSITORY" snapshots \
    --group-by "host,tags" \
    --format "  %(short_id)  %(time)  [%(tags)]" 2>/dev/null

echo ""
SNAPSHOTS_LEFT=$(restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null | grep -c "^[a-f0-9]\{8\}" || echo "0")
REPO_SIZE=$(restic -r "$RESTIC_REPOSITORY" stats 2>/dev/null | grep -oP 'Total size: \K.*' || echo "unknown")
info "Snapshots remaining: $SNAPSHOTS_LEFT"
info "Repository size:     $REPO_SIZE"

# --- Notify ---
if [ "$SEND_NOTIFY" = true ] && [ "$DRY_RUN" = false ] && command -v notify-send &>/dev/null; then
    notify-send -u low "Modelink Backup" "Pruning complete: $SNAPSHOTS_LEFT snapshots, $REPO_SIZE"
fi
