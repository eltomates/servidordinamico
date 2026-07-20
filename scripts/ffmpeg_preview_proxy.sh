#!/usr/bin/env bash

# Proxy HLS "de vista previa" para probar rápidamente URLs remotas
# (incluyendo URLs .ts sueltas) y publicarlas como HLS local
# accesible en /hls/preview/index.m3u8.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"

OUT="${OUT:-/var/www/html/hls/preview}"
SRC_URL="${SRC_URL:-}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_TIME="${HLS_TIME:-4}"
PREVIEW_FPS="${PREVIEW_FPS:-25}"
GOP_SIZE="${GOP_SIZE:-100}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-45}"
MAX_SEGMENT_REPEAT_SECONDS="${MAX_SEGMENT_REPEAT_SECONDS:-30}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"

mkdir -p "$OUT"

if [ -z "$SRC_URL" ]; then
  echo "[ffmpeg_preview_proxy] SRC_URL no definido, nada que hacer." >&2
  exit 1
fi

# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
while true; do
  set +e

  # Mantener algunos segmentos previos para que el reproductor conserve buffer.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  echo "[ffmpeg_preview_proxy] Iniciando ffmpeg con origen: $SRC_URL" >&2

  ffmpeg \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -rw_timeout 15000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_at_eof 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -max_reload 100000 \
    -m3u8_hold_counters 100000 \
    -seg_max_retry 8 \
    -http_persistent 0 \
    -http_multiple 0 \
    -http_seekable 0 \
    -i "$SRC_URL" \
    -vf "fps=${PREVIEW_FPS},setpts=N/(${PREVIEW_FPS}*TB)" \
    -af "aresample=async=1000:first_pts=0,asetpts=N/SR/TB" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -b:v 1000k \
    -maxrate 1500k \
    -bufsize 3000k \
    -max_muxing_queue_size 2048 \
    -r "$PREVIEW_FPS" \
    -fps_mode cfr \
    -g "$GOP_SIZE" \
    -keyint_min "$GOP_SIZE" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$KEEP_SEGMENTS" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

  # Supervisar que index.m3u8 se siga actualizando; si se queda congelado
  # durante demasiado tiempo, matamos ffmpeg y reintentamos.
  last_ok_ts="$(date +%s)"
  last_segment_ts="$last_ok_ts"
  last_segment=""
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
    last_segment="$(awk '/\.ts/ {seg=$0} END {print seg}' "$OUT/index.m3u8")"
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL_SECONDS"

    if [ -f "$OUT/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT/index.m3u8")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi

      current_segment="$(awk '/\.ts/ {seg=$0} END {print seg}' "$OUT/index.m3u8")"
      if [ -n "$current_segment" ] && [ "$current_segment" != "$last_segment" ]; then
        last_segment="$current_segment"
        last_segment_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))
    repeated_segment_seconds=$(( now_ts - last_segment_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_preview_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ "$repeated_segment_seconds" -ge "$MAX_SEGMENT_REPEAT_SECONDS" ]; then
      echo "[ffmpeg_preview_proxy] último segmento repetido $repeated_segment_seconds s, reiniciando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_preview_proxy] ffmpeg salió con código $rc. Reintentando en 5 segundos..." >&2
  sleep 5

done
