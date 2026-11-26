#!/usr/bin/env bash
# Sync claude-config (memory, skills, rules, agents, commands, CLAUDE.md)
# from laptop ~/.claude/ to brain ~/brain/claude-config/ for indexing.
#
# Runs via cron every 15 min. Mirrors useful, low-churn content; skips
# session JSONLs (already covered by sync-cc-sessions.sh) and secrets.

set -euo pipefail

SRC="$HOME/.claude/"
REMOTE="daniel@brain.tailnet-example.ts.net"
DEST="~/brain/claude-config/"

ssh -o ConnectTimeout=5 "$REMOTE" "mkdir -p $DEST" 2>/dev/null || exit 0

rsync -a --delete \
  --include='CLAUDE.md' \
  --include='projects/' \
  --include='projects/-home-daniel/' \
  --include='projects/-home-daniel/memory/' \
  --include='projects/-home-daniel/memory/**' \
  --include='skills/' \
  --include='skills/**' \
  --include='agents/' \
  --include='agents/**' \
  --include='rules/' \
  --include='rules/**' \
  --include='commands/' \
  --include='commands/**' \
  --exclude='*' \
  "$SRC" "$REMOTE:$DEST" 2>/dev/null || true
