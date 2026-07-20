#!/usr/bin/env bash

# Guardian para HDMI4:
# detecta proceso caido o segmentos estancados y reinicia ffmpeg_hdmi4.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
HLS_DIR="/var/www/html/hls/hdmi4"
LOCK_DIR="/var/www/html/logs/locks"
LOCK_FILE="$LOCK_DIR/hdmi4_guardian.lock"
ALARM_SCRIPT="$SCRIPT_DIR/web_channel_alarm.sh"
HDMI4_SCRIPT="$SCRIPT_DIR/ffmpeg_hdmi4.sh"
HDMI4_LOG="$LOG_DIR/ffmpeg_hdmi4.log"

CHECK_INTERVAL="${HDMI4_GUARD_INTERVAL:-8}"
STALE_SECONDS="${HDMI4_GUARD_STALE_SECONDS:-25}"
RESTART_COOLDOWN="${HDMI4_GUARD_RESTART_COOLDOWN:-20}"
BOOTSTRAP_GRACE_SECONDS="${HDMI4_GUARD_BOOTSTRAP_GRACE_SECONDS:-20}"

mkdir -p "$LOG_DIR" "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true
if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true

exec 7<>"$LOCK_FILE"
if ! flock -n 7; then
  echo "[hdmi4_guardian] ya hay otra instancia activa; saliendo." >> "$LOG_DIR/hdmi4_guardian.log"
  exit 0
fi

log() {
  echo "[hdmi4_guardian] $(date '+%F %T') $*" >> "$LOG_DIR/hdmi4_guardian.log"
}

emit_alarm() {
  local level="$1"
  local message="$2"
  if [ -x "$ALARM_SCRIPT" ]; then
    bash "$ALARM_SCRIPT" "hdmi4" "$level" "$message" 7>&- || true
  fi
}

latest_segment() {
  ls -1t "$HLS_DIR"/seg_*.ts 2>/dev/null | head -n1 || true
}

restart_hdmi4() {
  pkill -f "ffmpeg_hdmi4.sh" 2>/dev/null || true
  pkill -f 'ffmpeg .*hls/hdmi4' 2>/dev/null || true
  nohup bash "$HDMI4_SCRIPT" >> "$HDMI4_LOG" 2>&1 &
}

last_restart_ts=0
last_seen_seg=""
in_alarm=0
start_ts="$(date +%s)"

log "Iniciado (CHECK_INTERVAL=${CHECK_INTERVAL}s, STALE_SECONDS=${STALE_SECONDS}s, RESTART_COOLDOWN=${RESTART_COOLDOWN}s)."
emit_alarm "OK" "hdmi4 guardian activo"

while true; do
  now_ts="$(date +%s)"
  seg_path="$(latest_segment)"

  if [ $(( now_ts - start_ts )) -lt "$BOOTSTRAP_GRACE_SECONDS" ]; then
    sleep "$CHECK_INTERVAL"
    continue
  fi

  process_ok=0
  if pgrep -f "ffmpeg_hdmi4.sh" >/dev/null 2>&1 || pgrep -f 'ffmpeg .*hls/hdmi4' >/dev/null 2>&1; then
    process_ok=1
  fi

  if [ -z "$seg_path" ]; then
    seg_age=9999
  else
    seg_mtime="$(stat -c %Y "$seg_path" 2>/dev/null || echo 0)"
    seg_age=$(( now_ts - seg_mtime ))
    last_seen_seg="$(basename "$seg_path")"
  fi

  stale=0
  if [ "$seg_age" -ge "$STALE_SECONDS" ]; then
    stale=1
  fi

  if [ "$process_ok" -eq 0 ] || [ "$stale" -eq 1 ]; then
    since_restart=$(( now_ts - last_restart_ts ))
    if [ "$in_alarm" -eq 0 ]; then
      emit_alarm "ALARM" "hdmi4 caido/congelado (proceso=${process_ok}, edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})"
      in_alarm=1
    fi
    if [ "$since_restart" -ge "$RESTART_COOLDOWN" ]; then
      log "Falla detectada (proceso=${process_ok}, edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none}). Reiniciando hdmi4..."
      restart_hdmi4
      last_restart_ts="$now_ts"
    fi
  else
    if [ "$in_alarm" -eq 1 ]; then
      emit_alarm "OK" "hdmi4 recuperado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})"
      log "Canal recuperado (edad_ultimo_segmento=${seg_age}s, ultimo=${last_seen_seg:-none})."
      in_alarm=0
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
