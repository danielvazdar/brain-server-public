#!/usr/bin/env bash
# Brain on pc2, step 1 of the move from brain2 (Latitude), 2026-11-25: install the services.
#
# Run on pc2, from the folder that holds this script and a copy of server/systemd/:
#     sudo bash ~/brain-move/brain-install.sh
#
# Starts chroma, indexer, MCP server and bridge, so pc2 builds the new index on its GPU while
# brain2 keeps serving. Leaves syncthing@daniel and brain-bot OFF: they carry identities (the
# Syncthing device ID, the Telegram bot token) that must never run on two boxes at once.
# pc2-cutover.sh starts them after brain2 has stopped.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
UNITS="$HERE/systemd"
HOME_DIR=/home/daniel
[[ -f "$UNITS/brain-chroma.service" ]] || { echo "missing $UNITS: copy server/systemd/ next to this script" >&2; exit 1; }
[[ -x "$HOME_DIR/brain-server/venv/bin/chroma" ]] || { echo "Brain venv not built yet" >&2; exit 1; }
[[ -f "$HOME_DIR/brain-server/session_text.py" ]] || { echo "conversation-only indexer (#32) not in place" >&2; exit 1; }
# The startup scan should see all of ~/brain, not half a copy.
grep -q '^== archive' "$HOME_DIR/move-copy.log" 2>/dev/null || { echo "$HOME_DIR/brain is still being copied, try again when it is done" >&2; exit 1; }

echo "== 1/4 Syncthing 1.x from the official repo"
# brain2 runs 1.29.5; its config and database move over as-is at cutover. Ubuntu 24.04 ships
# 1.27.2, older than that, which may refuse them. stable-v1 = newest 1.x, never a jump to 2.x.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://syncthing.net/release-key.gpg -o /etc/apt/keyrings/syncthing-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v1" \
    > /etc/apt/sources.list.d/syncthing.list
apt-get update -q
apt-get install -y -q syncthing
syncthing --version
systemctl disable --now syncthing@daniel 2>/dev/null || true

echo "   tools the cron jobs use (offsite: rclone, jq; LinkedIn job: requests)"
apt-get install -y -q rclone jq restic age python3-requests

echo "== 2/4 Brain units (as on brain2, from server/systemd/)"
for unit in brain-bot brain-chroma brain-indexer brain-mcp brain-mcp-bridge; do
    install -m 0644 "$UNITS/$unit.service" /etc/systemd/system/
done
for dir in brain-indexer.service.d brain-mcp.service.d brain-mcp-bridge.service.d; do
    install -d -m 0755 "/etc/systemd/system/$dir"
    install -m 0644 "$UNITS/$dir"/*.conf "/etc/systemd/system/$dir/"
done
# pc2 indexes on the GTX 1050 Ti, so the indexer loses brain2's CPU-only pin (the MCP server
# keeps it: a query is one short embedding). 4 cores here, not 14: leave one for the rest.
rm -f /etc/systemd/system/brain-indexer.service.d/cpu-only.conf
cat > /etc/systemd/system/brain-indexer.service.d/zz-pc2.conf <<'EOF'
# pc2: GPU indexing on a 4-core box. Sorts after limits.conf, so these values win.
[Service]
CPUQuota=300%
Environment=OMP_NUM_THREADS=3
Environment=MKL_NUM_THREADS=3
EOF
install -m 0644 "$UNITS/brain-client-gate.env" /etc/brain-client-gate.env

echo "== 3/4 firewall: Syncthing on the LAN"
ufw allow 22000/tcp comment syncthing
ufw allow 22000/udp comment syncthing
ufw allow 21027/udp comment syncthing-discovery

echo "== 4/4 start the index build"
systemctl daemon-reload
systemctl disable brain-bot 2>/dev/null || true
systemctl enable --now brain-chroma
sleep 5
systemctl enable --now brain-indexer brain-mcp brain-mcp-bridge
sleep 10
systemctl is-active brain-chroma brain-indexer brain-mcp brain-mcp-bridge
echo "done: pc2 is building the index. brain2 still serves; cutover comes next."
