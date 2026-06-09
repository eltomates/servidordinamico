#!/usr/bin/env bash

# Registra alarmas de canales web y mantiene un estado JSON simple.
# Uso: web_channel_alarm.sh <canal> <ALARM|OK> <mensaje>

set -euo pipefail

CHANNEL="${1:-}"
LEVEL="${2:-ALARM}"
MESSAGE="${3:-}"

if [ -z "$CHANNEL" ]; then
  echo "Uso: $0 <canal> <ALARM|OK> <mensaje>" >&2
  exit 1
fi

LOG_DIR="/var/www/html/logs"
ALARM_LOG="$LOG_DIR/web_alarm.log"
STATUS_FILE="$LOG_DIR/web_alarm_status.json"

mkdir -p "$LOG_DIR"

NOW_EPOCH="$(date +%s)"
NOW_HUMAN="$(date '+%F %T')"

echo "[web_alarm] $NOW_HUMAN channel=$CHANNEL level=$LEVEL msg=$MESSAGE" >> "$ALARM_LOG"

python3 - "$STATUS_FILE" "$CHANNEL" "$LEVEL" "$MESSAGE" "$NOW_EPOCH" <<'PY'
import json
import os
import sys

status_file, channel, level, message, now_epoch = sys.argv[1:]
now_epoch = int(now_epoch)

data = {"timestamp": now_epoch, "channels": {}}
if os.path.exists(status_file):
    try:
        with open(status_file, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data.update(loaded)
            if not isinstance(data.get("channels"), dict):
                data["channels"] = {}
    except Exception:
        pass

data["timestamp"] = now_epoch
entry = data["channels"].get(channel, {})
if not isinstance(entry, dict):
    entry = {}

entry["level"] = level
entry["message"] = message
entry["updated_at"] = now_epoch
data["channels"][channel] = entry

tmp = status_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=True, separators=(",", ":"))
os.replace(tmp, status_file)
PY
