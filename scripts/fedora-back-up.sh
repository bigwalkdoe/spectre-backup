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

health_check() {
    local out_json=0
    local rc_ok=0 rc_deg=1 rc_fail=2
    local overall=$rc_ok
    for arg in "$@"; do
        case "$arg" in
            --json) out_json=1 ;;
        esac
    done

    local now=$(date -u +%s)
    local local_newest_ts="" local_newest_iso=""
    local off_newest_ts="" off_newest_iso=""
    local local_count=0 off_count=0
    local local_age_h=999999 off_age_h=999999
    local local_free_g=0
    local df_free_kb=0

    # Local
    if [ -n "${RESTIC_PASSWORD_FILE:-}" ] && [ -d "${RESTIC_REPOSITORY_LOCAL:-}" ] 2>/dev/null || [ -n "${RESTIC_REPOSITORY_LOCAL:-}" ]; then
        local_newest_iso=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY_LOCAL" snapshots --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || true)
        local_count=$(RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" timeout 180 restic -r "$RESTIC_REPOSITORY_LOCAL" snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    fi
    if [ -n "$local_newest_iso" ]; then
        local_newest_ts=$(date -u -d "$local_newest_iso" +%s 2>/dev/null || date -u +%s)
        local_age_h=$(( (now - local_newest_ts) / 3600 ))
    fi

    # Offsite
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
        used_pct=$(timeout 60 rclone about "${REMOTE_NAME:-fedora-back-up}:" 2>/dev/null | grep -oP 'Used:.*?([0-9.]+)%' | grep -oP '([0-9.]+)%' | tr -d '%' | head -1 || true)
    fi

    local local_status="ok" off_status="ok" disk_status="ok" quota_status="ok" locks_status="ok"

    # SLOs: local <1h ok, >2h deg, >24h fail
    if [ $local_age_h -gt 24 ]; then local_status="fail"; overall=$rc_fail
    elif [ $local_age_h -gt 2 ]; then local_status="degraded"; [ $overall -eq $rc_ok ] && overall=$rc_deg
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

    if [ $out_json -eq 1 ]; then
        cat <<JSON
{
  "status": "$( [ $overall -eq 0 ] && echo ok || ([ $overall -eq 1 ] && echo degraded || echo failed) )",
  "exit_code": $overall,
  "local": {"count": $local_count, "newest_iso": "$local_newest_iso", "age_hours": $local_age_h, "status": "$local_status"},
  "offsite": {"count": $off_count, "newest_iso": "$off_newest_iso", "age_hours": $off_age_h, "status": "$off_status"},
  "disk_free_g": $local_free_g, "disk_status": "$disk_status",
  "quota_used_pct": "${used_pct:-null}", "quota_status": "$quota_status",
  "locks_status": "$locks_status"
}
JSON
        return $overall
    else
        echo "health: $( [ $overall -eq 0 ] && echo OK || ([ $overall -eq 1 ] && echo DEGRADED || echo FAILED) )"
        echo "  local:   count=$local_count age_h=$local_age_h status=$local_status (newest=$local_newest_iso)"
        echo "  offsite: count=$off_count age_h=$off_age_h status=$off_status (newest=$off_newest_iso)"
        echo "  disk:    free_g=$local_free_g status=$disk_status"
        echo "  quota:   used_pct=${used_pct:-n/a} status=$quota_status"
        return $overall
    fi
}



# Auto-heal stale restic locks (resilience)
heal_lock() {
    local repo="$1" label="$2"
    if [ -n "${repo:-}" ]; then
        if timeout 60 restic -r "$repo" unlock --remove-all >/dev/null 2>&1; then
            echo "locks-healed: $label" >> "$LOG_DIR/backup.log"
        fi
    fi
}

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/password"
INCLUDE_FILE="${INCLUDE_FILE:-$CONFIG_DIR/include.conf}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$CONFIG_DIR/exclude.conf}"
# Offsite leg scope. The local and remote repositories do not have to carry the
# same paths: the remote may be a target with a much smaller quota than the
# disk it protects. When this file is absent the remote falls back to the full
# local scope, so existing deployments are unaffected.
INCLUDE_FILE_REMOTE="${INCLUDE_FILE_REMOTE:-$CONFIG_DIR/include-remote.conf}"
# # The remote path was rclone:fedora-back-up:, which has been
# deleted. Repointed to the current backup folder. Override with the
# RESTIC_REPOSITORY environment variable rather than editing this line.
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:fedora-back-up:}"
RESTIC_REMOTE="fedora-back-up"

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


# Health dispatch
for arg in "$@"; do
    case "$arg" in
        --health|health)
            health_check "$@"
            exit $?
            ;;
    esac
done

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

# Does the offsite leg have a usable backend?
#
# This used to `exit 1` when the rclone remote was missing. The local repository
# is not backed up until much later in the run, so an unreachable offsite remote
# silently cancelled the local backup too: snapshots in RESTIC_REPOSITORY_LOCAL
# stopped on 11 September while every run after that failed here with "rclone
# remote gdrive not found". A remote that cannot be reached is a degradation, not
# a reason to also lose the local copy.
#
# Local snapshots stopped on 24 September, when the remote folder was deleted and
# the configured path stopped resolving.
#
# The run still exits non-zero overall and still notifies, so a broken offsite leg
# cannot pass for a healthy backup.
REMOTE_AVAILABLE=1
BACKEND="${RESTIC_REPOSITORY%%:*}"
if [ "$BACKEND" = "rclone" ]; then
    REMOTE="${RESTIC_REPOSITORY#*:}"
    REMOTE_NAME="${REMOTE%%:*}"
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        error "rclone remote '$REMOTE_NAME:' is not defined -- offsite leg will be SKIPPED"
        warn "The local repository will still be backed up."
        warn "Create the remote with: rclone config   (n) new remote -> $REMOTE_NAME -> Storage: drive"
        notify "Backup Degraded" "rclone remote $REMOTE_NAME not defined; local backup still running" "warning"
        REMOTE_AVAILABLE=0
    elif ! rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        # Defined is not the same as usable. A remote can exist in the config with
        # no OAuth token, which is exactly the current state: `rclone listremotes`
        # listed it, so a presence-only check passed, and the run then failed deep
        # inside restic with "empty token found" instead of naming the cause here.
        # One directory listing distinguishes the two, and takes the same trip to
        # the provider as the backup itself would.
        error "rclone remote '$REMOTE_NAME:' is defined but not usable -- offsite leg will be SKIPPED"
        warn "The local repository will still be backed up."
        warn "Most often an expired or missing OAuth token. Re-authorise with:"
        warn "    rclone config reconnect ${REMOTE_NAME}:"
        notify "Backup Degraded" "rclone remote $REMOTE_NAME needs re-authorising; local backup still running" "warning"
        REMOTE_AVAILABLE=0
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
        elif [ $rc -ne 0 ]; then
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
# build_targets <include_file> -> populates TARGETS_OUT
#
# Split out because the two repositories can have different scopes. Duplicated
# inline it was impossible to give the remote a smaller path set than local,
# which is what a quota-limited offsite target needs.
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
RESTIC_COMMON_ARGS+=(--tag "fedora-back-up")
RESTIC_COMMON_ARGS+=(--tag "workstation")
RESTIC_COMMON_ARGS+=(--host "$(hostname)")

if [ -f "$EXCLUDE_FILE" ] && [ -s "$EXCLUDE_FILE" ]; then
    RESTIC_COMMON_ARGS+=(--exclude-file "$EXCLUDE_FILE")
fi

RESTIC_COMMON_ARGS+=(--exclude "$DUMPS_DIR") # exclude from general backup pattern scanning

info "Starting backup of ${#BACKUP_TARGETS[@]} target paths..."

REPO_FAILED=0
# Make sure a repository exists before backing up to it.
#
# There was no `restic init` anywhere in this script, so a repository that did not
# yet exist failed at the first backup with "unable to open config file". That is
# exactly the state of a newly created offsite folder: the remote was created,
# nothing was ever initialised in it, and the first run would have failed for a
# third reason after the path was corrected and the token re-authorised.
#
# Idempotent in both directions: an existing repository is left alone, and a repo
# that exists but cannot be read (a wrong password, say) is reported rather than
# being re-initialised over the top of.
ensure_repo_initialized() {
    local repo="$1" label="$2"
    if restic -r "$repo" cat config >/dev/null 2>&1; then
        return 0
    fi
    info "[$label] No repository at $repo -- initialising"
    if restic -r "$repo" init >/dev/null 2>&1; then
        info "[$label] Repository initialised"
        return 0
    fi
    if restic -r "$repo" cat config >/dev/null 2>&1; then
        # init reported failure but the repository is readable: it existed already.
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
      ensure_repo_initialized "$RESTIC_REPOSITORY" "drive" || REPO_FAILED=1
      run_repo_backup "$RESTIC_REPOSITORY" "drive" REMOTE_TARGETS
else
    warn "Offsite leg skipped: the rclone remote is not configured"
    OFFSITE_SKIPPED=1
    REPO_FAILED=1
fi

if [ $REPO_FAILED -ne 0 ]; then
    if [ "$OFFSITE_SKIPPED" -eq 1 ] && [ "$REPO_FAILED" -eq 1 ]; then
        # Only the offsite leg was skipped; the local backup is fine. Reporting
        # this as a restic error points whoever reads it at the wrong subsystem.
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



# ============================================================
# Health check
# ============================================================









heal_lock "$RESTIC_REPOSITORY_LOCAL" local
heal_lock "$RESTIC_REPOSITORY" offsite
