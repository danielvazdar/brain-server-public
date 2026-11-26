#!/usr/bin/env bash
# CI runners live on the CI box (the Latitude since 2026-11-26) and are checked from brain over ssh.
# Expected: a stopped runner is named, and an unreachable CI box is one alert, never silence.
# Run: bash server/tests/test-monitor-ci-host.sh
# A fake `ssh` on PATH stands in for the CI box; the Telegram send goes to a dead proxy.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'BOT_TOKEN=test\nCHAT_ID=0\n' > "$TMP/env"
mkdir -p "$TMP/bin"

fake_ssh() {  # $1 = script body for the fake ssh
    printf '#!/usr/bin/env bash\n%s\n' "$1" > "$TMP/bin/ssh"
    chmod +x "$TMP/bin/ssh"
}

run_monitor() {
    rm -rf "$TMP/alerts.log" "$TMP/cooldown" "$TMP/state"
    PATH="$TMP/bin:$PATH" \
    BRAIN_MONITOR_ENV="$TMP/env" \
    BRAIN_MONITOR_ALERT_LOG="$TMP/alerts.log" \
    BRAIN_MONITOR_COOLDOWN_DIR="$TMP/cooldown" \
    BRAIN_MONITOR_STATE_DIR="$TMP/state" \
    https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 no_proxy=localhost,127.0.0.1 \
    bash "$HERE/../brain-monitor.sh" > /dev/null 2>&1 || true
}

fail() { echo "FAIL: $1"; echo "--- alert log:"; cat "$TMP/alerts.log" 2>/dev/null; exit 1; }

# The forced command on the CI box prints one systemctl line per runner, in CI_RUNNERS order, then df.
# 8 runners since 2026-11-16 (ops#89/#121): + ci-evemos-3, ci-evemos-4, ci-evemos-release.
# 9 since 2026-11-17: + ci-client-c.
# 10 since 2026-11-23: + ci-inpersonmarketing (last).
A='active\n'
ALL_UP="$A$A$A$A$A$A$A$A$A$A"

# One runner stopped: systemctl prints one line per unit and exits 3; df still prints.
fake_ssh "printf \"${A}failed\\n$A$A$A$A$A$A$A$A 40%%\\n\"; exit 3"
run_monitor
grep -q "danielvazdar-evemos.ci-evemos-2\` on the CI box is failed" "$TMP/alerts.log" \
    || fail "stopped runner on the CI box not reported"
! grep -q "danielvazdar-kyuro.ci-kyuro\` on the CI box" "$TMP/alerts.log" \
    || fail "a running runner was reported"

# CI box unreachable: ssh prints nothing and exits 255.
fake_ssh 'exit 255'
run_monitor
grep -q "CI box (\`daniel@100.73.52.11\`) unreachable" "$TMP/alerts.log" || fail "unreachable CI box not reported"

# All runners up, disk fine: no CI alert at all.
fake_ssh "printf \"${ALL_UP} 40%%\\n\""
run_monitor
! grep -qE "CI (runner|box)" "$TMP/alerts.log" || fail "CI alert while every runner is active"

# The release runner (8th) stopped: deploys wait on it, so it must be named.
fake_ssh "printf \"$A$A$A$A$A$A${A}inactive\\n$A$A 40%%\\n\"; exit 3"
run_monitor
grep -q "danielvazdar-evemos.ci-evemos-release\` on the CI box is inactive" "$TMP/alerts.log" \
    || fail "stopped release runner not reported"

# The summit runner (9th) stopped: named.
fake_ssh "printf \"$A$A$A$A$A$A$A${A}failed\\n$A 40%%\\n\"; exit 3"
run_monitor
grep -q "danielvazdar-client-c.ci-client-c\` on the CI box is failed" "$TMP/alerts.log" \
    || fail "stopped summit runner not reported"

# The In-Person Marketing runner (last in the list) stopped: named, and the disk line is still read.
fake_ssh "printf \"$A$A$A$A$A$A$A$A${A}failed\\n 40%%\\n\"; exit 3"
run_monitor
grep -q "danielvazdar-inpersonmarketing.ci-inpersonmarketing\` on the CI box is failed" "$TMP/alerts.log" \
    || fail "stopped inpersonmarketing runner not reported"
! grep -q "did not report its disk use" "$TMP/alerts.log" || fail "disk line misread after the last runner"

# Disk nearly full (ops#109): named with its percentage.
fake_ssh "printf \"${ALL_UP} 97%%\\n\""
run_monitor
grep -q "CI box disk at 97%" "$TMP/alerts.log" || fail "full CI box disk not reported"

# Forced command lost its df line: an alert, never a silently skipped check.
fake_ssh "printf \"${ALL_UP}\""
run_monitor
grep -q "CI box did not report its disk use" "$TMP/alerts.log" || fail "missing disk line not reported"

echo "PASS: the CI box's 10 runners + disk checked over ssh; stopped, full, unreported and unreachable all alert"
