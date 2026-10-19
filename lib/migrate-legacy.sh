#!/bin/bash
# ============================================================
# spectre-backup - Legacy install migration
# Migrates fedora-back-up installs to spectre-backup
# ============================================================

migrate_legacy_install() {
    # Only run when there's a legacy config to migrate; no-op otherwise.
    # Returns 0 = safe to continue; 1 = ambiguous state, stop.
    local legacy_config="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-back-up"
    local new_config="${XDG_CONFIG_HOME:-$HOME/.config}/spectre-backup"
    local legacy_state="${XDG_STATE_HOME:-$HOME/.local/state}/fedora-back-up"
    local new_state="${XDG_STATE_HOME:-$HOME/.local/state}/spectre-backup"
    local bin_dir="${XDG_DATA_HOME:-$HOME/.local}/bin"
    local systemd_user_dir="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
    local rclone_conf="$HOME/.config/rclone/rclone.conf"

    # 1. Detect legacy vs new config
    if [ -d "$legacy_config" ] && [ -d "$new_config" ]; then
        error "Both $legacy_config and $new_config exist — ambiguous state, aborting"
        return 1
    fi

    local have_legacy=0
    if [ -d "$legacy_config" ]; then
        have_legacy=1
    fi

    if [ "$have_legacy" -eq 0 ]; then
        info "No legacy config found — skipping migration (leftovers still cleaned)"
    fi

    # 2. Read legacy .env values before any move
    # (RESTIC_REPOSITORY is not read here: the config rewrite in step 8
    # updates it in place, so only the local repo path drives the moves.)
    local restic_repository_local=""
    if [ "$have_legacy" -eq 1 ] && [ -f "$legacy_config/.env" ]; then
        restic_repository_local=$(grep -E '^RESTIC_REPOSITORY_LOCAL=' "$legacy_config/.env" | head -1 | cut -d= -f2- | tr -d '"')
    fi

    # 3. Repo-path validation
    local old_repo=""
    local new_repo=""
    if [ -n "$restic_repository_local" ]; then
        old_repo="$restic_repository_local"
        new_repo="${old_repo//fedora-back-up/spectre-backup}"
        if [ -e "$old_repo" ] && [ -e "$new_repo" ]; then
            error "Both $old_repo and $new_repo exist — ambiguous repo state, aborting"
            return 1
        fi
    elif [ "$have_legacy" -eq 1 ]; then
        warn "No RESTIC_REPOSITORY_LOCAL in legacy .env; repo move skipped"
    fi

    # 4. State move (only logs)
    if [ -d "$legacy_state" ] && [ ! -d "$new_state" ]; then
        info "Moving state dir: $legacy_state -> $new_state"
        mv "$legacy_state" "$new_state"
    elif [ -d "$legacy_state" ] && [ -d "$new_state" ]; then
        warn "Both $legacy_state and $new_state exist — state move skipped (logs only)"
    fi

    # 5. Archive rollback copies (only when legacy config existed)
    if [ "$have_legacy" -eq 1 ]; then
        local archive_dir
        archive_dir="$new_state/migration-backup-$(date '+%Y%m%d-%H%M%S')"
        info "Creating rollback archive: $archive_dir"
        mkdir -p "$archive_dir"
        cp -f "$legacy_config/.env" "$archive_dir/.env" 2>/dev/null || true
        if [ -f "$rclone_conf" ]; then
            cp -f "$rclone_conf" "$archive_dir/rclone.conf" 2>/dev/null || true
        fi
    fi

    # 6. rclone section rename
    if [ -f "$rclone_conf" ] && grep -q '^\[fedora-back-up\]$' "$rclone_conf" && ! grep -q '^\[spectre-backup\]$' "$rclone_conf"; then
        info "Renaming rclone remote section: [fedora-back-up] -> [spectre-backup]"
        sed -i 's/^\[fedora-back-up\]$/[spectre-backup]/' "$rclone_conf"
    elif [ -f "$rclone_conf" ] && grep -q '^\[spectre-backup\]$' "$rclone_conf"; then
        warn "rclone already has [spectre-backup] section — leaving as-is"
    elif [ -f "$rclone_conf" ] && grep -q '^\[fedora-back-up\]$' "$rclone_conf"; then
        warn "rclone has [fedora-back-up] but [spectre-backup] also present — leaving as-is"
    fi

    # 7. Repo dir move
    if [ -n "$old_repo" ] && [ -e "$old_repo" ] && [ ! -e "$new_repo" ]; then
        info "Moving repository: $old_repo -> $new_repo"
        mv "$old_repo" "$new_repo"
    elif [ -n "$old_repo" ] && [ ! -e "$old_repo" ]; then
        warn "Old repo path $old_repo does not exist — skipping repo move"
    fi

    # 8. Config move + rewrite
    if [ "$have_legacy" -eq 1 ] && [ -d "$legacy_config" ] && [ ! -d "$new_config" ]; then
        info "Moving config dir: $legacy_config -> $new_config"
        mv "$legacy_config" "$new_config"
        # Rewrite all files in the new config dir (find covers dotfiles like .env)
        while IFS= read -r -d '' f; do
            sed -i 's/fedora-back-up/spectre-backup/g; s/FEDORA_BACK_UP/SPECTRE_BACK_UP/g' "$f"
        done < <(find "$new_config" -type f -print0)
    elif [ "$have_legacy" -eq 1 ] && [ -d "$new_config" ]; then
        warn "New config dir already exists — config move skipped"
    fi

    # 9. Cleanup (always runs, even without legacy config)
    info "Cleaning up legacy bin scripts and user units"

    # Remove old bin scripts and symlink
    local old_scripts=("fedora-back-up.sh" "fedora-back-up-restore.sh" "fedora-back-up-verify.sh" "fedora-back-up-prune.sh" "backup-common.sh" "fedora-back-up")
    for s in "${old_scripts[@]}"; do
        if [ -e "$bin_dir/$s" ]; then
            rm -f "$bin_dir/$s"
            info "Removed legacy bin: $bin_dir/$s"
        fi
    done

    # Disable and remove old user units
    if command -v systemctl >/dev/null 2>&1; then
        if [ -f "$systemd_user_dir/fedora-back-up.timer" ] || [ -f "$systemd_user_dir/fedora-back-up.service" ]; then
            info "Disabling legacy user timer"
            systemctl --user disable --now fedora-back-up.timer 2>/dev/null || warn "systemctl --user disable failed (tolerated)"
            rm -f "$systemd_user_dir/fedora-back-up.service" "$systemd_user_dir/fedora-back-up.timer"
            systemctl --user daemon-reload 2>/dev/null || warn "systemctl --user daemon-reload failed (tolerated)"
            info "Removed legacy user units"
        fi
    fi

    # 10. Sudo guidance (print-only)
    if [ -f /etc/systemd/system/fedora-back-up.service ] || [ -f /etc/systemd/system/fedora-back-up.timer ]; then
        warn "Legacy SYSTEM units found at /etc/systemd/system/fedora-back-up.{service,timer} — remove manually:"
        echo "  sudo systemctl disable --now fedora-back-up.timer"
        echo "  sudo rm /etc/systemd/system/fedora-back-up.service /etc/systemd/system/fedora-back-up.timer"
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