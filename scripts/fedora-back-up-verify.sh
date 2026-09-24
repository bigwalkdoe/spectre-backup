#!/bin/bash
# ============================================================
# fedora-back-up - Repository Verification
#
# Runs integrity checks on the Restic repository.
# Full verification (--full) reads all data and checks pack files.
# Quick verification (default) checks structure only.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-back-up"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "$(date '+%H:%M:%S') ${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "$(date '+%H:%M:%S') ${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "$(date '+%H:%M:%S') ${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

FULL_CHECK=false
for arg in "$@"; do
    case "$arg" in
        --full|--check-data) FULL_CHECK=true ;;
        --help|-h)
            echo "Usage: $0 [--full]"
            echo ""
            echo "  --full   Full verification (reads all data, checks pack files)"
            echo "  (default) Quick verification (structure only, no data read)"
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
LOG_FILE="$LOG_DIR/verify-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Pre-flight ---
header "fedora-back-up - Repository Verification"

if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    error "Restic password file not found: $RESTIC_PASSWORD_FILE"
    exit 1
fi

info "Repository: $RESTIC_REPOSITORY"

if [ "$FULL_CHECK" = true ]; then
    info "Mode: FULL verification (reading all data)"
    info "This will download and verify all pack files."
    echo ""
else
    info "Mode: Quick verification (structure only)"
    info "Use --full for a complete data integrity check."
    echo ""
fi

# --- Verify repository access ---
header "Testing repository access"

if ! restic -r "$RESTIC_REPOSITORY" snapshots 2>/dev/null > /dev/null; then
    error "Cannot access repository at: $RESTIC_REPOSITORY"
    exit 1
fi

SNAPSHOT_COUNT=$(restic -r "$RESTIC_REPOSITORY" snapshots --compact 2>/dev/null | grep -c "^[a-f0-9]\{8\}" || echo "0")
info "Repository accessible - $SNAPSHOT_COUNT snapshots found"

# --- Check statistics ---
header "Repository statistics"

restic -r "$RESTIC_REPOSITORY" stats 2>/dev/null || warn "Could not retrieve repository stats"

# --- Run integrity check ---
header "Running repository integrity check"

START_TS=$(date +%s)

if [ "$FULL_CHECK" = true ]; then
    set +e
    restic -r "$RESTIC_REPOSITORY" check --read-data 2>&1
    CHECK_EXIT=$?
    set -e
else
    set +e
    restic -r "$RESTIC_REPOSITORY" check 2>&1
    CHECK_EXIT=$?
    set -e
fi

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

# --- Report ---
header "Verification Report"

if [ $CHECK_EXIT -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ Integrity check passed${NC}"
    echo -e "  ${BOLD}Duration:${NC}     $DURATION seconds"
    echo -e "  ${BOLD}Snapshots:${NC}    $SNAPSHOT_COUNT"
    echo -e "  ${BOLD}Log file:${NC}     $LOG_FILE"
    echo ""
    info "Repository is healthy"
else
    echo -e "  ${RED}${BOLD}✗ Integrity check FAILED${NC}"
    echo -e "  ${BOLD}Duration:${NC}     $DURATION seconds"
    echo -e "  ${BOLD}Log file:${NC}     $LOG_FILE"
    echo ""
    error "Repository corruption detected!"
    error "Check the log file for details: $LOG_FILE"
    error "Consider restoring from a known-good snapshot."
fi

# --- Monthly check notification ---
if [ "$FULL_CHECK" = true ]; then
    echo ""
    info "Monthly full verification completed"
    if [ $CHECK_EXIT -eq 0 ]; then
        if command -v notify-send &>/dev/null; then
            notify-send -u normal "fedora-back-up" "Monthly verification passed ($SNAPSHOT_COUNT snapshots, ${DURATION}s)"
        fi
    fi
fi

exit $CHECK_EXIT
