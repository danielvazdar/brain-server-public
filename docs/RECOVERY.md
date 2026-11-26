# Brain recovery: when the Brain box won't come back

Updated 2026-11-26. **Brain is pc2**, a second-hand desktop: 16 GB, GTX 1050 Ti, 1 TB SATA HDD, no
battery. On the tailnet it is `brain` (100.73.52.9), on the LAN 192.168.1.117. CI runs on the
**Latitude** (`latitude`, 100.73.52.11, LAN .116). The **Inspiron** (`brain-old`, 100.73.52.10) is a
powered-off spare. Why: brain2 (the Latitude) went dark on 2026-11-24 after a loose wall plug drained
its battery (DECISIONS 2026-11-25).

## What stops while Brain is off
- Brain search for Claude sessions (MCP `brain`).
- **Backups.** The laptop, KVM1, Evemos and Client A restic repos live in `brain:~/backups/*-restic`, so nightly
  runs have nowhere to land. Offsite copy: Google Drive `brain-offsite/`, refreshed daily
  06:30 UTC, so the newest copy is from before the outage.
- **All outside monitoring** in `~/brain-monitor.sh`: the site/API checks, KVM restic freshness, the
  CI-runner check (the runners on the Latitude keep working, unwatched).
  Only the healthchecks.io dead-man (`brain-heartbeat.sh`) lives outside Brain, and that is what alerts.
- The Telegram bot, and the `grind.sh` cron job (every 2 h).

## Step 0: power
pc2 has no battery, so a power cut stops it at once. The BIOS turns it back on when power returns
(Restore AC Power Loss = Power On). **Until its CMOS coin battery (CR2032) is replaced (ops#142), a
power cut can reset the BIOS to defaults:** then pc2 stays off, or stops at "Press F1". Press power
(and F1), and with a monitor and keyboard set the three settings again: Restore AC Power Loss = Power
On, Wait for F1 If Error = Disabled, Secure Boot OS Type = Other OS.

## Path A: pc2 dead, disk fine (data intact)
1. The disk is a plain SATA HDD (no LVM, no encryption). Take it out and connect it to the Latitude with
   a USB-SATA adapter (~15 €). Mount it read-only.
2. The Latitude takes over as `brain`. **Until its old Brain data is wiped (about 2026-12-03, #34)** it
   still has the units, the crontab backup and the config from 2026-11-25. Copy the newer pieces from
   pc2's disk over them: `~/backups`, `~/brain`, `~/.local/share/chroma` (4 GB, the conversation-only
   index), `~/brain-server` (code and venv), `~/brain-*.{py,sh}`, `~/.config/brain-monitor.env` (it
   holds the bot token rotated on 2026-11-25), `~/.config/rclone`, `~/.local/state/syncthing`.
   After the wipe, copy everything: `pc2/brain-install.sh` lists every piece,
   including `/etc/systemd/system/brain-*` and the indexer drop-ins.
3. Copy pc2's `/etc/ssh/ssh_host_*`, `/etc/ssh/authorized_keys/daniel` and
   `/etc/ssh/sshd_config.d/00-hardening.conf`, so the laptop, KVM1 and KVM2 need no changes and the
   restic jobs simply resume.
4. Start Brain: `crontab ~/crontab.pre-pc2-move.txt` (or `server/crontab.txt`), then
   `sudo systemctl enable --now brain-chroma brain-indexer brain-mcp brain-mcp-bridge brain-bot syncthing@daniel`.
   In the Tailscale admin, set the dead pc2 to another IP first, then the Latitude to name `brain`,
   IP 100.73.52.9. Each IP change is a separate edit from the rename.
5. RAM: the Latitude has 14 GB, Brain uses ~4 GB, and the 10 CI runners use the rest when busy. If
   builds get OOM-killed, stop the Evemos runners until pc2 is back. The Inspiron spare can take
   either job: power it on and follow the same steps.

## Path B: disk dead too (rebuild)
| What | Where it survives |
|---|---|
| Project files (`~/brain/`) | the laptop (Syncthing source) |
| `~/.claude` config and session logs | the laptop (rsync source) |
| Brain code, systemd units, cron | this repo: `server/`, `pc2/brain-install.sh` |
| restic repos (laptop, KVM1, Evemos, Client A) | Google Drive `brain-offsite/`, download with rclone |
| restic passwords | on the machines that write them (laptop `/etc/restic`, KVM1 `~/.config/restic`, KVM2) |
| Search index | re-embed everything from `~/brain`: ~9 h on pc2 (first pass 2026-11-25; the disk, not the GPU, is the limit), longer on CPU |
| rclone Drive login | **only on Brain.** Scope is `drive.file`: a new OAuth client can't see files the old one made. If its client id is gone, download `brain-offsite/` in the Drive web UI instead |
| Telegram bot token, healthchecks URL (`brain-monitor.env`) | **only on Brain.** Get them again from BotFather and the healthchecks dashboard |
| Syncthing identity | new device id; pair again with the laptop and mainpc, Brain's folders receive-only |

Lost for good: the backup runs since the last offsite copy (each machine runs again the next night),
and the plain Client A SQL dumps (their contents are also inside `client-a-restic`).

## Gaps to close
1. ~~"On battery" alert in `brain-monitor.sh`.~~ Done 2026-11-25 (#30). pc2 has no battery, so the
   check skips itself there.
2. Second copy of the Brain-only secrets (`brain-monitor.env`, the rclone conf with its OAuth client id)
   in NordPass.
3. The site monitoring dies with Brain. Run a copy on the Latitude (#34).
4. The copy of this repo in `~/PROJECT/KYURO/brain-server` on mainpc has no `.git` and is older than
   GitHub. Work from GitHub or the box, never from that copy (#34).
5. pc2's CMOS battery and its 100 Mbit link (cable suspected), ops#142.

## If new hardware is bought
pc2 already covers most of what the last two boxes taught us: no battery, a network cable, a GPU for
indexing. Its limits are 16 GB of RAM (enough since sessions are indexed as conversation only: ~4 GB in
use) and a hard disk that slows indexing. A replacement should have 32 GB of RAM, a 1 TB SSD, and
"power on after AC loss" in the BIOS. Skip N100-class machines, they max out at 16 GB.
