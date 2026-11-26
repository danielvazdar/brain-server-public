# brain-server

Scripts and services for my home server. It's a laptop on my desk that holds the backups of my other machines, watches my websites and keeps a searchable index of my notes and work logs.

This is a public copy of a private repo, with its own fresh history. Client names and account details are replaced with placeholders such as `client-a.example`.

## What's in it

- `server/brain-monitor.sh` runs from cron every five minutes. It checks disk space, the services below, the CI runners on a second machine, Tailscale, how fresh each restic backup is, whether the websites answer, TLS certificate expiry, and whether the laptop is still on mains power. Problems go to Telegram. A website or certificate check has to fail twice in a row before it alerts, so one slow response doesn't page me.
- `server/brain-heartbeat.sh` pings healthchecks.io every five minutes, so a server that is completely down still gets noticed from outside.
- `server/brain-offsite-backup.sh` copies the restic repositories to Google Drive every morning with rclone. It checks the copy and only then writes the stamp the monitor looks for.
- `server/indexer.py` watches a folder of notes and session logs and embeds them into ChromaDB. `mcp_server.py` serves search over HTTP, `mcp_bridge.py` exposes it as MCP tools, and `client_gate.py` lets only my own machines in.
- `server/brain-bot.py` is a Telegram bot that answers `/status`.
- `ci-box/` sets up self-hosted GitHub Actions runners on a second laptop. Each runner has its own OS user, and the jobs that need Docker get a rootless Docker of their own.
- `pc2/` installs everything on a new machine, and `docs/RECOVERY.md` is the runbook for when the server dies.

## Tests

```sh
cd server
pip install -r requirements.txt pytest
python -m pytest tests                     # 51 tests
for t in tests/*.sh; do bash "$t"; done    # monitor and offsite-backup tests, with faked commands on PATH
```
