#!/usr/bin/env bash
# Brain Server Bootstrap — Run on the Dell Inspiron (brain)
# Usage: scp bootstrap.sh daniel@192.168.1.116:~/ && ssh daniel@192.168.1.116 'bash ~/bootstrap.sh'
set -euo pipefail

echo "=== Phase 1: System Setup ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip python3-venv git curl wget build-essential

echo "=== Installing Node.js 22 LTS ==="
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

echo "=== Phase 2: Install Claude Code ==="
sudo npm install -g @anthropic-ai/claude-code

echo "=== Prep brain-server directory ==="
mkdir -p ~/brain-server

echo ""
echo "=== Bootstrap complete ==="
echo "  node:    $(node --version)"
echo "  python:  $(python3 --version)"
echo "  claude:  $(claude --version 2>/dev/null || echo 'run claude to authenticate')"
echo ""
echo "Next: copy CLAUDE.md to ~/brain-server/ and run 'cd ~/brain-server && claude'"
