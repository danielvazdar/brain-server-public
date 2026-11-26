#!/usr/bin/env bash
# Switch brain2 to ONE Chroma server holding the index (2026-11-02).
# Run ON brain2 after the new files are in ~/brain-staging:
#   bash ~/brain-staging/deploy-single-chroma.sh            # apply
#   bash ~/brain-staging/deploy-single-chroma.sh rollback   # undo
set -euo pipefail

LIVE=/home/daniel/brain-server
STAGE=/home/daniel/brain-staging
UNITS=/etc/systemd/system
TAG=bak-20261102-single-chroma
FILES=(indexer.py mcp_server.py)

wait_http() { # url, seconds
  for _ in $(seq 1 "$2"); do curl -fsS -o /dev/null "$1" && return 0; sleep 2; done
  echo "!! $1 did not answer" >&2; return 1
}

rollback() {
  sudo -n systemctl stop brain-mcp brain-indexer
  for f in "${FILES[@]}"; do cp "$LIVE/$f.$TAG" "$LIVE/$f"; done
  sudo -n rm -f "$UNITS/brain-indexer.service.d/chroma.conf" "$UNITS/brain-mcp.service.d/chroma.conf"
  sudo -n systemctl disable --now brain-chroma
  sudo -n rm -f "$UNITS/brain-chroma.service"
  sudo -n systemctl daemon-reload
  sudo -n systemctl start brain-indexer brain-mcp
  wait_http http://127.0.0.1:8080/health 120 && echo "rolled back OK"
}

[[ "${1:-}" == rollback ]] && { rollback; exit 0; }

echo "== preflight"
for f in chroma_client.py "${FILES[@]}" systemd/brain-chroma.service \
         systemd/brain-indexer.service.d/chroma.conf systemd/brain-mcp.service.d/chroma.conf; do
  [[ -f "$STAGE/$f" ]] || { echo "!! missing $STAGE/$f" >&2; exit 1; }
done
"$LIVE/venv/bin/python" -m py_compile "$STAGE/chroma_client.py" "$STAGE/indexer.py" "$STAGE/mcp_server.py"
if ss -ltn | grep -q ':8000 '; then echo "!! port 8000 already in use" >&2; exit 1; fi
for f in "${FILES[@]}"; do diff -u "$LIVE/$f" "$STAGE/$f" || true; done

echo "== backup"
for f in "${FILES[@]}"; do cp -n "$LIVE/$f" "$LIVE/$f.$TAG"; done

echo "== stop the two in-process index owners (one writer at a time)"
sudo -n systemctl stop brain-indexer brain-mcp

echo "== install + start brain-chroma"
sudo -n install -m 644 "$STAGE/systemd/brain-chroma.service" "$UNITS/"
sudo -n install -m 644 "$STAGE/systemd/brain-indexer.service.d/chroma.conf" "$UNITS/brain-indexer.service.d/"
sudo -n install -m 644 "$STAGE/systemd/brain-mcp.service.d/chroma.conf" "$UNITS/brain-mcp.service.d/"
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now brain-chroma
wait_http http://127.0.0.1:8000/api/v2/heartbeat 120 || { rollback; exit 1; }

echo "== new code + start"
install -m 644 "$STAGE/chroma_client.py" "${FILES[@]/#/$STAGE/}" "$LIVE/"
sudo -n systemctl start brain-mcp brain-indexer
wait_http http://127.0.0.1:8080/health 120 || { rollback; exit 1; }

echo "== result"
curl -fsS http://127.0.0.1:8080/health; echo
sleep 30
systemctl is-active brain-chroma brain-mcp brain-indexer brain-mcp-bridge
ps -eo rss,args --sort=-rss | head -4 | cut -c1-90
free -h | head -2
