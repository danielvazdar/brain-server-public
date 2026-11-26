#!/usr/bin/env bash
# Reproduces 2026-09-23 / 09-25: brain's own uplink saturated, every outside probe returns
# HTTP 000. Expected: one "Brain server has no internet" issue, no "<site> DOWN" issue, and
# the per-site strike counters untouched. A dead proxy makes every outbound request fail
# instantly, including the Telegram send, so nothing leaves the box and no live state is used.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'BOT_TOKEN=test\nCHAT_ID=0\n' > "$TMP/env"

run_monitor() {
    BRAIN_MONITOR_ENV="$TMP/env" \
    BRAIN_MONITOR_ALERT_LOG="$TMP/alerts.log" \
    BRAIN_MONITOR_COOLDOWN_DIR="$TMP/cooldown" \
    BRAIN_MONITOR_STATE_DIR="$TMP/state" \
    https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 no_proxy=localhost,127.0.0.1 \
    bash "$HERE/../brain-monitor.sh" > /dev/null 2>&1 || true
}

run_monitor   # strike 1: nothing reported yet
run_monitor   # strike 2: the offline verdict must appear

fail() { echo "FAIL: $1"; echo "--- alert log:"; cat "$TMP/alerts.log" 2>/dev/null; exit 1; }

grep -q "Brain server has no internet" "$TMP/alerts.log" 2>/dev/null \
    || fail "offline verdict not reported after two strikes"
! grep -q "DOWN (HTTP" "$TMP/alerts.log" \
    || fail "sites reported DOWN while the brain itself was offline"
[[ -z "$(ls "$TMP/state"/url-*.fails 2>/dev/null)" ]] \
    || fail "per-site strike counters were touched while offline"
[[ ! -d "$TMP/cooldown" || -z "$(ls "$TMP/cooldown" 2>/dev/null)" ]] \
    || fail "a failed Telegram send started the cooldown"
echo "PASS: offline reported as offline, no site paged as DOWN"
