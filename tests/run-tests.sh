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
assert_eq "DISTRO_ID is set" "fedora" "$DISTRO_ID"
assert_eq "PKG_MANAGER is set" "dnf" "$PKG_MANAGER"
assert_eq "PKG_INSTALL is set" "dnf install -y" "$PKG_INSTALL"

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
             "$HOME/.config/rclone" "$SANDBOX/backups/fedora-back-up"
    printf 'RESTIC_REPOSITORY="rclone:fedora-back-up:"\nRESTIC_REPOSITORY_LOCAL="%s/backups/fedora-back-up"\nLOG_DIR="%s/state/fedora-back-up"\n' \
        "$SANDBOX" "$SANDBOX" > "$XDG_CONFIG_HOME/fedora-back-up/.env"
    printf '# fedora-back-up - Included Paths\n/whatever\n' > "$XDG_CONFIG_HOME/fedora-back-up/include.conf"
    printf 's3cr3t\n' > "$XDG_CONFIG_HOME/fedora-back-up/password"
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
    cat > "$HOME/.config/rclone/rclone.conf" <<EOF
[fedora-back-up]
type = drive
token = {"secret":"keep-me"}
root_folder_id = abc123
EOF
}

assert_not_exists() {
    local desc="$1" path="$2"
    TOTAL=$((TOTAL + 1))
    if [ ! -e "$path" ]; then
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
teardown_legacy_sandbox
assert_eq "migration: fresh machine returns 0" 0 "$rc"
assert_not_exists "migration: no migration archive on fresh machine" "$XDG_STATE_HOME/spectre-backup/migration-backup-*"
assert_not_exists "migration: no config dir created on fresh machine" "$XDG_CONFIG_HOME/fedora-back-up"

# 2: full legacy workstation converts
make_legacy_sandbox
build_legacy_fixture
run_migrate
assert_eq "migration: full legacy workstation returns 0" 0 "$rc"
assert_grep "migration: rclone section renamed to [spectre-backup]" '^\[spectre-backup\]$' "$HOME/.config/rclone/rclone.conf"
assert_grep "migration: rclone token line untouched" 'token = {"secret":"keep-me"}' "$HOME/.config/rclone/rclone.conf"
assert_file_exists "migration: repo moved, marker intact" "$SANDBOX/backups/spectre-backup/config"
assert_not_exists "migration: old repo path gone" "$SANDBOX/backups/fedora-back-up/config"
assert_file_exists "migration: config dir at new name" "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env RESTIC_REPOSITORY rewritten" 'RESTIC_REPOSITORY="rclone:spectre-backup:"' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env RESTIC_REPOSITORY_LOCAL rewritten" 'RESTIC_REPOSITORY_LOCAL=.*spectre-backup' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: .env LOG_DIR rewritten" 'LOG_DIR=.*spectre-backup' "$XDG_CONFIG_HOME/spectre-backup/.env"
assert_grep "migration: password file unchanged" 's3cr3t' "$XDG_CONFIG_HOME/spectre-backup/password"
assert_file_exists "migration: state dir moved with logs" "$XDG_STATE_HOME/spectre-backup/backup.log"
archive_count=$(ls -1d "$XDG_STATE_HOME/spectre-backup"/migration-backup-* 2>/dev/null | wc -l)
assert_eq "migration: one rollback archive created" 1 "$archive_count"
archive_dir=$(ls -1d "$XDG_STATE_HOME/spectre-backup"/migration-backup-* 2>/dev/null | head -1)
assert_file_exists "migration: archive holds legacy .env" "$archive_dir/.env"
assert_file_exists "migration: archive holds legacy rclone.conf" "$archive_dir/rclone.conf"
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
archive_count=$(ls -1d "$XDG_STATE_HOME/spectre-backup"/migration-backup-* 2>/dev/null | wc -l)
assert_eq "migration: re-run returns 0" 0 "$rc"
assert_eq "migration: still one rollback archive after re-run" 1 "$archive_count"
teardown_legacy_sandbox

# 4: leftovers cleaned without legacy config
make_legacy_sandbox
mkdir -p "$XDG_DATA_HOME/bin" "$XDG_DATA_HOME/systemd/user"
: > "$XDG_DATA_HOME/bin/fedora-back-up.sh"
ln -sf fedora-back-up.sh "$XDG_DATA_HOME/bin/fedora-back-up"
printf '[Timer]\n' > "$XDG_DATA_HOME/systemd/user/fedora-back-up.timer"
run_migrate
assert_eq "migration: leftovers returns 0" 0 "$rc"
assert_not_exists "migration: leftover bin scripts removed" "$XDG_DATA_HOME/bin/fedora-back-up.sh"
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
assert_grep "migration: abort leaves rclone.conf untouched" '\[fedora-back-up\]' "$HOME/.config/rclone/rclone.conf"
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
cat > "$HOME/.config/rclone/rclone.conf" <<EOF
[gdrive]
type = drive
EOF
run_migrate
assert_eq "migration: offsite-only custom remote returns 0" 0 "$rc"
assert_grep "migration: custom rclone remote untouched" '^\[gdrive\]$' "$HOME/.config/rclone/rclone.conf"
TOTAL=$((TOTAL + 1))
if grep -q '^\[spectre-backup\]$' "$HOME/.config/rclone/rclone.conf"; then
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

# 9: installer calls migration before resolve_dirs
installer="$PROJECT_DIR/scripts/spectre-backup-install.sh"
call_line=$(grep -n 'migrate_legacy_install' "$installer" | head -1 | cut -d: -f1)
resolve_line=$(grep -n '^resolve_dirs' "$installer" | head -1 | cut -d: -f1)
assert_eq "migration: installer wiring present" "yes" "$([ -n "$call_line" ] && echo yes || echo no)"
assert_eq "migration: migration call precedes resolve_dirs" "yes" "$([ -n "$call_line" ] && [ -n "$resolve_line" ] && [ "$call_line" -lt "$resolve_line" ] && echo yes || echo no)"

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
