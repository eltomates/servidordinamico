#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV a un HLS local servido por Apache.
# Entrada:  http://tv.proyectox.vip:8080/ELLtdmaiz204fj/ScMZEQzYga/9604
# Salida:   /var/www/html/hls/web8/index.m3u8 (accesible como /hls/web8/index.m3u8)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web8}"
SRC_URL="${SRC_URL:-https://streaming.alwaysdata.net/tudn.php}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-30}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-120}"
VIDEO_MAP="${VIDEO_MAP:-0:8}"

mkdir -p "$OUT"

while true; do
  set +e
  echo "[ffmpeg_web8_proxy] usando VIDEO_MAP=${VIDEO_MAP}" >&2

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"

  ffmpeg \
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -user_agent "VLC/3.0.20 LibVLC/3.0.20" \
    -rw_timeout 15000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -i "$SRC_URL" \
    -map "$VIDEO_MAP" \
    -map 0:a:0 \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -b:v 800k \
    -maxrate 900k \
    -bufsize 2400k \
    -max_muxing_queue_size 2048 \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time 6 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

  last_ok_ts="$(date +%s)"
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
    sleep 15

    if [ -f "$OUT/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT/index.m3u8")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web8_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web8_proxy] ffmpeg salió con código $rc. Reintentando en 10 segundos..." >&2
  sleep 10

done
