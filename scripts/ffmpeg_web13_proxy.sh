#!/usr/bin/env bash

# Proxy HLS para páginas o streams remotos que requieren extracción previa.
# Entrada:  https://www.radioformula.com.mx/en-vivo/teleformula
# Salida:   /var/www/html/hls/web13/index.m3u8 (accesible como /hls/web13/index.m3u8)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web13}"
SRC_URL="${SRC_URL:-https://www.radioformula.com.mx/en-vivo/teleformula}"
YT_SEARCH_FALLBACK="${YT_SEARCH_FALLBACK:-https://mdstrm.com/live-stream-playlist/62f2c855f7981b5a5a2d8763.m3u8}"
YT_FORMAT_SELECTOR="${YT_FORMAT_SELECTOR:-bv*[vcodec^=avc1][height<=720][ext=mp4]+ba[ext=mp4]/bv*[vcodec^=avc1][ext=mp4]+ba[ext=mp4]/b}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-420}"
LOCAL_SEGMENT_STALE_SECONDS="${LOCAL_SEGMENT_STALE_SECONDS:-150}"
FFMPEG_USER_AGENT="${FFMPEG_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0}"
FORCE_FALLBACK_FLAG="${FORCE_FALLBACK_FLAG:-/var/www/html/logs/channel_fallback_flags/web13.force_fallback}"
FORCE_FALLBACK_TTL_SECONDS="${FORCE_FALLBACK_TTL_SECONDS:-21600}"

mkdir -p "$OUT"

is_direct_stream_url() {
  case "$1" in
    *.m3u8*|*.mpd*) return 0 ;;
    *) return 1 ;;
  esac
}

fallback_flag_is_active() {
  local flag_mtime
  local now_ts

  if [ -z "$YT_SEARCH_FALLBACK" ] || [ ! -f "$FORCE_FALLBACK_FLAG" ]; then
    return 1
  fi

  flag_mtime="$(stat -c %Y "$FORCE_FALLBACK_FLAG" 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"

  if [ "$flag_mtime" -le 0 ] || [ $(( now_ts - flag_mtime )) -ge "$FORCE_FALLBACK_TTL_SECONDS" ]; then
    rm -f "$FORCE_FALLBACK_FLAG" 2>/dev/null || true
    return 1
  fi

  return 0
}

latest_segment_mtime() {
  local latest_segment

  latest_segment="$(find "$OUT" -maxdepth 1 -type f -name 'seg_*.ts' -printf '%T@ %p
' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  if [ -z "$latest_segment" ]; then
    echo 0
    return
  fi

  stat -c %Y "$latest_segment" 2>/dev/null || echo 0
}

run_ffmpeg_from_direct_url() {
  local input_url="$1"

  echo "[ffmpeg_web13_proxy] Usando origen directo: $input_url" >&2

  ffmpeg     -loglevel info     -rw_timeout 15000000     -reconnect 1     -reconnect_streamed 1     -reconnect_on_network_error 1     -reconnect_on_http_error 4xx,5xx     -reconnect_delay_max 10     -fflags +discardcorrupt+genpts     -err_detect ignore_err     -user_agent "$FFMPEG_USER_AGENT"     -i "$input_url"     -map 0:v:0?     -map 0:a:0?     -dn     -sn     -c:v libx264     -preset ultrafast     -tune zerolatency     -profile:v baseline     -level 3.1     -vf "scale=-2:480:flags=fast_bilinear,fps=20"     -b:v 800k     -maxrate 900k     -bufsize 2400k     -max_muxing_queue_size 2048     -g 40     -keyint_min 40     -sc_threshold 0     -c:a aac     -ac 2     -b:a 96k     -f hls     -hls_time 4     -hls_list_size 10     -start_number "$START_NUMBER"     -hls_flags delete_segments+program_date_time+independent_segments     -hls_segment_filename "$OUT/seg_%06d.ts"     "$OUT/index.m3u8" &
}

run_ffmpeg_from_ytdlp() {
  local source_url="$1"

  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "[ffmpeg_web13_proxy] yt-dlp no está instalado; no se puede resolver $source_url" >&2
    return 1
  fi

  echo "[ffmpeg_web13_proxy] Resolviendo y enviando por tubería: $source_url" >&2

  set -o pipefail
  yt-dlp --no-warnings --no-playlist -f "$YT_FORMAT_SELECTOR" -o - "$source_url" |     ffmpeg       -loglevel info       -fflags +discardcorrupt+genpts       -err_detect ignore_err       -i pipe:0       -c:v libx264       -preset ultrafast       -tune zerolatency       -profile:v baseline       -level 3.1       -vf "scale=-2:480:flags=fast_bilinear,fps=20"       -r 20       -b:v 800k       -maxrate 900k       -bufsize 2400k       -max_muxing_queue_size 2048       -g 40       -keyint_min 40       -c:a aac       -ac 2       -b:a 96k       -f hls       -hls_time 4       -hls_list_size 10       -start_number "$START_NUMBER"       -hls_flags delete_segments+program_date_time+independent_segments       -hls_segment_filename "$OUT/seg_%06d.ts"       "$OUT/index.m3u8"
}

consecutive_stale_kills=0

while true; do
  set +e

  find "$OUT" -maxdepth 1 -type f -name 'seg_*.ts' -delete
  START_NUMBER="$(date +%s)"

  current_source_url="$SRC_URL"
  force_ytdlp_fallback=0
  if fallback_flag_is_active; then
    force_ytdlp_fallback=1
    current_source_url="$YT_SEARCH_FALLBACK"
    echo "[ffmpeg_web13_proxy] Fallback preventivo activo; usando $YT_SEARCH_FALLBACK" >&2
  elif [ "$consecutive_stale_kills" -ge 3 ] && ! is_direct_stream_url "$SRC_URL"; then
    force_ytdlp_fallback=1
    current_source_url="$YT_SEARCH_FALLBACK"
    echo "[ffmpeg_web13_proxy] Detectados $consecutive_stale_kills reinicios por stale; probando fallback temporal." >&2
  fi

  if [ "$force_ytdlp_fallback" -eq 0 ] && is_direct_stream_url "$current_source_url"; then
    run_ffmpeg_from_direct_url "$current_source_url"
    ffmpeg_pid=$!
  else
    run_ffmpeg_from_ytdlp "$current_source_url" &
    ffmpeg_pid=$!

    sleep 5
    if ! kill -0 "$ffmpeg_pid" 2>/dev/null && [[ "$SRC_URL" == *radioformula.com.mx*teleformula* ]]; then
      echo "[ffmpeg_web13_proxy] Falló la URL original; probando fallback $YT_SEARCH_FALLBACK" >&2
      if is_direct_stream_url "$YT_SEARCH_FALLBACK"; then
        run_ffmpeg_from_direct_url "$YT_SEARCH_FALLBACK"
      else
        run_ffmpeg_from_ytdlp "$YT_SEARCH_FALLBACK" &
      fi
      ffmpeg_pid=$!
    fi
  fi

  last_ok_ts="$(date +%s)"
  last_index_mtime="$(stat -c %Y "$OUT/index.m3u8" 2>/dev/null || echo 0)"
  last_segment_mtime="$(latest_segment_mtime)"

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep 15
    now_ts="$(date +%s)"
    progress=0

    current_index_mtime="$(stat -c %Y "$OUT/index.m3u8" 2>/dev/null || echo 0)"
    if [ "$current_index_mtime" -gt 0 ] && [ "$current_index_mtime" != "$last_index_mtime" ]; then
      last_index_mtime="$current_index_mtime"
      progress=1
    fi

    current_segment_mtime="$(latest_segment_mtime)"
    if [ "$current_segment_mtime" -gt 0 ] && [ "$current_segment_mtime" != "$last_segment_mtime" ]; then
      last_segment_mtime="$current_segment_mtime"
      progress=1
    fi

    if [ "$progress" -eq 1 ]; then
      last_ok_ts="$now_ts"
    fi

    if [ "$current_segment_mtime" -gt 0 ] && [ $(( now_ts - current_segment_mtime )) -ge "$LOCAL_SEGMENT_STALE_SECONDS" ]; then
      echo "[ffmpeg_web13_proxy] ultimo segmento local lleva $(( now_ts - current_segment_mtime )) s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      consecutive_stale_kills=$((consecutive_stale_kills + 1))
      sleep 2
      break
    fi

    stale_seconds=$(( now_ts - last_ok_ts ))
    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web13_proxy] index/segmentos llevan $stale_seconds s sin progreso, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      consecutive_stale_kills=$((consecutive_stale_kills + 1))
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    consecutive_stale_kills=0
  fi

  echo "[ffmpeg_web13_proxy] ffmpeg salió con código $rc (stale_restarts=$consecutive_stale_kills). Reintentando en 5 segundos..." >&2
  sleep 5
done
