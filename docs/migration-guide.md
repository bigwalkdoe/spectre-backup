# Migration guide: spectre-backup

Two migrations live here:

1. **[Renaming from fedora-back-up to spectre-backup](#renaming-from-fedora-back-up-to-spectre-backup)** — the product name changed (2026-10-18)
2. **The layout migration below** — the original single-user Fedora workstation layout moving to the multi-distro, multi-role platform

## Renaming from fedora-back-up to spectre-backup

The tool was named after the single machine it started on. It now runs on
Fedora and Ubuntu, as workstations and servers, so the name changed to
`spectre-backup`. Nothing about the backup engine changed — same restic
engine, same scope, same retention.

### What the installer migrates automatically

Run the installer on the machine; before anything else it migrates a legacy
install in place:

```bash
./scripts/spectre-backup-install.sh --role=workstation
```

It will, logging each step:

- rename the rclone remote section `[fedora-back-up]` → `[spectre-backup]`
  in `~/.config/rclone/rclone.conf` (no remote data moves)
- move the local repository (e.g. `/backups/fedora-back-up` →
  `/backups/spectre-backup`) — same filesystem, so this is instant; the
  repository moves *before* `.env` is rewritten, so the path never points at
  a missing repository
- move `~/.config/fedora-back-up/` → `~/.config/spectre-backup/` and rewrite
  the old name inside every file there (`.env` paths, comments)
- move `~/.local/state/fedora-back-up/` → `~/.local/state/spectre-backup/`
  (logs and DB dumps travel with it)
- remove the old installed scripts (`~/.local/bin/fedora-back-up*.sh`,
  `backup-common.sh`, the `fedora-back-up` symlink)
- disable the old user timer, remove the old user unit files, reload systemd

Before touching anything it archives your legacy `.env` and `rclone.conf` to
`~/.local/state/spectre-backup/migration-backup-<timestamp>/` for rollback.

Safety rules the migration follows:

- **It never merges repositories.** If both the old and new paths exist, it
  stops and reports instead of guessing.
- **It never points `.env` at a missing repository.** If the old path is
  absent (an unmounted drive, for example), it stops rather than letting the
  next run initialize an empty repository.
- **It never touches your password.** The password file is archived for
  rollback but never rewritten.
- **It is idempotent.** An interrupted migration is finished by re-running
  the installer; completed steps are skipped.
- **Old snapshots keep their old tags.** Tags are immutable history; new
  snapshots are tagged `spectre-backup` plus the role.

### What stays manual (needs root)

Legacy *system-level* units from old deployments are never touched by the
installer — they need `sudo`, so it only prints the commands:

```bash
sudo systemctl disable --now fedora-back-up.timer
sudo rm -f /etc/systemd/system/fedora-back-up.service /etc/systemd/system/fedora-back-up.timer
sudo systemctl daemon-reload
```

Server-shaped old installs (`/etc/fedora-back-up`, system units) are not
automated either:

```bash
sudo mv /etc/fedora-back-up /etc/spectre-backup
# then install the new units from the repo (sudo cp systemd/spectre-backup*.{service,timer} /etc/systemd/system/)
sudo systemctl daemon-reload
```

> A leftover legacy system timer is harmless but noisy: it fires daily and
> fails instantly because it execs a script that no longer exists. Remove it
> with the three commands above.

The Google Drive folder's display name is cosmetic and unrelated — the rclone
remote is pinned by its `root_folder_id`, and no tooling reads the folder
name. Rename it in the Drive web UI if you like.

### Verify

```bash
rclone lsd spectre-backup:
spectre-backup.sh --health                       # expect OK
restic -r /backups/spectre-backup snapshots      # same snapshots as before
spectre-backup-restore.sh --list
systemctl --user list-timers spectre-backup.timer
```

Roll back with the archived copies in
`~/.local/state/spectre-backup/migration-backup-<timestamp>/` plus the reverse
directory moves if anything looks wrong.

## Layout migration: single-user workstation → multi-distro, multi-role

Moving from the original single-user Fedora workstation layout to the expanded
multi-distro, multi-role platform.

## What changed

| Area | Before | After |
|------|--------|-------|
| Distros | Fedora only (`dnf`) | Fedora (`dnf`) and Ubuntu (`apt`) |
| Roles | Workstation only | Workstation + server |
| Config location | `~/.config/fedora-back-up/` | `~/.config/spectre-backup/` (workstation) or `/etc/spectre-backup/` (server) |
| Config scope | Hardcoded `/home/<user>/...` paths | Role- and distro-specific scopes in `config/<role>/<distro>/` |
| Paths | `~/dev` (working trees) | `~/.git-mirror` (bare mirrors, history only) |
| systemd | User service only | User service (workstation) + system service (server) |
| Password | `~/.config/spectre-backup/password` | Same (workstation) or `/etc/spectre-backup/password` (server) |

## Step 1: Re-run the installer

The installer is idempotent — it won't overwrite existing config, password, or
the initialized repository. Just run it with your role:

```bash
# Workstation (this machine)
./scripts/spectre-backup-install.sh --role=workstation

# Server
./scripts/spectre-backup-install.sh --role=server
```

The installer will:

1. Detect your distro and pick `dnf` or `apt`
2. Install/update scripts and the shared library to `~/.local/bin/`
3. Copy role- and distro-specific config to `~/.config/spectre-backup/` (or `/etc/spectre-backup/` for servers)
4. Keep your existing `.env`, `include.conf`, `exclude.conf`, and `password` (not overwritten)
5. Install the appropriate systemd unit (user for workstation, system for server)
6. Start the daily timer

> **Clean up a stale installer copy if one exists.** The installer now runs from
> the repo checkout and does not install itself. Some old deployments left a
> copy at `~/.local/bin/fedora-back-up-install.sh`; it cannot work from there
> (it needs the repo's `lib/`, `config/`, and `systemd/` trees) and would
> reinstall the old single-machine layout if it ever ran. Remove it:
>
> ```bash
> rm -f ~/.local/bin/fedora-back-up-install.sh
> ```

## Step 2: Review your config

Your existing config files were preserved, but you should review them against the
new role-specific defaults:

```bash
# Workstation
diff config/workstation/fedora/include.conf  ~/.config/spectre-backup/include.conf
diff config/workstation/fedora/exclude.conf  ~/.config/spectre-backup/exclude.conf
diff config/workstation/fedora/include-remote.conf  ~/.config/spectre-backup/include-remote.conf
```

Key changes to consider:

- **`~/.git-mirror` is now included** instead of `~/dev` working trees. The git mirror is refreshed before each backup, so history (including unpushed commits) is protected without copying 20 GiB of working trees.
- **`/etc` and `/opt` are commented out** by default. Uncomment them in `include.conf` deliberately — they roughly triple snapshot size.
- **`exclude.conf` now drops derived content** (Chrome AI model, VS Code extension cache, opencode state, Baloo index, core dumps) — about 10.8 GiB saved per snapshot.
- **Offsite scope is separate** (`include-remote.conf`). Only irreplaceable small data goes to Google Drive (keys, dotfiles, editor config). The rest is local-only.

If you previously had `~/dev` in your includes, you can remove it — `~/.git-mirror` replaces it for history protection.

## Step 3: Verify everything works

```bash
# Run a backup
~/.local/bin/spectre-backup.sh

# Check health
~/.local/bin/spectre-backup.sh --health

# List snapshots
~/.local/bin/spectre-backup-restore.sh --list

# Verify repository
~/.local/bin/spectre-backup-verify.sh
```

## Step 4: Update any cron jobs or external references

If you had external cron entries or scripts calling the old backup paths,
update them to the new locations:

```bash
# Scripts: same location, new names
~/.local/bin/spectre-backup.sh
~/.local/bin/spectre-backup-restore.sh

# Config: same location for workstations
~/.config/spectre-backup/.env

# Servers: system service instead of user service
systemctl status spectre-backup.timer   # instead of systemctl --user
journalctl -u spectre-backup.service    # instead of journalctl --user
```

## Rollback

The installer never deletes your config, password, or repository. If something
goes wrong:

1. Scripts in `~/.local/bin/` were replaced by the installer. The previous versions are in the repo's git history (`git log -- scripts/`) if you need to restore them
2. Your old config in `~/.config/spectre-backup/` was not overwritten
3. Your restic repository and password are untouched
4. The systemd timer can be disabled: `systemctl --user disable spectre-backup.timer`

## Compatibility matrix

| Old behavior | New behavior | Action needed |
|--------------|--------------|---------------|
| `fedora-back-up.sh` in `~/.local/bin/` | `spectre-backup.sh`, same path | None — installer migrates it |
| `fedora-back-up-install.sh` in `~/.local/bin/` | Installer runs from the repo checkout | Remove the stale copy |
| `~/dev` in include.conf | `~/.git-mirror` in include.conf | Update include.conf |
| User systemd only | User + system systemd | Servers need `--role=server` |
| Hardcoded distro (Fedora/dnf) | Auto-detect (Fedora/Ubuntu) | None |
| All data to Drive | Local full + Drive subset | Review include-remote.conf |
