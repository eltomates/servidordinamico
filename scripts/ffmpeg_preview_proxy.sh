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
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -i "$SRC_URL" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -b:v 1000k \
    -maxrate 1500k \
    -bufsize 3000k \
    -max_muxing_queue_size 2048 \
    -g 48 \
    -keyint_min 48 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$KEEP_SEGMENTS" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

  # Supervisar que index.m3u8 se siga actualizando; si se queda congelado
  # durante demasiado tiempo, matamos ffmpeg y reintentamos.
  MAX_STALE_SECONDS=180

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
      echo "[ffmpeg_preview_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
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
