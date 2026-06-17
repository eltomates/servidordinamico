#!/usr/bin/env bash

# Monitor rapido para web6/web7.
# Detecta congelamiento por playlist sin cambios y reinicia solo el canal afectado.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
LOCK_DIR="/var/www/html/logs/locks"
HLS_BASE="/var/www/html/hls"

CHANNELS=(web6 web7)
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
STALE_SECONDS="${STALE_SECONDS:-120}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-60}"
MISSING_GRACE_CHECKS="${MISSING_GRACE_CHECKS:-2}"
ENDLIST_GRACE_CHECKS="${ENDLIST_GRACE_CHECKS:-2}"

LOCK_FILE="$LOCK_DIR/monitor_web67_quick.lock"
LOG_FILE="$LOG_DIR/monitor_web67_quick.log"
STATUS_FILE="$LOG_DIR/web67_status.json"

mkdir -p "$LOG_DIR" "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true
if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true

exec 9<>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[monitor_web67_quick] ya hay una instancia activa; saliendo."
  exit 0
fi

log() {
  echo "[monitor_web67_quick] $(date '+%F %T') $*" >> "$LOG_FILE"
}

write_status_file() {
  local now_ts="$1"
  shift
  local -a bad=("$@")

  {
    printf '{ "timestamp": %s, "monitored_channels": ["web6","web7"], "channels_not_updating": [' "$now_ts"
    if [ "${#bad[@]}" -gt 0 ]; then
      printf '"%s"' "${bad[0]}"
      local i
      for ((i=1; i<${#bad[@]}; i++)); do
        printf ',"%s"' "${bad[$i]}"
      done
    fi
    printf '] }\n'
  } > "$STATUS_FILE.tmp"

  command mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

playlist_seq() {
  local playlist="$1"
  awk -F: '/^#EXT-X-MEDIA-SEQUENCE:/{print $2; exit}' "$playlist" 2>/dev/null || true
}

playlist_has_endlist() {
  local playlist="$1"
  grep -q '^#EXT-X-ENDLIST' "$playlist" 2>/dev/null
}

declare -A LAST_SEQ

declare -A LAST_CHANGE_TS

declare -A LAST_RESTART_TS

declare -A MISSING_HITS

declare -A ENDLIST_HITS

restart_channel() {
  local channel="$1"

  if [ -x "$SCRIPT_DIR/start_all_proxies.sh" ]; then
    bash "$SCRIPT_DIR/start_all_proxies.sh" --channel "$channel" >> "$LOG_FILE" 2>&1 || true
    return
  fi

  local script="$SCRIPT_DIR/ffmpeg_${channel}_proxy.sh"
  local ch_log="$LOG_DIR/ffmpeg_${channel}.log"
  if [ -x "$script" ]; then
    pkill -f "ffmpeg_${channel}_proxy.sh" 2>/dev/null || true
    pkill -f "ffmpeg .*hls/${channel}" 2>/dev/null || true
    nohup bash "$script" >> "$ch_log" 2>&1 &
  fi
}

for channel in "${CHANNELS[@]}"; do
  LAST_SEQ["$channel"]=""
  LAST_CHANGE_TS["$channel"]="$(date +%s)"
  LAST_RESTART_TS["$channel"]=0
  MISSING_HITS["$channel"]=0
  ENDLIST_HITS["$channel"]=0
done

log "iniciado (channels=${CHANNELS[*]}, check=${CHECK_INTERVAL}s, stale=${STALE_SECONDS}s, cooldown=${COOLDOWN_SECONDS}s)"
write_status_file "$(date +%s)"

while true; do
  now_ts="$(date +%s)"
  unhealthy=()

  for channel in "${CHANNELS[@]}"; do
    playlist="$HLS_BASE/$channel/index.m3u8"

    if [ ! -s "$playlist" ]; then
      MISSING_HITS["$channel"]=$(( MISSING_HITS[$channel] + 1 ))
      if [ "${MISSING_HITS[$channel]}" -lt "$MISSING_GRACE_CHECKS" ]; then
        continue
      fi
      unhealthy+=("$channel")
      if [ $(( now_ts - LAST_RESTART_TS[$channel] )) -ge "$COOLDOWN_SECONDS" ]; then
        log "$channel playlist vacia o ausente; reiniciando"
        restart_channel "$channel"
        LAST_RESTART_TS["$channel"]="$now_ts"
      fi
      continue
    fi
    MISSING_HITS["$channel"]=0

    if playlist_has_endlist "$playlist"; then
      ENDLIST_HITS["$channel"]=$(( ENDLIST_HITS[$channel] + 1 ))
      if [ "${ENDLIST_HITS[$channel]}" -lt "$ENDLIST_GRACE_CHECKS" ]; then
        continue
      fi
      unhealthy+=("$channel")
      if [ $(( now_ts - LAST_RESTART_TS[$channel] )) -ge "$COOLDOWN_SECONDS" ]; then
        log "$channel detectado con #EXT-X-ENDLIST; reiniciando"
        restart_channel "$channel"
        LAST_RESTART_TS["$channel"]="$now_ts"
      fi
      continue
    fi
    ENDLIST_HITS["$channel"]=0

    seq="$(playlist_seq "$playlist")"
    mtime="$(stat -c %Y "$playlist" 2>/dev/null || echo 0)"

    if [ -n "$seq" ] && [ "$seq" != "${LAST_SEQ[$channel]}" ]; then
      LAST_SEQ["$channel"]="$seq"
      LAST_CHANGE_TS["$channel"]="$now_ts"
      continue
    fi

    # Si no cambia seq, usa tambien mtime para detectar actividad real.
    if [ "$mtime" -gt 0 ] && [ $(( now_ts - mtime )) -lt "$CHECK_INTERVAL" ]; then
      LAST_CHANGE_TS["$channel"]="$now_ts"
      continue
    fi

    stale_for=$(( now_ts - LAST_CHANGE_TS[$channel] ))
    if [ "$stale_for" -ge "$STALE_SECONDS" ]; then
      unhealthy+=("$channel")
      if [ $(( now_ts - LAST_RESTART_TS[$channel] )) -ge "$COOLDOWN_SECONDS" ]; then
        log "$channel congelado ${stale_for}s (seq=${seq:-na}); reiniciando"
        restart_channel "$channel"
        LAST_RESTART_TS["$channel"]="$now_ts"
      fi
    fi
  done

  # Deduplicar canales en mal estado antes de publicar.
  if [ "${#unhealthy[@]}" -gt 0 ]; then
    mapfile -t unhealthy < <(printf '%s\n' "${unhealthy[@]}" | awk '!seen[$0]++')
  fi
  write_status_file "$now_ts" "${unhealthy[@]}"

  sleep "$CHECK_INTERVAL"
done
