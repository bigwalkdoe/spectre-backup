#!/bin/bash
# ============================================================
# fedora-back-up - Main Backup Engine
# Encrypted, versioned workstation backup via Restic + rclone
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Configuration ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-back-up"
if [ -f "$CONFIG_DIR/.env" ]; then
    set -a; source "$CONFIG_DIR/.env"; set +a
elif [ -f "$PROJECT_DIR/config/.env.example" ]; then
    set -a; source "$PROJECT_DIR/config/.env.example"; set +a
fi

LOG_DIR="${LOG_DIR:-$HOME/.local/state/fedora-back-up}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"
INCLUDE_FILE="${INCLUDE_FILE:-$CONFIG_DIR/include.conf}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/exclude.conf}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:gdrive:ModelinkBackups/workstation}"

NOTIFY_ENABLED="${NOTIFY_ENABLED:-true}"
NOTIFY_DESKTOP="${NOTIFY_DESKTOP:-true}"
PG_ENABLED="${PG_ENABLED:-true}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
CONTAINERS_ENABLED="${CONTAINERS_ENABLED:-true}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DUMPS_DIR="$LOG_DIR/dumps/$TIMESTAMP"
mkdir -p "$LOG_DIR" "$DUMPS_DIR"
LOG_FILE="$LOG_DIR/backup.log"
ERROR_LOG="$LOG_DIR/error.log"

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERROR_LOG" >&2)

RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
fi

info()  { echo -e "$(date '+%H:%M:%S') ${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "$(date '+%H:%M:%S') ${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "$(date '+%H:%M:%S') ${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"; }

notify() {
    local title="$1" msg="$2" urgency="${3:-normal}"
    [ "$NOTIFY_ENABLED" != "true" ] && return 0
    echo "$title: $msg"
    if [ "$NOTIFY_DESKTOP" = "true" ] && command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$msg" 2>/dev/null || true
    fi
}

cleanup() {
    rm -rf "$DUMPS_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Pre-flight checks
# ============================================================
header "Pre-flight checks"

if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    error "Restic password file not found: $RESTIC_PASSWORD_FILE"
    notify "Backup Failed" "Restic password file missing" "critical"
    exit 1
fi

if [ ! -d "$CONFIG_DIR" ]; then
    error "Config directory not found: $CONFIG_DIR"
    notify "Backup Failed" "Config directory missing" "critical"
    exit 1
fi

for cmd in restic rclone; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
        notify "Backup Failed" "Missing dependency: $cmd" "critical"
        exit 1
    fi
done

BACKEND="${RESTIC_REPOSITORY%%:*}"
if [ "$BACKEND" = "rclone" ]; then
    REMOTE="${RESTIC_REPOSITORY#*:}"
    REMOTE_NAME="${REMOTE%%:*}"
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        error "rclone remote '$REMOTE_NAME:' not configured"
        notify "Backup Failed" "rclone remote $REMOTE_NAME not found" "critical"
        exit 1
    fi
fi

export RESTIC_PASSWORD_COMMAND="cat $RESTIC_PASSWORD_FILE"
START_TS=$(date +%s)
START_BYTES=$(restic -r "$RESTIC_REPOSITORY" stats 2>/dev/null | grep -oP 'Total size: \K[0-9]+' || echo "0")

# ============================================================
# Phase 1: PostgreSQL dump
# ============================================================
if [ "$PG_ENABLED" = "true" ] && command -v pg_dumpall &>/dev/null; then
    header "Phase 1: PostgreSQL dump"

    PG_DUMP_FILE="$DUMPS_DIR/postgres.sql.gz"
    PG_USER="${PG_USER:-$USER}"

    if command -v pg_isready &>/dev/null && pg_isready -h "$PG_HOST" -p "$PG_PORT" &>/dev/null; then
        info "Dumping all PostgreSQL databases..."
        PGPASSWORD="${PG_PASSWORD:-}" pg_dumpall \
            -h "$PG_HOST" -p "$PG_PORT" \
            -U "$PG_USER" \
            --clean --if-exists \
            2>/dev/null | gzip > "$PG_DUMP_FILE"

        if [ -f "$PG_DUMP_FILE" ] && [ -s "$PG_DUMP_FILE" ]; then
            SIZE=$(du -h "$PG_DUMP_FILE" | cut -f1)
            info "PostgreSQL dump complete: $SIZE"
        else
            warn "PostgreSQL dump produced empty output (no databases?)"
            rm -f "$PG_DUMP_FILE"
        fi
    else
        warn "PostgreSQL not running or not accessible - skipping database dump"
    fi
else
    info "PostgreSQL backup disabled or pg_dumpall not found - skipping"
fi

# ============================================================
# Phase 2: Container configuration backup
# ============================================================
if [ "$CONTAINERS_ENABLED" = "true" ]; then
    header "Phase 2: Container configuration backup"

    CONTAINER_DIR="$DUMPS_DIR/containers"
    mkdir -p "$CONTAINER_DIR"

    # Podman quadlets
    if [ -d "$HOME/.config/containers/systemd" ]; then
        cp -r "$HOME/.config/containers" "$CONTAINER_DIR/podman/"
        info "Backed up podman configs"
    fi

    # Docker compose files (common locations)
    for dir in "$HOME" "$HOME/Projects" "$HOME/Documents"; do
        if [ -d "$dir" ]; then
            find "$dir" -maxdepth 5 -name "docker-compose*.yml" -o -name "compose*.yml" -o -name "Dockerfile" 2>/dev/null \
                | while IFS= read -r f; do
                    rel="${f#$dir/}"
                    mkdir -p "$CONTAINER_DIR/compose/$(dirname "$rel")"
                    cp "$f" "$CONTAINER_DIR/compose/$rel" 2>/dev/null || true
                done
        fi
    done
    info "Collected container compose files"

    # Docker config
    if [ -f "$HOME/.docker/config.json" ]; then
        mkdir -p "$CONTAINER_DIR/docker"
        cp "$HOME/.docker/config.json" "$CONTAINER_DIR/docker/config.json" 2>/dev/null || true
    fi

    # Containerfile / Dockerfile in home
    find "$HOME" -maxdepth 3 -name "Containerfile" -o -name "Dockerfile" 2>/dev/null \
        | head -20 | while IFS= read -r f; do
            rel="${f#$HOME/}"
            mkdir -p "$CONTAINER_DIR/containerfiles/$(dirname "$rel")"
            cp "$f" "$CONTAINER_DIR/containerfiles/$rel" 2>/dev/null || true
        done

    info "Container configuration backup complete"
fi

# ============================================================
# Phase 3: Restic backup
# ============================================================
header "Phase 3: Restic filesystem backup"

BACKUP_TARGETS=()
if [ -f "$INCLUDE_FILE" ] && [ -s "$INCLUDE_FILE" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"  # strip comments
        line="${line//\~/$HOME}"  # expand ~
        line="${line%/}"  # remove trailing slash
        [ -z "$line" ] && continue
        if [ -e "$line" ]; then
            BACKUP_TARGETS+=("$line")
        else
            warn "Include path not found, skipping: $line"
        fi
    done < "$INCLUDE_FILE"
else
    error "Include file not found or empty: $INCLUDE_FILE"
    notify "Backup Failed" "Include file missing" "critical"
    exit 1
fi

# Add the dumps directory to the backup
if [ -d "$DUMPS_DIR" ] && [ "$(ls -A "$DUMPS_DIR" 2>/dev/null)" ]; then
    BACKUP_TARGETS+=("$DUMPS_DIR")
    info "Including pre-backup dumps in snapshot"
fi

RESTIC_COMMON_ARGS=()
RESTIC_COMMON_ARGS+=(-o "rclone.program=rclone --tpslimit 2 --drive-chunk-size 64M")
RESTIC_COMMON_ARGS+=(--verbose)
RESTIC_COMMON_ARGS+=(--tag "fedora-back-up")
RESTIC_COMMON_ARGS+=(--tag "workstation")
RESTIC_COMMON_ARGS+=(--host "$(hostname)")

if [ -f "$EXCLUDE_FILE" ] && [ -s "$EXCLUDE_FILE" ]; then
    RESTIC_COMMON_ARGS+=(--exclude-file "$EXCLUDE_FILE")
fi

RESTIC_COMMON_ARGS+=(--exclude "$DUMPS_DIR") # exclude from general backup pattern scanning

info "Starting backup of ${#BACKUP_TARGETS[@]} target paths..."

REPO_FAILED=0
run_repo_backup() {
    local repo="$1" label="$2"
    info "[$label] Starting backup to $repo"
    set +e
    local exit_code=0
    for attempt in 1 2 3; do
        info "[$label] Backup attempt $attempt/3"
        restic -r "$repo" "${RESTIC_COMMON_ARGS[@]}" backup "${BACKUP_TARGETS[@]}" 2>&1
        exit_code=$?
        [ $exit_code -eq 0 ] && break
        warn "[$label] Attempt $attempt failed (exit $exit_code); retrying in $((attempt * 300))s..."
        sleep $((attempt * 300))
    done
    set -e
    if [ $exit_code -ne 0 ]; then
        REPO_FAILED=1
        error "[$label] Restic backup failed after 3 attempts"
    fi
}

if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
    run_repo_backup "$RESTIC_REPOSITORY_LOCAL" "local"
else
    warn "No local repository configured (RESTIC_REPOSITORY_LOCAL) - skipping local backup"
fi
run_repo_backup "$RESTIC_REPOSITORY" "drive"

if [ $REPO_FAILED -ne 0 ]; then
    notify "Backup Failed" "Restic backup error" "critical"
    exit 1
fi

info "Filesystem backup complete"

# ============================================================
# Phase 4: Integrity check
# ============================================================
header "Phase 4: Repository integrity check"

set +e
restic -r "$RESTIC_REPOSITORY" -o "rclone.program=rclone --tpslimit 2 --drive-chunk-size 64M" check --no-lock 2>&1
CHECK_EXIT=$?
set -e

if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
    set +e
    restic -r "$RESTIC_REPOSITORY_LOCAL" check --no-lock 2>&1
    LOCAL_CHECK_EXIT=$?
    set -e
    if [ $LOCAL_CHECK_EXIT -ne 0 ]; then
        error "Local repository integrity check FAILED"
        notify "Backup Warning" "Local repository integrity check failed" "critical"
    else
        info "Local repository integrity check passed"
    fi
fi

if [ $CHECK_EXIT -ne 0 ]; then
    error "Repository integrity check FAILED"
    notify "Backup Warning" "Repository integrity check failed - run verify.sh" "critical"
else
    info "Repository integrity check passed"
fi

# ============================================================
# Summary
# ============================================================
header "Backup Summary"

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
DURATION_STR=""
if [ $DURATION -ge 3600 ]; then
    DURATION_STR="$((DURATION / 3600))h $(((DURATION % 3600) / 60))m $((DURATION % 60))s"
elif [ $DURATION -ge 60 ]; then
    DURATION_STR="$((DURATION / 60))m $((DURATION % 60))s"
else
    DURATION_STR="${DURATION}s"
fi

SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --latest 1 --compact 2>/dev/null | grep -v "^ID\|^──\|^$" | awk '{print $1}' || echo "unknown")
REPO_SIZE=$(restic -r "$RESTIC_REPOSITORY" stats 2>/dev/null | grep -oP 'Total size: \K.*' || echo "unknown")

echo ""
echo -e "  ${BOLD}Status:${NC}        ${GREEN}✓ Backup Successful${NC}"
echo -e "  ${BOLD}Duration:${NC}      $DURATION_STR"
echo -e "  ${BOLD}Repository:${NC}    $RESTIC_REPOSITORY"
echo -e "  ${BOLD}Repository Size:${NC} $REPO_SIZE"
echo -e "  ${BOLD}Snapshot ID:${NC}   ${SNAPSHOT_ID}"
echo -e "  ${BOLD}Log file:${NC}      $LOG_FILE"
echo ""

notify "✓ Backup Successful" "Duration: $DURATION_STR | Snapshot: $SNAPSHOT_ID" "normal"

# ============================================================
# Phase 5: Prune (cleanup old snapshots)
# ============================================================
header "Phase 5: Pruning old snapshots"

if [ -f "$SCRIPT_DIR/fedora-back-up-prune.sh" ]; then
    info "Running prune script..."
    bash "$SCRIPT_DIR/fedora-back-up-prune.sh" --no-notify || warn "Prune completed with warnings"
elif [ -f "$BIN_DIR/fedora-back-up-prune.sh" ]; then
    info "Running prune script..."
    bash "$BIN_DIR/fedora-back-up-prune.sh" --no-notify || warn "Prune completed with warnings"
else
    warn "Prune script not found - skipping automatic pruning"
fi

exit 0
