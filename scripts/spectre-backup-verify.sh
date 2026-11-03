#!/bin/bash
# ============================================================
# spectre-backup - Repository Verification
#
# Runs integrity checks on the Restic repository.
# Full verification (--full) reads all data and checks pack files.
# Quick verification (default) checks structure only.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Source shared library ---
if [ -f "$SCRIPT_DIR/spectre-backup-common.sh" ]; then
    . "$SCRIPT_DIR/spectre-backup-common.sh"
elif [ -f "$PROJECT_DIR/lib/spectre-backup-common.sh" ]; then
    . "$PROJECT_DIR/lib/spectre-backup-common.sh"
else
    echo "ERROR: Cannot find spectre-backup-common.sh library" >&2
    exit 1
fi

detect_distro
ROLE="${SPECTRE_BACKUP_ROLE:-$(detect_role)}"
resolve_dirs

# --- Config directory ---
if [ "$ROLE" = "server" ]; then
    CONFIG_DIR="/etc/spectre-backup"
else
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spectre-backup"
fi

RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { [ "${QUIET:-false}" = true ] || echo -e "$(date '+%H:%M:%S') ${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "$(date '+%H:%M:%S') ${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "$(date '+%H:%M:%S') ${RED}[ERROR]${NC} $*" >&2; }
header(){ [ "${QUIET:-false}" = true ] || echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

FULL_CHECK=false
QUIET=false
DEBUG=false
JSON_OUTPUT=false
for arg in "$@"; do
    case "$arg" in
        --full|--check-data) FULL_CHECK=true ;;
        --role=*) SPECTRE_BACKUP_ROLE="${arg#*=}" ;;
        --quiet) QUIET=true ;;
        --password-file=*) RESTIC_PASSWORD_FILE="${arg#*=}" ;;
        --debug|--trace) DEBUG=true ;;
        --json) JSON_OUTPUT=true ;;
        --env) PRINT_ENV=true ;;
        --help|-h)
            echo "Usage: $0 [--full] [--role=workstation|server]"
            echo ""
            echo "  --full   Full verification (reads all data, checks pack files)"
            echo "  --json   Machine-readable JSON summary"
            echo "  --env    Print resolved configuration and exit"
            echo "  (default) Quick verification (structure only, no data read)"
            echo "  --role=  Override auto-detected role (workstation|server)"
            exit 0
            ;;
        --version)
            if git -C "$PROJECT_DIR" describe --tags --always >/dev/null 2>&1; then
                echo "spectre-backup $(git -C "$PROJECT_DIR" describe --tags --always 2>/dev/null)"
            else
                echo "spectre-backup (dev)"
            fi
            exit 0
            ;;
    esac
done

# --- Load config ---
if [ -f "$CONFIG_DIR/.env" ]; then
    set -a; source "$CONFIG_DIR/.env"; set +a
fi
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:spectre-backup:}"
export RESTIC_PASSWORD_COMMAND="cat $RESTIC_PASSWORD_FILE"

mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/verify-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Pre-flight ---
if [ "${DEBUG:-false}" = true ]; then set -x; fi

header "spectre-backup - Repository Verification ($DISTRO_ID, role=$ROLE)"

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

SNAPSHOT_COUNT=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
info "Repository accessible - $SNAPSHOT_COUNT snapshots found"

# --- Check statistics ---
header "Repository statistics"

# raw-data mode reports the on-disk size from the index alone; the default
# restore-size mode walks every snapshot's file trees (minutes on big repos).
restic -r "$RESTIC_REPOSITORY" stats --mode raw-data 2>/dev/null || warn "Could not retrieve repository stats"

# --- Repositories to verify (offsite + local when configured) ---
VERIFY_REPOS=()
[ -n "${RESTIC_REPOSITORY:-}" ] && VERIFY_REPOS+=("$RESTIC_REPOSITORY")
if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ] && [ "${RESTIC_REPOSITORY_LOCAL}" != "${RESTIC_REPOSITORY}" ]; then
    VERIFY_REPOS+=("$RESTIC_REPOSITORY_LOCAL")
fi

OVERALL_EXIT=0

for VERIFY_REPO in "${VERIFY_REPOS[@]}"; do
    if [ "$PRINT_ENV" = true ]; then
    echo "DISTRO_ID=$DISTRO_ID"
    echo "DISTRO_VERSION_ID=$DISTRO_VERSION_ID"
    echo "ROLE=$ROLE"
    echo "CONFIG_DIR=$CONFIG_DIR"
    echo "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
    echo "RESTIC_REPOSITORY_LOCAL=${RESTIC_REPOSITORY_LOCAL:-}"
    echo "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE"
    exit 0
fi

# --- Run integrity check ---
    header "Running repository integrity check: $VERIFY_REPO"

    START_TS=$(date +%s)

    if [ "$FULL_CHECK" = true ]; then
        set +e
        restic -r "$VERIFY_REPO" check --read-data 2>&1
        CHECK_EXIT=$?
        set -e
    else
        set +e
        restic -r "$VERIFY_REPO" check 2>&1
        CHECK_EXIT=$?
        set -e
    fi

    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))

    REPO_SNAPSHOTS=$(restic -r "$VERIFY_REPO" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    # --- Report ---
    header "Verification Report: $VERIFY_REPO"

    if [ $CHECK_EXIT -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}✓ Integrity check passed${NC}"
        echo -e "  ${BOLD}Distro:${NC}     $DISTRO_ID $DISTRO_VERSION_ID"
        echo -e "  ${BOLD}Role:${NC}       $ROLE"
        echo -e "  ${BOLD}Duration:${NC}   $DURATION seconds"
        echo -e "  ${BOLD}Snapshots:${NC}  $REPO_SNAPSHOTS"
        echo -e "  ${BOLD}Log file:${NC}   $LOG_FILE"
        echo ""
        info "Repository is healthy: $VERIFY_REPO"
    else
        echo -e "  ${RED}${BOLD}✗ Integrity check FAILED${NC}"
        echo -e "  ${BOLD}Duration:${NC}   $DURATION seconds"
        echo -e "  ${BOLD}Log file:${NC}   $LOG_FILE"
        echo ""
        error "Repository corruption detected: $VERIFY_REPO"
        error "Check the log file for details: $LOG_FILE"
        error "Consider restoring from a known-good snapshot."
        OVERALL_EXIT=1
    fi
done

# --- Monthly check notification ---
if [ "$FULL_CHECK" = true ]; then
    echo ""
    info "Monthly full verification completed"
    if [ $OVERALL_EXIT -eq 0 ]; then
        if [ "${QUIET:-false}" != true ] && command -v notify-send &>/dev/null; then
            notify-send -u normal "spectre-backup" "Monthly verification passed (${DURATION}s)"
        fi
    fi
fi

if [ "$JSON_OUTPUT" = true ]; then
    cat <<JSON
{"status": "$([ $OVERALL_EXIT -eq 0 ] && echo ok || echo failed)", "exit_code": $OVERALL_EXIT, "snapshots": ${REPO_SNAPSHOTS:-0}, "full": $FULL_CHECK}
JSON
fi

exit $OVERALL_EXIT
