#!/bin/bash
# ============================================================
# spectre-backup - Test suite
#
# Tests distro detection, role detection, config coverage,
# restic output parsing, and shellcheck compliance across all scripts.
#
# Usage:
#   ./tests/run-tests.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

# Sandboxes are registered here and removed on exit, so an aborted run does
# not leave /tmp/spectre-* directories behind.
CLEANUP_DIRS=()
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup_sandboxes() {
    if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then
        local d
        for d in "${CLEANUP_DIRS[@]}"; do
            rm -rf "$d"
        done
    fi
}
trap cleanup_sandboxes EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    TOTAL=$((TOTAL + 1))
    if [ -f "$file" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: $file)"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_exists() {
    local desc="$1" dir="$2"
    TOTAL=$((TOTAL + 1))
    if [ -d "$dir" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (missing: $dir)"
        FAIL=$((FAIL + 1))
    fi
}

# shellcheck source=../lib/spectre-backup-common.sh
. "$PROJECT_DIR/lib/spectre-backup-common.sh"
# shellcheck source=../lib/migrate-legacy.sh
. "$PROJECT_DIR/lib/migrate-legacy.sh"

echo "============================================================"
echo "spectre-backup test suite"
echo "============================================================"
echo ""

# -------------------------------------------------------------
# Test group: distro detection
# -------------------------------------------------------------
echo "--- Distro detection ---"
detect_distro || { echo "FAIL: detect_distro returned non-zero"; exit 1; }

TOTAL=$((TOTAL + 1))
case "$DISTRO_ID" in
    fedora|ubuntu|debian)
        echo "  PASS: DISTRO_ID is supported ($DISTRO_ID)"
        PASS=$((PASS + 1))
        ;;
    *)
        echo "  FAIL: unsupported DISTRO_ID '$DISTRO_ID'"
        FAIL=$((FAIL + 1))
        ;;
esac

expected_manager=""
expected_install=""
case "$DISTRO_ID" in
    fedora)        expected_manager="dnf"; expected_install="dnf install -y" ;;
    ubuntu|debian) expected_manager="apt"; expected_install="apt-get install -y" ;;
esac
assert_eq "PKG_MANAGER matches the distro" "$expected_manager" "$PKG_MANAGER"
assert_eq "PKG_INSTALL matches the distro" "$expected_install" "$PKG_INSTALL"

# Test install_packages skips already-installed packages
echo ""
echo "--- Package installation ---"
TOTAL=$((TOTAL + 1))
if install_packages restic rclone jq 2>/dev/null; then
    echo "  PASS: install_packages succeeds with already-installed packages"
    PASS=$((PASS + 1))
else
    echo "  FAIL: install_packages returned non-zero"
    FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------
# Test group: role detection
# -------------------------------------------------------------
echo ""
echo "--- Role detection ---"
TOTAL=$((TOTAL + 1))
ROLE_DETECTED=$(detect_role)
if [ "$ROLE_DETECTED" = "workstation" ] || [ "$ROLE_DETECTED" = "server" ]; then
    echo "  PASS: detect_role returned '$ROLE_DETECTED'"
    PASS=$((PASS + 1))
else
    echo "  FAIL: detect_role returned '$ROLE_DETECTED'"
    FAIL=$((FAIL + 1))
fi

# Test env var override
export SPECTRE_BACKUP_ROLE=server
TOTAL=$((TOTAL + 1))
ROLE_OVERRIDE=$(detect_role)
if [ "$ROLE_OVERRIDE" = "server" ]; then
    echo "  PASS: SPECTRE_BACKUP_ROLE=server overrides auto-detect"
    PASS=$((PASS + 1))
else
    echo "  FAIL: SPECTRE_BACKUP_ROLE=server returned '$ROLE_OVERRIDE'"
    FAIL=$((FAIL + 1))
fi
unset SPECTRE_BACKUP_ROLE

export SPECTRE_BACKUP_ROLE=workstation
TOTAL=$((TOTAL + 1))
ROLE_OVERRIDE=$(detect_role)
if [ "$ROLE_OVERRIDE" = "workstation" ]; then
    echo "  PASS: SPECTRE_BACKUP_ROLE=workstation overrides auto-detect"
    PASS=$((PASS + 1))
else
    echo "  FAIL: SPECTRE_BACKUP_ROLE=workstation returned '$ROLE_OVERRIDE'"
    FAIL=$((FAIL + 1))
fi
unset SPECTRE_BACKUP_ROLE

# -------------------------------------------------------------
# Test group: config coverage
# -------------------------------------------------------------
echo ""
echo "--- Config coverage ---"

for role in workstation server; do
    for distro in fedora ubuntu; do
        config_dir="$PROJECT_DIR/config/$role/$distro"
        assert_dir_exists "Config dir: $role/$distro" "$config_dir"
        assert_file_exists "include.conf: $role/$distro"  "$config_dir/include.conf"
        assert_file_exists "exclude.conf: $role/$distro"  "$config_dir/exclude.conf"
        assert_file_exists "include-remote.conf: $role/$distro" "$config_dir/include-remote.conf"
    done
done

assert_dir_exists "Config defaults dir" "$PROJECT_DIR/config/defaults"
assert_file_exists "defaults/include.conf"   "$PROJECT_DIR/config/defaults/include.conf"
assert_file_exists "defaults/exclude.conf"   "$PROJECT_DIR/config/defaults/exclude.conf"
assert_file_exists "defaults/include-remote.conf" "$PROJECT_DIR/config/defaults/include-remote.conf"

assert_file_exists "Root .env.example" "$PROJECT_DIR/config/.env.example"

# -------------------------------------------------------------
# Test group: scripts exist and are executable
# -------------------------------------------------------------
echo ""
echo "--- Scripts ---"

for script in spectre-backup-install.sh spectre-backup.sh spectre-backup-restore.sh spectre-backup-verify.sh spectre-backup-prune.sh git-mirror.sh; do
    assert_file_exists "Script: $script" "$PROJECT_DIR/scripts/$script"
    TOTAL=$((TOTAL + 1))
    if [ -x "$PROJECT_DIR/scripts/$script" ]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# -------------------------------------------------------------
# Test group: syntax checks
# -------------------------------------------------------------
echo ""
echo "--- Syntax checks ---"

for script in lib/*.sh scripts/*.sh; do
    file="$PROJECT_DIR/$script"
    TOTAL=$((TOTAL + 1))
    if bash -n "$file" 2>/dev/null; then
        echo "  PASS: bash -n $script"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: bash -n $script"
        FAIL=$((FAIL + 1))
    fi
done

# -------------------------------------------------------------
# Test group: shellcheck
# -------------------------------------------------------------
echo ""
echo "--- Shellcheck ---"

if command -v shellcheck >/dev/null 2>&1; then
    for script in lib/*.sh scripts/*.sh; do
        file="$PROJECT_DIR/$script"
        TOTAL=$((TOTAL + 1))
        # Only fail on errors (level error), not warnings/info
        if shellcheck "$file" 2>&1 | grep -qE "^.*: [0-9]+:[0-9]+: (SC[0-9]+)"; then
            # Check if any are errors (not warnings)
            if shellcheck "$file" 2>&1 | grep -qE "SC[0-9]+.*error"; then
                echo "  FAIL: shellcheck $script (errors found)"
                shellcheck "$file" 2>&1 | grep -E "error" | head -5
                FAIL=$((FAIL + 1))
            else
                echo "  PASS: shellcheck $script (warnings only)"
                PASS=$((PASS + 1))
            fi
        else
            echo "  PASS: shellcheck $script (clean)"
            PASS=$((PASS + 1))
        fi
    done
else
    echo "  SKIP: shellcheck not installed"
fi

# -------------------------------------------------------------
# Test group: snapshot tags
# -------------------------------------------------------------
echo ""
echo "--- Snapshot tags ---"
# The role tag must come from $ROLE: a leftover hardcoded workstation tag
# made workstations carry a duplicate and would mislabel servers.

TOTAL=$((TOTAL + 1))
if grep -n -- '--tag "workstation"' "$PROJECT_DIR/scripts/spectre-backup.sh" >/dev/null 2>&1; then
    echo "  FAIL: hardcoded workstation tag in backup script"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no hardcoded workstation tag"
    PASS=$((PASS + 1))
fi

TOTAL=$((TOTAL + 1))
# shellcheck disable=SC2016  # the pattern is literal text being searched for
if grep -n -- '--tag "$ROLE"' "$PROJECT_DIR/scripts/spectre-backup.sh" >/dev/null 2>&1; then
    echo "  PASS: role tag comes from \$ROLE"
    PASS=$((PASS + 1))
else
    echo "  FAIL: role tag does not use \$ROLE"
    FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------
# Test group: restic output parsing
# -------------------------------------------------------------
echo ""
echo "--- Restic output parsing ---"
# Guards regressions that failed silently in production: restic 0.17.3 prints
# "Total Size:" (capital S), has no --format flag for snapshots, and its
# --compact tables wrap rows and lead with a row of dashes.

TOTAL=$((TOTAL + 1))
if grep -rn "Total size:" "$PROJECT_DIR/scripts" >/dev/null 2>&1; then
    echo "  FAIL: lowercase 'Total size:' pattern (never matches restic output)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no lowercase 'Total size:' pattern"
    PASS=$((PASS + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -rn -- "--compact" "$PROJECT_DIR/scripts" >/dev/null 2>&1; then
    echo "  FAIL: snapshot table parsing with --compact (use --json + jq)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no snapshot table parsing with --compact"
    PASS=$((PASS + 1))
fi

TOTAL=$((TOTAL + 1))
if grep -rEn '^[^#]*restic.*--format' "$PROJECT_DIR/scripts" >/dev/null 2>&1; then
    echo "  FAIL: --format passed to restic (unsupported in 0.17.3, fails silently)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no --format passed to restic"
    PASS=$((PASS + 1))
fi

# The size pattern must capture the value from restic's output shape.
TOTAL=$((TOTAL + 1))
captured=$(echo "              Total Size:  2.121 KiB" | grep -oP 'Total Size:\s+\K\S.*' || true)
if [ "$captured" = "2.121 KiB" ]; then
    echo "  PASS: repo size pattern captures the size"
    PASS=$((PASS + 1))
else
    echo "  FAIL: repo size pattern captured '$captured'"
    FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------
# Test group: systemd units
# -------------------------------------------------------------
echo ""
echo "--- Systemd units ---"

assert_file_exists "User service"    "$PROJECT_DIR/systemd/spectre-backup.service"
assert_file_exists "System service"  "$PROJECT_DIR/systemd/spectre-backup-system.service"
assert_file_exists "Timer"           "$PROJECT_DIR/systemd/spectre-backup.timer"

TOTAL=$((TOTAL + 1))
server_unit_copy=$(grep -n 'spectre-backup-system.service.*SYSTEMD_DIR/spectre-backup.service' "$PROJECT_DIR/scripts/spectre-backup-install.sh" || true)
if [ -n "$server_unit_copy" ]; then
    echo "  PASS: server install uses the system unit"
    PASS=$((PASS + 1))
else
    echo "  FAIL: server install does not copy spectre-backup-system.service"
    FAIL=$((FAIL + 1))
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP: server install refuses non-root (test runs as root)"
else
    set +e
    guard_out=$("$PROJECT_DIR/scripts/spectre-backup-install.sh" --role=server --bin-only 2>&1)
    guard_rc=$?
    set -e
    assert_eq "server install refuses non-root" "1" "$guard_rc"
    assert_eq "server install explains the fix" "yes" "$(printf '%s' "$guard_out" | grep -q 'sudo' && echo yes || echo no)"
fi

assert_eq "server scripts install under /root/.local/bin" "yes" "$(grep -q 'BIN_DIR="/root/.local/bin"' "$PROJECT_DIR/scripts/spectre-backup-install.sh" && echo yes || echo no)"

# -------------------------------------------------------------
# Test group: naming guards
# -------------------------------------------------------------
echo ""
echo "--- Naming guards ---"

# The old product name must not survive anywhere in the code surface.
# (tests/ is excluded so this guard's own pattern text cannot self-match.
# lib/migrate-legacy.sh is excluded — it legitimately references old names to find them.)
TOTAL=$((TOTAL + 1))
stragglers=$(grep -rEn 'fedora-back-up|FEDORA_BACK_UP|fedora_back_up' \
    "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib" "$PROJECT_DIR/systemd" "$PROJECT_DIR/config" 2>/dev/null \
    | grep -v '/lib/migrate-legacy\.sh:' || true)
if [ -z "$stragglers" ]; then
    echo "  PASS: no old product name in scripts/lib/systemd/config"
    PASS=$((PASS + 1))
else
    echo "  FAIL: old product name found:"
    echo "$stragglers" | head -20
    FAIL=$((FAIL + 1))
fi

# All renamed files must exist under their new names.
for f in scripts/spectre-backup.sh scripts/spectre-backup-install.sh \
         scripts/spectre-backup-restore.sh scripts/spectre-backup-verify.sh \
         scripts/spectre-backup-prune.sh lib/spectre-backup-common.sh \
         systemd/spectre-backup.service systemd/spectre-backup.timer \
         systemd/spectre-backup-system.service; do
    assert_file_exists "Renamed file: $f" "$PROJECT_DIR/$f"
done

# The shared library must be referenced only under its new name.
# (lib/migrate-legacy.sh is excluded — it lists old script names to remove.)
TOTAL=$((TOTAL + 1))
librefs=$(grep -rn 'backup-common\.sh' \
    "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib" "$PROJECT_DIR/systemd" 2>/dev/null \
    | grep -v 'spectre-backup-common\.sh' | grep -v '/lib/migrate-legacy\.sh:' || true)
if [ -z "$librefs" ]; then
    echo "  PASS: shared library referenced only as spectre-backup-common.sh"
    PASS=$((PASS + 1))
else
    echo "  FAIL: legacy library reference found:"
    echo "$librefs" | head -10
    FAIL=$((FAIL + 1))
fi

# New snapshots carry the product tag alongside the role tag.
TOTAL=$((TOTAL + 1))
if grep -q -- '--tag "spectre-backup"' "$PROJECT_DIR/scripts/spectre-backup.sh"; then
    echo "  PASS: product tag is spectre-backup"
    PASS=$((PASS + 1))
else
    echo "  FAIL: product tag is not spectre-backup"
    FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------
# Test helpers: legacy migration sandbox
# -------------------------------------------------------------

SAVED_HOME=""
SAVED_XDG_CONFIG_HOME=""
SAVED_XDG_STATE_HOME=""
SAVED_XDG_DATA_HOME=""
SAVED_PATH=""
SANDBOX=""

make_legacy_sandbox() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/spectre-migtest.XXXXXX")
    CLEANUP_DIRS+=("$SANDBOX")
    export SANDBOX
    SAVED_HOME="${HOME:-}"
    SAVED_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"
    SAVED_XDG_STATE_HOME="${XDG_STATE_HOME:-}"
    SAVED_XDG_DATA_HOME="${XDG_DATA_HOME:-}"
    SAVED_PATH="$PATH"
    export HOME="$SANDBOX/home"
    export XDG_CONFIG_HOME="$SANDBOX/config"
    export XDG_STATE_HOME="$SANDBOX/state"
    export XDG_DATA_HOME="$SANDBOX/data"
    export PATH="$SANDBOX/stubbin:$PATH"
    mkdir -p "$SANDBOX/stubbin"
    # \$* is escaped so the stub logs its own arguments at run time;
    # $SANDBOX expands now so the stub knows where to write.
    cat > "$SANDBOX/stubbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SANDBOX/systemctl.log"
exit 0
EOF
    chmod +x "$SANDBOX/stubbin/systemctl"
}

teardown_legacy_sandbox() {
    export HOME="${SAVED_HOME:-}"
    export XDG_CONFIG_HOME="${SAVED_XDG_CONFIG_HOME:-}"
    export XDG_STATE_HOME="${SAVED_XDG_STATE_HOME:-}"
    export XDG_DATA_HOME="${SAVED_XDG_DATA_HOME:-}"
    export PATH="$SAVED_PATH"
    rm -rf "$SANDBOX"
    unset SANDBOX SAVED_HOME SAVED_XDG_CONFIG_HOME SAVED_XDG_STATE_HOME SAVED_XDG_DATA_HOME SAVED_PATH
}

build_legacy_fixture() {
    mkdir -p "$XDG_CONFIG_HOME/fedora-back-up" "$XDG_STATE_HOME/fedora-back-up" \
             "$XDG_DATA_HOME/bin" "$XDG_DATA_HOME/systemd/user" \
             "$XDG_CONFIG_HOME/rclone" "$SANDBOX/backups/fedora-back-up"
    printf 'RESTIC_REPOSITORY="rclone:fedora-back-up:"\nRESTIC_REPOSITORY_LOCAL="%s/backups/fedora-back-up"\nLOG_DIR="%s/state/fedora-back-up"\n' \
        "$SANDBOX" "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
    printf '# fedora-back-up - Included Paths\n/whatever\n' > "$XDG_CONFIG_HOME/fedora-back-up/include.conf"
    # The token is deliberately embedded: the rewrite must never touch secrets.
    printf 's3cr3t-fedora-back-up\n' > "$XDG_CONFIG_HOME/fedora-back-up/password"
    chmod 600 "$XDG_CONFIG_HOME/fedora-back-up/password"
    printf 'log line one\n' > "$XDG_STATE_HOME/fedora-back-up/backup.log"
    printf 'repo-marker\n' > "$SANDBOX/backups/fedora-back-up/config"
    : > "$XDG_DATA_HOME/bin/fedora-back-up.sh"
    : > "$XDG_DATA_HOME/bin/fedora-back-up-restore.sh"
    : > "$XDG_DATA_HOME/bin/fedora-back-up-verify.sh"
    : > "$XDG_DATA_HOME/bin/fedora-back-up-prune.sh"
    : > "$XDG_DATA_HOME/bin/backup-common.sh"
    ln -sf fedora-back-up.sh "$XDG_DATA_HOME/bin/fedora-back-up"
    printf '[Unit]\nDescription=old\n' > "$XDG_DATA_HOME/systemd/user/fedora-back-up.service"
    printf '[Timer]\n' > "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
    cat > "$XDG_CONFIG_HOME/rclone/rclone.conf" <<EOF
[fedora-back-up]
type = drive
token = {"secret":"keep-me"}
root_folder_id = abc123
EOF
}

assert_not_exists() {
    local desc="$1" path="$2"
    TOTAL=$((TOTAL + 1))
    # -L: a dangling symlink is still an artifact that must be gone; -e alone
    # follows the link and would report a broken one as absent.
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (exists: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_grep() {
    local desc="$1" pattern="$2" file="$3"
    TOTAL=$((TOTAL + 1))
    if grep -q -- "$pattern" "$file"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern not found in $file)"
        FAIL=$((FAIL + 1))
    fi
}

# -------------------------------------------------------------
# Test group: legacy migration
# -------------------------------------------------------------
echo ""
echo "--- Legacy migration ---"

run_migrate() {
    if migrate_legacy_install; then
        rc=0
    else
        rc=$?
    fi
}

# 1: fresh machine is a no-op
make_legacy_sandbox
run_migrate
assert_eq "migration: fresh machine returns 0" 0 "$rc"
archive_count=$(find "$SANDBOX/state/spectre-backup" -maxdepth 1 -type d -name 'migration-backup-*' 2>/dev/null | wc -l || true)
assert_eq "migration: no migration archive on fresh machine" 0 "$archive_count"
assert_not_exists "migration: no new config dir created on fresh machine" "$SANDBOX/config/spectre-backup"
assert_not_exists "migration: no legacy config dir created on fresh machine" "$SANDBOX/config/fedora-back-up"
teardown_legacy_sandbox

# 2: full legacy workstation converts
make_legacy_sandbox
build_legacy_fixture
run_migrate
assert_eq "migration: full legacy workstation returns 0" 0 "$rc"
assert_grep "migration: rclone section renamed to [spectre-backup]" '^\[spectre-backup\]$' "$XDG_CONFIG_HOME/rclone/rclone.conf"
assert_grep "migration: rclone token line untouched" 'token = {"secret":"keep-me"}' "$XDG_CONFIG_HOME/rclone/rclone.conf"
assert_file_exists "migration: repo moved, marker intact" "$SANDBOX/backups/spectre-backup/config"
assert_not_exists "migration: old repo path gone" "$SANDBOX/backups/fedora-back-up/config"
assert_file_exists "migration: config dir at new name" "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env RESTIC_REPOSITORY rewritten" 'RESTIC_REPOSITORY="rclone:spectre-backup:"' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env RESTIC_REPOSITORY_LOCAL rewritten" 'RESTIC_REPOSITORY_LOCAL=.*spectre-backup' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env LOG_DIR rewritten" 'LOG_DIR=.*spectre-backup' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_eq "migration: password file unchanged byte-for-byte" 's3cr3t-fedora-back-up' "$(cat "$XDG_CONFIG_HOME/spectre-backup/password")"
assert_file_exists "migration: state dir moved with logs" "$XDG_STATE_HOME/spectre-backup/backup.log"
archive_count=$(find "$XDG_STATE_HOME/spectre-backup" -maxdepth 1 -type d -name 'migration-backup-*' 2>/dev/null | wc -l || true)
assert_eq "migration: one rollback archive created" 1 "$archive_count"
archive_dir=$(find "$XDG_STATE_HOME/spectre-backup" -maxdepth 1 -type d -name 'migration-backup-*' 2>/dev/null | head -1 || true)
assert_file_exists "migration: archive holds legacy .env" "$archive_dir/.env"
assert_file_exists "migration: archive holds legacy rclone.conf" "$archive_dir/rclone.conf"
assert_eq "migration: archive holds the password" 's3cr3t-fedora-back-up' "$(cat "$archive_dir/password")"
assert_not_exists "migration: old bin script gone" "$XDG_DATA_HOME/bin/fedora-back-up.sh"
assert_not_exists "migration: old symlink gone" "$XDG_DATA_HOME/bin/fedora-back-up"
assert_not_exists "migration: old service unit gone" "$XDG_DATA_HOME/systemd/user/fedora-back-up.service"
assert_not_exists "migration: old timer unit gone" "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
assert_grep "migration: systemctl disable called" '--user disable --now fedora-back-up.timer' "$SANDBOX/systemctl.log"
assert_grep "migration: systemctl daemon-reload called" '--user daemon-reload' "$SANDBOX/systemctl.log"
teardown_legacy_sandbox

# 3: re-run is a no-op
make_legacy_sandbox
build_legacy_fixture
run_migrate
run_migrate
archive_count=$(find "$XDG_STATE_HOME/spectre-backup" -maxdepth 1 -type d -name 'migration-backup-*' 2>/dev/null | wc -l || true)
assert_eq "migration: re-run returns 0" 0 "$rc"
assert_eq "migration: still one rollback archive after re-run" 1 "$archive_count"
teardown_legacy_sandbox

# 4: leftovers cleaned without legacy config
make_legacy_sandbox
mkdir -p "$XDG_DATA_HOME/bin" "$XDG_DATA_HOME/systemd/user"
: > "$XDG_DATA_HOME/bin/fedora-back-up.sh"
ln -sf fedora-back-up.sh "$XDG_DATA_HOME/bin/fedora-back-up"
# A dangling link must also be cleaned up (-e follows links and misses it).
ln -sf missing-target.sh "$XDG_DATA_HOME/bin/fedora-back-up-restore.sh"
printf '[Timer]\n' > "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
run_migrate
assert_eq "migration: leftovers returns 0" 0 "$rc"
assert_not_exists "migration: leftover bin scripts removed" "$XDG_DATA_HOME/bin/fedora-back-up.sh"
assert_not_exists "migration: leftover dangling symlink removed" "$XDG_DATA_HOME/bin/fedora-back-up-restore.sh"
assert_not_exists "migration: leftover timer removed" "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
assert_grep "migration: leftover disable logged" '--user disable --now fedora-back-up.timer' "$SANDBOX/systemctl.log"
teardown_legacy_sandbox

# 5: ambiguous config state aborts
make_legacy_sandbox
build_legacy_fixture
mkdir -p "$XDG_CONFIG_HOME/spectre-backup"
run_migrate
assert_eq "migration: ambiguous config aborts with 1" 1 "$rc"
assert_file_exists "migration: abort leaves repo at old path" "$SANDBOX/backups/fedora-back-up/config"
assert_grep "migration: abort leaves rclone.conf untouched" '\[fedora-back-up\]' "$XDG_CONFIG_HOME/rclone/rclone.conf"
assert_file_exists "migration: abort leaves bin scripts in place" "$XDG_DATA_HOME/bin/fedora-back-up.sh"
teardown_legacy_sandbox

# 6: repo target exists aborts
make_legacy_sandbox
build_legacy_fixture
mkdir -p "$SANDBOX/backups/spectre-backup"
run_migrate
assert_eq "migration: repo target exists aborts with 1" 1 "$rc"
assert_not_exists "migration: abort does not move config dir" "$XDG_CONFIG_HOME/spectre-backup"
assert_file_exists "migration: abort leaves legacy config in place" "$XDG_CONFIG_HOME/fedora-back-up/.env"
teardown_legacy_sandbox

# 7: offsite-only env with custom remote is left alone
make_legacy_sandbox
build_legacy_fixture
printf 'RESTIC_REPOSITORY="rclone:fedora-back-up:"\nLOG_DIR="%s/state/fedora-back-up"\n' "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
cat > "$XDG_CONFIG_HOME/rclone/rclone.conf" <<EOF
[gdrive]
type = drive
EOF
run_migrate
assert_eq "migration: offsite-only custom remote returns 0" 0 "$rc"
assert_grep "migration: custom rclone remote untouched" '^\[gdrive\]$' "$XDG_CONFIG_HOME/rclone/rclone.conf"
TOTAL=$((TOTAL + 1))
if grep -q '^\[spectre-backup\]$' "$XDG_CONFIG_HOME/rclone/rclone.conf"; then
    echo "  FAIL: migration: no [spectre-backup] section added"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: migration: no [spectre-backup] section added"
    PASS=$((PASS + 1))
fi
assert_not_exists "migration: no repo dirs created" "$SANDBOX/backups/spectre-backup"
teardown_legacy_sandbox

# 8: failing systemctl is tolerated
make_legacy_sandbox
build_legacy_fixture
cat > "$SANDBOX/stubbin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SANDBOX/systemctl.log"
exit 1
EOF
chmod +x "$SANDBOX/stubbin/systemctl"
run_migrate
assert_eq "migration: failing systemctl still returns 0" 0 "$rc"
assert_not_exists "migration: units removed despite failing systemctl" "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
teardown_legacy_sandbox

# 9: single-quoted .env values still move the repo
make_legacy_sandbox
build_legacy_fixture
printf "RESTIC_REPOSITORY='rclone:fedora-back-up:'\nRESTIC_REPOSITORY_LOCAL='%s/backups/fedora-back-up'\nLOG_DIR=\"%s/state/fedora-back-up\"\n" "$SANDBOX" "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
run_migrate
assert_eq "migration: single-quoted .env returns 0" 0 "$rc"
assert_file_exists "migration: single-quoted repo path still moved" "$SANDBOX/backups/spectre-backup/config"
assert_not_exists "migration: single-quoted old repo path gone" "$SANDBOX/backups/fedora-back-up/config"
assert_grep "migration: single-quoted .env rewritten" "RESTIC_REPOSITORY_LOCAL=.*spectre-backup" "$XDG_CONFIG_HOME/spectre-backup/.env"
teardown_legacy_sandbox

# 10: missing repo dir aborts instead of orphaning .env
make_legacy_sandbox
build_legacy_fixture
rm -rf "$SANDBOX/backups/fedora-back-up"
run_migrate
assert_eq "migration: missing repo dir aborts with 1" 1 "$rc"
assert_file_exists "migration: abort leaves legacy config in place" "$XDG_CONFIG_HOME/fedora-back-up/.env"
assert_grep "migration: abort leaves .env repo path untouched" 'backups/fedora-back-up' "$XDG_CONFIG_HOME/fedora-back-up/.env"
assert_not_exists "migration: abort does not create new config dir" "$XDG_CONFIG_HOME/spectre-backup"
assert_not_exists "migration: abort does not create target repo" "$SANDBOX/backups/spectre-backup"
teardown_legacy_sandbox

# 11: a neutral repo path (no old product name) is left in place
make_legacy_sandbox
build_legacy_fixture
mv "$SANDBOX/backups/fedora-back-up" "$SANDBOX/backups/restic-repo"
printf 'RESTIC_REPOSITORY="rclone:fedora-back-up:"\nRESTIC_REPOSITORY_LOCAL="%s/backups/restic-repo"\nLOG_DIR="%s/state/fedora-back-up"\n' "$SANDBOX" "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
run_migrate
assert_eq "migration: neutral repo path returns 0" 0 "$rc"
assert_file_exists "migration: neutral repo path untouched" "$SANDBOX/backups/restic-repo/config"
assert_grep "migration: neutral repo value unchanged in .env" 'backups/restic-repo' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: neutral repo run still rewrites LOG_DIR" 'LOG_DIR=.*spectre-backup' "$XDG_CONFIG_HOME/spectre-backup/.env"
teardown_legacy_sandbox

# 12: interrupted migration (moved but not rewritten) is repaired on re-run
make_legacy_sandbox
build_legacy_fixture
run_migrate
sed -i 's/spectre-backup/fedora-back-up/g' "$XDG_CONFIG_HOME/spectre-backup/.env"
run_migrate
assert_eq "migration: repair re-run returns 0" 0 "$rc"
assert_grep "migration: repair rewrites stale .env" 'RESTIC_REPOSITORY="rclone:spectre-backup:"' "$XDG_CONFIG_HOME/spectre-backup/.env"
TOTAL=$((TOTAL + 1))
if grep -q 'fedora-back-up' "$XDG_CONFIG_HOME/spectre-backup/.env"; then
    echo "  FAIL: migration: repair leaves no old token in .env"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: migration: repair leaves no old token in .env"
    PASS=$((PASS + 1))
fi
teardown_legacy_sandbox

# 13: installer-context invocation (errexit) survives an offsite-only .env
make_legacy_sandbox
build_legacy_fixture
printf 'RESTIC_REPOSITORY="rclone:fedora-back-up:"\nLOG_DIR="%s/state/fedora-back-up"\n' "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
TOTAL=$((TOTAL + 1))
# Not run inside `if`/`&&`: a condition context suppresses errexit even in a
# subshell, which would make this test pass no matter what.
set +e
( set -euo pipefail; migrate_legacy_install ) >/dev/null 2>&1
rc_errexit=$?
set -e
if [ "$rc_errexit" -eq 0 ]; then
    echo "  PASS: migration: survives errexit with offsite-only .env"
    PASS=$((PASS + 1))
else
    echo "  FAIL: migration: dies under errexit with offsite-only .env (rc=$rc_errexit)"
    FAIL=$((FAIL + 1))
fi
assert_file_exists "migration: errexit run still moves config" "$XDG_CONFIG_HOME/spectre-backup/.env"
teardown_legacy_sandbox

# 14: password containing the old token is never rewritten
make_legacy_sandbox
build_legacy_fixture
printf 'my-fedora-back-up-pass\n' > "$XDG_CONFIG_HOME/fedora-back-up/password"
run_migrate
assert_eq "migration: secret password migrated intact" 0 "$rc"
assert_eq "migration: secret password byte-identical" 'my-fedora-back-up-pass' "$(cat "$XDG_CONFIG_HOME/spectre-backup/password")"
teardown_legacy_sandbox

# 15: the legacy timer is disabled before the repository moves
ml="$PROJECT_DIR/lib/migrate-legacy.sh"
disable_line=$(grep -n 'user disable --now fedora-back-up.timer' "$ml" | head -1 | cut -d: -f1)
move_line=$(grep -n 'Moving repository' "$ml" | head -1 | cut -d: -f1)
assert_eq "migration: timer disabled before repo move" "yes" "$([ -n "$disable_line" ] && [ -n "$move_line" ] && [ "$disable_line" -lt "$move_line" ] && echo yes || echo no)"

# 16: installer calls migration before resolve_dirs
installer="$PROJECT_DIR/scripts/spectre-backup-install.sh"
call_line=$(grep -n 'migrate_legacy_install' "$installer" | head -1 | cut -d: -f1)
resolve_line=$(grep -n '^resolve_dirs' "$installer" | head -1 | cut -d: -f1)
assert_eq "migration: installer wiring present" "yes" "$([ -n "$call_line" ] && echo yes || echo no)"
assert_eq "migration: migration call precedes resolve_dirs" "yes" "$([ -n "$call_line" ] && [ -n "$resolve_line" ] && [ "$call_line" -lt "$resolve_line" ] && echo yes || echo no)"

# -------------------------------------------------------------
echo ""
echo "--- Health check SLOs ---"

make_health_sandbox() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/spectre-health.XXXXXX")
    CLEANUP_DIRS+=("$SANDBOX")
    export SANDBOX
    mkdir -p "$SANDBOX/config/spectre-backup" "$SANDBOX/state" "$SANDBOX/home" \
             "$SANDBOX/repo" "$SANDBOX/stubbin"
    cat > "$SANDBOX/config/spectre-backup/.env" <<EOF
RESTIC_REPOSITORY="rclone:fake-remote:"
RESTIC_REPOSITORY_LOCAL="$SANDBOX/repo"
NOTIFY_ENABLED="false"
EOF
    printf 'test-password\n' > "$SANDBOX/config/spectre-backup/password"
    printf '/tmp\n' > "$SANDBOX/config/spectre-backup/include.conf"
    # restic stub: a snapshot aged LOCAL_AGE_H for the local repo, OFF_AGE_H
    # for the offsite repo.
    cat > "$SANDBOX/stubbin/restic" <<EOF
#!/bin/bash
repo="\$2"
if [ "\$repo" = "$SANDBOX/repo" ]; then age="\${LOCAL_AGE_H:-2}"; else age="\${OFF_AGE_H:-2}"; fi
printf '[{"time":"%s"}]\n' "\$(date -u -d "-\$age hours" +%Y-%m-%dT%H:%M:%SZ)"
EOF
    # df stub: /tmp is small, and the SLO must not depend on the host's disk.
    cat > "$SANDBOX/stubbin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 104857600 1048576 103809024 1% /"
EOF
    cat > "$SANDBOX/stubbin/rclone" <<'EOF'
#!/bin/bash
[ "$1" = "about" ] && echo "Used:  10%"
exit 0
EOF
    chmod +x "$SANDBOX/stubbin/restic" "$SANDBOX/stubbin/df" "$SANDBOX/stubbin/rclone"
}

teardown_health_sandbox() {
    rm -rf "$SANDBOX"
    unset SANDBOX
}

run_health() {
    local local_age="$1" off_age="$2"
    set +e
    LOCAL_AGE_H="$local_age" OFF_AGE_H="$off_age" \
        SPECTRE_BACKUP_ROLE=workstation \
        XDG_CONFIG_HOME="$SANDBOX/config" \
        XDG_STATE_HOME="$SANDBOX/state" \
        HOME="$SANDBOX/home" \
        PATH="$SANDBOX/stubbin:$PATH" \
        bash "$PROJECT_DIR/scripts/spectre-backup.sh" --health --json \
        > "$SANDBOX/health.json" 2> "$SANDBOX/health.err"
    health_rc=$?
    set -e
    # The script routes stdout through tee (process substitution), which can
    # land a moment after it exits.
    for _ in $(seq 1 20); do
        jq -e . "$SANDBOX/health.json" >/dev/null 2>&1 && break
        sleep 0.1
    done
    health_local=$(jq -r '.local.status' "$SANDBOX/health.json" 2>/dev/null || echo "parse-error")
}

# A few hours old: ok (regression guard for the normal case)
make_health_sandbox
run_health 1 1
assert_eq "health: 1h local is ok" "ok" "$health_local"
assert_eq "health: 1h exits 0" 0 "$health_rc"
teardown_health_sandbox

# A daily timer's normal age is still ok (26h window, age_h floors to 24)
make_health_sandbox
run_health 25 25
assert_eq "health: 25h local is ok (daily cadence)" "ok" "$health_local"
assert_eq "health: 25h exits 0" 0 "$health_rc"
teardown_health_sandbox

# One missed run: degraded
make_health_sandbox
run_health 28 28
assert_eq "health: 28h local is degraded" "degraded" "$health_local"
assert_eq "health: 28h exits 1" 1 "$health_rc"
teardown_health_sandbox

# Two days without a run is still degraded, not failed
make_health_sandbox
run_health 47 47
assert_eq "health: 47h local is degraded" "degraded" "$health_local"
assert_eq "health: 47h exits 1" 1 "$health_rc"
teardown_health_sandbox

# Past two days: failed
make_health_sandbox
run_health 50 50
assert_eq "health: 50h local signal is fail" "fail" "$health_local"
assert_eq "health: 50h exits 2" 2 "$health_rc"
teardown_health_sandbox

# -------------------------------------------------------------
# Test group: CLI help / flag parsing
# -------------------------------------------------------------
echo ""
echo "--- CLI help ---"

for script in spectre-backup.sh spectre-backup-restore.sh spectre-backup-verify.sh spectre-backup-prune.sh; do
    TOTAL=$((TOTAL + 1))
    if "$PROJECT_DIR/scripts/$script" --help >/dev/null 2>&1; then
        echo "  PASS: $script --help exits 0"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script --help non-zero"
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
    if "$PROJECT_DIR/scripts/$script" --version >/dev/null 2>&1; then
        echo "  PASS: $script --version exits 0"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script --version non-zero"
        FAIL=$((FAIL + 1))
    fi
done

# Restore --local without config should fail gracefully (not crash)
TOTAL=$((TOTAL + 1))
set +e
"$PROJECT_DIR/scripts/spectre-backup-restore.sh" --local --yes --dry-run >/dev/null 2>&1
rc=$?
set -e
# Either succeeds (if local repo configured) or fails with a clear error; must
# not segfault. Accept any non-127/139 exit.
if [ "$rc" -ne 127 ] && [ "$rc" -ne 139 ]; then
    echo "  PASS: restore --local runs without crashing (rc=$rc)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: restore --local crashed (rc=$rc)"
    FAIL=$((FAIL + 1))
fi

# -------------------------------------------------------------
# Summary
# -------------------------------------------------------------
echo ""
echo "============================================================"
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
