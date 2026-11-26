#!/usr/bin/env bash
# pc2 first setup: the second-hand desktop (ASUS H110M-R, i5-7400, 16 GB, 1 TB HDD, GTX 1050 Ti)
# on trial as either the backup/monitoring box or the next Brain (DECISIONS 2026-11-25).
#
# Run once, from a real terminal on the laptop/mainpc, so the Tailscale login link can be clicked:
#     scp pc2/setup.sh daniel@192.168.1.117:~/ && ssh -t daniel@192.168.1.117 'sudo bash ~/setup.sh'
#
# What it does, in order (every step is safe to run again):
#   1. system upgrade + the few tools the other boxes have (sysstat, smartmontools)
#   2. SSH: keys only, no root login (a 10- drop-in wins over cloud-init's 50- file)
#   3. firewall: deny incoming except SSH and the tailnet
#   4. never suspend (it's a server)
#   5. Tailscale, without Tailscale SSH (off on all boxes since 2026-10-25); prints a login link
#   6. NVIDIA 580-server driver, precompiled modules, headless. 580 is the last branch for Pascal.
#   7. disk health summary, then reboot so the new kernel and driver load
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || { echo "run as daniel via sudo, not as root directly" >&2; exit 1; }

LOG=/var/log/pc2-setup.log
exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
say() { printf '\n== %s\n' "$*"; }

say "1/7 system upgrade"
# The installer picked the Croatian mirror (hr.archive.ubuntu.com); on 2026-11-25 it was unreachable
# and the upgrade failed. The main archive is always up; a few km of locality isn't worth the risk.
sed -i -E 's#http://[a-z]+\.archive\.ubuntu\.com/ubuntu/#http://archive.ubuntu.com/ubuntu/#' \
    /etc/apt/sources.list.d/ubuntu.sources
grep '^URIs' /etc/apt/sources.list.d/ubuntu.sources
apt-get update -q
apt-get full-upgrade -y -q
apt-get install -y -q ufw sysstat smartmontools python3-venv git curl
sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
systemctl enable --now sysstat

say "2/7 SSH: keys only"
# Refuse to lock ourselves out: the invoking user must already have a key in place.
[[ -s "/home/$SUDO_USER/.ssh/authorized_keys" ]] || { echo "no authorized_keys for $SUDO_USER, not touching SSH" >&2; exit 1; }
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
# pc2 setup.sh: keys only. 10- sorts before cloud-init's 50- file, and sshd keeps the first value.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sshd -t
systemctl try-reload-or-restart ssh
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '

say "3/7 firewall"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow in on tailscale0
ufw --force enable
ufw status verbose | head -12

say "4/7 never suspend"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

say "5/7 Tailscale"
if ! command -v tailscale > /dev/null; then
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -q
    apt-get install -y -q tailscale
fi
if [[ "$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)" != "Running" ]]; then
    echo ">>> Open the login link below in your browser and approve pc2 <<<"
    tailscale up --hostname=pc2 --ssh=false
fi
tailscale ip -4

say "6/7 NVIDIA driver (580-server, headless)"
# Not `ubuntu-drivers install`: this ASUS BIOS names some ACPI devices with non-UTF-8 bytes
# (/sys/bus/acpi/devices/<garbage>:00), and ubuntu-drivers dies reading their modalias
# (UnicodeDecodeError, 2026-11-25). The packages it would pick, by hand: precompiled modules that
# follow the generic kernel, plus the headless userspace and nvidia-smi.
apt-get install -y -q linux-modules-nvidia-580-server-generic \
    nvidia-headless-no-dkms-580-server nvidia-utils-580-server

say "7/7 disk health"
smartctl -H /dev/sda | grep -i -E 'overall|result' || true
smartctl -A /dev/sda | grep -E 'Power_On_Hours|Reallocated_Sector|Current_Pending|Offline_Uncorrectable' || true

say "done, rebooting in 10 s (log: $LOG)"
sleep 10
systemctl reboot
