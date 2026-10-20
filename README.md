# spectre-backup

[![tests](https://github.com/bigwalkdoe/spectre-backup/actions/workflows/tests.yml/badge.svg)](https://github.com/bigwalkdoe/spectre-backup/actions/workflows/tests.yml)

Encrypted, automated, versioned backup platform for Linux workstations and servers.

**Target: New machine → Fully operational in under 2 hours**

## Supported platforms

| Distro | Role | Install command |
|--------|------|-----------------|
| Fedora | Workstation | `./scripts/spectre-backup-install.sh --role=workstation` |
| Fedora | Server | `sudo ./scripts/spectre-backup-install.sh --role=server` |
| Ubuntu | Workstation | `./scripts/spectre-backup-install.sh --role=workstation` |
| Ubuntu | Server | `sudo ./scripts/spectre-backup-install.sh --role=server` |

Role is auto-detected if not specified: a graphical session means workstation, otherwise server. Override with `--role=workstation|server` or the `SPECTRE_BACKUP_ROLE` environment variable.

Already running the original single-machine install? See [`docs/migration-guide.md`](docs/migration-guide.md).

Upgrading from the old `fedora-back-up` name? The installer migrates a legacy
install automatically — see [Renaming from fedora-back-up to spectre-backup](docs/migration-guide.md#renaming-from-fedora-back-up-to-spectre-backup).

## Architecture

```
  Linux Machine (workstation or server)
      │
      ├── Filesystem (projects, config, documents, /etc, /opt, /var)
      ├── PostgreSQL (pg_dumpall → compressed)
      └── Containers (Docker compose, Podman quadlets, configs)
              │
              ▼
      Restic Backup Engine
     (AES-256 encryption, deduplication)
              │
              ├── Local repository (full scope, fast)
              └── rclone → Offsite storage (Google Drive, S3, etc.)
                     (small, irreplaceable scope only)
```

Dual-repository design: the local repository holds everything; the offsite repository carries only what fits your quota and cannot be regenerated (SSH/GPG keys, dotfiles, system config). A broken offsite remote degrades gracefully — the local backup still runs.

## Requirements

- Fedora or Ubuntu
- Google Drive account (or any rclone-supported storage)
- `sudo` access for initial package installation

## Quick Install

```bash
# Clone the repository
git clone https://github.com/bigwalkdoe/spectre-backup.git
cd spectre-backup

# Workstation (default if a desktop session is detected)
./scripts/spectre-backup-install.sh --role=workstation

# Server (system systemd service, runs as root — install with sudo)
sudo ./scripts/spectre-backup-install.sh --role=server
```

The installer will:

1. Detect distro (Fedora → `dnf`, Ubuntu → `apt`)
2. Install packages: `restic`, `rclone`, `jq`
3. Create configuration (role- and distro-specific scopes)
4. Guide you through rclone offsite storage authentication
5. Prompt for your Restic repository encryption password
6. Initialize the encrypted Restic repository
7. Install systemd service and timer (user service for workstations, system service for servers)
8. Offer to run a test backup

## Configuration layout

Workstations install config to `~/.config/spectre-backup/`. Servers install to `/etc/spectre-backup/`.

```
~/.config/spectre-backup/          (workstation)
/etc/spectre-backup/               (server)
    .env             # Environment configuration
    password         # Restic repository password (chmod 600)
    include.conf     # Paths to include in backups
    exclude.conf     # Patterns to exclude
    include-remote.conf  # Offsite scope (small, fits quota)
```

Config is selected by role and distro: `config/<role>/<distro>/`. Falls back to `config/defaults/` when no match exists.

## Usage

### Manual backup

```bash
spectre-backup.sh
```

### Health check

```bash
spectre-backup.sh --health          # Human-readable
spectre-backup.sh --health --json   # Machine-readable JSON
```

Exit codes make it suitable for monitoring (cron, systemd OnFailure, uptime checks): `0` = ok, `1` = degraded, `2` = failed.

| Signal | ok | degraded | failed |
|--------|-----|----------|--------|
| Local snapshot age | ≤ 26h | > 26h | > 48h |
| Offsite snapshot age | ≤ 36h | > 36h | > 72h |
| Local disk free | ≥ 25 GiB | < 25 GiB | < 15 GiB |
| Offsite quota used | ≤ 85% | > 85% | > 95% |

### View snapshots

```bash
spectre-backup-restore.sh --list
```

Snapshots are tagged `spectre-backup` plus the role (`workstation` or `server`), for example `restic snapshots --tag server`.

### Restore from latest snapshot

```bash
spectre-backup-restore.sh
```

### Restore from specific snapshot

```bash
spectre-backup-restore.sh --snapshot=<snapshot-id>
```

### Rehearse a restore

```bash
spectre-backup-restore.sh --snapshot=<snapshot-id> --dry-run
```

### Verify repository integrity

```bash
# Quick check (structure only)
spectre-backup-verify.sh

# Full check (reads all data - slower)
spectre-backup-verify.sh --full
```

### Prune old snapshots

```bash
# Preview what would be removed
spectre-backup-prune.sh --dry-run

# Apply retention policy
spectre-backup-prune.sh
```

## Retention policy

| Interval | Retention |
|----------|-----------|
| Hourly   | Last 24   |
| Daily    | Last 30   |
| Weekly   | Last 12   |
| Monthly  | Last 12   |
| Yearly   | Keep all  |

Pruning runs automatically after each backup.

## Scheduled backups

A systemd timer runs daily at 04:00 (with up to 1h random delay).

Workstation (user timer):
```bash
systemctl --user status spectre-backup.timer
journalctl --user -u spectre-backup.service -n 50
journalctl --user -u spectre-backup.service -f
```

Server (system timer):
```bash
systemctl status spectre-backup.timer
journalctl -u spectre-backup.service -n 50
journalctl -u spectre-backup.service -f
```

## Troubleshooting

**`repository is already locked`**
A run was interrupted (machine slept or was shut down mid-backup) and left a lock behind. Every backup and prune now heals stale locks before it starts — `restic unlock`, which removes only locks whose owning process is gone, so a backup that is genuinely running is never disturbed. If you want to clear them by hand:

```bash
restic -r <repository> unlock
```

**Google Drive `rateLimitExceeded` / HTTP 403**
A transient Google-side quota. The offsite leg retries with backoff and normally completes; repeated occurrences only slow the backup down. Check the remote itself with:

```bash
rclone lsd spectre-backup:
```

**"Backup Degraded" notification**
The offsite remote was unreachable, so only the local repository was updated — the local backup is complete and intact. Confirm with `spectre-backup.sh --health` once the remote is back, then run `spectre-backup.sh` to catch the offsite leg up.

## Disaster recovery workflow

When replacing a lost machine:

```
1. Install Fedora or Ubuntu (minimal)         ~30 min
2. Install dependencies                        ~~~~5 min
   Fedora:  sudo dnf install -y restic rclone
   Ubuntu:  sudo apt-get install -y restic rclone jq
3. Authenticate offsite storage                ~~~~5 min
   rclone config
4. Run the installer                           ~~~~5 min
   ./scripts/spectre-backup-install.sh
5. Restore backup                              ~30 min
   spectre-backup-restore.sh
6. Verify SSH/GPG keys                         ~~~~5 min
7. Install remaining packages                  ~15 min
8. Restore PostgreSQL dumps                    ~~~~5 min
9. Review container configs                    ~~~~5 min
----------------------------------------------
Total:                                    < 2 hours
```

## Scripts reference

| Script | Purpose |
|--------|---------|
| `spectre-backup-install.sh` | One-time setup: packages, config, rclone auth, repo init, systemd |
| `spectre-backup.sh` | Main backup engine: files + DB dumps + containers → Restic |
| `spectre-backup-restore.sh` | Disaster recovery: restore everything from a snapshot |
| `spectre-backup-verify.sh` | Integrity verification (quick or full) |
| `spectre-backup-prune.sh` | Enforce retention policy with `restic forget` + `prune` |
| `git-mirror.sh` | Mirror git history (without working trees) for backup |
| `spectre-backup-common.sh` | Shared library: distro/role detection, package install, config loading |

## Logs

All logs are stored in `~/.local/state/spectre-backup/` (workstations) or `/root/.local/state/spectre-backup/` (servers):

| File | Content |
|------|---------|
| `backup.log` | Each backup run output |
| `restore.log` | Restore operations |
| `verify.log` | Verification results |
| `cleanup.log` | Pruning operations |
| `error.log` | Error output |

## Security

- No credentials are hard-coded in scripts
- Restic repository password is stored in the config directory (chmod 600)
- All data is encrypted with AES-256 before leaving your machine
- Backup logs exclude sensitive content
- Environment templates (`.env.example`) contain no secrets
- The config directory holding the password is deliberately **excluded** from the offsite backup, so offsite storage access alone cannot unlock your backups

## Custom storage backend

By default, offsite backups go to Google Drive via the `spectre-backup:` rclone remote. To use a different backend:

1. Configure rclone: `rclone config`
2. Change `RESTIC_REPOSITORY` in your `.env`:

```bash
# Examples (the part after the colon is your bucket/folder name):
RESTIC_REPOSITORY="rclone:s3:my-backup-bucket/workstation"
RESTIC_REPOSITORY="rclone:dropbox:Backups/workstation"
RESTIC_REPOSITORY="rclone:wasabi:my-backup-bucket/workstation"
RESTIC_REPOSITORY="s3:https://.../bucket/workstation"
```

## Idempotency

All operations are safe to run repeatedly:

- `spectre-backup-install.sh` - Won't overwrite existing config, password, or initialized repo
- `spectre-backup.sh` - Restic deduplicates; identical files stored only once
- `spectre-backup-restore.sh` - Overwrites existing files with backed-up versions
- `spectre-backup-verify.sh` - Read-only; no side effects
- `spectre-backup-prune.sh` - Only removes snapshots matching unused retention criteria

## File layout (installed)

```
~/.config/spectre-backup/          (workstation config)
/etc/spectre-backup/               (server config)
~/.local/state/spectre-backup/     (logs, dumps, state)
    dumps/
        YYYYMMDD-HHMMSS/
            postgres.sql.gz
            containers/
~/.local/bin/                      (workstation scripts)
/root/.local/bin/                  (server scripts)
    spectre-backup.sh
    spectre-backup-restore.sh
    spectre-backup-verify.sh
    spectre-backup-prune.sh
    git-mirror.sh
    spectre-backup-common.sh
```

The installer itself is not copied to `~/.local/bin/` — run it from the repo checkout.

## Testing

```bash
./tests/run-tests.sh
```

The suite prints its own totals. It covers distro and role detection, config
coverage for every role/distro combination, restic output parsing, snapshot
tags, systemd units, naming guards (the old product name must not reappear),
the legacy-install migration against synthetic fixtures (including ambiguous
state, idempotent re-runs, and a broken `systemctl`), and shellcheck
compliance.
