#!/usr/bin/env bash

# Proxy HLS desde una URL remota a un HLS local servido por Apache.
# Entrada:  http://38.49.128.38:8000/play/a0c0/index.m3u8
# Salida:   /var/www/html/hls/web3/index.m3u8 (accesible como /hls/web3/index.m3u8)

set -e
umask 000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web3}"
SRC_URL="${SRC_URL:-http://38.49.128.38:8000/play/a0c0/index.m3u8}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-20}"
# Ajustes más similares a un canal estable (p.ej. web1)
FPS="${FPS:-25}"
GOP="${GOP:-50}"
VBV_MAX="${VBV_MAX:-1200k}"
VBV_BUF="${VBV_BUF:-3000k}"
VIDEO_BITRATE="${VIDEO_BITRATE:-1000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-180}"

mkdir -p "$OUT"
chmod 777 "$OUT" 2>/dev/null || true

while true; do
  set +e

  # Mantener segmentos antiguos para evitar cortes en el reproductor tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  # Usar un identificador único por reinicio en el nombre de los
  # segmentos para evitar que el cliente reutilice archivos en caché.
  RUN_ID="$(date +%s)"

  ffmpeg \
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -user_agent "VLC/3.0.20 LibVLC/3.0.20" \
    -i "$SRC_URL" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r "$FPS" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VBV_MAX" \
    -bufsize "$VBV_BUF" \
    -max_muxing_queue_size 2048 \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -c:a aac \
    -ac 2 \
    -b:a "$AUDIO_BITRATE" \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_${RUN_ID}_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

  last_ok_ts="$(date +%s)"
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
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
      echo "[ffmpeg_web3_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web3_proxy] ffmpeg salió con código $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
