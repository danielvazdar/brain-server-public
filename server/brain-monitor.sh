#!/usr/bin/env bash
# Brain Server Monitor — checks services, resources, and alerts via Telegram
# Deployed to brain server at /home/daniel/brain-monitor.sh
# Cron: */5 * * * * /home/daniel/brain-monitor.sh

set -euo pipefail

CONFIG_FILE="${BRAIN_MONITOR_ENV:-/home/daniel/.config/brain-monitor.env}"
if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "FATAL: $CONFIG_FILE missing or unreadable - refusing to run blind" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${BOT_TOKEN:?BOT_TOKEN not set in $CONFIG_FILE}"
: "${CHAT_ID:?CHAT_ID not set in $CONFIG_FILE}"
ALERT_COOLDOWN_DIR="${BRAIN_MONITOR_COOLDOWN_DIR:-/tmp/brain-monitor-cooldown}"
COOLDOWN_MINUTES=30
# Every alert is also written here. Without it the only record of what this script
# said is the Telegram chat, so a burst of overnight alerts cannot be diagnosed
# afterwards (2026-09-22: 3 days of "no offsite laptop stamp" alerts, no local trace).
ALERT_LOG="${BRAIN_MONITOR_ALERT_LOG:-/home/daniel/brain-monitor-alerts.log}"

# Thresholds
DISK_THRESHOLD=85
MEMORY_THRESHOLD=90
LOAD_THRESHOLD=$(nproc)  # 1.0 per core

mkdir -p "$ALERT_COOLDOWN_DIR"

log_alert() {
    printf '[%s] %s\n' "$(date -u '+%F %T UTC')" "$1" >> "$ALERT_LOG" 2>/dev/null || true
}

send_alert() {
    local key="$1"
    local message="$2"
    local cooldown_file="$ALERT_COOLDOWN_DIR/$key"

    # Check cooldown — don't spam the same alert
    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(cat "$cooldown_file")
        local now
        now=$(date +%s)
        local diff=$(( now - last_alert ))
        if (( diff < COOLDOWN_MINUTES * 60 )); then
            return 0
        fi
    fi

    # A failed send is logged and NOT put on cooldown, so the next run retries.
    if ! curl -sf --max-time 20 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$message" > /dev/null 2>&1; then
        log_alert "SEND-FAILED $key"
        return 0
    fi

    log_alert "SENT    $key"
    date +%s > "$cooldown_file"
}

clear_alert() {
    local key="$1"
    [[ -f "$ALERT_COOLDOWN_DIR/$key" ]] && log_alert "CLEARED $key"
    rm -f "$ALERT_COOLDOWN_DIR/$key"
}

ISSUES=()

# --- Check services ---
# No docker: it only ever served the CI runners, which left Brain on 2026-10-28; pc2 (Brain since
# 2026-11-25) doesn't run it. brain-bot is listed so a dead Telegram /status is noticed.
SERVICES=("brain-chroma" "brain-indexer" "brain-mcp" "brain-mcp-bridge" "brain-bot" "syncthing@daniel")
for svc in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$svc"; then
        ISSUES+=("Service \`$svc\` is DOWN")
    fi
done

# --- Check the CI runners on the CI box ---
# 2026-10-28: CI moved back to the old box (brain-old). brain2 + 5 runners did
# not fit in 16 GB (OOM-killed builds 27.10). Checked from here over ssh, so a
# dead CI box alerts instead of going quiet with it. The key is restricted on brain-old
# (/etc/ssh/authorized_keys/daniel: `restrict,command="systemctl is-active <these units>;
# df --output=pcent / | tail -n1"`): it can only ask. One line per runner, then the disk line.
# 2026-11-11 (ops#109): brain-old's disk filled to 100% with CI images and every job failed
# unseen, because only brain's own disk was watched.
# 2026-11-26 (#34): CI moved to the Latitude (tailnet `latitude`); its runners are named ci-<user>.
CI_HOST="${CI_HOST:-daniel@100.73.52.11}"
CI_KEY="${CI_KEY:-/home/daniel/.ssh/ci_check_ed25519}"
CI_RUNNERS=("actions.runner.danielvazdar-evemos.ci-evemos-1" "actions.runner.danielvazdar-evemos.ci-evemos-2" "actions.runner.danielvazdar-kyuro.ci-kyuro" "actions.runner.danielvazdar-client-a.ci-client-a" "actions.runner.danielvazdar-client-b.ci-client-b" "actions.runner.danielvazdar-evemos.ci-evemos-3" "actions.runner.danielvazdar-evemos.ci-evemos-4" "actions.runner.danielvazdar-evemos.ci-evemos-release" "actions.runner.danielvazdar-client-c.ci-client-c" "actions.runner.danielvazdar-inpersonmarketing.ci-inpersonmarketing")
if CI_STATE=$(ssh -i "$CI_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ControlPath=none "$CI_HOST" systemctl is-active "${CI_RUNNERS[@]}" 2>/dev/null) || [[ -n "$CI_STATE" ]]; then
    mapfile -t CI_LINES <<< "$CI_STATE"
    for i in "${!CI_RUNNERS[@]}"; do
        if [[ "${CI_LINES[$i]:-}" != "active" ]]; then
            ISSUES+=("CI runner \`${CI_RUNNERS[$i]}\` on the CI box is ${CI_LINES[$i]:-unknown}")
        fi
    done
    CI_DISK="${CI_LINES[${#CI_RUNNERS[@]}]:-}"
    CI_DISK="${CI_DISK//[^0-9]/}"
    if [[ -z "$CI_DISK" ]]; then
        ISSUES+=("CI box did not report its disk use (forced command lost its \`df\`?)")
    elif (( CI_DISK > DISK_THRESHOLD )); then
        ISSUES+=("CI box disk at ${CI_DISK}% (threshold: ${DISK_THRESHOLD}%) - every CI job fails when it is full")
    fi
else
    ISSUES+=("CI box (\`$CI_HOST\`) unreachable over ssh - all CI runners unchecked")
fi

# --- Check tailnet membership ---
# 2026-10-06: the node key expired and tailscaled sat "Logged out." for 22h.
# Internet stayed up, so the healthchecks.io heartbeat kept passing and nothing
# alerted — but brain was unreachable from the tailnet and every laptop sync
# failed. Telegram still delivers in this state, so alert from here.
TS_STATE=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
if [[ "$TS_STATE" != "Running" ]]; then
    ISSUES+=("Tailscale off the tailnet (state: ${TS_STATE:-unknown}) — key expired? Fix: \`sudo tailscale up\`")
fi

# --- Check health endpoint ---
if ! curl -sf http://localhost:8080/health > /dev/null 2>&1; then
    ISSUES+=("Health endpoint (localhost:8080/health) not responding")
fi

# --- Check that a real search works ---
# /health only counts the collection; it never embeds a query. On 2026-09-17 a
# reboot made torch pick an unsupported GPU: /health said healthy while every
# /search returned 500. Exercise the actual path.
if ! curl -sf -m 60 -X POST http://localhost:8080/search \
        -H "content-type: application/json" \
        -d "{\"query\":\"brain monitor probe\",\"n_results\":1}" | grep -q "\"results\""; then
    ISSUES+=("Search (/search) failing - queries return errors")
fi

# --- Check disk usage ---
DISK_USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')
if (( DISK_USAGE > DISK_THRESHOLD )); then
    ISSUES+=("Disk usage at ${DISK_USAGE}% (threshold: ${DISK_THRESHOLD}%)")
fi

# --- Check memory usage ---
MEM_USAGE=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
if (( MEM_USAGE > MEMORY_THRESHOLD )); then
    ISSUES+=("Memory usage at ${MEM_USAGE}% (threshold: ${MEMORY_THRESHOLD}%)")
fi

# --- Check load average ---
LOAD_1M=$(awk '{print $1}' /proc/loadavg)
# CI runs on brain-old since 2026-10-28; the ghrunner check below only matters if a
# runner is started here again. While a job runs, load near 2x cores is expected.
# Alert above 3x then, so a real runaway still shows; otherwise 2x.
LOAD_LIMIT=$(( LOAD_THRESHOLD * 2 ))
if pgrep -u ghrunner -x Runner.Worker >/dev/null 2>&1; then
    LOAD_LIMIT=$(( LOAD_THRESHOLD * 3 ))
fi
if awk "BEGIN {exit !($LOAD_1M > $LOAD_LIMIT)}"; then
    ISSUES+=("Load average ${LOAD_1M} (threshold: ${LOAD_LIMIT})")
fi

# --- Check backup freshness ---
# Monitors OUTPUTS, not producer liveness: producers (laptop restic timer,
# KVM2 backup cron) can fail silently on their side — the only trustworthy
# signal is whether fresh backup files actually land here.
# Added 2026-07-06 after laptop restic prune failed silently Jun 8 → Jul 6.
check_backup_freshness() {
    local name="$1" dir="$2" pattern="$3" max_hours="$4"
    if [[ ! -d "$dir" ]]; then
        ISSUES+=("Backup dir missing: \`$dir\`")
        return
    fi
    local newest now age_hours
    newest=$(find "$dir" -type f -name "$pattern" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [[ -z "$newest" ]]; then
        ISSUES+=("No backups matching \`$pattern\` in \`$dir\`")
        return
    fi
    now=$(date +%s)
    age_hours=$(( (now - ${newest%.*}) / 3600 ))
    if (( age_hours > max_hours )); then
        ISSUES+=("${name} backup STALE: newest is ${age_hours}h old (max ${max_hours}h)")
    fi
}
# Laptop restic: daily at noon, but laptop may be off/away — allow 72h.
check_backup_freshness "Laptop restic" /home/daniel/backups/laptop-restic/snapshots '*' 72
# Client A restic (Ghost content): nightly 03:00 UTC from KVM2 — allow 30h.
check_backup_freshness "Client A Ghost restic" /home/daniel/backups/client-a-restic/snapshots '*' 30
# Client A MySQL dumps: nightly 03:00 UTC via rsync — allow 30h.
check_backup_freshness "Client A MySQL" /home/daniel/backups/client-a 'mysql_*.sql.gz*' 30
# Client A Postgres PII dumps (registrations/accreditation + CRM) — the crown jewels, previously
# unwatched (KVM2 audit 2026-09-19 C-02/D-06). `pg_client-a_2*` = the dated nightly, excluding the
# `pg_client-a_pre-*` manual dumps and the crm one (checked separately). Allow 30h.
# `.sql.gz*` matches both the plain dumps and the age-encrypted `.sql.gz.age` ones (2026-09-26).
check_backup_freshness "Client A Postgres (site)" /home/daniel/backups/client-a 'pg_client-a_2*.sql.gz*' 30
check_backup_freshness "Client A Postgres (CRM)" /home/daniel/backups/client-a 'pg_client-a_crm_*.sql.gz*' 30

# Offsite copy to Google Drive (brain-offsite-backup.sh, daily 06:30 UTC) — allow 36h.
# The stamp is written only after every repo synced AND verified.
# Per repo (audit 2026-09-19 C-03): KVM1 + Client A daily, the 34 GB laptop repo gets a week.
check_backup_freshness "Offsite KVM1" /home/daniel/backups '.offsite-last-success-kvm1-restic' 36
check_backup_freshness "Offsite Client A" /home/daniel/backups '.offsite-last-success-client-a-restic' 36
check_backup_freshness "Offsite laptop" /home/daniel/backups '.offsite-last-success-laptop-restic' 168
check_backup_freshness "Offsite Evemos" /home/daniel/backups '.offsite-last-success-evemos-restic' 36
# KVM1 restic: nightly kvm1-backup.timer pushes here — allow 30h.
check_backup_freshness "KVM1 restic" /home/daniel/backups/kvm1-restic/snapshots '*' 30
# Evemos restic (evemos-restic since evemos F-152c): nightly evemos-backup.timer on KVM1 (03:30 UTC) — allow 30h.
check_backup_freshness "Evemos restic" /home/daniel/backups/evemos-restic/snapshots '*' 30

# --- Outside-in checks: what a customer sees (added 2026-09-17) ---
# Brain is a different network from both VPSes, so these catch what the servers' own
# monitors can't: a firewall/DNS/Cloudflare cut (SFS + SVG were down 11 days in Sept and
# nothing on the box noticed) or a job that stopped producing output.
# A check must fail twice in a row (10 min) before it counts, so one slow reply isn't a page.
OUTSIDE_STATE_DIR="${BRAIN_MONITOR_STATE_DIR:-/home/daniel/.local/state/brain-monitor}"
mkdir -p "$OUTSIDE_STATE_DIR"

outside_issue() {
    local key="$1" message="$2" failed="$3"
    local counter="$OUTSIDE_STATE_DIR/$key.fails"
    if [[ "$failed" != "1" ]]; then
        rm -f "$counter"
        return
    fi
    local fails
    fails=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    echo "$fails" > "$counter"
    if (( fails >= 2 )); then
        ISSUES+=("$message")
    fi
}

# check_url only records; report_outside_urls decides. If NOT ONE probe managed to connect
# (curl code 000) the sites are not down, this box is offline: 2026-09-23 and 09-25 the
# 06:30 offsite upload saturated the ~6 Mbit/s home uplink and five sites on three servers
# were paged as DOWN at once. Per-site strike counters are left untouched in that case.
URL_KEYS=()
URL_MSGS=()
URL_FAILED=()
URL_NOCONN=0
BRAIN_OFFLINE=0

check_url() {
    local name="$1" url="$2" code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -A brain-monitor "$url" || true)
    URL_KEYS+=("url-$name")
    if [[ "$code" =~ ^[23] ]]; then
        URL_MSGS+=("")
        URL_FAILED+=(0)
    else
        URL_MSGS+=("${name} DOWN (HTTP ${code:-none}) ${url}")
        URL_FAILED+=(1)
        if [[ -z "$code" || "$code" == "000" ]]; then
            URL_NOCONN=$(( URL_NOCONN + 1 ))
        fi
    fi
}

report_outside_urls() {
    local total=${#URL_KEYS[@]} i
    if (( total > 0 && URL_NOCONN == total )); then
        BRAIN_OFFLINE=1
        outside_issue "brain-offline" \
            "Brain server has no internet: none of ${total} outside checks could connect (sites NOT known to be down)" 1
        return
    fi
    outside_issue "brain-offline" "" 0
    for (( i = 0; i < total; i++ )); do
        outside_issue "${URL_KEYS[i]}" "${URL_MSGS[i]}" "${URL_FAILED[i]}"
    done
}

check_cert() {  # $1 host, $2 min days, [$3 address to connect to, $4 where (e.g. "KVM2 origin")]
    local host="$1" min_days="$2" connect="${3:-$1}" where="${4:-}" end_epoch days key name
    key="cert-$host${where:+-origin}"
    name="$host${where:+ ($where)}"
    end_epoch=$(echo | timeout 20 openssl s_client -servername "$host" -connect "$connect:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || true)
    if [[ -z "$end_epoch" ]]; then
        outside_issue "$key" "TLS certificate for ${name} could not be read" 1
        return
    fi
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
    if (( days >= min_days )); then
        outside_issue "$key" "" 0
    else
        outside_issue "$key" "TLS certificate for ${name} expires in ${days} days" 1
    fi
}

# Ghost sites only. Asks the Content API for the newest post by created_at, i.e. when
# WE published it. RSS <pubDate> is published_at, which Client News backdates to the
# source story's date, so on a slow news day a working publisher looked dead (2026-10-05).
# The Content API key is public by design (Ghost prints it in every page as data-key).
check_ghost_fresh() {
    local name="$1" site="$2" max_hours="$3" key newest age_hours
    # `|| true`: with pipefail a page without data-key (site down, CF challenge) used to end the
    # whole monitor run here, so nothing at all was reported (found 2026-11-17).
    key=$(curl -s --max-time 20 -A brain-monitor "$site/" | grep -oE 'data-key="[a-f0-9]+"' | head -1 | cut -d'"' -f2 || true)
    newest=""
    if [[ -n "$key" ]]; then
        newest=$(curl -s --max-time 20 -A brain-monitor \
            "$site/ghost/api/content/posts/?key=${key}&limit=1&order=created_at%20desc&fields=created_at" \
            | jq -r '.posts[0].created_at // empty' 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null || true)
    fi
    if [[ -z "$newest" ]]; then
        outside_issue "feed-$name" "${name}: newest post unreadable at ${site}" 1
        return
    fi
    age_hours=$(( ($(date +%s) - newest) / 3600 ))
    if (( age_hours <= max_hours )); then
        outside_issue "feed-$name" "" 0
    else
        outside_issue "feed-$name" "${name}: nothing published for ${age_hours}h (max ${max_hours}h)" 1
    fi
}

check_url "kyuro.tech" https://kyuro.tech/
check_url "Kyuro funnel API" https://webinar.kyuro.tech/api/health
check_url "DocuSeal" https://sign.kyuro.tech/
check_url "client-a.example" https://client-a.example/
check_url "Client News" https://client-news.example/
check_url "client-b.example" https://client-b.example/
check_url "client-c.example" https://client-c.example/
check_url "Kyuro sajam app" https://demo.kyuro.tech/sajam/api/zdravlje
# Evemos: the final hosts, never expono.events (it 301s, and check_url counts any 3xx as up).
# The app host's /admin sits behind Cloudflare Access (always 302), so watch the organiser sign-in page.
check_url "Evemos" https://evemos.events/api/health
check_url "Evemos app" https://app.evemos.events/login
check_url "Evemos mail" https://evemos.events/api/health/mail
# The hourly 24-month retention sweep (evemos F-142d, #546): red when the scheduler stopped,
# a sweep gave up within 24 h, or one is stuck over 2 h (evemos docs/GDPR.md has the recovery).
check_url "Evemos retention" https://evemos.events/api/health/retention
report_outside_urls

# Certificates: once an hour is plenty (minute 0–4 window of the */5 cron).
# Skipped while offline: an unreadable cert would be the same false alarm.
if (( BRAIN_OFFLINE == 0 && ( ${BRAIN_MONITOR_CERTS_NOW:-0} == 1 || 10#$(date +%M) < 5 ) )); then
    for host in kyuro.tech webinar.kyuro.tech sign.kyuro.tech client-a.example client-news.example \
                client-b.example client-c.example evemos.events app.evemos.events; do
        check_cert "$host" 14
    done
    # 2026-11-17: behind Cloudflare the check above only sees Cloudflare's own edge cert.
    # mta-sts.client-a.example's server cert sat 5 days past its renewal date unseen (certbot could
    # not reach it). So KVM2's own certs are read over the tailnet; 21 days = certbot (renews
    # at 30) has failed for 9 days. KVM1 needs none: its sites are DNS-only or use a CF origin cert.
    for host in client-a.example staging.client-a.example summit.client-a.example analytics.client-a.example \
                mta-sts.client-a.example client-news.example analytics.client-news.example \
                client-b.example client-c.example; do
        check_cert "$host" 21 "${KVM2_TAILNET_IP:-100.112.188.71}" "KVM2 origin"
    done
fi

# Client News publisher runs ~12× a day; a day with no post means it stopped.
if (( BRAIN_OFFLINE == 0 )); then
    check_ghost_fresh "Client News publisher" https://client-news.example 24
fi

# --- Check mains power (added 2026-11-25) ---
# Brain is a laptop. On 2026-11-24 its wall plug slipped at 17:39; it ran 6 h on battery and
# powered off at 23:42 with nothing said, because nothing here looked at power. This fires
# while the box still runs, so there are hours left to push the plug back in. Two runs in a
# row (10 min) before it counts, so wiggling the plug isn't a page. The USB-C ports show up
# as type USB; the Mains supply (AC) is the one that says whether the charger feeds the box.
POWER_DIR="${BRAIN_MONITOR_POWER_DIR:-/sys/class/power_supply}"

check_mains_power() {
    local supply type has_mains=0 mains_online=0 battery_pct=""
    for supply in "$POWER_DIR"/*; do
        [[ -r "$supply/type" ]] || continue
        type=$(cat "$supply/type")
        if [[ "$type" == "Mains" ]]; then
            has_mains=1
            if [[ "$(cat "$supply/online" 2>/dev/null || true)" == "1" ]]; then
                mains_online=1
            fi
        elif [[ "$type" == "Battery" && -z "$battery_pct" ]]; then
            battery_pct=$(cat "$supply/capacity" 2>/dev/null || true)
        fi
    done
    # No mains supply listed (a desktop, or no sysfs): nothing to judge.
    (( has_mains == 1 )) || return 0
    if (( mains_online == 1 )); then
        outside_issue "on-battery" "" 0
    else
        outside_issue "on-battery" \
            "Brain is running on battery (${battery_pct:-?}% left): the charger is not powering it. Check the wall plug" 1
    fi
}
check_mains_power

# --- Check uptime (just rebooted?) ---
UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime)
if (( UPTIME_SECONDS < 300 )); then
    UPTIME_HUMAN=$(uptime -p)
    ISSUES+=("Server just rebooted — ${UPTIME_HUMAN}")
fi

# --- Report ---
if (( ${#ISSUES[@]} > 0 )); then
    ISSUE_TEXT=""
    for issue in "${ISSUES[@]}"; do
        ISSUE_TEXT+="• ${issue}\n"
    done
    log_alert "ISSUES  $(printf '%b' "$ISSUE_TEXT" | paste -sd'|' -)"
    send_alert "brain-issues" "$(printf '🔴 *Brain Server Alert*\n\n%b\n_%s_' "$ISSUE_TEXT" "$(date '+%Y-%m-%d %H:%M:%S')")"
else
    clear_alert "brain-issues"
fi
