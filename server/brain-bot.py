#!/usr/bin/env python3
"""Brain Server Telegram Bot — responds to /status with live server health."""

import subprocess
import time
import urllib.request
import urllib.parse
import json

BOT_TOKEN = "<REDACTED in this backup — the real value lives only in /home/daniel/brain-bot.py on the server>"
CHAT_ID = "<REDACTED in this backup — set on the server>"
API_BASE = f"https://api.telegram.org/bot{BOT_TOKEN}"
POLL_INTERVAL = 2

SERVICES = ["brain-chroma", "brain-indexer", "brain-mcp", "brain-mcp-bridge", "syncthing@daniel"]


def api_call(method, data=None):
    url = f"{API_BASE}/{method}"
    if data:
        data = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def get_service_status(name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() == "active"
    except Exception:
        return False


def get_uptime():
    with open("/proc/uptime") as f:
        seconds = int(float(f.read().split()[0]))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)


def get_disk_usage():
    result = subprocess.run(
        ["df", "/", "--output=pcent,avail", "-h"],
        capture_output=True, text=True, timeout=5,
    )
    line = result.stdout.strip().split("\n")[1].split()
    return line[0], line[1]


def get_memory_usage():
    result = subprocess.run(
        ["free", "-h"], capture_output=True, text=True, timeout=5,
    )
    parts = result.stdout.split("\n")[1].split()
    total, used = parts[1], parts[2]
    result2 = subprocess.run(
        ["free"], capture_output=True, text=True, timeout=5,
    )
    nums = result2.stdout.split("\n")[1].split()
    pct = int(float(nums[2]) / float(nums[1]) * 100)
    return f"{used}/{total} ({pct}%)"


def get_load():
    with open("/proc/loadavg") as f:
        parts = f.read().split()
    return f"{parts[0]} / {parts[1]} / {parts[2]}"


def get_health_endpoint():
    try:
        req = urllib.request.Request("http://localhost:8080/health")
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status == 200
    except Exception:
        return False



THERMAL_ZONES = {
    "x86_pkg_temp": "CPU",
    "pch_cannonlake": "PCH",
    "TSKN": "Chassis",
    "TMEM": "Memory",
    "NGFF": "SSD",
}

TEMP_WARN = 80
TEMP_CRIT = 90


def get_temperatures():
    """Read thermal zones and return list of (label, temp_c, icon)."""
    import os
    temps = []
    base = "/sys/class/thermal"
    try:
        for zone in sorted(os.listdir(base)):
            if not zone.startswith("thermal_zone"):
                continue
            zone_path = os.path.join(base, zone)
            with open(os.path.join(zone_path, "type")) as f:
                zone_type = f.read().strip()
            if zone_type not in THERMAL_ZONES:
                continue
            with open(os.path.join(zone_path, "temp")) as f:
                temp_c = int(f.read().strip()) / 1000
            label = THERMAL_ZONES[zone_type]
            if temp_c >= TEMP_CRIT:
                icon = "\U0001f534"  # red circle
            elif temp_c >= TEMP_WARN:
                icon = "\U0001f7e1"  # yellow circle
            else:
                icon = "\U0001f7e2"  # green circle
            temps.append((label, temp_c, icon))
    except Exception:
        pass
    return temps


def build_status_message():
    lines = ["*🧠 Brain Server Status*", ""]

    # Services
    lines.append("*Services:*")
    for svc in SERVICES:
        status = get_service_status(svc)
        icon = "✅" if status else "🔴"
        lines.append(f"  {icon} `{svc}`")

    # Health endpoint
    health = get_health_endpoint()
    icon = "✅" if health else "🔴"
    lines.append(f"  {icon} `health endpoint`")

    # Resources
    lines.append("")
    lines.append("*Resources:*")
    disk_pct, disk_avail = get_disk_usage()
    lines.append(f"  💾 Disk: {disk_pct} used ({disk_avail} free)")
    lines.append(f"  🧮 Memory: {get_memory_usage()}")
    lines.append(f"  ⚡ Load: {get_load()}")
    lines.append(f"  ⏱ Uptime: {get_uptime()}")

    # Temperatures
    temps = get_temperatures()
    if temps:
        lines.append("")
        lines.append("*Thermals:*")
        max_temp = 0
        for label, temp_c, icon in temps:
            lines.append(f"  {icon} {label}: {temp_c:.0f}\u00b0C")
            if temp_c > max_temp:
                max_temp = temp_c
        if max_temp >= TEMP_CRIT:
            lines.append("")
            lines.append("\u26a0\ufe0f *OVERHEATING \u2014 check airflow/fans!*")
        elif max_temp >= TEMP_WARN:
            lines.append("")
            lines.append("\u26a0\ufe0f *Running warm \u2014 monitor closely*")

    return "\n".join(lines)


def main():
    offset = None

    # Clear old updates on startup
    try:
        result = api_call("getUpdates", {"offset": -1, "limit": 1})
        if result.get("result"):
            offset = result["result"][-1]["update_id"] + 1
    except Exception:
        pass

    while True:
        try:
            params = {"timeout": 30, "allowed_updates": '["message"]'}
            if offset is not None:
                params["offset"] = offset
            result = api_call("getUpdates", params)

            for update in result.get("result", []):
                offset = update["update_id"] + 1
                msg = update.get("message", {})
                text = msg.get("text", "")
                chat_id = msg.get("chat", {}).get("id")

                if not chat_id:
                    continue

                if text.strip().lower() in ("/status", "/status@brainserverbot"):
                    status_msg = build_status_message()
                    api_call("sendMessage", {
                        "chat_id": chat_id,
                        "text": status_msg,
                        "parse_mode": "Markdown",
                    })

        except Exception:
            time.sleep(5)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
