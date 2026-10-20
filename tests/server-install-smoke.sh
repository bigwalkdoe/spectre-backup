#!/bin/bash
# ============================================================
# spectre-backup - Server install smoke test
#
# End-to-end check of the root/server path inside a disposable
# container: installer, system unit placement, local + offsite
# backup (rclone alias backend), snapshot tags, and health.
#
# Requires: root, restic, rclone, jq, sudo, systemd-analyze.
# Destroys /etc/spectre-backup, /root/.local/bin/spectre-backup*,
# /etc/systemd/system/spectre-backup.* and /tmp/spectre-smoke-*.
# Refuses to run outside a container for that reason.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK=""
cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

# --- Systemctl stub placed where sudo will find it (secure_path) ---
# Containers have no systemd PID 1, so the installer's systemctl calls need
# a stub that succeeds. This is test-only hygiene; real systems use systemd.
cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/spectre-server-smoke-systemctl.log
case "$*" in
    *is-enabled*) exit 1 ;;
    *is-active*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x /usr/local/bin/systemctl
export SYSTEMD_STUB=/usr/local/bin/systemctl
rm -f /tmp/spectre-server-smoke-systemctl.log

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

check_jq() {
    local desc="$1" file="$2" filter="$3"
    if jq -e "$filter" "$file" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- Safety and prerequisites ---
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
    fail "refusing to run outside a disposable container (Docker/Podman)"
fi
[ "$(id -u)" -eq 0 ] || fail "must run as root"

for cmd in restic rclone jq sudo systemd-analyze systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing dependency: $cmd"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/spectre-server-smoke.XXXXXX")

# --- systemctl stub (containers have no systemd PID 1) ---
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/systemctl.log"
case "\$*" in
    *is-enabled*) exit 1 ;;
    *is-active*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
SYSTEMCTL_LOG="/tmp/spectre-server-smoke-systemctl.log"
export SYSTEMCTL_LOG

# --- Clean slate (test-scoped paths only) ---
rm -rf /etc/spectre-backup \
       /root/.local/bin/spectre-backup /root/.local/bin/spectre-backup.sh \
       /root/.local/bin/spectre-backup-common.sh \
       /etc/systemd/system/spectre-backup.service \
       /etc/systemd/system/spectre-backup.timer \
       /tmp/spectre-smoke-local /tmp/spectre-smoke-offsite
mkdir -p /etc/spectre-backup /root/.config/rclone /tmp/spectre-smoke-offsite
printf 'smoke-test-password\n' > /etc/spectre-backup/password
chmod 600 /etc/spectre-backup/password

# Offsite leg through rclone's alias backend, so no network or OAuth.
cat > /root/.config/rclone/rclone.conf <<'EOF'
[spectre-backup]
type = alias
remote = /tmp/spectre-smoke-offsite
EOF

# --- Install as a server, non-interactively ---
echo "--- Installing as server ---"
"$PROJECT_DIR/scripts/spectre-backup-install.sh" --role=server --skip-test

# --- Installed footprint ---
echo ""
echo "--- Installed footprint ---"
check "backup script installed" test -x /root/.local/bin/spectre-backup.sh
check "shared library installed" test -f /root/.local/bin/spectre-backup-common.sh
check "convenience symlink installed" test -L /root/.local/bin/spectre-backup
check "server config installed" test -f /etc/spectre-backup/.env
check ".env is private" test "$(stat -c %a /etc/spectre-backup/.env)" = "600"
check "password preserved byte-for-byte" test "$(cat /etc/spectre-backup/password)" = "smoke-test-password"
check "system unit installed" test -f /etc/systemd/system/spectre-backup.service
check "timer installed" test -f /etc/systemd/system/spectre-backup.timer
check "system unit runs as root" grep -qx 'User=root' /etc/systemd/system/spectre-backup.service
check "system unit sets server role" grep -qx 'Environment=SPECTRE_BACKUP_ROLE=server' /etc/systemd/system/spectre-backup.service
check "system unit exec path matches install" grep -qx 'ExecStart=/root/.local/bin/spectre-backup.sh' /etc/systemd/system/spectre-backup.service
check "system unit is not the user unit" bash -c '! grep -qx "User=%u" "$1"' _ /etc/systemd/system/spectre-backup.service
check "daemon reloaded" grep -q 'daemon-reload' "$SYSTEMCTL_LOG"
check "timer enabled" grep -q 'enable spectre-backup.timer' "$SYSTEMCTL_LOG"
check "timer started" grep -q 'start spectre-backup.timer' "$SYSTEMCTL_LOG"

echo ""
echo "--- Unit file validation ---"
if systemd-analyze verify /etc/systemd/system/spectre-backup.service \
        /etc/systemd/system/spectre-backup.timer; then
    echo "  PASS: systemd-analyze verify"
    PASS=$((PASS + 1))
else
    echo "  FAIL: systemd-analyze verify"
    FAIL=$((FAIL + 1))
fi

# --- Real backup against throwaway repos ---
echo ""
echo "--- Backup run ---"
sed -i 's/^PG_ENABLED=.*/PG_ENABLED="false"/; s/^CONTAINERS_ENABLED=.*/CONTAINERS_ENABLED="false"/; s/^NOTIFY_ENABLED=.*/NOTIFY_ENABLED="false"/' /etc/spectre-backup/.env
printf 'RESTIC_REPOSITORY_LOCAL="/tmp/spectre-smoke-local"\n' >> /etc/spectre-backup/.env
printf '/etc/hostname\n' > /etc/spectre-backup/include.conf
printf '/etc/hostname\n' > /etc/spectre-backup/include-remote.conf

if SPECTRE_BACKUP_ROLE=server /root/.local/bin/spectre-backup.sh > "$WORK/backup.log" 2>&1; then
    echo "  PASS: backup exited 0"
    PASS=$((PASS + 1))
else
    echo "  FAIL: backup exited $?"
    tail -40 "$WORK/backup.log"
    FAIL=$((FAIL + 1))
fi

snapshot_tags() {
    restic -r "$1" --password-file /etc/spectre-backup/password snapshots --json 2>/dev/null \
        | jq -r '.[-1].tags // [] | sort | join(",")' 2>/dev/null || true
}
check "local snapshot tags" test "$(snapshot_tags /tmp/spectre-smoke-local)" = "server,spectre-backup"
check "offsite snapshot tags" test "$(snapshot_tags rclone:spectre-backup:)" = "server,spectre-backup"

# --- Health ---
echo ""
echo "--- Health ---"
SPECTRE_BACKUP_ROLE=server /root/.local/bin/spectre-backup.sh --health --json > "$WORK/health.json" 2> "$WORK/health.err" || true
check_jq "health sees the local snapshot" "$WORK/health.json" '.local.count >= 1'
check_jq "health sees the offsite snapshot" "$WORK/health.json" '.offsite.count >= 1'
check_jq "health reports local ok" "$WORK/health.json" '.local.status == "ok"'
check_jq "health reports offsite ok" "$WORK/health.json" '.offsite.status == "ok"'
check_jq "health reports server role" "$WORK/health.json" '.role == "server"'

# --- Summary ---
echo ""
echo "============================================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
