#!/usr/bin/env bash
# Sync Claude Code session JSONL files directly to brain server.
# Runs via cron every 30 minutes. Uses rsync over SSH for incremental copy.
#
# Source: ~/.claude/projects/  (CC session JSONL files)
# Dest:   brain:~/brain/convos/cc-sessions/

set -euo pipefail

SRC="$HOME/.claude/projects/"
# Use Tailscale FQDN so this works from any network (home LAN or remote).
# Requires Tailscale to be running on the host executing this script.
REMOTE="daniel@brain.tailnet-example.ts.net"
DEST="~/brain/convos/cc-sessions/"

# Ensure remote dir exists
ssh -o ConnectTimeout=5 "$REMOTE" "mkdir -p $DEST" 2>/dev/null || exit 0

# rsync only .jsonl files, preserve directory structure (project dirs),
# skip files already synced
rsync -a --include='*/' --include='*.jsonl' --exclude='*' \
  --ignore-existing \
  "$SRC" "$REMOTE:$DEST" 2>/dev/null || true
