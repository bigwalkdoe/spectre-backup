#!/bin/bash
# ============================================================
# spectre-backup - Snapshot Pruning
#
# Enforces retention policy:
#   Hourly:    last 24
#   Daily:     last 30
#   Weekly:    last 12
#   Monthly:   last 12
#   Yearly:    keep all (no limit specified)
#
# Usage:
#   spectre-backup-prune.sh           # Prune and notify
#   spectre-backup-prune.sh --dry-run # Preview only
#   spectre-backup-prune.sh --no-notify # Silent (for automated runs)
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

info()  { [ "${QUIET:-false}" = true ] || echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ [ "${QUIET:-false}" = true ] || echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

DRY_RUN=false
SEND_NOTIFY=true
QUIET=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-notify) SEND_NOTIFY=false ;;
        --quiet) QUIET=true ;;
        --role=*) SPECTRE_BACKUP_ROLE="${arg#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--no-notify] [--role=workstation|server]"
            echo ""
            echo "  --dry-run    Preview pruning without deleting"
            echo "  --no-notify  Suppress desktop notifications"
            echo "  --role=      Override auto-detected role (workstation|server)"
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

# Prune both local and offsite repositories. Local first (it holds every real
# snapshot). Each pass is time-boxed so an unreachable offsite remote cannot
# stall the whole prune.
PRUNE_TARGETS=()
PRUNE_TIMEOUT="${PRUNE_TIMEOUT:-900}"
[ -n "${RESTIC_REPOSITORY_LOCAL:-}" ] && PRUNE_TARGETS+=("$RESTIC_REPOSITORY_LOCAL")
[ -n "${RESTIC_REPOSITORY:-}" ] && PRUNE_TARGETS+=("$RESTIC_REPOSITORY")
if [ -n "${PRUNE_TARGETS_OVERRIDE:-}" ]; then
    read -ra PRUNE_TARGETS <<< "$PRUNE_TARGETS_OVERRIDE"
fi
[ "${#PRUNE_TARGETS[@]}" -eq 0 ] && PRUNE_TARGETS=("rclone:spectre-backup:")
export RESTIC_PASSWORD_COMMAND="cat $RESTIC_PASSWORD_FILE"

mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/cleanup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Pre-flight ---
if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    error "Password file not found: $RESTIC_PASSWORD_FILE"
    exit 1
fi

echo ""
PRUNE_FAILED=0
# One pass per configured repository. A repository that cannot be listed or
# pruned records the failure and the loop continues: an unreachable offsite
# remote must not prevent the local repository from being pruned.
for RESTIC_REPOSITORY in "${PRUNE_TARGETS[@]}"; do
    info "Repository: $RESTIC_REPOSITORY ($DISTRO_ID, role=$ROLE)"

    # Heal stale locks before taking the exclusive lock that `forget` needs.
    # A run interrupted mid-backup leaves a lock behind, and prune then fails
    # with "repository is already locked" until someone removes it manually.
    # Plain `unlock` only removes stale locks, so a running backup is safe.
    if timeout 120 restic -r "$RESTIC_REPOSITORY" unlock >/dev/null 2>&1; then
        info "Stale locks cleared (if any) for $RESTIC_REPOSITORY"
    fi

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

    snapshot_json=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>&1)
    snapshot_rc=$?
    if [ $snapshot_rc -ne 0 ]; then
        error "Could not list snapshots in $RESTIC_REPOSITORY (restic exit $snapshot_rc):"
        printf '%s\n' "$snapshot_json" | sed 's/^/     /'
        PRUNE_FAILED=1
    continue
    fi
    snapshot_count=$(printf '%s' "$snapshot_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "$snapshot_count" -eq 0 ]; then
        warn "No snapshots in $RESTIC_REPOSITORY - skipping it"
        continue
    fi
    printf '%s' "$snapshot_json" \
        | jq -r 'sort_by(.time) | reverse | .[] | "  \(.short_id)  \(.time)  \(.hostname)"'

    # --- Build forget command ---
    FORGET_ARGS=(forget)
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

    # --- Apply retention policy ---
    info "Applying retention policy..."

    set +e
    if command -v timeout >/dev/null 2>&1; then
        timeout "$PRUNE_TIMEOUT" restic "${FORGET_ARGS[@]}" 2>&1
    else
        restic "${FORGET_ARGS[@]}" 2>&1
    fi
    FORGET_EXIT=$?
    set -e

    if [ $FORGET_EXIT -ne 0 ]; then
        error "Restic forget command failed (exit $FORGET_EXIT)"
        PRUNE_FAILED=1
    continue
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
            PRUNE_FAILED=1
    continue
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
    restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null \
        | jq -r 'sort_by(.time) | reverse | .[] | "  \(.short_id)  \(.time)"' || true

    echo ""
    SNAPSHOTS_LEFT=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    # Capital "Total Size:" (restic's actual output) and raw-data mode: the old
    # lowercase pattern silently yielded "unknown", and restore-size mode walks
    # every snapshot's trees right after prune has invalidated the caches.
    REPO_SIZE=$(restic -r "$RESTIC_REPOSITORY" stats --mode raw-data 2>/dev/null | grep -oP 'Total Size:\s+\K\S.*' || echo "unknown")
    info "Snapshots remaining: $SNAPSHOTS_LEFT"
    info "Repository size:     $REPO_SIZE"
done

if [ "$PRUNE_FAILED" -ne 0 ]; then
    error "Pruning failed for at least one repository"
    exit 1
fi

info "Pruning complete."

# --- Notify ---
if [ "$SEND_NOTIFY" = true ] && [ "$DRY_RUN" = false ] && [ "${QUIET:-false}" != true ] && command -v notify-send &>/dev/null; then
    notify-send -u low "spectre-backup" "Pruning complete: $SNAPSHOTS_LEFT snapshots, $REPO_SIZE"
fi
