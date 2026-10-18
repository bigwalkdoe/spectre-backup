# fedora-back-up

Encrypted, automated, versioned backup platform for Linux workstations and servers.

**Target: New machine → Fully operational in under 2 hours**

## Supported platforms

| Distro | Role | Install command |
|--------|------|-----------------|
| Fedora | Workstation | `./scripts/fedora-back-up-install.sh --role=workstation` |
| Fedora | Server | `./scripts/fedora-back-up-install.sh --role=server` |
| Ubuntu | Workstation | `./scripts/fedora-back-up-install.sh --role=workstation` |
| Ubuntu | Server | `./scripts/fedora-back-up-install.sh --role=server` |

Role is auto-detected if not specified: a graphical session means workstation, otherwise server.

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
# Clone or copy the fedora-back-up directory
cd fedora-back-up

# Workstation (default if a desktop session is detected)
./scripts/fedora-back-up-install.sh --role=workstation

# Server (system systemd service, runs as root)
./scripts/fedora-back-up-install.sh --role=server
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

Workstations install config to `~/.config/fedora-back-up/`. Servers install to `/etc/fedora-back-up/`.

```
~/.config/fedora-back-up/          (workstation)
/etc/fedora-back-up/               (server)
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
fedora-back-up.sh
```

### Health check

```bash
fedora-back-up.sh --health          # Human-readable
fedora-back-up.sh --health --json   # Machine-readable JSON
```

### View snapshots

```bash
fedora-back-up-restore.sh --list
```

### Restore from latest snapshot

```bash
fedora-back-up-restore.sh
```

### Restore from specific snapshot

```bash
fedora-back-up-restore.sh --snapshot=<snapshot-id>
```

### Verify repository integrity

```bash
# Quick check (structure only)
fedora-back-up-verify.sh

# Full check (reads all data - slower)
fedora-back-up-verify.sh --full
```

### Prune old snapshots

```bash
# Preview what would be removed
fedora-back-up-prune.sh --dry-run

# Apply retention policy
fedora-back-up-prune.sh
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
systemctl --user status fedora-back-up.timer
journalctl --user -u fedora-back-up.service -n 50
journalctl --user -u fedora-back-up.service -f
```

Server (system timer):
```bash
systemctl status fedora-back-up.timer
journalctl -u fedora-back-up.service -n 50
journalctl -u fedora-back-up.service -f
```

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
   ./scripts/fedora-back-up-install.sh
5. Restore backup                              ~30 min
   fedora-back-up-restore.sh
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
| `fedora-back-up-install.sh` | One-time setup: packages, config, rclone auth, repo init, systemd |
| `fedora-back-up.sh` | Main backup engine: files + DB dumps + containers → Restic |
| `fedora-back-up-restore.sh` | Disaster recovery: restore everything from a snapshot |
| `fedora-back-up-verify.sh` | Integrity verification (quick or full) |
| `fedora-back-up-prune.sh` | Enforce retention policy with `restic forget` + `prune` |
| `git-mirror.sh` | Mirror git history (without working trees) for backup |

## Logs

All logs are stored in `~/.local/state/fedora-back-up/` (workstations) or `/root/.local/state/fedora-back-up/` (servers):

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

By default, offsite backups go to Google Drive via the `fedora-back-up:` rclone remote. To use a different backend:

1. Configure rclone: `rclone config`
2. Change `RESTIC_REPOSITORY` in your `.env`:

```bash
# Examples:
RESTIC_REPOSITORY="rclone:s3:fedora-back-up/workstation"
RESTIC_REPOSITORY="rclone:dropbox:Backups/workstation"
RESTIC_REPOSITORY="rclone:wasabi:fedora-back-ups/workstation"
RESTIC_REPOSITORY="s3:https://.../bucket/workstation"
```

## Idempotency

All operations are safe to run repeatedly:

- `fedora-back-up-install.sh` - Won't overwrite existing config, password, or initialized repo
- `fedora-back-up.sh` - Restic deduplicates; identical files stored only once
- `fedora-back-up-restore.sh` - Overwrites existing files with backed-up versions
- `fedora-back-up-verify.sh` - Read-only; no side effects
- `fedora-back-up-prune.sh` - Only removes snapshots matching unused retention criteria

## File layout (installed)

```
~/.config/fedora-back-up/          (workstation config)
/etc/fedora-back-up/               (server config)
~/.local/state/fedora-back-up/     (logs, dumps, state)
    dumps/
        YYYYMMDD-HHMMSS/
            postgres.sql.gz
            containers/
~/.local/bin/                      (workstation scripts)
/root/.local/bin/                  (server scripts)
    fedora-back-up.sh
    fedora-back-up-restore.sh
    fedora-back-up-verify.sh
    fedora-back-up-prune.sh
    git-mirror.sh
```
