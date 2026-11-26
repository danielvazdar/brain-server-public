#!/usr/bin/env bash
# Offsite copy of every restic repo on brain → backup-account@example.com Google Drive (2 TB Google One).
#
# 2026-09-21: this header said "backup-account@example.com" since day one, but the remote it
# used was authorised against the 30 GB Kyuro Workspace account. The comment and the
# remote's name both lied; only `rclone about` told the truth. Hence the quota guard
# below, and hence the remote is now named after the account it actually belongs to.
# Deployed to brain at /home/daniel/brain-offsite-backup.sh
# Cron: 30 6 * * * (after Client A 03:00 UTC and KVM1 nightly, before laptop ~10:00 UTC)
#
# Why: until 2026-09-16 every backup of laptop, KVM1 and Client A lived only on brain,
# one disk in one house. This is the second location of a 3-2-1 setup.
#
# What goes up: the restic repos only. They are already encrypted by restic, so the
# Drive copy is unreadable without the per-repo passwords (kept on the machines that
# write them — laptop /etc/restic, KVM1 ~/.config/restic, KVM2). The plain SQL dumps in
# ~/backups/client-a are NOT uploaded: they are unencrypted and duplicated inside
# client-a-restic.
#
# Safety:
#   - rclone token has scope drive.file: it can only see files it created itself.
#   - A source that doesn't look like a restic repo (no `config`) aborts the run, so a
#     wiped or unmounted directory can never sync an empty tree over the good copy.
#   - Remote deletions/overwrites move to brain-offsite-deleted/<date>/ (kept 30 days),
#     so a corrupted local repo can't silently destroy the offsite one.
#   - On success a stamp is written; brain-monitor.sh alerts if it is older than 36h.
#   - Any failure sends a Telegram alert immediately.

set -euo pipefail

CONF="/home/daniel/.config/rclone/gdrive-offsite.conf"
# Upload cap. Brain sits on a home uplink measured at ~730 KB/s (2026-09-25). Uncapped, the
# laptop-restic sync filled it for 12 minutes and every outside check in brain-monitor.sh
# (5 sites, 3 servers) was paged as DOWN on 09-23 and 09-25. 500 KiB/s leaves ~30% headroom.
BWLIMIT="${OFFSITE_BWLIMIT:-500k}"
MONITOR_ENV="/home/daniel/.config/brain-monitor.env"
REMOTE="gdrive-offsite:brain-offsite"
TRASH="gdrive-offsite:brain-offsite-deleted"
BACKUPS="/home/daniel/backups"
# Most important and smallest first: a slow laptop repo must not starve KVM1 (audit 2026-09-19 C-03).
REPOS=(kvm1-restic evemos-restic client-a-restic laptop-restic)
STAMP="$BACKUPS/.offsite-last-success"
KEEP_DELETED_DAYS=30
LOCK="/tmp/brain-offsite-backup.lock"

log() { echo "[$(date -u '+%F %T UTC')] $*"; }

alert() {
    # shellcheck source=/dev/null
    source "$MONITOR_ENV"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="🔴 Brain offsite backup FAILED: $1" > /dev/null || true
}

fail() { log "FATAL: $1"; alert "$1"; exit 1; }

# Drive refuses to trash a whole folder when it holds anything this OAuth app didn't
# create (drive.file scope can't even list such items): `purge` fails with 403
# appNotAuthorizedToChild. Seen from 2026-10-26 on the 09-25..09-27 folders, while a
# fresh test folder purged fine. Fallback: delete the files we can see one by one, then
# the folders that end up empty. A leftover is logged, not alerted: it holds none of the
# restic data we uploaded, and a daily alert would teach you to ignore the real ones.
prune_dir() {
    local dir="$1" path="$TRASH/$1" left
    if rclone purge "$path" --config "$CONF" --retries 1; then
        log "purged $dir"; return 0
    fi
    log "purge of $dir refused, deleting its files one by one"
    rclone delete "$path" --config "$CONF" --rmdirs || log "some files in $dir would not delete"
    if rclone rmdir "$path" --config "$CONF"; then
        log "purged $dir (file by file)"; return 0
    fi
    left=$(rclone lsf -R "$path" --config "$CONF" 2>/dev/null | wc -l)
    log "LEFTOVER: $dir still exists with $left visible items; Drive holds something in it this app can't see, empty it in the Drive web UI"
}

prune_trash() {
    local cutoff dir
    log "pruning deleted-file archive older than ${KEEP_DELETED_DAYS} days"
    cutoff=$(date -u -d "-${KEEP_DELETED_DAYS} days" +%F)
    while read -r dir; do
        dir="${dir%/}"
        [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$dir" < "$cutoff" ]] || continue
        prune_dir "$dir"
    done < <(rclone lsf --dirs-only "$TRASH" --config "$CONF" 2>/dev/null || true)
}

# Sourced by server/tests/test-offsite-prune.sh: define the functions, run nothing.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

exec 9> "$LOCK"
flock -n 9 || { log "another run is still going, skipping"; exit 0; }

[[ -r "$CONF" ]] || fail "rclone config $CONF missing"
command -v rclone > /dev/null || fail "rclone not installed"

# --- Refuse to sync into a Drive that cannot hold the payload ---------------
# 2026-09-21: this remote is NAMED "gdrive-personal" but its token was authorised
# against the 30 GB Kyuro Workspace account. rclone filled it to 31/30 GB with a
# laptop repo that is 35 GB on its own, so the sync could never finish, the
# success stamp was never written, and brain-monitor alerted every 30 minutes for
# two days. A remote's NAME is not evidence of which account its token belongs to.
# Measure the quota before writing a single byte.
NEED_BYTES=$(du -sb "${REPOS[@]/#/$BACKUPS/}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
(( NEED_BYTES > 0 )) || fail "could not measure local repo sizes - refusing to sync blind"

ABOUT_JSON=$(rclone about "${REMOTE%%:*}:" --config "$CONF" --json 2>/dev/null) \
    || fail "cannot read Drive quota for ${REMOTE%%:*} - refusing to sync blind"
QUOTA_TOTAL=$(printf '%s' "$ABOUT_JSON" | jq -r '.total // 0')
QUOTA_USED=$(printf '%s' "$ABOUT_JSON" | jq -r '.used // 0')
(( QUOTA_TOTAL > 0 )) || fail "Drive reports no quota - refusing to sync blind"

log "drive quota: $(numfmt --to=iec "$QUOTA_USED") used of $(numfmt --to=iec "$QUOTA_TOTAL"), payload $(numfmt --to=iec "$NEED_BYTES")"

if (( QUOTA_TOTAL < NEED_BYTES )); then
    fail "Drive holds only $(numfmt --to=iec "$QUOTA_TOTAL") but the backups are $(numfmt --to=iec "$NEED_BYTES") - wrong account, or the plan is too small"
fi
if (( QUOTA_USED >= QUOTA_TOTAL )); then
    fail "Drive is full ($(numfmt --to=iec "$QUOTA_USED") of $(numfmt --to=iec "$QUOTA_TOTAL")) - free space before syncing"
fi

today=$(date -u +%F)
failed=()
for repo in "${REPOS[@]}"; do
    src="$BACKUPS/$repo"
    [[ -f "$src/config" && -d "$src/data" ]] || fail "$src does not look like a restic repo, refusing to sync"
    log "syncing $repo"
    # --tpslimit keeps us under Drive's per-user rate limit (the 09-17 run stalled on rateLimitExceeded).
    if ! rclone sync "$src" "$REMOTE/$repo" \
        --config "$CONF" \
        --backup-dir "$TRASH/$today/$repo" \
        --exclude "locks/**" \
        --transfers 4 --checkers 8 --tpslimit 8 --drive-chunk-size 64M \
        --bwlimit "$BWLIMIT" \
        --stats-one-line --stats 10m; then
        log "rclone sync of $repo exited non-zero"; failed+=("$repo"); continue
    fi
    log "verifying $repo"
    if ! rclone check "$src" "$REMOTE/$repo" --config "$CONF" --one-way --size-only \
        --exclude "locks/**" 2>&1 | tail -2; then
        log "offsite copy of $repo does not match local"; failed+=("$repo"); continue
    fi
    # Per-repo stamp: brain-monitor watches each repo on its own, so one stuck repo
    # can't hide the others' freshness.
    date +%s > "$STAMP-$repo"
done

prune_trash

(( ${#failed[@]} == 0 )) || fail "offsite sync failed for: ${failed[*]} (others synced)"
date +%s > "$STAMP"
log "done"
