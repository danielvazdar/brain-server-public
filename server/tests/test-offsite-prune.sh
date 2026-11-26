#!/usr/bin/env bash
# Reproduces 2026-10-26..28: Drive answered `rclone purge` on the 09-25..09-27 trash folders
# with 403 appNotAuthorizedToChild, so 30-day-old backups were never removed.
# Expected: a refused purge falls back to deleting file by file; a folder Drive still won't
# remove is logged as LEFTOVER; folders younger than the cutoff are never touched.
# The fake rclone below encodes our reading of Drive's behaviour; the real proof is the
# next live run's log (grep "purged\|LEFTOVER" ~/backups/offsite.log on brain).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

old=$(date -u -d "-40 days" +%F)
older=$(date -u -d "-41 days" +%F)
oldest=$(date -u -d "-42 days" +%F)
recent=$(date -u -d "-5 days" +%F)
printf '%s/\n' "$oldest" "$older" "$old" "$recent" not-a-date > "$TMP/dirs"
echo "$older" > "$TMP/refuse-purge"          # purge refused, file-by-file works
printf '%s\n' "$oldest" >> "$TMP/refuse-purge"
echo "$oldest" > "$TMP/refuse-rmdir"         # even the empty folder won't go

mkdir "$TMP/bin"
cat > "$TMP/bin/rclone" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
dir=$(basename "${2:-}")
case "$1" in
    lsf) [[ "$*" == *--dirs-only* ]] && cat "$FAKE/dirs"; exit 0 ;;
    purge) grep -qx "$dir" "$FAKE/refuse-purge" && { echo "403 appNotAuthorizedToChild" >&2; exit 1; }; exit 0 ;;
    delete) exit 0 ;;
    rmdir) grep -qx "$dir" "$FAKE/refuse-rmdir" && exit 1; exit 0 ;;
esac
exit 2
EOF
chmod +x "$TMP/bin/rclone"

# shellcheck source=/dev/null
source "$HERE/../brain-offsite-backup.sh"
out=$(FAKE="$TMP" PATH="$TMP/bin:$PATH" prune_trash 2>/dev/null)

fail() { echo "FAIL: $1"; echo "--- output:"; echo "$out"; echo "--- calls:"; cat "$TMP/calls"; exit 1; }

grep -q "purged $old$" <<< "$out" || fail "plain purge of $old not reported"
grep -q "purged $older (file by file)" <<< "$out" || fail "refused purge of $older did not fall back"
grep -q "^delete .*/$older " "$TMP/calls" || fail "no file-by-file delete for $older"
grep -q "LEFTOVER: $oldest" <<< "$out" || fail "undeletable $oldest not logged as LEFTOVER"
! grep -q "$recent" "$TMP/calls" || fail "folder younger than the cutoff was touched"
! grep -q "not-a-date" "$TMP/calls" || fail "non-date folder was touched"
echo "PASS: refused purge falls back to file-by-file, leftovers logged, recent folders kept"
