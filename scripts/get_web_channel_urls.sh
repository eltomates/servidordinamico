#!/usr/bin/env bash

# Devuelve las URLs actuales configuradas para los canales web en formato JSON.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
PRIMARY_CONFIG="$LOG_DIR/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
CONFIG_FILE=""

if [ -f "$PRIMARY_CONFIG" ]; then
  CONFIG_FILE="$PRIMARY_CONFIG"
elif [ -f "$LEGACY_CONFIG" ]; then
  CONFIG_FILE="$LEGACY_CONFIG"
fi

channels=(web1 web2 web3 web4 web5 web6 web7 web8 web9 web10 web11 web12 web13 web14 web15)

if [ -n "$CONFIG_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a
fi

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo

python3 - <<'PY'
import json
import os

channels = [
    "web1",
    "web2",
    "web3",
    "web4",
    "web5",
    "web6",
    "web7",
    "web8",
    "web9",
    "web10",
    "web11",
    "web12",
    "web13",
    "web14",
    "web15",
]

payload = {ch: os.environ.get(f"{ch.upper()}_URL", "") for ch in channels}
print(json.dumps(payload))
PY
