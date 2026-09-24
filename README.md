# fedora-back-up

Encrypted, automated, versioned backup platform for Fedora Linux workstations.

**Target: New laptop → Fully operational in under 2 hours**

## Architecture

```
  Fedora Workstation
      │
      ├── Filesystem (projects, config, documents)
      ├── PostgreSQL (pg_dumpall → compressed)
      └── Containers (compose files, quadlets, configs)
              │
              ▼
      Restic Backup Engine
         (AES-256 encryption)
              │
              ▼
      rclone → Google Drive
         (versioned snapshots)
```

## Requirements

- Fedora Workstation (or any modern Linux)
- Google Drive account (or any rclone-supported storage)
- `sudo` access for initial package installation

## Quick Install

```bash
# Clone or copy the fedora-back-up directory
cd fedora-back-up
./scripts/fedora-back-up-install.sh
```

The installer will:

1. Install packages: `restic`, `rclone`, `jq`
2. Create configuration at `~/.config/fedora-back-up/`
3. Guide you through rclone Google Drive authentication
4. Create the `ModelinkBackups/workstation` folder on Google Drive
5. Prompt for your Restic repository encryption password
6. Initialize the encrypted Restic repository
7. Install systemd service and timer
8. Offer to run a test backup

## Manual Configuration

### 1. Configure includes

Edit `~/.config/fedora-back-up/include.conf`:

```
/home/deon/Documents
/home/deon/Projects
/home/deon/.config
/home/deon/.ssh
/home/deon/.gnupg
/home/deon/.bashrc
/home/deon/.zshrc
/home/deon/.gitconfig
/etc
/opt
```

### 2. Configure excludes

Edit `~/.config/fedora-back-up/exclude.conf`:

```
node_modules
.venv
target/
dist/
.cache
Trash
*.iso
Steam
```

### 3. Configure environment

Edit `~/.config/fedora-back-up/.env`:

```bash
RESTIC_REPOSITORY="rclone:gdrive:ModelinkBackups/workstation"
PG_ENABLED="true"
NOTIFY_ENABLED="true"
```

## Usage

### Manual backup

```bash
fedora-back-up.sh
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

## Retention Policy

| Interval | Retention |
|----------|-----------|
| Hourly   | Last 24   |
| Daily    | Last 30   |
| Weekly   | Last 12   |
| Monthly  | Last 12   |
| Yearly   | Keep all  |

Pruning runs automatically after each backup.

## Scheduled Backups

A systemd timer runs daily at 04:00 (with random delay).

```bash
# Check timer status
systemctl --user status fedora-back-up.timer

# View last backup log
journalctl --user -u fedora-back-up.service -n 50

# Follow backup output
journalctl --user -u fedora-back-up.service -f
```

## Disaster Recovery Workflow

When replacing a lost laptop:

```
1. Install Fedora (minimal)             ~30 min
2. Install dependencies                 ~~~~5 min
     sudo dnf install -y restic rclone
3. Authenticate Google Drive            ~~~~5 min
     rclone config
4. Restore backup                       ~30 min
     fedora-back-up-restore.sh
5. Verify SSH/GPG keys                  ~~~~5 min
6. Install remaining packages           ~15 min
   (from restored config, you know what you need)
7. Restore PostgreSQL dumps             ~~~~5 min
8. Review container configs             ~~~~5 min
----------------------------------------------
Total:                              < 2 hours
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `fedora-back-up-install.sh` | One-time setup: packages, config, rclone auth, repo init, systemd |
| `fedora-back-up.sh` | Main backup engine: files + DB dumps + containers → Restic |
| `fedora-back-up-restore.sh` | Disaster recovery: restore everything from a snapshot |
| `fedora-back-up-verify.sh` | Integrity verification (quick or full) |
| `fedora-back-up-prune.sh` | Enforce retention policy with `restic forget` + `prune` |

## Logs

All logs are stored in `~/.local/state/fedora-back-up/`:

| File | Content |
|------|---------|
| `backup.log` | Each backup run output |
| `restore.log` | Restore operations |
| `verify.log` | Verification results |
| `cleanup.log` | Pruning operations |
| `error.log` | Error output |

## Security

- No credentials are hard-coded in scripts
- Restic repository password is stored in `~/.config/fedora-back-up/password` (chmod 600)
- All data is encrypted with AES-256 before leaving your machine
- Backup logs exclude sensitive content
- Environment templates (`.env.example`) contain no secrets
- PostgreSQL credentials are read from environment or `.env` file (chmod 600)

## File Layout

```
~/.config/fedora-back-up/
    .env              # Environment configuration
    password          # Restic repository password (chmod 600)
    include.conf      # Paths to include in backups
    exclude.conf      # Patterns to exclude

~/.local/state/fedora-back-up/
    backup.log        # Backup operation log
    verify.log        # Verification log
    cleanup.log       # Pruning log
    dumps/            # Pre-backup data dumps
        YYYYMMDD-HHMMSS/
            postgres.sql.gz
            containers/

~/.local/bin/
    fedora-back-up.sh    # Main backup script
    fedora-back-up-restore.sh   # Restore script
    fedora-back-up-verify.sh    # Verification script
    fedora-back-up-prune.sh     # Pruning script
```

## Custom Storage Backend

By default, backups go to Google Drive. To use a different backend:

1. Configure rclone: `rclone config`
2. Change `RESTIC_REPOSITORY` in `~/.config/fedora-back-up/.env`:

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
