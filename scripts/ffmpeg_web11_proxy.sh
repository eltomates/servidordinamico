#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV a un HLS local servido por Apache.
# Entrada:  https://d3s7x6kmqcnb6b.cloudfront.net/d/distro001a/G7RPZJDZ6V3CRIAWTNFU/hls3/now,-1m/m.m3u8?ads.vf=vc24NGfvvqe
# Salida:   /var/www/html/hls/web11/index.m3u8 (accesible como /hls/web11/index.m3u8)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web11}"
SRC_URL="${SRC_URL:-https://d3s7x6kmqcnb6b.cloudfront.net/d/distro001a/G7RPZJDZ6V3CRIAWTNFU/hls3/now,-1m/m.m3u8?ads.vf=vc24NGfvvqe}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-36}"
HLS_TIME="${HLS_TIME:-6}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-15}"
HLS_DELETE_THRESHOLD="${HLS_DELETE_THRESHOLD:-10}"
FPS="${FPS:-25}"
GOP="${GOP:-150}"

mkdir -p "$OUT"

# Limpia segmentos heredados solo al arranque del script.
find "$OUT" -maxdepth 1 -type f -name 'seg_*.ts' -delete

while true; do
  set +e

  # Mantener algunos segmentos previos reduce cortes cuando ffmpeg reinicia.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"

  ffmpeg \
    -loglevel info \
    -rw_timeout 15000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0" \
    -i "$SRC_URL" \
    -map 0:v:0? \
    -map 0:a:0? \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r "$FPS" \
    -b:v 800k \
    -maxrate 900k \
    -bufsize 2400k \
    -max_muxing_queue_size 2048 \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_delete_threshold "$HLS_DELETE_THRESHOLD" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

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
      echo "[ffmpeg_web11_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web11_proxy] ffmpeg salió con código $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
