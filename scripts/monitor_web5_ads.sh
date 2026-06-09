#!/usr/bin/env bash

# Monitor de web5 enfocado en detectar congelamientos alrededor de transiciones comerciales.
# No reinicia procesos: solo registra evidencia para ajuste fino de parametros.

set -euo pipefail

CHANNEL="${CHANNEL:-web5}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
STALE_SECONDS="${STALE_SECONDS:-40}"
TAIL_LINES="${TAIL_LINES:-160}"
AUTO_RESTART_ON_ADS_STALE="${AUTO_RESTART_ON_ADS_STALE:-1}"
ADS_STALE_HITS_TO_RESTART="${ADS_STALE_HITS_TO_RESTART:-8}"
RESTART_COOLDOWN_SECONDS="${RESTART_COOLDOWN_SECONDS:-180}"
FORCE_RESTART_STALE_SECONDS="${FORCE_RESTART_STALE_SECONDS:-120}"
POST_RESTART_GRACE_SECONDS="${POST_RESTART_GRACE_SECONDS:-25}"
AUTO_RESTART_ON_ADS_END="${AUTO_RESTART_ON_ADS_END:-1}"
ADS_END_CLEAR_HITS="${ADS_END_CLEAR_HITS:-2}"
ADS_END_RESTART_COOLDOWN_SECONDS="${ADS_END_RESTART_COOLDOWN_SECONDS:-180}"

LOG_DIR="/var/www/html/logs"
LOCK_DIR="/var/www/html/logs/locks"
HLS_DIR="/var/www/html/hls/${CHANNEL}"
PLAYLIST="${HLS_DIR}/index.m3u8"
FFMPEG_LOG="${LOG_DIR}/ffmpeg_${CHANNEL}.log"
MONITOR_LOG="${LOG_DIR}/monitor_${CHANNEL}_ads.log"
STATUS_FILE="${LOG_DIR}/${CHANNEL}_ads_status.json"
LOCK_FILE="${LOCK_DIR}/monitor_${CHANNEL}_ads.lock"

mkdir -p "$LOG_DIR" "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true
if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true

exec 9<>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[monitor_${CHANNEL}_ads] ya hay una instancia activa; saliendo."
  exit 0
fi

log() {
  echo "[monitor_${CHANNEL}_ads] $(date '+%F %T') $*" >> "$MONITOR_LOG"
}

restart_channel() {
  local channel="$1"
  local script_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -x "$script_dir/start_all_proxies.sh" ]; then
    bash "$script_dir/start_all_proxies.sh" --channel "$channel" >> "$MONITOR_LOG" 2>&1 || true
    return 0
  fi

  # Fallback defensivo por si no existe el orquestador.
  pkill -f "ffmpeg_${channel}_proxy.sh" 2>/dev/null || true
  pkill -f "ffmpeg .*hls/${channel}/" 2>/dev/null || true
  if [ -x "$script_dir/ffmpeg_${channel}_proxy.sh" ]; then
    nohup bash "$script_dir/ffmpeg_${channel}_proxy.sh" >> "$LOG_DIR/ffmpeg_${channel}.log" 2>&1 &
  fi
}

playlist_seq() {
  awk -F: '/^#EXT-X-MEDIA-SEQUENCE:/{print $2; exit}' "$PLAYLIST" 2>/dev/null || true
}

playlist_last_segment() {
  grep -E '^seg_.*\.ts$' "$PLAYLIST" 2>/dev/null | tail -n1 || true
}

playlist_has_discontinuity() {
  grep -q '^#EXT-X-DISCONTINUITY' "$PLAYLIST" 2>/dev/null
}

recent_log_has_slate() {
  if [ ! -s "$FFMPEG_LOG" ]; then
    return 1
  fi
  tail -n "$TAIL_LINES" "$FFMPEG_LOG" 2>/dev/null | grep -q '/slate/'
}

write_status() {
  local now_ts="$1"
  local index_age="$2"
  local seg_age="$3"
  local seq="$4"
  local stale="$5"
  local disc="$6"
  local slate="$7"
  local reason="$8"

  {
    printf '{\n'
    printf '  "timestamp": %s,\n' "$now_ts"
    printf '  "channel": "%s",\n' "$CHANNEL"
    printf '  "index_age_seconds": %s,\n' "$index_age"
    printf '  "last_segment_age_seconds": %s,\n' "$seg_age"
    printf '  "media_sequence": "%s",\n' "$seq"
    printf '  "stale": %s,\n' "$stale"
    printf '  "playlist_discontinuity": %s,\n' "$disc"
    printf '  "recent_slate_in_log": %s,\n' "$slate"
    printf '  "reason": "%s"\n' "$reason"
    printf '}\n'
  } > "${STATUS_FILE}.tmp"

  command mv -f "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

last_seq=""
last_progress_ts="$(date +%s)"
stale_ads_hits=0
ads_clear_hits=0
last_ads_signal=false
last_restart_ts=0

log "iniciado (channel=${CHANNEL}, check=${CHECK_INTERVAL}s, stale=${STALE_SECONDS}s, tail_lines=${TAIL_LINES}, auto_restart=${AUTO_RESTART_ON_ADS_STALE}, hits_to_restart=${ADS_STALE_HITS_TO_RESTART}, cooldown=${RESTART_COOLDOWN_SECONDS}s, force_restart_stale=${FORCE_RESTART_STALE_SECONDS}s, post_restart_grace=${POST_RESTART_GRACE_SECONDS}s, auto_restart_on_ads_end=${AUTO_RESTART_ON_ADS_END}, ads_end_clear_hits=${ADS_END_CLEAR_HITS}, ads_end_cooldown=${ADS_END_RESTART_COOLDOWN_SECONDS}s)"

while true; do
  now_ts="$(date +%s)"

  if [ ! -s "$PLAYLIST" ]; then
    stale_ads_hits=0
    ads_clear_hits=0
    write_status "$now_ts" 99999 99999 "" true false false "playlist_missing"
    log "playlist ausente o vacia"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  seq="$(playlist_seq)"
  index_mtime="$(stat -c %Y "$PLAYLIST" 2>/dev/null || echo 0)"
  index_age=$(( now_ts - index_mtime ))

  last_seg="$(playlist_last_segment)"
  if [ -n "$last_seg" ] && [ -f "${HLS_DIR}/${last_seg}" ]; then
    seg_mtime="$(stat -c %Y "${HLS_DIR}/${last_seg}" 2>/dev/null || echo 0)"
    seg_age=$(( now_ts - seg_mtime ))
  else
    seg_age=99999
  fi

  if [ $(( now_ts - last_restart_ts )) -lt "$POST_RESTART_GRACE_SECONDS" ]; then
    write_status "$now_ts" "$index_age" "$seg_age" "${seq:-}" false false false "restart_grace"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if [ -n "$seq" ] && [ "$seq" != "$last_seq" ]; then
    last_seq="$seq"
    last_progress_ts="$now_ts"
  fi

  if [ "$seg_age" -lt "$CHECK_INTERVAL" ]; then
    last_progress_ts="$now_ts"
  fi

  stale_for=$(( now_ts - last_progress_ts ))
  is_stale=false
  if [ "$stale_for" -ge "$STALE_SECONDS" ] || [ "$index_age" -ge "$STALE_SECONDS" ] || [ "$seg_age" -ge "$STALE_SECONDS" ]; then
    is_stale=true
  fi

  has_disc=false
  if playlist_has_discontinuity; then
    has_disc=true
  fi

  has_slate=false
  if recent_log_has_slate; then
    has_slate=true
  fi

  ads_block_now=false
  if [ "$has_disc" = true ] || [ "$has_slate" = true ]; then
    ads_block_now=true
  fi

  if [ "$ads_block_now" = true ]; then
    last_ads_signal=true
    ads_clear_hits=0
  else
    if [ "$last_ads_signal" = true ]; then
      ads_clear_hits=$(( ads_clear_hits + 1 ))
    else
      ads_clear_hits=0
    fi
  fi

  reason="ok"
  if [ "$is_stale" = true ] && { [ "$has_disc" = true ] || [ "$has_slate" = true ]; }; then
    reason="stale_during_ads_transition"
    stale_ads_hits=$(( stale_ads_hits + 1 ))
    log "ALERTA stale=${stale_for}s index_age=${index_age}s seg_age=${seg_age}s seq=${seq:-na} disc=${has_disc} slate=${has_slate}"

    if [ "$AUTO_RESTART_ON_ADS_STALE" = "1" ] && [ "$stale_ads_hits" -ge "$ADS_STALE_HITS_TO_RESTART" ]; then
      if [ $(( now_ts - last_restart_ts )) -ge "$RESTART_COOLDOWN_SECONDS" ] || [ "$stale_for" -ge "$FORCE_RESTART_STALE_SECONDS" ]; then
        log "accion=restart channel=${CHANNEL} motivo=stale_during_ads_transition hits=${stale_ads_hits} cooldown_ok=1"
        restart_channel "$CHANNEL"
        last_restart_ts="$now_ts"
        stale_ads_hits=0
      else
        log "accion=skip_restart channel=${CHANNEL} motivo=cooldown_activo hits=${stale_ads_hits}"
      fi
    fi
  elif [ "$is_stale" = true ]; then
    reason="stale_without_ads_signal"
    stale_ads_hits=0
    log "ALERTA stale=${stale_for}s index_age=${index_age}s seg_age=${seg_age}s seq=${seq:-na} disc=${has_disc} slate=${has_slate}"
  else
    stale_ads_hits=0
  fi

  if [ "$AUTO_RESTART_ON_ADS_END" = "1" ] && [ "$last_ads_signal" = true ] && [ "$ads_clear_hits" -ge "$ADS_END_CLEAR_HITS" ]; then
    if [ $(( now_ts - last_restart_ts )) -ge "$ADS_END_RESTART_COOLDOWN_SECONDS" ]; then
      log "accion=restart channel=${CHANNEL} motivo=ads_end_detected clear_hits=${ads_clear_hits} cooldown_ok=1"
      restart_channel "$CHANNEL"
      last_restart_ts="$now_ts"
      stale_ads_hits=0
      ads_clear_hits=0
      last_ads_signal=false
      write_status "$now_ts" "$index_age" "$seg_age" "${seq:-}" false "$has_disc" "$has_slate" "ads_end_restart"
      sleep "$CHECK_INTERVAL"
      continue
    else
      log "accion=skip_restart channel=${CHANNEL} motivo=ads_end_cooldown clear_hits=${ads_clear_hits}"
    fi
  fi

  write_status "$now_ts" "$index_age" "$seg_age" "${seq:-}" "$is_stale" "$has_disc" "$has_slate" "$reason"

  sleep "$CHECK_INTERVAL"
done
