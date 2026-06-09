#!/usr/bin/env bash

# Reinicia todos los proxies web en horarios programados.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
LOCK_DIR="${WEB_HLS_LOCK_DIR:-/var/www/html/logs/locks}"
LOCK_FILE="$LOCK_DIR/restart_all_webs_scheduled.lock"
LOG_FILE="$LOG_DIR/restart_all_webs_scheduled.log"

mkdir -p "$LOG_DIR" "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true

if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true

exec 8<>"$LOCK_FILE"
if ! flock -n 8; then
  echo "[$(date '+%F %T')] [restart_all_webs_scheduled] Otra ejecucion ya esta en curso." >>"$LOG_FILE"
  exit 0
fi

echo "[$(date '+%F %T')] [restart_all_webs_scheduled] Inicio de reinicio programado." >>"$LOG_FILE"

if /usr/bin/bash "$SCRIPT_DIR/start_all_proxies.sh" >>"$LOG_FILE" 2>&1; then
  echo "[$(date '+%F %T')] [restart_all_webs_scheduled] Reinicio completado OK." >>"$LOG_FILE"
  exit 0
fi

status=$?
echo "[$(date '+%F %T')] [restart_all_webs_scheduled] ERROR al reiniciar. Exit code: $status" >>"$LOG_FILE"
exit "$status"
