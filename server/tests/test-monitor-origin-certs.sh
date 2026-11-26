#!/usr/bin/env bash
# KVM2's own TLS certs are read over the tailnet, not only Cloudflare's edge cert (2026-11-17:
# mta-sts.client-a.example's server cert was past its renewal date and nothing said so).
# Expected: an origin cert close to expiry, or unreadable, alerts and names "(KVM2 origin)";
# healthy origin certs stay quiet.
# Run: bash server/tests/test-monitor-origin-certs.sh
# Fakes on PATH: curl (every site answers 200, so the box is "online"), ssh (CI box all up),
# openssl (s_client echoes host + address; x509 turns that into an expiry date).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'BOT_TOKEN=test\nCHAT_ID=0\n' > "$TMP/env"
mkdir -p "$TMP/bin"
TAILNET=100.112.188.71

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ $a == "%{http_code}" ]] && { printf 200; exit 0; }; done
exit 0
EOF
printf '#!/usr/bin/env bash\nfor i in $(seq 9); do echo active; done; echo " 40%%"\n' > "$TMP/bin/ssh"
chmod +x "$TMP/bin/curl" "$TMP/bin/ssh"

fake_openssl() {  # $1 = host whose origin cert expires in 5 days, $2 = host whose origin is unreadable
    cat > "$TMP/bin/openssl" <<EOF
#!/usr/bin/env bash
if [[ \$1 == s_client ]]; then
    host="" addr=""
    while (( \$# )); do
        case \$1 in -servername) host=\$2; shift ;; -connect) addr=\$2; shift ;; esac
        shift
    done
    [[ \$host == "$2" && \$addr == "$TAILNET:443" ]] && exit 1
    echo "HOST \$host ADDR \$addr"
    exit 0
fi
read -r _ host _ addr || exit 1
if [[ \$host == "$1" && \$addr == "$TAILNET:443" ]]; then days=5; else days=60; fi
echo "notAfter=\$(LC_ALL=C date -u -d "+\$days days" '+%b %e %H:%M:%S %Y GMT')"
EOF
    chmod +x "$TMP/bin/openssl"
}

run_monitor_twice() {  # outside issues alert on the 2nd strike in a row
    rm -rf "$TMP/alerts.log" "$TMP/cooldown" "$TMP/state"
    for _ in 1 2; do
        PATH="$TMP/bin:$PATH" \
        BRAIN_MONITOR_ENV="$TMP/env" \
        BRAIN_MONITOR_ALERT_LOG="$TMP/alerts.log" \
        BRAIN_MONITOR_COOLDOWN_DIR="$TMP/cooldown" \
        BRAIN_MONITOR_STATE_DIR="$TMP/state" \
        BRAIN_MONITOR_CERTS_NOW=1 \
        bash "$HERE/../brain-monitor.sh" > /dev/null 2>&1 || true
    done
}

fail() { echo "FAIL: $1"; echo "--- alert log:"; cat "$TMP/alerts.log" 2>/dev/null; exit 1; }

# mta-sts's server cert is 5 days from expiry while Cloudflare's edge cert is fine.
fake_openssl mta-sts.client-a.example none
run_monitor_twice
grep -q "TLS certificate for mta-sts.client-a.example (KVM2 origin) expires in" "$TMP/alerts.log" \
    || fail "expiring KVM2 origin cert not reported"
! grep -q "TLS certificate for client-a.example" "$TMP/alerts.log" || fail "healthy cert reported"
# The fake curl serves pages without Ghost's data-key: that must be one alert, and must not end
# the run before the report (pipefail did, until 2026-11-17).
grep -q "Client News publisher: newest post unreadable" "$TMP/alerts.log" \
    || fail "unreadable Ghost feed ended the run silently"

# KVM2 does not answer for one host over the tailnet: unreadable is an alert, not silence.
fake_openssl none summit.client-a.example
run_monitor_twice
grep -q "TLS certificate for summit.client-a.example (KVM2 origin) could not be read" "$TMP/alerts.log" \
    || fail "unreadable KVM2 origin cert not reported"

# Everything healthy: no certificate alert at all.
fake_openssl none none
run_monitor_twice
! grep -q "TLS certificate" "$TMP/alerts.log" || fail "certificate alert while every cert is fine"

echo "PASS: KVM2 origin certs checked over the tailnet; expiring and unreadable both alert"
