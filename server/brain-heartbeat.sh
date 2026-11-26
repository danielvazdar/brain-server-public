#!/usr/bin/env bash
# Brain Server Heartbeat — pings healthchecks.io to detect total server failure
# If this stops pinging, healthchecks.io alerts via Telegram
# Cron: */5 * * * * /home/daniel/brain-heartbeat.sh
#
# SETUP: Replace PING_URL with your healthchecks.io ping URL
# 1. Sign up at https://healthchecks.io (free, 20 checks)
# 2. Create a check named "Brain Server Heartbeat", period 5 min, grace 10 min
# 3. Add Telegram integration (Settings → Integrations → Telegram)
# 4. Paste the ping URL below

PING_URL="${HEALTHCHECKS_PING_URL:-https://hc-ping.com/27a0adf3-465a-4239-9fd3-7949b3da03b4}"

if [[ -z "$PING_URL" ]]; then
    # No healthchecks.io configured — skip silently
    exit 0
fi

curl -fsS --retry 3 --max-time 10 "$PING_URL" > /dev/null 2>&1
