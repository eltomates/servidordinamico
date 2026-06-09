#!/usr/bin/env bash

# Guardian dedicado para web14:
# detecta estancamiento de segmentos, emite alarma y fuerza reinicio del canal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
HLS_DIR="/var/www/html/hls/web14"
LOCK_DIR="/var/www/html/logs/locks"
LOCK_FILE="$LOCK_DIR/web14_guardian.lock"
ALARM_SCRIPT="$SCRIPT_DIR/web_channel_alarm.sh"

CHECK_INTERVAL="${WEB14_GUARD_INTERVAL:-8}"
STALE_SECONDS="${WEB14_GUARD_STALE_SECONDS:-120}"
RESTART_COOLDOWN="${WEB14_GUARD_RESTART_COOLDOWN:-120}"
BOOTSTRAP_GRACE_SECONDS="${WEB14_GUARD_BOOTSTRAP_GRACE_SECONDS:-180}"

mkdir -p "$LOG_DIR" "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true
if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true

exec 7<>"$LOCK_FILE"
if ! flock -n 7; then
  echo "[web14_guardian] ya hay otra instancia activa; saliendo." >> "$LOG_DIR/web14_guardian.log"
  exit 0
fi

log() {
  echo "[web14_guardian] $(date '+%F %T') $*" >> "$LOG_DIR/web14_guardian.log"
}

emit_alarm() {
  local level="$1"
  local message="$2"
  if [ -x "$ALARM_SCRIPT" ]; then
    bash "$ALARM_SCRIPT" "web14" "$level" "$message" || true
  fi
}

latest_segment() {
  ls -1t "$HLS_DIR"/seg_*.ts 2>/dev/null | head -n1 || true
}

last_restart_ts=0
last_seen_seg=""
in_alarm=0
start_ts="$(date +%s)"

log "Iniciado (CHECK_INTERVAL=${CHECK_INTERVAL}s, STALE_SECONDS=${STALE_SECONDS}s, RESTART_COOLDOWN=${RESTART_COOLDOWN}s)."
emit_alarm "OK" "web14 monitor activo"

while true; do
  now_ts="$(date +%s)"
  seg_path="$(latest_segment)"

  if [ $(( now_ts - start_ts )) -lt "$BOOTSTRAP_GRACE_SECONDS" ]; then
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if [ -z "$seg_path" ]; then
    seg_age=9999
  else
    seg_mtime="$(stat -c %Y "$seg_path" 2>/dev/null || echo 0)"
    seg_age=$(( now_ts - seg_mtime ))
    last_seen_seg="$(basename "$seg_path")"
  fi

  if [ "$seg_age" -ge "$STALE_SECONDS" ]; then
    if pgrep -f 'resolve_pluto_chromium.py .*5ddd7cb2cbb9010009b4fe32' >/dev/null 2>&1; then
      sleep "$CHECK_INTERVAL"
      continue
    fi

    since_restart=$(( now_ts - last_restart_ts ))
    if [ "$in_alarm" -eq 0 ]; then
      emit_alarm "ALARM" "web14 congelado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})"
      in_alarm=1
    fi
    if [ "$since_restart" -ge "$RESTART_COOLDOWN" ]; then
      log "Congelado detectado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none}). Reiniciando web14..."
      bash "$SCRIPT_DIR/start_all_proxies.sh" --channel web14 >> "$LOG_DIR/web14_guardian.log" 2>&1 || true
      last_restart_ts="$now_ts"
    fi
  else
    if [ "$in_alarm" -eq 1 ]; then
      emit_alarm "OK" "web14 recuperado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})"
      log "Canal recuperado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})."
      in_alarm=0
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
