# Migration guide: fedora-back-up

Moving from the original single-user Fedora workstation layout to the expanded
multi-distro, multi-role platform.

## What changed

| Area | Before | After |
|------|--------|-------|
| Distros | Fedora only (`dnf`) | Fedora (`dnf`) and Ubuntu (`apt`) |
| Roles | Workstation only | Workstation + server |
| Config location | `~/.config/fedora-back-up/` | `~/.config/fedora-back-up/` (workstation) or `/etc/fedora-back-up/` (server) |
| Config scope | Hardcoded `/home/deon/...` paths | Role- and distro-specific scopes in `config/<role>/<distro>/` |
| Paths | `/home/deon/dev` (working trees) | `~/.git-mirror` (bare mirrors, history only) |
| systemd | User service only | User service (workstation) + system service (server) |
| Password | `~/.config/fedora-back-up/password` | Same (workstation) or `/etc/fedora-back-up/password` (server) |

## Step 1: Re-run the installer

The installer is idempotent — it won't overwrite existing config, password, or
the initialized repository. Just run it with your role:

```bash
# Workstation (this machine)
./scripts/fedora-back-up-install.sh --role=workstation

# Server
./scripts/fedora-back-up-install.sh --role=server
```

The installer will:

1. Detect your distro and pick `dnf` or `apt`
2. Install/update scripts and the shared library to `~/.local/bin/`
3. Copy role- and distro-specific config to `~/.config/fedora-back-up/` (or `/etc/fedora-back-up/` for servers)
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
diff config/workstation/fedora/include.conf  ~/.config/fedora-back-up/include.conf
diff config/workstation/fedora/exclude.conf  ~/.config/fedora-back-up/exclude.conf
diff config/workstation/fedora/include-remote.conf  ~/.config/fedora-back-up/include-remote.conf
```

Key changes to consider:

- **`~/.git-mirror` is now included** instead of `~/dev` working trees. The git mirror is refreshed before each backup, so history (including unpushed commits) is protected without copying 20 GiB of working trees.
- **`/etc` and `/opt` are commented out** by default. Uncomment them in `include.conf` deliberately — they roughly triple snapshot size.
- **`exclude.conf` now drops derived content** (Chrome AI model, VS Code extension cache, opencode state, Baloo index, core dumps) — about 10.8 GiB saved per snapshot.
- **Offsite scope is separate** (`include-remote.conf`). Only irreplaceable small data goes to Google Drive (keys, dotfiles, editor config). The rest is local-only.

If you previously had `/home/deon/dev` in your includes, you can remove it — `~/.git-mirror` replaces it for history protection.

## Step 3: Verify everything works

```bash
# Run a backup
~/.local/bin/fedora-back-up.sh

# Check health
~/.local/bin/fedora-back-up.sh --health

# List snapshots
~/.local/bin/fedora-back-up-restore.sh --list

# Verify repository
~/.local/bin/fedora-back-up-verify.sh
```

## Step 4: Update any cron jobs or external references

If you had external cron entries or scripts calling the old backup paths,
update them to the new locations:

```bash
# Old (user scripts directory)
~/.local/bin/fedora-back-up.sh   # unchanged location

# Old config
~/.config/fedora-back-up/.env    # unchanged for workstations

# New: system service (servers only)
systemctl status fedora-back-up.timer   # instead of systemctl --user
journalctl -u fedora-back-up.service    # instead of journalctl --user
```

## Rollback

The installer never deletes your config, password, or repository. If something
goes wrong:

1. Scripts in `~/.local/bin/` were replaced by the installer. The previous versions are in the repo's git history (`git log -- scripts/`) if you need to restore them
2. Your old config in `~/.config/fedora-back-up/` was not overwritten
3. Your restic repository and password are untouched
4. The systemd timer can be disabled: `systemctl --user disable fedora-back-up.timer`

## Compatibility matrix

| Old behavior | New behavior | Action needed |
|--------------|--------------|---------------|
| `fedora-back-up.sh` in `~/.local/bin/` | Same path, new content | None — auto-updated by installer |
| `fedora-back-up-install.sh` in `~/.local/bin/` | Installer runs from the repo checkout | Remove the stale copy |
| `~/dev` in include.conf | `~/.git-mirror` in include.conf | Update include.conf |
| User systemd only | User + system systemd | Servers need `--role=server` |
| Hardcoded distro (Fedora/dnf) | Auto-detect (Fedora/Ubuntu) | None |
| All data to Drive | Local full + Drive subset | Review include-remote.conf |
