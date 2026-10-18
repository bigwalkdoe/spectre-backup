# Rename `fedora-back-up` → `spectre-backup`

Date: 2026-10-18
Status: awaiting review

## Intent

The tool started as a single-user Fedora-workstation backup script, so it was
named after both things. It now runs on Fedora and Ubuntu, as workstations and
as servers, and the GitHub repository has already been renamed to
`spectre-backup`. The `fedora-` prefix is wrong on every Ubuntu machine and
misleading everywhere else.

Directive from the owner: **rename everything.** Nothing in the tool's
surface, its installed footprint, or its live data on this machine should
still say `fedora-back-up` when this is done.

## Goals

- Zero `fedora-back-up` / `FEDORA_BACK_UP` references in scripts, library,
  systemd units, config trees, and tests. Docs describe the new name and
  document the migration path.
- This machine's live install is fully renamed: config dir, state dir, local
  repository directory, rclone remote section, installed scripts, user units.
- Backups continue to work across the migration: the same restic snapshots
  stay accessible in both repositories, and the timer keeps its schedule.
- The migration is repeatable: it is driven by the installer, so the Ubuntu
  machine converts the same way with the same code path.

## Non-goals and anti-goals

Non-goals:

- Historical snapshots keep their old tags — snapshot tags are immutable
  history and new snapshots simply use the new tag.
- The machine's hostname (`fedora`) is unrelated and stays.
- The Google Drive folder's *display name* is invisible to all tooling (the
  remote is pinned by `root_folder_id`); it can be renamed by hand in the web
  UI if desired, and nothing in the system depends on it.
- Unrelated user tooling that happens to reference the old name.

Anti-goals (would make this a failure even if it "works"):

- Any data loss, or a restic repository being re-initialized because a path
  was rewritten without moving the directory first.
- Two backup timers racing (old and new) or a window where neither exists.
- Partial migration that leaves `.env` pointing at paths that no longer exist.
- A half-renamed repo that later machines then migrate inconsistently.

## Constraints

- No sudo passwordless on this machine: the legacy **system**-level units in
  `/etc/systemd/system/` (a pre-rewrite leftover that fails daily with
  203/EXEC) must be removed by the owner with a prepared command. Everything
  else works in user space.
- `/backups` and `/backups/fedora-back-up` are owned by the user and on the
  same filesystem: the 56 GB repository renames in place with `mv` (metadata
  only, instant).
- The rclone remote is a single section (`[fedora-back-up]`, `type=drive`,
  `root_folder_id`); renaming the section touches no remote data.
- Restic repositories are self-contained; only `.env` names their location.
- The currently installed user timer must keep working until the replacement
  units are in place (no gap), and the next run is not due until tomorrow
  04:35 PKT.

## Decisions (owner-approved)

- **Rename everything**, product name `spectre-backup`.
- **No compatibility aliases** — old command names stop existing; the
  migration guide is the bridge.
- **Library** becomes `spectre-backup-common.sh`.
- **Legacy root config files** (`config/include.conf`, `config/exclude.conf`,
  `config/include-remote.conf`) are deleted; the `<role>/<distro>` trees
  supersede them and git history keeps them.
- **The installer performs the legacy migration** (detect, move, rewrite,
  clean) so every machine converts by running it; sudo-only leftovers are
  printed as exact commands.
- New snapshots are tagged `spectre-backup` + role; historical tags stay.

## Rename map (repository)

| Old | New |
|-----|-----|
| `scripts/fedora-back-up.sh` | `scripts/spectre-backup.sh` |
| `scripts/fedora-back-up-install.sh` | `scripts/spectre-backup-install.sh` |
| `scripts/fedora-back-up-restore.sh` | `scripts/spectre-backup-restore.sh` |
| `scripts/fedora-back-up-verify.sh` | `scripts/spectre-backup-verify.sh` |
| `scripts/fedora-back-up-prune.sh` | `scripts/spectre-backup-prune.sh` |
| `scripts/git-mirror.sh` | unchanged name (content refs updated) |
| `lib/backup-common.sh` | `lib/spectre-backup-common.sh` |
| `systemd/fedora-back-up.service` | `systemd/spectre-backup.service` |
| `systemd/fedora-back-up.timer` | `systemd/spectre-backup.timer` |
| `systemd/fedora-back-up-system.service` | `systemd/spectre-backup-system.service` |
| `FEDORA_BACK_UP_ROLE` | `SPECTRE_BACKUP_ROLE` |
| `config/<role>/<distro>/*` | same filenames, updated content |
| `config/.env.example` | same filename, updated defaults |
| `config/include.conf` et al. | deleted (superseded) |
| README, migration guide, tests | updated; tests gain naming guards |

Renames use `git mv` so history follows. Message strings, log prefixes,
notification titles, unit descriptions, and headers all change with it.

New snapshot tag set: `spectre-backup`, plus the role (`workstation` or
`server`) — same shape as today, new product token.

## Live migration (this machine)

The new installer detects a legacy install and migrates it. Ordering is
chosen so the repository is always reachable at the path `.env` names:

1. **Pre-flight** — confirm no backup is running and the timer's next fire is
   in the future; archive copies of `.env` and `rclone.conf` into the state
   dir (`migration-backup-<timestamp>/`) for rollback.
2. **Stop the old schedule** — `systemctl --user disable --now
   fedora-back-up.timer`. Old unit files remain until the replacements are
   installed (no gap for the new units).
3. **Rename the rclone section** — rewrite `[fedora-back-up]` →
   `[spectre-backup]` in `~/.config/rclone/rclone.conf`; verify with
   `rclone lsd spectre-backup:`.
4. **Move the local repository** — `mv /backups/fedora-back-up
   /backups/spectre-backup`, *before* any `.env` rewrite (anti-goal: path
   rewritten while data stayed behind). Skip with a loud warning if the
   target already exists (never merge repositories).
5. **Move the config dir** — `mv ~/.config/fedora-back-up
   ~/.config/spectre-backup`, then rewrite references inside all files
   (`RESTIC_REPOSITORY`, `RESTIC_REPOSITORY_LOCAL`, `LOG_DIR`, comments,
   including the `deliberately excluded from offsite` note).
6. **Move the state dir** — `mv ~/.local/state/fedora-back-up
   ~/.local/state/spectre-backup` (logs and dumps travel with it).
7. **Replace installed scripts** — remove old `fedora-back-up*` and
   `backup-common.sh` from `~/.local/bin`, install the renamed set plus
   `spectre-backup-common.sh` and the `spectre-backup` symlink.
8. **Replace user units** — remove old unit files from
   `~/.local/share/systemd/user/`, install and enable the renamed ones,
   `daemon-reload`, verify the timer is armed.
9. **Legacy system units (owner, with sudo)** — `systemctl disable --now`
   and remove `/etc/systemd/system/fedora-back-up.{service,timer}`; they have
   failed daily since 24 Sep and protect nothing.
10. **Verify** — `rclone lsd`, `restic snapshots` on both repositories,
    `spectre-backup.sh --health`, then a manual backup run; the new snapshot
    must carry the new tags and the old snapshots must still be listed.

Migration logic rules: only act when the legacy shape is *exactly* present
(old dir exists, new does not); every step is idempotent; every action is
logged with before/after; if any step cannot be completed safely, stop and
report rather than half-migrate.

Rollback: archived `.env` + `rclone.conf` copies, reverse `mv`s, and git
history for the repo side. The old timer is only finally removed once the new
units are enabled.

## Verification plan

- Test suite (renamed) passes; new guards assert the old tokens are absent
  from scripts/lib/systemd/config and that migration strings are present.
- Installer migration exercised against synthetic legacy state (a fake old
  config dir + `.env` + bin scripts) in the test suite, including the
  safety skips (target exists, partial state).
- On this machine: the full ordered sequence above, ending with a real backup
  whose new snapshot is visible in both repositories with new tags.

## Left to the builder

- Exact installer implementation (function boundaries, logging text).
- Test-vector list and commit slicing.
- Whether the migration write-up lives only in the migration guide or also as
  a section in the README (a short pointer is planned).
