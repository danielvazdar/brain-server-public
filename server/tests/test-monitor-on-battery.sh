#!/usr/bin/env bash
# Reproduces 2026-11-24: brain2's wall plug slipped at 17:39, it ran 6 h on battery and
# powered off at 23:42 with no alert. Expected: "running on battery" after two runs on
# battery, nothing after one (a wiggled plug), nothing with mains back, nothing on a box
# without a mains supply. A fake sysfs stands in for /sys/class/power_supply; a dead proxy
# keeps every outbound request (and the Telegram send) on the box.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'BOT_TOKEN=test\nCHAT_ID=0\n' > "$TMP/env"

fake_supply() {  # $1 name, $2 type, $3 online, [$4 capacity]
    mkdir -p "$TMP/power/$1"
    echo "$2" > "$TMP/power/$1/type"
    echo "$3" > "$TMP/power/$1/online"
    [[ -z "${4:-}" ]] || echo "$4" > "$TMP/power/$1/capacity"
}

run_monitor() {
    BRAIN_MONITOR_ENV="$TMP/env" \
    BRAIN_MONITOR_ALERT_LOG="$TMP/alerts.log" \
    BRAIN_MONITOR_COOLDOWN_DIR="$TMP/cooldown" \
    BRAIN_MONITOR_STATE_DIR="$TMP/state" \
    BRAIN_MONITOR_POWER_DIR="$TMP/power" \
    https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 no_proxy=localhost,127.0.0.1 \
    bash "$HERE/../brain-monitor.sh" > /dev/null 2>&1 || true
}

fail() { echo "FAIL: $1"; echo "--- alert log:"; cat "$TMP/alerts.log" 2>/dev/null; exit 1; }
on_battery_reported() { grep -q "running on battery" "$TMP/alerts.log" 2>/dev/null; }

# brain2's real layout: AC is the Mains supply, the USB-C ports are type USB.
fake_supply AC Mains 0
fake_supply BAT0 Battery "" 42
fake_supply ucsi-source-psy-USBC000:001 USB 0

run_monitor
! on_battery_reported || fail "paged after one run on battery (a wiggled plug would page)"
run_monitor
on_battery_reported || fail "two runs on battery and no alert"
grep -q "running on battery (42% left)" "$TMP/alerts.log" || fail "alert does not say how much battery is left"

echo 1 > "$TMP/power/AC/online"
: > "$TMP/alerts.log"
run_monitor
run_monitor
! on_battery_reported || fail "still reported on battery with mains back"
[[ ! -e "$TMP/state/on-battery.fails" ]] || fail "strike counter not cleared when mains came back"

rm -rf "$TMP/power/AC" "$TMP/state"
: > "$TMP/alerts.log"
run_monitor
run_monitor
! on_battery_reported || fail "a box with no mains supply was reported on battery"

echo "PASS: on battery reported after two runs, cleared when mains is back"
