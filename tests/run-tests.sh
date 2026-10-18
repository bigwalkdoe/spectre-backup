#!/bin/bash
# ============================================================
# fedora-back-up - Test suite
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

# shellcheck source=../lib/backup-common.sh
. "$PROJECT_DIR/lib/backup-common.sh"

echo "============================================================"
echo "fedora-back-up test suite"
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
export FEDORA_BACK_UP_ROLE=server
TOTAL=$((TOTAL + 1))
ROLE_OVERRIDE=$(detect_role)
if [ "$ROLE_OVERRIDE" = "server" ]; then
    echo "  PASS: FEDORA_BACK_UP_ROLE=server overrides auto-detect"
    PASS=$((PASS + 1))
else
    echo "  FAIL: FEDORA_BACK_UP_ROLE=server returned '$ROLE_OVERRIDE'"
    FAIL=$((FAIL + 1))
fi
unset FEDORA_BACK_UP_ROLE

export FEDORA_BACK_UP_ROLE=workstation
TOTAL=$((TOTAL + 1))
ROLE_OVERRIDE=$(detect_role)
if [ "$ROLE_OVERRIDE" = "workstation" ]; then
    echo "  PASS: FEDORA_BACK_UP_ROLE=workstation overrides auto-detect"
    PASS=$((PASS + 1))
else
    echo "  FAIL: FEDORA_BACK_UP_ROLE=workstation returned '$ROLE_OVERRIDE'"
    FAIL=$((FAIL + 1))
fi
unset FEDORA_BACK_UP_ROLE

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

for script in fedora-back-up-install.sh fedora-back-up.sh fedora-back-up-restore.sh fedora-back-up-verify.sh fedora-back-up-prune.sh git-mirror.sh; do
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

for script in lib/backup-common.sh scripts/*.sh; do
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
    for script in lib/backup-common.sh scripts/*.sh; do
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

assert_file_exists "User service"    "$PROJECT_DIR/systemd/fedora-back-up.service"
assert_file_exists "System service"  "$PROJECT_DIR/systemd/fedora-back-up-system.service"
assert_file_exists "Timer"           "$PROJECT_DIR/systemd/fedora-back-up.timer"

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
