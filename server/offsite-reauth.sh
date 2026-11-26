#!/usr/bin/env bash
# ============================================================
# offsite-reauth.sh — point the offsite backup at a different Google account.
#
# Why this exists: until 2026-09-21 the offsite remote was NAMED "gdrive-personal"
# but its token belonged to the 30 GB Kyuro Workspace account. It filled that
# account to 31/30 GB with a 35 GB laptop repo that could never fit, which also
# puts Kyuro's Gmail at risk (Workspace shares one pot between Drive and Gmail).
#
# RUN THIS IN A REAL TERMINAL, with the OAuth port tunnelled:
#
#     ssh -L 53682:localhost:53682 brain
#     ~/offsite-reauth.sh
#
# The tunnel matters: rclone opens a listener on brain:53682 and Google redirects
# your laptop browser back to it. Without -L the redirect lands nowhere.
# It asks questions, so it cannot be driven from a Claude `!` line (no stdin).
# ============================================================
set -euo pipefail

OLD_CONF="/home/daniel/.config/rclone/gdrive-personal.conf"
OLD_REMOTE="gdrive-personal"
NEW_CONF="/home/daniel/.config/rclone/gdrive-offsite.conf"
NEW_REMOTE="gdrive-offsite"
# Refuse anything under 500 GB: the whole point is to stop landing in a small
# account by accident. The target is the 2 TB backup-account@example.com Google One plan.
MIN_TOTAL_BYTES=$((500 * 1000 * 1000 * 1000))

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -t 0 ]] || die "run me in a terminal - I need to ask you things"
[[ -r "$OLD_CONF" ]] || die "$OLD_CONF not readable"
command -v rclone > /dev/null || die "rclone not installed"
command -v jq > /dev/null || die "jq not installed"

if [[ -e "$NEW_CONF" ]]; then
    read -r -p "$NEW_CONF already exists. Overwrite? [y/N] " a
    [[ "$a" == [yY] ]] || die "aborted"
fi

# Reuse the existing OAuth client (same Google Cloud project, same quota headroom
# won back on 2026-09-20). Copying the section keeps client_id and client_secret
# inside the file - they are never printed, never passed on a command line.
umask 077
sed "s/^\[${OLD_REMOTE}\]$/[${NEW_REMOTE}]/" "$OLD_CONF" > "$NEW_CONF"
grep -q "^\[${NEW_REMOTE}\]$" "$NEW_CONF" || die "could not rename the remote section - is $OLD_CONF shaped as expected?"

cat <<EOF

--------------------------------------------------------------------
A Google sign-in page is about to open (or a URL will be printed).

  >>> SIGN IN AS  backup-account@example.com  <<<
  >>> NOT the Kyuro account.        <<<

If a URL is printed instead of opening, paste it into your laptop browser.
--------------------------------------------------------------------

EOF
read -r -p "Ready? [enter] " _

# Re-run OAuth for the copied remote; this replaces the stale Kyuro token.
rclone config reconnect "${NEW_REMOTE}:" --config "$NEW_CONF" \
    || die "authorisation failed - nothing else was changed"

echo
echo "Checking which account we actually landed in..."
about=$(rclone about "${NEW_REMOTE}:" --config "$NEW_CONF" --json 2>/dev/null) \
    || die "cannot read the new account's quota"
total=$(printf '%s' "$about" | jq -r '.total // 0')
used=$(printf '%s' "$about" | jq -r '.used // 0')

if (( total < MIN_TOTAL_BYTES )); then
    rm -f "$NEW_CONF"
    die "that account holds only $(numfmt --to=iec "$total") - wrong account. Nothing was changed; $OLD_CONF is untouched."
fi

echo
echo "OK: $(numfmt --to=iec "$used") used of $(numfmt --to=iec "$total")."
echo "New remote ready: ${NEW_REMOTE}:  (config $NEW_CONF)"
echo
echo "Next: deploy the updated brain-offsite-backup.sh, then run it."
