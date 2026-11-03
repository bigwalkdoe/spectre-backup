#!/bin/bash
# ============================================================
# spectre-backup - Main Backup Engine
# Encrypted, versioned backup via Restic + rclone.
# Supports Fedora/Ubuntu, workstation/server roles.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Source shared library ---
# Look alongside the script first (installed location), then project dir (dev).
if [ -f "$SCRIPT_DIR/spectre-backup-common.sh" ]; then
    . "$SCRIPT_DIR/spectre-backup-common.sh"
elif [ -f "$PROJECT_DIR/lib/spectre-backup-common.sh" ]; then
    . "$PROJECT_DIR/lib/spectre-backup-common.sh"
else
    echo "ERROR: Cannot find spectre-backup-common.sh library" >&2
    exit 1
fi

# --- Detect distro and role ---
detect_distro
ROLE="${SPECTRE_BACKUP_ROLE:-$(detect_role)}"
resolve_dirs

# --- Config directory (system-wide for servers, user for workstations) ---
if [ "$ROLE" = "server" ]; then
    CONFIG_DIR="/etc/spectre-backup"
else
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spectre-backup"
fi
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup"

# --- Load environment ---
load_env || true

# --- Defaults (overridable via .env) ---
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_DIR/password}"
INCLUDE_FILE="${INCLUDE_FILE:-$CONFIG_DIR/include.conf}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/exclude.conf}"
INCLUDE_FILE_REMOTE="${INCLUDE_FILE_REMOTE:-$CONFIG_DIR/include-remote.conf}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:spectre-backup:}"
NOTIFY_ENABLED="${NOTIFY_ENABLED:-true}"
NOTIFY_DESKTOP="${NOTIFY_DESKTOP:-true}"
PG_ENABLED="${PG_ENABLED:-true}"
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
CONTAINERS_ENABLED="${CONTAINERS_ENABLED:-true}"

# Desktop notifications only make sense on workstations
if [ "$ROLE" = "server" ]; then
    NOTIFY_DESKTOP="false"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DUMPS_DIR="$STATE_DIR/dumps/$TIMESTAMP"
mkdir -p "$STATE_DIR" "$DUMPS_DIR"
LOG_FILE="$STATE_DIR/backup.log"
ERROR_LOG="$STATE_DIR/error.log"

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERROR_LOG" >&2)

# Colours
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

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    rm -rf "$DUMPS_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Health check
# ============================================================
health_check() {
    local out_json=0
    local rc_ok=0 rc_deg=1 rc_fail=2
    local overall=$rc_ok
    for arg in "$@"; do
        case "$arg" in
            --json) out_json=1 ;;
        esac
    done

    local now
    now=$(date -u +%s)
    local local_newest_ts="" local_newest_iso=""
    local off_newest_ts="" off_newest_iso=""
    local local_count=0 off_count=0
    local local_age_h=999999 off_age_h=999999
    local local_free_g=0
    local df_free_kb=0

    # Local repository
    if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ] && [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
        local_newest_iso=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY_LOCAL" snapshots --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || true)
        local_count=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY_LOCAL" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    fi
    if [ -n "$local_newest_iso" ]; then
        local_newest_ts=$(date -u -d "$local_newest_iso" +%s 2>/dev/null || date -u +%s)
        local_age_h=$(( (now - local_newest_ts) / 3600 ))
    fi

    # Offsite repository
    if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
        off_newest_iso=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || true)
        off_count=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    fi
    if [ -n "$off_newest_iso" ]; then
        off_newest_ts=$(date -u -d "$off_newest_iso" +%s 2>/dev/null || date -u +%s)
        off_age_h=$(( (now - off_newest_ts) / 3600 ))
    fi

    # Disk free for local repo root
    if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
        local_repo_root=$(dirname "$RESTIC_REPOSITORY_LOCAL") || true
        [ -z "$local_repo_root" ] && local_repo_root="/backups"
        df_free_kb=$(df -P "$local_repo_root" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$df_free_kb" ] && [[ "$df_free_kb" =~ ^[0-9]+$ ]]; then
            local_free_g=$(( df_free_kb / 1024 / 1024 ))
        fi
    fi

    # Quota for offsite (rclone)
    local used_pct=""
    if command -v rclone >/dev/null 2>&1; then
        REMOTE_NAME="${RESTIC_REPOSITORY#*:}"
        REMOTE_NAME="${REMOTE_NAME%%:*}"
        used_pct=$(timeout 60 rclone about "${REMOTE_NAME}:" 2>/dev/null | grep -oP 'Used:.*?([0-9.]+)%' | grep -oP '([0-9.]+)%' | tr -d '%' | head -1 || true)
    fi

    local local_status="ok" off_status="ok" disk_status="ok" quota_status="ok" locks_status="ok"

    # SLOs: local <=26h ok (daily timer + randomised delay), >26h deg, >48h fail
    if [ $local_age_h -gt 48 ]; then local_status="fail"; overall=$rc_fail
    elif [ $local_age_h -gt 26 ]; then local_status="degraded"; [ $overall -eq $rc_ok ] && overall=$rc_deg
    fi
    # offsite <24h ok, >36h deg, >72h fail
    if [ $off_age_h -gt 72 ]; then off_status="fail"; overall=$rc_fail
    elif [ $off_age_h -gt 36 ]; then off_status="degraded"; [ $overall -eq $rc_ok ] && overall=$rc_deg
    fi
    # disk
    if [ $local_free_g -lt 15 ]; then disk_status="fail"; overall=$rc_fail
    elif [ $local_free_g -lt 25 ]; then disk_status="degraded"; [ $overall -eq $rc_ok ] && overall=$rc_deg
    fi
    # quota
    if [ -n "$used_pct" ] && [[ "$used_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        local up=${used_pct%.*}
        if [ "$up" -gt 95 ] 2>/dev/null; then quota_status="fail"; overall=$rc_fail
        elif [ "$up" -gt 85 ] 2>/dev/null; then quota_status="degraded"; [ $overall -eq $rc_ok ] && overall=$rc_deg
        fi
    fi

    # One status word for both output formats (0=ok, 1=degraded, 2=failed)
    local status_word status_label
    case $overall in
        0) status_word="ok";       status_label="OK" ;;
        1) status_word="degraded"; status_label="DEGRADED" ;;
        *) status_word="failed";   status_label="FAILED" ;;
    esac

    if [ $out_json -eq 1 ]; then
        cat <<JSON
{
  "status": "$status_word",
  "exit_code": $overall,
  "distro": "$DISTRO_ID",
  "role": "$ROLE",
  "local": {"count": $local_count, "newest_iso": "$local_newest_iso", "age_hours": $local_age_h, "status": "$local_status"},
  "offsite": {"count": $off_count, "newest_iso": "$off_newest_iso", "age_hours": $off_age_h, "status": "$off_status"},
  "disk_free_g": $local_free_g, "disk_status": "$disk_status",
  "quota_used_pct": "${used_pct:-null}", "quota_status": "$quota_status",
  "locks_status": "$locks_status"
}
JSON
        return $overall
    else
        echo "health: $status_label"
        echo "  distro:  $DISTRO_ID $DISTRO_VERSION_ID"
        echo "  role:    $ROLE"
        echo "  local:   count=$local_count age_h=$local_age_h status=$local_status (newest=$local_newest_iso)"
        echo "  offsite: count=$off_count age_h=$off_age_h status=$off_status (newest=$off_newest_iso)"
        echo "  disk:    free_g=$local_free_g status=$disk_status"
        echo "  quota:   used_pct=${used_pct:-n/a} status=$quota_status"
        return $overall
    fi
}

# Auto-heal stale restic locks (resilience).
#
# A run that is interrupted (machine sleeps or is shut down mid-backup, or a
# manual run is killed) leaves a lock behind. restic's own stale-lock handling
# did not clear them in practice: the timer run of 18 Oct 2026 found locks from
# 3 Oct and 16 Oct still present, and every prune since had failed with
# "repository is already locked". Plain `unlock` (without --remove-all) only
# removes locks that are already stale, so a backup that is genuinely running
# is not disturbed.
heal_lock() {
    local repo="$1" label="$2"
    if [ -n "${repo:-}" ]; then
        if timeout 120 restic -r "$repo" unlock >/dev/null 2>&1; then
            echo "locks-healed (stale only): $label" >> "$STATE_DIR/backup.log"
        fi
    fi
}

# ============================================================
# Health dispatch
# ============================================================
for arg in "$@"; do
    case "$arg" in
        --health|health)
            health_check "$@"
            exit $?
            ;;
    esac
done

header "Pre-flight checks ($DISTRO_ID $DISTRO_VERSION_ID, role=$ROLE)"

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

# --- Offsite remote availability ---
# A broken remote degrades gracefully: the local backup still runs.
REMOTE_AVAILABLE=1
BACKEND="${RESTIC_REPOSITORY%%:*}"
if [ "$BACKEND" = "rclone" ]; then
    REMOTE="${RESTIC_REPOSITORY#*:}"
    REMOTE_NAME="${REMOTE%%:*}"
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        error "rclone remote '$REMOTE_NAME:' is not defined -- offsite leg will be SKIPPED"
        warn "The local repository will still be backed up."
        warn "Create the remote with: rclone config   (n) new remote -> $REMOTE_NAME"
        notify "Backup Degraded" "rclone remote $REMOTE_NAME not defined; local backup still running" "warning"
        REMOTE_AVAILABLE=0
    elif ! timeout 60 rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        error "rclone remote '$REMOTE_NAME:' is defined but not usable -- offsite leg will be SKIPPED"
        warn "Most often an expired or missing OAuth token. Re-authorise with:"
        warn "    rclone config reconnect ${REMOTE_NAME}:"
        notify "Backup Degraded" "rclone remote $REMOTE_NAME needs re-authorising; local backup still running" "warning"
        REMOTE_AVAILABLE=0
    fi
fi

export RESTIC_PASSWORD_COMMAND="cat $RESTIC_PASSWORD_FILE"

# --- Heal stale locks before touching either repository ---
# Must run before the first restic command that takes a lock; otherwise an
# interrupted previous run blocks this one (and the prune at the end of it).
if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
    heal_lock "$RESTIC_REPOSITORY_LOCAL" "local"
fi
if [ "$REMOTE_AVAILABLE" -eq 1 ]; then
    heal_lock "$RESTIC_REPOSITORY" "offsite"
fi

START_TS=$(date +%s)

# ============================================================
# Phase 1: PostgreSQL dump
# ============================================================
if [ "$PG_ENABLED" = "true" ] && command -v pg_dumpall &>/dev/null; then
    header "Phase 1: PostgreSQL dump"

    PG_DUMP_FILE="$DUMPS_DIR/postgres.sql.gz"
    PG_USER="${PG_USER:-$(whoami)}"

    if command -v pg_isready &>/dev/null && pg_isready -h "$PG_HOST" -p "$PG_PORT" &>/dev/null; then
        info "Dumping all PostgreSQL databases..."
        set +e
        PGPASSWORD="${PG_PASSWORD:-}" pg_dumpall \
            -h "$PG_HOST" -p "$PG_PORT" \
            -U "$PG_USER" \
            --clean --if-exists 2>/dev/null | gzip > "$PG_DUMP_FILE"
        rc=${PIPESTATUS[0]:-${PIPESTATUS[1]:-1}}
        set -e
        if [ -f "$PG_DUMP_FILE" ] && [ -s "$PG_DUMP_FILE" ]; then
            SIZE=$(du -h "$PG_DUMP_FILE" | cut -f1)
            info "PostgreSQL dump complete: $SIZE"
        elif [ "$rc" -ne 0 ]; then
            warn "PostgreSQL dump failed (exit $rc) — continuing without DB dump"
            rm -f "$PG_DUMP_FILE"
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

    # Detect container runtime
    CONTAINER_RUNTIME=""
    if command -v podman &>/dev/null; then CONTAINER_RUNTIME="podman"; fi
    if command -v docker &>/dev/null; then CONTAINER_RUNTIME="docker"; fi

    if [ "$CONTAINER_RUNTIME" = "podman" ]; then
        # Podman quadlets
        if [ -d "$HOME/.config/containers/systemd" ]; then
            cp -r "$HOME/.config/containers" "$CONTAINER_DIR/podman/"
            info "Backed up podman configs"
        fi
        if [ -d "/etc/containers" ]; then
            mkdir -p "$CONTAINER_DIR/podman-system"
            cp -r /etc/containers "$CONTAINER_DIR/podman-system/" 2>/dev/null || true
            info "Backed up system podman configs"
        fi
    fi

    if [ "$CONTAINER_RUNTIME" = "docker" ]; then
        # Docker compose files (common locations)
        for dir in "$HOME" "$HOME/Projects" "$HOME/Documents" "/opt" "/var/www"; do
            if [ -d "$dir" ]; then
                find "$dir" -maxdepth 5 \( -name "docker-compose*.yml" -o -name "compose*.yml" -o -name "Dockerfile" \) 2>/dev/null \
                    | while IFS= read -r f; do
                        rel="${f#"$dir"/}"
                        mkdir -p "$CONTAINER_DIR/compose/$(dirname "$rel")"
                        cp "$f" "$CONTAINER_DIR/compose/$rel" 2>/dev/null || true
                    done || true
            fi
        done
        info "Collected docker compose files"

        # Docker config
        if [ -f "$HOME/.docker/config.json" ]; then
            mkdir -p "$CONTAINER_DIR/docker"
            cp "$HOME/.docker/config.json" "$CONTAINER_DIR/docker/config.json" 2>/dev/null || true
        fi
        if [ -f "/root/.docker/config.json" ] && [ -w "/root/.docker/config.json" ] 2>/dev/null; then
            mkdir -p "$CONTAINER_DIR/docker-system"
            cp /root/.docker/config.json "$CONTAINER_DIR/docker-system/config.json" 2>/dev/null || true
        fi
    fi

    # Containerfile / Dockerfile in home and common locations
    find "$HOME" -maxdepth 3 \( -name "Containerfile" -o -name "Dockerfile" \) 2>/dev/null \
        | head -20 | while IFS= read -r f; do
            rel="${f#"$HOME"/}"
            mkdir -p "$CONTAINER_DIR/containerfiles/$(dirname "$rel")"
            cp "$f" "$CONTAINER_DIR/containerfiles/$rel" 2>/dev/null || true
        done || true

    info "Container configuration backup complete ($CONTAINER_RUNTIME)"
fi

# ============================================================
# Phase 3: Restic backup
# ============================================================
header "Phase 3: Restic filesystem backup"

# Refresh the git mirrors before they are read. include.conf backs up
# ~/.git-mirror instead of working trees, so the history captured depends
# on this having just run. Doing it here keeps the mirror and snapshot
# consistent.
#
# Failure is warned about, not fatal: a stale mirror is still real history.
if [ -f "$SCRIPT_DIR/git-mirror.sh" ]; then
    info "Refreshing git mirrors..."
    bash "$SCRIPT_DIR/git-mirror.sh" || warn "Git mirror refresh failed - backing up the previous mirror state"
else
    warn "git-mirror.sh not found - the git mirror may be stale"
fi

BACKUP_TARGETS=()
# build_targets <include_file> -> populates TARGETS_OUT
build_targets() {
    local file="$1"
    # shellcheck disable=SC2178  # nameref: the string is the name of a caller array
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

if ! build_targets "$INCLUDE_FILE" BACKUP_TARGETS; then
    error "Include file not found or empty: $INCLUDE_FILE"
    notify "Backup Failed" "Include file missing" "critical"
    exit 1
fi

# Remote scope: its own include file when present, otherwise the local one.
REMOTE_TARGETS=()
if build_targets "$INCLUDE_FILE_REMOTE" REMOTE_TARGETS; then
    info "Offsite leg uses its own scope: $INCLUDE_FILE_REMOTE (${#REMOTE_TARGETS[@]} paths vs ${#BACKUP_TARGETS[@]} local)"
else
    REMOTE_TARGETS=("${BACKUP_TARGETS[@]}")
fi

# Add the dumps directory to the backup
if [ -d "$DUMPS_DIR" ] && [ "$(ls -A "$DUMPS_DIR" 2>/dev/null)" ]; then
    BACKUP_TARGETS+=("$DUMPS_DIR")
    info "Including pre-backup dumps in snapshot"
fi

RESTIC_COMMON_ARGS=()
RESTIC_COMMON_ARGS+=(-o "rclone.program=rclone --tpslimit 2 --drive-chunk-size 64M")
RESTIC_COMMON_ARGS+=(--verbose)
# Tags: product name plus the detected role. The role must come from $ROLE --
# a leftover hardcoded "workstation" tag duplicated it on workstations and
# would have mislabelled every server snapshot.
RESTIC_COMMON_ARGS+=(--tag "spectre-backup")
RESTIC_COMMON_ARGS+=(--tag "$ROLE")
RESTIC_COMMON_ARGS+=(--host "${HOSTNAME:-$(uname -n)}")

if [ -f "$EXCLUDE_FILE" ] && [ -s "$EXCLUDE_FILE" ]; then
    RESTIC_COMMON_ARGS+=(--exclude-file "$EXCLUDE_FILE")
fi

# Dumps are added as an explicit target above; do not exclude them globally,
# otherwise PostgreSQL/container dumps are never captured in the snapshot.

info "Starting backup of ${#BACKUP_TARGETS[@]} target paths..."

REPO_FAILED=0
# Make sure a repository exists before backing up to it.
ensure_repo_initialized() {
    local repo="$1" label="$2"
    if timeout 120 restic -r "$repo" cat config >/dev/null 2>&1; then
        return 0
    fi
    info "[$label] No repository at $repo -- initialising"
    if restic -r "$repo" init >/dev/null 2>&1; then
        info "[$label] Repository initialised"
        return 0
    fi
    if timeout 120 restic -r "$repo" cat config >/dev/null 2>&1; then
        return 0
    fi
    error "[$label] Cannot initialise or read a repository at $repo"
    return 1
}

run_repo_backup() {
    local repo="$1" label="$2"
    local -n targets_ref="$3"
    info "[$label] Starting backup to $repo (${#targets_ref[@]} paths)"
    set +e
    local exit_code=0
    for attempt in 1 2 3; do
        info "[$label] Backup attempt $attempt/3"
        restic -r "$repo" "${RESTIC_COMMON_ARGS[@]}" backup "${targets_ref[@]}" 2>&1
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

# Local first: it is the copy that survives a failed upload.
if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
    ensure_repo_initialized "$RESTIC_REPOSITORY_LOCAL" "local" || REPO_FAILED=1
    run_repo_backup "$RESTIC_REPOSITORY_LOCAL" "local" BACKUP_TARGETS
else
    warn "No local repository configured (RESTIC_REPOSITORY_LOCAL) - skipping local backup"
fi

OFFSITE_SKIPPED=0
if [ "$REMOTE_AVAILABLE" -eq 1 ]; then
    ensure_repo_initialized "$RESTIC_REPOSITORY" "offsite" || REPO_FAILED=1
    run_repo_backup "$RESTIC_REPOSITORY" "offsite" REMOTE_TARGETS
else
    warn "Offsite leg skipped: the rclone remote is not configured"
    OFFSITE_SKIPPED=1
    REPO_FAILED=1
fi

if [ $REPO_FAILED -ne 0 ]; then
    if [ "$OFFSITE_SKIPPED" -eq 1 ] && [ "$REPO_FAILED" -eq 1 ]; then
        notify "Backup Degraded" "Local backup succeeded; offsite leg skipped (rclone remote not configured)" "warning"
    else
        notify "Backup Failed" "Restic backup error" "critical"
    fi
    exit 1
fi

info "Filesystem backup complete"

# ============================================================
# Phase 4: Integrity check
# ============================================================
header "Phase 4: Repository integrity check"

INTEGRITY_FAILED=0

set +e
restic -r "$RESTIC_REPOSITORY" -o "rclone.program=rclone --tpslimit 2 --drive-chunk-size 64M" check --no-lock 2>&1
CHECK_EXIT=$?
set -e

if [ $CHECK_EXIT -ne 0 ]; then
    error "Offsite repository integrity check FAILED"
    notify "Backup Failed" "Offsite repository integrity check failed - run verify.sh" "critical"
    INTEGRITY_FAILED=1
else
    info "Offsite repository integrity check passed"
fi

if [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
    set +e
    restic -r "$RESTIC_REPOSITORY_LOCAL" check --no-lock 2>&1
    LOCAL_CHECK_EXIT=$?
    set -e
    if [ $LOCAL_CHECK_EXIT -ne 0 ]; then
        error "Local repository integrity check FAILED"
        notify "Backup Failed" "Local repository integrity check failed - run verify.sh" "critical"
        INTEGRITY_FAILED=1
    else
        info "Local repository integrity check passed"
    fi
fi

if [ "$INTEGRITY_FAILED" -ne 0 ]; then
    error "Repository integrity check FAILED -- backup is not considered successful"
    exit 1
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

# Snapshot ID via JSON: the table output wraps tag lines and leads with a row
# of dashes, which previously ended up printed as the snapshot id.
SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq -r 'sort_by(.time) | last | .short_id // "unknown"' 2>/dev/null || echo "unknown")
# restic prints "Total Size:" with a capital S; the old lowercase pattern never
# matched, so every summary showed "unknown". raw-data mode reads only the
# index instead of walking every snapshot's file trees, which takes minutes on
# a repository this size.
REPO_SIZE=$(restic -r "$RESTIC_REPOSITORY" stats --mode raw-data 2>/dev/null | grep -oP 'Total Size:\s+\K\S.*' || echo "unknown")

echo ""
echo -e "  ${BOLD}Status:${NC}        ${GREEN}✓ Backup Successful${NC}"
echo -e "  ${BOLD}Distro:${NC}        $DISTRO_ID $DISTRO_VERSION_ID"
echo -e "  ${BOLD}Role:${NC}          $ROLE"
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

if [ -f "$SCRIPT_DIR/spectre-backup-prune.sh" ]; then
    info "Running prune script..."
    bash "$SCRIPT_DIR/spectre-backup-prune.sh" --no-notify || warn "Prune completed with warnings"
else
    warn "Prune script not found - skipping automatic pruning"
fi

exit 0
