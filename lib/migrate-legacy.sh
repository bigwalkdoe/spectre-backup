#!/bin/bash
# ============================================================
# spectre-backup - Legacy install migration
# Migrates fedora-back-up installs to spectre-backup
# ============================================================

# Report a migration conflict, then let the caller stop. Always follow this
# with an explicit `return 1`: under `set -e` a failing call exits the
# installer, but inside a conditional (tests, `if migrate_legacy_install`)
# errexit is suppressed and execution would otherwise continue.
_migrate_fail() {
    error "$1"
    echo "  Nothing further was changed." >&2
    echo "  Fix the conflict above and re-run the installer to finish, or roll back from" >&2
    echo "  ${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup/migration-backup-<timestamp>/" >&2
}

migrate_legacy_install() {
    # Only run when there's a legacy install to migrate; no-op otherwise.
    # Returns 0 = safe to continue; 1 = ambiguous/unsafe state, stop.
    local user_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
    local legacy_config="$user_config_dir/fedora-back-up"
    local new_config="$user_config_dir/spectre-backup"
    local legacy_state="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
    local new_state="${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup"
    local bin_dir="${XDG_DATA_HOME:-$HOME/.local}/bin"
    local systemd_user_dir="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
    local rclone_conf="$user_config_dir/rclone/rclone.conf"

    # 1. Detect legacy vs new config. Both present means a previous migration
    # was interrupted in a way we cannot resolve safely: stop before touching
    # anything.
    if [ -d "$legacy_config" ] && [ -d "$new_config" ]; then
        _migrate_fail "Both $legacy_config and $new_config exist — ambiguous state, aborting"
        return 1
    fi

    local have_legacy=0
    if [ -d "$legacy_config" ]; then
        have_legacy=1
    fi

    if [ "$have_legacy" -eq 0 ]; then
        info "No legacy config found — skipping migration (leftovers still cleaned)"
    fi

    # 2. Stop the legacy schedule before anything moves: the old timer must
    # never fire against half-renamed state.
    if command -v systemctl >/dev/null 2>&1; then
        if [ -f "$systemd_user_dir/fedora-back-up.timer" ] || [ -f "$systemd_user_dir/fedora-back-up.service" ]; then
            info "Disabling legacy user timer (before any moves)"
            systemctl --user disable --now fedora-back-up.timer 2>/dev/null || warn "systemctl --user disable failed (tolerated)"
        fi
    fi

    # 3. Read the local repo path from the legacy .env. Quote-agnostic, and
    # tolerant of a missing key: a grep miss must not kill the installer
    # (the pipeline runs under `set -o pipefail`).
    local restic_repository_local=""
    if [ "$have_legacy" -eq 1 ] && [ -f "$legacy_config/.env" ]; then
        restic_repository_local=$(grep -E '^RESTIC_REPOSITORY_LOCAL=' "$legacy_config/.env" \
            | head -1 | cut -d= -f2- \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]$//" \
            || true)
    fi

    # 4. Validate the repo path before rewriting anything. Pointing .env at a
    # path with no repository would orphan the history and let the next run
    # initialize an empty repo.
    local old_repo=""
    local new_repo=""
    local repo_move=0
    if [ -n "$restic_repository_local" ]; then
        old_repo="$restic_repository_local"
        new_repo="${old_repo//fedora-back-up/spectre-backup}"
        if [ "${old_repo#/}" = "$old_repo" ]; then
            _migrate_fail "RESTIC_REPOSITORY_LOCAL is not an absolute path ($old_repo) — cannot migrate it safely"
            return 1
        elif [ "$old_repo" = "$new_repo" ]; then
            info "Local repository path has no old product name ($old_repo) — leaving it in place"
        elif [ -e "$old_repo" ] && [ -e "$new_repo" ]; then
            _migrate_fail "Both $old_repo and $new_repo exist — ambiguous repo state, aborting"
            return 1
        elif [ -e "$old_repo" ]; then
            if [ ! -d "$(dirname "$new_repo")" ]; then
                _migrate_fail "Parent directory of $new_repo does not exist — cannot move the repository"
                return 1
            fi
            repo_move=1
        elif [ -e "$new_repo" ]; then
            # A previous run already moved it; continue where it stopped.
            info "Repository already at $new_repo — continuing"
        else
            _migrate_fail "Local repository $old_repo does not exist (unmounted drive?) — refusing to point .env at $new_repo"
            return 1
        fi
    elif [ "$have_legacy" -eq 1 ]; then
        warn "No RESTIC_REPOSITORY_LOCAL in legacy .env; repo move skipped"
    fi

    # 5. State move (logs and DB dumps travel with it)
    if [ -d "$legacy_state" ] && [ ! -d "$new_state" ]; then
        info "Moving state dir: $legacy_state -> $new_state"
        mv "$legacy_state" "$new_state"
    elif [ -d "$legacy_state" ] && [ -d "$new_state" ]; then
        warn "Both $legacy_state and $new_state exist — state move skipped (logs only)"
    fi

    # 6. Archive rollback copies before rewriting anything. `password` is a
    # secret: archived with its permissions, never rewritten.
    if [ "$have_legacy" -eq 1 ]; then
        local archive_dir
        archive_dir="$new_state/migration-backup-$(date '+%Y%m%d-%H%M%S')"
        info "Creating rollback archive: $archive_dir"
        mkdir -p "$archive_dir"
        local archive_file
        for archive_file in .env password; do
            if [ -f "$legacy_config/$archive_file" ]; then
                cp -p "$legacy_config/$archive_file" "$archive_dir/$archive_file" 2>/dev/null || true
            fi
        done
        if [ -f "$rclone_conf" ]; then
            cp -f "$rclone_conf" "$archive_dir/rclone.conf" 2>/dev/null || true
        fi
    fi

    # 7. rclone section rename. The remote token and pinned root_folder_id
    # travel with the section, so no remote data moves.
    if [ -f "$rclone_conf" ]; then
        if grep -q '^\[fedora-back-up\]$' "$rclone_conf" && ! grep -q '^\[spectre-backup\]$' "$rclone_conf"; then
            info "Renaming rclone remote section: [fedora-back-up] -> [spectre-backup]"
            sed -i 's/^\[fedora-back-up\]$/[spectre-backup]/' "$rclone_conf"
        elif grep -q '^\[fedora-back-up\]$' "$rclone_conf"; then
            warn "rclone has [fedora-back-up] but [spectre-backup] also present — leaving as-is"
        elif grep -q '^\[spectre-backup\]$' "$rclone_conf"; then
            warn "rclone already has [spectre-backup] section — leaving as-is"
        fi
    elif [ "$have_legacy" -eq 1 ] && [ -f "$legacy_config/.env" ] && grep -q 'rclone:fedora-back-up:' "$legacy_config/.env"; then
        warn "No rclone config at $rclone_conf but .env uses rclone:fedora-back-up: — configure a [spectre-backup] remote manually"
    fi

    # 8. Repo dir move. Same filesystem in the normal layout, so this is a
    # rename; it happens before .env is rewritten so the path is never stale.
    if [ "$repo_move" -eq 1 ]; then
        info "Moving repository: $old_repo -> $new_repo"
        mv "$old_repo" "$new_repo"
    fi

    # 9. Config move + rewrite. The rewrite doubles as the repair path for an
    # interrupted run: if the new config still holds old names, rewrite now.
    local rewrite=0
    if [ "$have_legacy" -eq 1 ] && [ -d "$legacy_config" ] && [ ! -d "$new_config" ]; then
        info "Moving config dir: $legacy_config -> $new_config"
        mv "$legacy_config" "$new_config"
        rewrite=1
    elif [ "$have_legacy" -eq 1 ] && [ -d "$new_config" ]; then
        warn "New config dir already exists — config move skipped"
    elif [ "$have_legacy" -eq 0 ] && [ -d "$new_config" ] && grep -rqsE --exclude=password 'fedora-back-up|FEDORA_BACK_UP' "$new_config" 2>/dev/null; then
        info "Finishing an interrupted migration: rewriting old names in $new_config"
        rewrite=1
    fi

    if [ "$rewrite" -eq 1 ]; then
        # find covers dotfiles like .env. `password` is excluded: it is a
        # secret, not a config string, and rewriting it would lock the user
        # out of every existing snapshot.
        local cfg_file
        while IFS= read -r -d '' cfg_file; do
            sed -i 's/fedora-back-up/spectre-backup/g; s/FEDORA_BACK_UP/SPECTRE_BACK_UP/g' "$cfg_file"
        done < <(find "$new_config" -type f ! -name password -print0)
    fi

    # 10. Cleanup (always runs, even without a legacy config)
    info "Cleaning up legacy bin scripts and user units"

    # Remove old bin scripts and symlink
    local old_scripts=("fedora-back-up.sh" "fedora-back-up-restore.sh" "fedora-back-up-verify.sh" "fedora-back-up-prune.sh" "backup-common.sh" "fedora-back-up")
    local s
    for s in "${old_scripts[@]}"; do
        # -L: a symlink whose target was just removed (the .sh above) is
        # dangling, and -e follows links, so it must be checked separately.
        if [ -e "$bin_dir/$s" ] || [ -L "$bin_dir/$s" ]; then
            rm -f "$bin_dir/$s"
            info "Removed legacy bin: $bin_dir/$s"
        fi
    done

    # Remove old user units (the timer was already disabled in step 2)
    if command -v systemctl >/dev/null 2>&1; then
        if [ -f "$systemd_user_dir/fedora-back-up.timer" ] || [ -f "$systemd_user_dir/fedora-back-up.service" ]; then
            rm -f "$systemd_user_dir/fedora-back-up.service" "$systemd_user_dir/fedora-back-up.timer"
            systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed (tolerated)"
            info "Removed legacy user units"
        fi
    fi

    # 11. Sudo guidance (print-only)
    if [ -f /etc/systemd/system/fedora-back-up.service ] || [ -f /etc/systemd/system/fedora-back-up.timer ]; then
        warn "Legacy SYSTEM units found at /etc/systemd/system/fedora-back-up.{service,timer} — remove manually:"
        echo "  sudo systemctl disable --now fedora-back-up.timer"
        echo "  sudo rm -f /etc/systemd/system/fedora-back-up.service /etc/systemd/system/fedora-back-up.timer"
        echo "  sudo systemctl daemon-reload"
    fi
    if [ -d /etc/fedora-back-up ]; then
        warn "Legacy system config /etc/fedora-back-up found — move manually:"
        echo "  sudo mv /etc/fedora-back-up /etc/spectre-backup"
        echo "  # Then install the new system units and run: sudo systemctl daemon-reload"
    fi
    # Old repo dir without legacy config
    if [ "$have_legacy" -eq 0 ] && [ -n "$old_repo" ] && [ -e "$old_repo" ]; then
        warn "Old repo $old_repo exists without legacy config — rename manually if it is yours"
    elif [ "$have_legacy" -eq 0 ] && [ -e "/backups/fedora-back-up" ]; then
        warn "Old repo /backups/fedora-back-up exists without legacy config — rename manually if it is yours"
    fi

    return 0
}
