# Rename fedora-back-up → spectre-backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the whole product from `fedora-back-up` to `spectre-backup` — repo, installed footprint, and this machine's live data — with an installer-driven, idempotent migration for legacy installs.

**Architecture:** Three code changes first — (1) the mechanical rename plus naming-guard tests, (2) a new `lib/migrate-legacy.sh` that the installer runs before anything else, with a sandboxed test group, (3) docs rewritten around the new name — then (4) executing that migration on this machine and (5) verifying end-to-end. No functional behavior changes beyond the rename and the migration.

**Tech Stack:** bash, restic 0.17.3, rclone, systemd (user units), jq, coreutils/grep/sed.

**Spec:** `docs/superpowers/specs/2026-10-18-rename-to-spectre-backup-design.md` (the plan argues from the spec; both travel together).

**Execution method:** Native — the owner directed "execute"; the implementer is this session.

## Global Constraints

- New product token `spectre-backup` everywhere; env var `SPECTRE_BACKUP_ROLE`; old tokens `fedora-back-up`, `FEDORA_BACK_UP`, `fedora_back_up` must not remain in `scripts/`, `lib/`, `systemd/`, `config/` (docs may name the old name only where describing migration).
- Exact renamed files: `scripts/spectre-backup.sh`, `scripts/spectre-backup-install.sh`, `scripts/spectre-backup-restore.sh`, `scripts/spectre-backup-verify.sh`, `scripts/spectre-backup-prune.sh`, `lib/spectre-backup-common.sh`, `systemd/spectre-backup.service`, `systemd/spectre-backup.timer`, `systemd/spectre-backup-system.service`. `scripts/git-mirror.sh` keeps its name.
- Live paths after migration: `~/.config/spectre-backup/`, `~/.local/state/spectre-backup/`, `/backups/spectre-backup`, rclone remote `spectre-backup:`, system config `/etc/spectre-backup`.
- New snapshots tagged `spectre-backup` + `$ROLE`; historical snapshots and their tags are untouched.
- No compatibility aliases.
- Automated migration covers the workstation shape only; server-shaped leftovers are printed as exact sudo commands, never executed by the installer.
- Migration is idempotent; ambiguous state (old and new both present, or the repo target already exists) aborts before acting; repositories are never merged.
- Test suite must end with `FAIL=0`; shellcheck reports no errors (warnings tolerated, per suite policy).
- Commits: conventional style, e.g. `refactor:`, `feat(installer):`, `docs:`.

## Review Focus

Five failure modes the spec implies; each gets a test in the named task.

1. Re-run / partially-completed migration must complete cleanly, never double-migrate (test: Task 2 — re-run is a no-op; leftovers cleaned without legacy config).
2. Ambiguous state (old and new both present, repo target exists) must abort before touching anything (test: Task 2 — both-exist fixtures assert nothing moved).
3. `.env` variants — offsite-only (no `RESTIC_REPOSITORY_LOCAL`) or a differently-named remote — must not invent moves (test: Task 2 — custom/offsite fixture asserts remote file and dirs untouched).
4. A broken `systemctl` must not fail the migration (test: Task 2 — failing stub, migration returns 0, files still cleaned).
5. The new snapshot tag shape must survive the rename — product tag `spectre-backup` plus role, no hardcoded role (test: Task 1 — naming-guard group asserts `--tag "spectre-backup"` and `--tag "$ROLE"` present).

---

### Task 1: Mechanical rename + naming guards

**Files:**
- Rename (via `git mv`): the nine files listed in Global Constraints.
- Modify: contents of all files under `scripts/`, `lib/`, `systemd/`, `config/`; `tests/run-tests.sh`.
- Delete: `config/include.conf`, `config/exclude.conf`, `config/include-remote.conf`.

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the new file names and `SPECTRE_BACKUP_ROLE` that every later task references; the "Naming guards" test group; `lib/*.sh scripts/*.sh` loops in the suite (so later lib files are covered automatically).

- [ ] **Step 1: Add the failing naming-guard group** to `tests/run-tests.sh` (insert before the Summary section). Guards, in the suite's existing PASS/FAIL style:
  - straggler scan: `grep -rEn 'fedora-back-up|FEDORA_BACK_UP|fedora_back_up' "$PROJECT_DIR/scripts" "$PROJECT_DIR/lib" "$PROJECT_DIR/systemd" "$PROJECT_DIR/config"` must produce no output (scan excludes `tests/` so the guard's own pattern text cannot self-match).
  - new file set: loop `for f in scripts/spectre-backup.sh scripts/spectre-backup-install.sh scripts/spectre-backup-restore.sh scripts/spectre-backup-verify.sh scripts/spectre-backup-prune.sh lib/spectre-backup-common.sh systemd/spectre-backup.service systemd/spectre-backup.timer systemd/spectre-backup-system.service` with `assert_file_exists`.
  - legacy library name: `grep -rn 'backup-common\.sh' scripts lib systemd tests | grep -v 'spectre-backup-common\.sh'` must produce no output.
  - product tag present: `grep -q -- '--tag "spectre-backup"' "$PROJECT_DIR/scripts/spectre-backup.sh"`.
- [ ] **Step 2: Run the suite and verify the guards fail** — `./tests/run-tests.sh`; expect FAIL lines for the guard group (old tokens present, new files missing).
- [ ] **Step 3: Rename with `git mv`** the nine files to their new names.
- [ ] **Step 4: Token replacement** across `scripts/ lib/ systemd/ config/` using the file list captured first (`grep -rIl .` then `xargs sed -i`), in this order:
  1. `s/FEDORA_BACK_UP/SPECTRE_BACK_UP/g`
  2. `s/fedora-back-up/spectre-backup/g`
  3. library reference, run-once safe: `s/spectre-backup-common\.sh/@@LIB@@/g; s/backup-common\.sh/spectre-backup-common.sh/g; s/@@LIB@@/spectre-backup-common.sh/g` (protects against double substitution).
  Then audit: `grep -rEn 'fedora-back-up|FEDORA_BACK_UP' scripts lib systemd config` must be empty (expect only hits, then zero after fixing stragglers; `systemd/` Documentation URLs already say `spectre-backup`).
- [ ] **Step 5: Same token replacement in `tests/run-tests.sh`**, plus change the two loops `for script in lib/backup-common.sh scripts/*.sh` (syntax + shellcheck groups) to `for script in lib/*.sh scripts/*.sh` so future lib files are covered.
- [ ] **Step 6: Delete the superseded root config files** — `git rm config/include.conf config/exclude.conf config/include-remote.conf`.
- [ ] **Step 7: Run the suite — expect all PASS (`FAIL=0`).** Fix any straggler the guards find.
- [ ] **Step 8: Audit the diff** — `git status` + `git diff --stat -M` (renames detected), `bash -n` on renamed scripts.
- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: rename fedora-back-up to spectre-backup everywhere"
```

### Task 2: Legacy migration — `lib/migrate-legacy.sh` (TDD)

**Files:**
- Create: `lib/migrate-legacy.sh`
- Modify: `scripts/spectre-backup-install.sh` (source it; call it between role detection and `resolve_dirs`; skip when `--bin-only`)
- Modify: `tests/run-tests.sh` (source the new lib; new "Legacy migration" group + sandbox helpers)

**Interfaces:**
- Consumes: names from Task 1; `info/warn/error` from `lib/spectre-backup-common.sh` (installer sources common first, then migrate).
- Produces: `migrate_legacy_install()` — no arguments; reads `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`; all reads defaulted (suite runs `set -u`). Returns `0` = safe to continue (migrated / leftover-cleanup done / nothing to do) or `1` = ambiguous state, stop, reason printed. Rollback archive: `$XDG_STATE_HOME/spectre-backup/migration-backup-<YYYYmmdd-HHMMSS>/`. Test helpers (same file): `make_legacy_sandbox`, `teardown_legacy_sandbox`, `assert_not_exists`.

**Ordered algorithm (spec §Live migration steps 2–9, adapted):**

1. Detect: `$XDG_CONFIG_HOME/fedora-back-up` exists? and `$XDG_CONFIG_HOME/spectre-backup` exists? Both → abort(1), nothing touched. Legacy only → run moves. Neither → "nothing to migrate", but still run step 8–9 checks (leftovers).
2. Read legacy `.env` values (`RESTIC_REPOSITORY`, `RESTIC_REPOSITORY_LOCAL`) before any move.
3. Repo-path validation: `old_repo` = value of `RESTIC_REPOSITORY_LOCAL`; `new_repo` = same value with `fedora-back-up` → `spectre-backup`. If `old_repo` exists and `new_repo` exists → abort(1). (`old_repo` missing → nothing to move, not an abort; var absent → warn "no local repository configured", skip.)
4. State move: old state dir → new, when old exists and new missing (both → warn + skip; state is only logs).
5. Archive rollback copies into `$XDG_STATE_HOME/spectre-backup/migration-backup-<ts>/`: legacy `.env` and `~/.config/rclone/rclone.conf` (if present). Runs only in the legacy-present path, so a re-run does not create a second archive.
6. rclone section: if `rclone.conf` contains a line exactly `[fedora-back-up]` and does not contain `[spectre-backup]` → replace that header line only; every other byte stays. Otherwise leave the file, warn.
7. Repo dir move: `mv "$old_repo" "$new_repo"` guarded per step 3.
8. Config move + rewrite: `mv` config dir old → new; then for every file in the new dir `sed -i 's/fedora-back-up/spectre-backup/g; s/FEDORA_BACK_UP/SPECTRE_BACK_UP/g'` (rewrites `RESTIC_REPOSITORY`, `RESTIC_REPOSITORY_LOCAL`, `LOG_DIR`, comments; `password` has no matches so it survives untouched).
9. Cleanup, always (not gated on legacy config): remove `$BIN_DIR/{fedora-back-up.sh,fedora-back-up-restore.sh,fedora-back-up-verify.sh,fedora-back-up-prune.sh,backup-common.sh,fedora-back-up}`; for old user units: with `command -v systemctl` and `$XDG_DATA_HOME/systemd/user/fedora-back-up.timer` present → `systemctl --user disable --now fedora-back-up.timer` (tolerate failure with `warn`), `rm -f` both old unit files, `systemctl --user daemon-reload` (tolerated).
10. Sudo guidance, print-only: if `/etc/systemd/system/fedora-back-up.{service,timer}` or `/etc/fedora-back-up` exist → print the exact commands from Task 3's guide (`sudo systemctl disable --now fedora-back-up.timer` / `sudo rm ...` / `sudo systemctl daemon-reload`; server case: `sudo mv /etc/fedora-back-up /etc/spectre-backup`). Also, if legacy config was absent but `/backups/fedora-back-up` exists → warn "old repo dir present without legacy config; rename manually if it is yours".

**Installer wiring (exact):** after `info "Role: $ROLE"` and before `resolve_dirs`, add:

```bash
# Legacy rename migration (before resolve_dirs so detection sees real state)
if [ "$INSTALL_BIN_ONLY" = true ]; then
    info "Skipping legacy migration (--bin-only)"
else
    header "Step 0: Migrating legacy install (if any)"
    migrate_legacy_install
fi
```

`migrate_legacy_install` returning 1 exits the installer via `set -e` — intended (stop + report).

- [ ] **Step 1: Write the failing tests.** Add to `tests/run-tests.sh`: `# shellcheck source=../lib/migrate-legacy.sh` + `. "$PROJECT_DIR/lib/migrate-legacy.sh"` near the existing source line, then a `--- Legacy migration ---` group. Helpers: `make_legacy_sandbox` creates `SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/spectre-migtest.XXXXXX")`, saves and overrides `HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME`/`XDG_DATA_HOME` to sandbox paths, builds the fixture (legacy config dir with `.env` containing `RESTIC_REPOSITORY="rclone:fedora-back-up:"`, `RESTIC_REPOSITORY_LOCAL="$SANDBOX/backups/fedora-back-up"`, `LOG_DIR=.../state/fedora-back-up`; `include.conf`; own `password`; legacy state dir with a log file; legacy repo dir with a marker file; legacy bin files incl. symlink; legacy unit files; `rclone.conf` with `[fedora-back-up]` + `type = drive` + `token = {"secret":"keep-me"}`), and prepends `$SANDBOX/stubbin` to `PATH` with a `systemctl` stub that logs `"$@"` to `$SANDBOX/systemctl.log` and exits 0. `teardown_legacy_sandbox` restores the saved env and `rm -rf "$SANDBOX"`. Add `assert_not_exists` beside the other asserts. Test cases (each in the suite's PASS/FAIL style; call the function inside `if` so `set -e` does not abort on rc=1):
  1. `migration: fresh machine is a no-op` — empty sandbox; rc=0; no `migration-backup-*` dir; sandbox tree unchanged.
  2. `migration: full legacy workstation converts` — rc=0; rclone.conf header is `[spectre-backup]` and the `token` line is byte-identical; repo marker intact at `$SANDBOX/backups/spectre-backup`, old path gone; config dir at `spectre-backup/` with `.env` rewritten (three values) and `password` unchanged; state dir moved with log intact; one `migration-backup-*/` containing `.env` + `rclone.conf` copies; all six old bin entries gone; both old unit files gone; `systemctl.log` contains `--user disable --now fedora-back-up.timer` and `--user daemon-reload`.
  3. `migration: re-run is a no-op` — run twice; second rc=0; total `migration-backup-*` count still 1.
  4. `migration: leftovers cleaned without legacy config` — sandbox with only old bin files + old units; rc=0; all gone; stub log shows the disable.
  5. `migration: ambiguous config state aborts` — legacy config AND new config both exist; rc=1; repo still at old path; rclone.conf unchanged; bin files still present.
  6. `migration: repo target exists aborts` — legacy config present, both repo dirs exist; rc=1; config dir NOT moved.
  7. `migration: offsite-only env with custom remote is left alone` — `.env` without `RESTIC_REPOSITORY_LOCAL`, `rclone.conf` with `[gdrive]`; rc=0; rclone.conf untouched; no `backups/` paths created.
  8. `migration: failing systemctl is tolerated` — stub exits 1; rc=0; unit files still removed.
  9. `migration: installer calls it before resolve_dirs` — static: `grep -n` the call line and the `^resolve_dirs` line in `scripts/spectre-backup-install.sh`; call line must come first.
- [ ] **Step 2: Run the suite and verify it fails** — `./tests/run-tests.sh`; expect it to die or FAIL at the migration source/group (function missing).
- [ ] **Step 3: Implement `lib/migrate-legacy.sh`** with the ordered algorithm above. Style: `#!/bin/bash` header comment "spectre-backup - Legacy install migration"; every variable read with a default (`${XDG_CONFIG_HOME:-$HOME/.config}`); tolerate every external-command failure with `warn ... || true` patterns that still work under the installer's `set -euo pipefail`; one `info` line per action (before/after values), one `warn` per skip, `error` + `return 1` for aborts.
- [ ] **Step 4: Wire the installer** exactly as pinned above.
- [ ] **Step 5: Run the suite — expect `FAIL=0`.** Fix stragglers.
- [ ] **Step 6: Shellcheck the new file and the installer** — no errors: `shellcheck lib/migrate-legacy.sh scripts/spectre-backup-install.sh`.
- [ ] **Step 7: Commit**

```bash
git add lib/migrate-legacy.sh scripts/spectre-backup-install.sh tests/run-tests.sh
git commit -m "feat(installer): migrate legacy fedora-back-up installs to spectre-backup"
```

### Task 3: Documentation — README + migration guide

**Files:**
- Modify: `README.md`, `docs/migration-guide.md`

**Interfaces:**
- Consumes: Task 1 names; Task 2 migration behavior (the guide must describe exactly what the installer does and what stays manual).
- Produces: the user-facing migration recipe referenced by Task 4's sudo step.

- [ ] **Step 1: Rewrite README references.** Walk every hit of `grep -n 'fedora-back-up\|FEDORA_BACK_UP' README.md` and update: title/description, install & quick-start commands (`./scripts/spectre-backup-install.sh ...`), config/state paths, systemd unit names, restore/verify/prune commands, health-check command. In the Testing section, drop the hardcoded check count (the suite prints its own total); list the groups instead. Add exactly one old-name mention — a pointer near the top: upgrading from the old `fedora-back-up` name → `docs/migration-guide.md`.
- [ ] **Step 2: Update `docs/migration-guide.md`** — mechanical references to new names/paths, then add a section `## Renaming from fedora-back-up to spectre-backup` containing, pinned:
  - what the installer migrates automatically on the next run (bullets: rclone section rename; repo dir move; config dir move + `.env` rewrite; state dir move; old scripts removed; old user units removed; rollback archive at `~/.local/state/spectre-backup/migration-backup-<timestamp>/`),
  - workstation sudo leftovers (exact block):

```bash
sudo systemctl disable --now fedora-back-up.timer
sudo rm /etc/systemd/system/fedora-back-up.service /etc/systemd/system/fedora-back-up.timer
sudo systemctl daemon-reload
```

  - server-shaped old installs: `sudo mv /etc/fedora-back-up /etc/spectre-backup` + replace the old system units with the repo's `spectre-backup-system.service` + `spectre-backup.timer` + `sudo systemctl daemon-reload`,
  - a note that the Google Drive folder's display name is cosmetic and unrelated (the remote is pinned by `root_folder_id`),
  - verification commands: `rclone lsd spectre-backup:`, snapshot counts on both repos, `spectre-backup.sh --health`,
  - rollback pointer (archive dir + reverse moves).
- [ ] **Step 3: Verify** — `grep -n 'fedora-back-up\|FEDORA_BACK_UP' README.md` returns only the one pointer line; the guide contains old-name mentions only in the rename section and the historical layout section; `./tests/run-tests.sh` still `FAIL=0` (docs do not affect it).
- [ ] **Step 4: Commit**

```bash
git add README.md docs/migration-guide.md
git commit -m "docs: rewrite README and migration guide for the spectre-backup rename"
```

### Task 4: Live migration on this machine + end-to-end verification

**Files:** none in the repo; touches `~/`, `/backups`, `~/.config/rclone/rclone.conf`.

**Interfaces:**
- Consumes: Task 1–3 code; the sudo block printed by Task 2's guidance for the user to run.
- Produces: a fully renamed live install; evidence for Task 5.

- [ ] **Step 1: Pre-flight.** Record timer state (`systemctl --user list-timers 'fedora-back-up*' --no-pager` — next fire tomorrow 04:35); assert no backup in flight (`pgrep -af 'restic|fedora-back-up'` → empty); `df -h /backups` sane; record before counts: local `RESTIC_PASSWORD_COMMAND="cat $HOME/.config/fedora-back-up/password" restic -r /backups/fedora-back-up snapshots --json | jq length` → 63; offsite same against `rclone:fedora-back-up:` → 11.
- [ ] **Step 2: Run the new installer** — `./scripts/spectre-backup-install.sh --role=workstation --skip-test 2>&1 | tee /tmp/opencode/spectre-migration.log`; expect the "Step 0" migration lines (archive, rclone rename, repo move, config move, state move, cleanup) and exit 0. If it aborts (rc=1), stop and investigate before anything else.
- [ ] **Step 3: Filesystem assertions** — old dirs gone, new exist (`~/.config/spectre-backup/.env` with rewritten values, `~/.local/state/spectre-backup/`), repo at `/backups/spectre-backup` (restic `config` file inside), `rclone lsd spectre-backup:` works, `~/.local/bin/fedora-back-up*` + `backup-common.sh` gone, `~/.local/bin/spectre-backup` symlink present, user units renamed and old ones gone, `systemctl --user list-timers spectre-backup.timer` armed.
- [ ] **Step 4: Repo assertions** — local count still 63 at the new path; offsite count still 11 via the new remote; `spectre-backup.sh --health` → `OK`, exit 0.
- [ ] **Step 5: User action (sudo, cannot be automated).** Present the exact three-command block (legacy `/etc` units, failing daily since Sep 24) and ask the owner to run it; note it in the final report if not yet run.
- [ ] **Step 6: Manual full backup** — `~/.local/bin/spectre-backup.sh 2>&1 | tail -30`; expect exit 0, one new snapshot in each repo; then `restic snapshots --json | jq -r '.[-1].tags | join(",")'` (password command as above) → `spectre-backup,workstation` on both; counts 64/12; verify logs now append under `~/.local/state/spectre-backup/`.
- [ ] **Step 7: Health again** — `spectre-backup.sh --health` → `OK`; note next timer fire.

### Task 5: Final sweep + push

**Files:** repo only if stragglers surface.

- [ ] **Step 1: Token sweep** — `grep -rEn 'fedora-back-up|FEDORA_BACK_UP' --exclude-dir=.git .` → hits allowed only in `docs/superpowers/` (historical) and the intended migration-guide/README pointer.
- [ ] **Step 2: Suite once more** — `./tests/run-tests.sh` → `FAIL=0`.
- [ ] **Step 3: `git status` clean / commit any strays**; review `git log --oneline -8`.
- [ ] **Step 4: Push** — `git push`; report: summary of migration, new timer schedule, outstanding sudo step.

---

## Notes for the implementer

- The suite's `PASS/FAIL` style means expected non-zero returns must sit inside `if`/`|| true` — do not let `set -e` kill the run on an expected `rc=1`.
- `/backups` and `~` are the same filesystem — moves are instant metadata operations; never copy.
- Historical snapshot tags and the machine hostname (`fedora`) are out of scope by design (spec §Non-goals).


