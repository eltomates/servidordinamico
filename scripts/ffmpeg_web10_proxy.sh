#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV a un HLS local servido por Apache.
# Entrada:  https://jmp2.uk/plu-61b793ccf571b80007b7a610.m3u8
# Salida:   /var/www/html/hls/web10/index.m3u8 (master HLS accesible como /hls/web10/index.m3u8)

set -e
umask 000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
CONFIG_SRC_URL=""
CONFIG_WATCH_URL=""
CONFIG_VARIANT_URL=""

if [ -f "$PRIMARY_CONFIG" ]; then
  # shellcheck source=/var/www/html/logs/web_sources.env
  . "$PRIMARY_CONFIG"
  CONFIG_WATCH_URL="${WEB10_URL:-}"
  CONFIG_SRC_URL="${WEB10_URL:-${WEB10_RESOLVED_URL:-}}"
  CONFIG_VARIANT_URL="${WEB10_VARIANT_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_WATCH_URL="${WEB10_URL:-}"
  CONFIG_SRC_URL="${WEB10_URL:-${WEB10_RESOLVED_URL:-}}"
  CONFIG_VARIANT_URL="${WEB10_VARIANT_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web10}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-http://38.49.128.38:8000/play/a0n6/index.m3u8}}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-18}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"
MAX_SEGMENT_REPEAT_SECONDS="${MAX_SEGMENT_REPEAT_SECONDS:-30}"
VISUAL_FREEZE_ENABLED="${VISUAL_FREEZE_ENABLED:-0}"
VISUAL_FREEZE_SAMPLE_INTERVAL_SECONDS="${VISUAL_FREEZE_SAMPLE_INTERVAL_SECONDS:-30}"
VISUAL_FREEZE_MAX_SECONDS="${VISUAL_FREEZE_MAX_SECONDS:-180}"
VISUAL_FREEZE_MIN_SAMPLES="${VISUAL_FREEZE_MIN_SAMPLES:-4}"
VISUAL_FREEZE_PROBE_TIMEOUT_SECONDS="${VISUAL_FREEZE_PROBE_TIMEOUT_SECONDS:-12}"
FPS="${FPS:-15}"
GOP="${GOP:-30}"
VBV_MAX="${VBV_MAX:-700k}"
VBV_BUF="${VBV_BUF:-1800k}"
VIDEO_BITRATE="${VIDEO_BITRATE:-600k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"
ROKU_TARGET_BANDWIDTH="${ROKU_TARGET_BANDWIDTH:-700000}"
ROKU_REFRESH_WINDOW_SECONDS="${ROKU_REFRESH_WINDOW_SECONDS:-600}"
YT_FORMAT_SELECTOR="${YT_FORMAT_SELECTOR:-bv*[vcodec^=avc1][height<=720][ext=mp4]+ba[ext=mp4]/bv*[vcodec^=avc1][ext=mp4]+ba[ext=mp4]/b}"
WEB10_TARGET_BANDWIDTH="${WEB10_TARGET_BANDWIDTH:-1200000}"
WEB10_PLUTO_DIRECT_HLS="${WEB10_PLUTO_DIRECT_HLS:-0}"
WEB10_PLUTO_DIRECT_MODE="${WEB10_PLUTO_DIRECT_MODE:-pair}"
WEB10_PLUTO_RESOLVE_SECONDS="${WEB10_PLUTO_RESOLVE_SECONDS:-20}"
PLUTO_TARGET_BANDWIDTH="${PLUTO_TARGET_BANDWIDTH:-$WEB10_TARGET_BANDWIDTH}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLUTO_CHROMIUM_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_TIMEOUT_SECONDS:-$WEB10_PLUTO_RESOLVE_SECONDS}"
PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS:-210}"
PLUTO_REQUIRE_CHROMIUM="${PLUTO_REQUIRE_CHROMIUM:-1}"
PLUTO_SKIP_VERIFY="${PLUTO_SKIP_VERIFY:-1}"
PLUTO_AUDIO_OFFSET_SECONDS="${WEB10_PLUTO_AUDIO_OFFSET_SECONDS:-${PLUTO_AUDIO_OFFSET_SECONDS:-0}}"
WEB10_SYNTH_AUDIO_ON_STITCHER="${WEB10_SYNTH_AUDIO_ON_STITCHER:-0}"
PLUTO_SOURCE_SWITCH_GRACE_SECONDS="${PLUTO_SOURCE_SWITCH_GRACE_SECONDS:-90}"
PLUTO_STALE_GRACE_SECONDS="${PLUTO_STALE_GRACE_SECONDS:-180}"
HLS_RW_TIMEOUT_US="${HLS_RW_TIMEOUT_US:-5000000}"
HLS_ALLOWED_EXTENSIONS="${HLS_ALLOWED_EXTENSIONS:-ALL}"
HLS_ALLOWED_SEGMENT_EXTENSIONS="${HLS_ALLOWED_SEGMENT_EXTENSIONS:-ALL}"
HLS_MAX_RELOAD="${HLS_MAX_RELOAD:-100000}"
HLS_M3U8_HOLD_COUNTERS="${HLS_M3U8_HOLD_COUNTERS:-100000}"
HLS_SEG_MAX_RETRY="${HLS_SEG_MAX_RETRY:-8}"
HLS_HTTP_PERSISTENT="${HLS_HTTP_PERSISTENT:-0}"
HLS_HTTP_MULTIPLE="${HLS_HTTP_MULTIPLE:-0}"
HLS_HTTP_SEEKABLE="${HLS_HTTP_SEEKABLE:-0}"
WEB10_JMP2_PASSTHROUGH="${WEB10_JMP2_PASSTHROUGH:-0}"
WEB10_JMP2_REFRESH_SECONDS="${WEB10_JMP2_REFRESH_SECONDS:-30}"
HLS_LIVE_START_INDEX="${HLS_LIVE_START_INDEX:--3}"
HLS_RECONNECT_DELAY_MAX="${HLS_RECONNECT_DELAY_MAX:-10}"
HLS_RECONNECT_AT_EOF="${HLS_RECONNECT_AT_EOF:-0}"
HLS_RECONNECT_MAX_RETRIES="${HLS_RECONNECT_MAX_RETRIES:--1}"
HLS_RECONNECT_DELAY_TOTAL_MAX="${HLS_RECONNECT_DELAY_TOTAL_MAX:-180}"
HLS_RESPECT_RETRY_AFTER="${HLS_RESPECT_RETRY_AFTER:-0}"
HLS_USE_WALLCLOCK_TS="${HLS_USE_WALLCLOCK_TS:-0}"
HLS_MAX_INTERLEAVE_DELTA_US="${HLS_MAX_INTERLEAVE_DELTA_US:-3000000}"
AUDIO_RESAMPLE_ASYNC="${AUDIO_RESAMPLE_ASYNC:-1000}"
AUTO_REPAIR_ENABLED="${AUTO_REPAIR_ENABLED:-1}"
AUTO_REPAIR_MAX_RESTARTS="${AUTO_REPAIR_MAX_RESTARTS:-3}"
AUTO_REPAIR_WINDOW_SECONDS="${AUTO_REPAIR_WINDOW_SECONDS:-900}"
AUTO_REPAIR_HEALTHY_RESET_SECONDS="${AUTO_REPAIR_HEALTHY_RESET_SECONDS:-600}"
AUTO_REPAIR_BACKOFF_SECONDS="${AUTO_REPAIR_BACKOFF_SECONDS:-8}"
AUTO_REPAIR_ESCALATE_TO_ORCHESTRATOR="${AUTO_REPAIR_ESCALATE_TO_ORCHESTRATOR:-1}"
AUTO_REPAIR_ALARM_SCRIPT="${AUTO_REPAIR_ALARM_SCRIPT:-$SCRIPT_DIR/web_channel_alarm.sh}"
WEB10_BROWSER_RESTREAM="${WEB10_BROWSER_RESTREAM:-1}"
WEB10_BROWSER_WIDTH="${WEB10_BROWSER_WIDTH:-854}"
WEB10_BROWSER_HEIGHT="${WEB10_BROWSER_HEIGHT:-480}"
WEB10_BROWSER_FPS="${WEB10_BROWSER_FPS:-20}"
WEB10_BROWSER_360_FPS="${WEB10_BROWSER_360_FPS:-15}"
WEB10_BROWSER_180_FPS="${WEB10_BROWSER_180_FPS:-12}"
WEB10_BROWSER_SESSION_SECONDS="${WEB10_BROWSER_SESSION_SECONDS:-0}"
WEB10_BROWSER_CAPTURE_TOP="${WEB10_BROWSER_CAPTURE_TOP:-0}"
WEB10_BROWSER_CAPTURE_LEFT="${WEB10_BROWSER_CAPTURE_LEFT:-0}"
WEB10_BROWSER_TRIM_TOP="${WEB10_BROWSER_TRIM_TOP:-76}"
WEB10_BROWSER_AUDIO_MODE="${WEB10_BROWSER_AUDIO_MODE:-browser-fifo}"
WEB10_BROWSER_AUDIO_DELAY_MS="${WEB10_BROWSER_AUDIO_DELAY_MS:-0}"
WEB10_BROWSER_VIDEO_DELAY_MS="${WEB10_BROWSER_VIDEO_DELAY_MS:-400}"
WEB10_BROWSER_ALSA_OUTPUT_DEVICE="${WEB10_BROWSER_ALSA_OUTPUT_DEVICE:-browser_fifo}"
WEB10_BROWSER_FIFO_ID="${WEB10_BROWSER_FIFO_ID:-web10}"
WEB10_BROWSER_BOOT_SECONDS="${WEB10_BROWSER_BOOT_SECONDS:-1}"

mkdir -p "$OUT" "$OUT/480p" "$OUT/360p" "$OUT/180p"
chmod 777 "$OUT" 2>/dev/null || true

get_config_file() {
  if [ -f "$PRIMARY_CONFIG" ]; then
    printf '%s\n' "$PRIMARY_CONFIG"
    return 0
  fi

  if [ -f "$LEGACY_CONFIG" ]; then
    printf '%s\n' "$LEGACY_CONFIG"
    return 0
  fi

  return 1
}

derive_pluto_audio_url() {
  local video_url="$1"

  case "$video_url" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*)
      printf '%s\n' "$(printf '%s' "$video_url" | sed -E 's#/([0-9]+)/playlist\.m3u8#/audio/audio/English/audio.m3u8#')"
      ;;
    *stitcher-ipv4.pluto.tv/v2/stitch/embed/hls/channel/*/[0-9]*/playlist.m3u8*)
      printf '%s\n' "$(printf '%s' "$video_url" | sed -E 's#/([0-9]+)/playlist\.m3u8#/audio/audio/English/audio.m3u8#')"
      ;;
    *)
      return 1
      ;;
  esac
}

build_absolute_url() {
  local base_url="$1"
  local child_url="$2"
  local scheme host base_dir

  case "$child_url" in
    http://*|https://*)
      printf '%s\n' "$child_url"
      return 0
      ;;
    /*)
      scheme="${base_url%%://*}"
      host="${base_url#*://}"
      host="${host%%/*}"
      printf '%s://%s%s\n' "$scheme" "$host" "$child_url"
      return 0
      ;;
    *)
      base_dir="${base_url%/*}"
      printf '%s/%s\n' "$base_dir" "$child_url"
      return 0
      ;;
  esac
}

select_best_hls_variant() {
  local master_url="$1"

  python3 - "$master_url" "$WEB10_TARGET_BANDWIDTH" <<'PY'
import re
import sys
import urllib.request
from urllib.parse import urljoin

master_url = sys.argv[1]
target_bandwidth = int(sys.argv[2])
req = urllib.request.Request(master_url, headers={'User-Agent': 'Mozilla/5.0'})

with urllib.request.urlopen(req, timeout=30) as response:
    final_url = response.geturl()
    text = response.read().decode('utf-8', 'ignore')

best_url = ''
best_score = None
pending_bandwidth = None

for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line.startswith('#EXT-X-STREAM-INF:'):
        match = re.search(r'(?:AVERAGE-)?BANDWIDTH=(\d+)', line)
        pending_bandwidth = int(match.group(1)) if match else 0
        continue
    if line.startswith('#') or pending_bandwidth is None:
        continue

    score = abs(pending_bandwidth - target_bandwidth)
    if best_score is None or score < best_score:
        best_score = score
        best_url = urljoin(final_url, line)
    pending_bandwidth = None

if not best_url:
    raise SystemExit(1)

print(best_url)
PY
}

url_has_video_stream() {
  local test_url="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    return 0
  fi

  timeout 8 ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

url_has_audio_stream() {
  local test_url="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    return 0
  fi

  timeout 8 ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

compute_visual_hash() {
  local playlist="$OUT/480p/index.m3u8"
  local timeout_cmd=( )

  if [ "$VISUAL_FREEZE_ENABLED" != "1" ] || [ ! -f "$playlist" ]; then
    return 1
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout "$VISUAL_FREEZE_PROBE_TIMEOUT_SECONDS")
  fi

  "${timeout_cmd[@]}" ffmpeg \
    -v error \
    -nostdin \
    -hide_banner \
    -fflags nobuffer \
    -i "$playlist" \
    -an \
    -frames:v 1 \
    -vf "scale=32:18:flags=fast_bilinear,format=gray" \
    -f md5 - 2>/dev/null | awk -F= '/^MD5=/{print $2; exit}'
}

stop_ffmpeg() {
  local pid="$1"
  local i

  kill "$pid" 2>/dev/null || return 0
  for i in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "[ffmpeg_web10_proxy] ffmpeg no terminó con SIGTERM; enviando SIGKILL ($pid)" >&2
  kill -9 "$pid" 2>/dev/null || true
}

add_hls_input_options() {
  FFMPEG_CMD+=(
    -extension_picky 0
    -allowed_extensions "$HLS_ALLOWED_EXTENSIONS"
    -allowed_segment_extensions "$HLS_ALLOWED_SEGMENT_EXTENSIONS"
    -max_reload "$HLS_MAX_RELOAD"
    -m3u8_hold_counters "$HLS_M3U8_HOLD_COUNTERS"
    -seg_max_retry "$HLS_SEG_MAX_RETRY"
    -http_persistent "$HLS_HTTP_PERSISTENT"
    -http_multiple "$HLS_HTTP_MULTIPLE"
    -http_seekable "$HLS_HTTP_SEEKABLE"
    -probesize 1000000
    -analyzeduration 1000000
  )
  if [ -n "$HLS_LIVE_START_INDEX" ]; then
    FFMPEG_CMD+=( -live_start_index "$HLS_LIVE_START_INDEX" )
  fi
  FFMPEG_CMD+=(
    -rw_timeout "$HLS_RW_TIMEOUT_US"
    -reconnect 1
    -reconnect_at_eof "$HLS_RECONNECT_AT_EOF"
    -reconnect_streamed 1
    -reconnect_on_network_error 1
    -reconnect_on_http_error 4xx,5xx
    -reconnect_delay_max "$HLS_RECONNECT_DELAY_MAX"
    -reconnect_max_retries "$HLS_RECONNECT_MAX_RETRIES"
    -reconnect_delay_total_max "$HLS_RECONNECT_DELAY_TOTAL_MAX"
    -respect_retry_after "$HLS_RESPECT_RETRY_AFTER"
    -use_wallclock_as_timestamps "$HLS_USE_WALLCLOCK_TS"
    -user_agent "Mozilla/5.0"
  )
}

append_common_output_options() {
  FFMPEG_CMD+=(
    -dn
    -sn
    -c:v libx264
    -preset ultrafast
    -tune zerolatency
    -profile:v baseline
    -level 3.1
    -b:v:0 650k -maxrate:v:0 780k -bufsize:v:0 1600k
    -b:v:1 420k -maxrate:v:1 520k -bufsize:v:1 1100k
    -b:v:2 220k -maxrate:v:2 300k -bufsize:v:2 700k
    -max_muxing_queue_size 4096
    -max_interleave_delta "$HLS_MAX_INTERLEAVE_DELTA_US"
    -r:v:0 20
    -r:v:1 15
    -r:v:2 12
    -g 80
    -keyint_min 80
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*4)"
    -c:a aac
    -ac 2
    -b:a:0 96k -b:a:1 96k -b:a:2 64k
    -f hls
    -hls_time 4
    -hls_list_size "$HLS_LIST_SIZE"
    -start_number "$START_NUMBER"
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist
    -var_stream_map "v:1,a:1,name:360p v:2,a:2,name:180p v:0,a:0,name:480p"
    -master_pl_name index.m3u8
    -hls_segment_filename "$OUT/%v/seg_${RUN_ID}_%06d.ts"
    "$OUT/%v/index.m3u8"
  )
}

run_ffmpeg_from_passthrough_url() {
  local input_url="$1"
  local video_stream_spec="${WEB10_JMP2_PASSTHROUGH_VIDEO_STREAM:-0:v:0}"
  local audio_stream_spec="${WEB10_JMP2_PASSTHROUGH_AUDIO_STREAM:-0:a:0}"
  local FFMPEG_CMD=(
    ffmpeg
    -nostdin
    -hide_banner
    -loglevel info
    -ignore_unknown
    -fflags +genpts+discardcorrupt
    -err_detect ignore_err
    -thread_queue_size 2048
  )

  echo "[ffmpeg_web10_proxy] Passthrough directo jmp2 sin filtros: video=$video_stream_spec audio=$audio_stream_spec" >&2
  HLS_LIVE_START_INDEX="${WEB10_JMP2_LIVE_START_INDEX:--3}"
  add_hls_input_options
  FFMPEG_CMD+=(
    -i "$input_url"
    -map "$video_stream_spec"
    -map "$audio_stream_spec"
    -dn
    -sn
    -c:v copy
    -c:a copy
    -max_muxing_queue_size 4096
    -max_interleave_delta "$HLS_MAX_INTERLEAVE_DELTA_US"
    -f hls
    -hls_time 4
    -hls_list_size "$HLS_LIST_SIZE"
    -start_number "$START_NUMBER"
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist
    -var_stream_map "v:0,a:0,name:480p"
    -master_pl_name index.m3u8
    -hls_segment_filename "$OUT/%v/seg_${RUN_ID}_%06d.ts"
    "$OUT/%v/index.m3u8"
  )
  "${FFMPEG_CMD[@]}" &
}

run_jmp2_master_passthrough_loop() {
  local source_url="$1"
  local tmp_file="$OUT/index.m3u8.tmp"

  echo "[ffmpeg_web10_proxy] Passthrough master jmp2: refrescando master local cada ${WEB10_JMP2_REFRESH_SECONDS}s" >&2
  while true; do
    if python3 - "$source_url" "$tmp_file" <<'PY'
import re
import sys
import urllib.request
from urllib.parse import urljoin

source_url, output_path = sys.argv[1:3]
request = urllib.request.Request(source_url, headers={'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20'})

with urllib.request.urlopen(request, timeout=30) as response:
    final_url = response.geturl()
    text = response.read().decode('utf-8', 'ignore')

def rewrite_uri_attributes(line):
    def repl(match):
        return f'{match.group(1)}"{urljoin(final_url, match.group(2))}"'
    return re.sub(r'(URI=)"([^"]+)"', repl, line)

out = []
expect_stream_uri = False
for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line.startswith('#EXT-X-STREAM-INF:'):
        out.append(line)
        expect_stream_uri = True
        continue
    if line.startswith('#'):
        out.append(rewrite_uri_attributes(line))
        continue
    if expect_stream_uri:
        out.append(urljoin(final_url, line))
        expect_stream_uri = False
    else:
        out.append(line)

if not any(line.startswith('#EXT-X-STREAM-INF:') for line in out):
    raise SystemExit('master sin variantes')

with open(output_path, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(out) + '\n')
PY
    then
      mv -f "$tmp_file" "$OUT/index.m3u8"
      chmod 666 "$OUT/index.m3u8" 2>/dev/null || true
    else
      rm -f "$tmp_file" 2>/dev/null || true
      echo "[ffmpeg_web10_proxy] No se pudo refrescar master jmp2; reintentando..." >&2
    fi
    sleep "$WEB10_JMP2_REFRESH_SECONDS"
  done
}

run_ffmpeg_from_direct_url() {
  local input_url="$1"
  case "$input_url" in
    *jmp2.uk/plu-61b793ccf571b80007b7a610.m3u8*)
      if [ "$WEB10_JMP2_PASSTHROUGH" = "1" ]; then
        run_ffmpeg_from_passthrough_url "$input_url"
        return
      fi
      ;;
  esac
  local video_stream_spec="${WEB10_DIRECT_VIDEO_STREAM:-0:v:0}"
  case "$input_url" in
    *jmp2.uk/plu-61b793ccf571b80007b7a610.m3u8*)
      video_stream_spec="${WEB10_DIRECT_VIDEO_STREAM:-0:v:0}"
      HLS_LIVE_START_INDEX="${WEB10_JMP2_LIVE_START_INDEX:--3}"
      ;;
  esac
  local FFMPEG_CMD=(
    ffmpeg
    -nostdin
    -hide_banner
    -loglevel info
    -ignore_unknown
    -fflags +genpts+discardcorrupt
    -err_detect ignore_err
    -thread_queue_size 2048
  )

  echo "[ffmpeg_web10_proxy] Modo HLS tolerante: extensiones=$HLS_ALLOWED_EXTENSIONS segmentos=$HLS_ALLOWED_SEGMENT_EXTENSIONS http_persistent=$HLS_HTTP_PERSISTENT retry_segmento=$HLS_SEG_MAX_RETRY" >&2
  add_hls_input_options
  FFMPEG_CMD+=(
    -i "$input_url"
    -filter_complex "[${video_stream_spec}]split=3[v480src][v360src][v180src];[v480src]scale=-2:480:flags=fast_bilinear,fps=20,setpts=N/(20*TB)[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=15,setpts=N/(15*TB)[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=12,setpts=N/(12*TB)[v180];[0:a:0]aresample=async=${AUDIO_RESAMPLE_ASYNC}:first_pts=0,asetpts=N/SR/TB,asplit=3[a480][a360][a180]"
    -map "[v480]" -map "[a480]"
    -map "[v360]" -map "[a360]"
    -map "[v180]" -map "[a180]"
  )
  append_common_output_options
  "${FFMPEG_CMD[@]}" &
}

run_ffmpeg_from_dual_url() {
  local video_url="$1"
  local audio_url="$2"
  local FFMPEG_CMD=(
    ffmpeg
    -nostdin
    -hide_banner
    -loglevel info
    -ignore_unknown
    -fflags +genpts+discardcorrupt
    -err_detect ignore_err
    -thread_queue_size 2048
  )

  echo "[ffmpeg_web10_proxy] Usando video + audio Pluto: $video_url | $audio_url" >&2
  echo "[ffmpeg_web10_proxy] Modo HLS tolerante: extensiones=$HLS_ALLOWED_EXTENSIONS segmentos=$HLS_ALLOWED_SEGMENT_EXTENSIONS http_persistent=$HLS_HTTP_PERSISTENT retry_segmento=$HLS_SEG_MAX_RETRY" >&2

  add_hls_input_options
  FFMPEG_CMD+=(
    -i "$video_url"
    -thread_queue_size 2048
    -itsoffset "$PLUTO_AUDIO_OFFSET_SECONDS"
  )
  add_hls_input_options
  FFMPEG_CMD+=(
    -i "$audio_url"
    -filter_complex "[0:v:0]split=3[v480src][v360src][v180src];[v480src]scale=-2:480:flags=fast_bilinear,fps=20,setpts=N/(20*TB)[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=15,setpts=N/(15*TB)[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=12,setpts=N/(12*TB)[v180];[1:a:0]aresample=async=${AUDIO_RESAMPLE_ASYNC}:first_pts=0,asetpts=N/SR/TB,asplit=3[a480][a360][a180]"
    -map "[v480]" -map "[a480]"
    -map "[v360]" -map "[a360]"
    -map "[v180]" -map "[a180]"
  )
  append_common_output_options
  "${FFMPEG_CMD[@]}" &
}

run_ffmpeg_from_video_with_synthetic_audio() {
  local video_url="$1"
  local FFMPEG_CMD=(
    ffmpeg
    -nostdin
    -hide_banner
    -loglevel info
    -ignore_unknown
    -fflags +genpts+discardcorrupt
    -err_detect ignore_err
    -thread_queue_size 2048
  )

  echo "[ffmpeg_web10_proxy] Usando video Pluto + audio sintetico estable para tolerar discontinuidades de anuncios: $video_url" >&2
  echo "[ffmpeg_web10_proxy] Modo HLS tolerante: extensiones=$HLS_ALLOWED_EXTENSIONS segmentos=$HLS_ALLOWED_SEGMENT_EXTENSIONS http_persistent=$HLS_HTTP_PERSISTENT retry_segmento=$HLS_SEG_MAX_RETRY" >&2

  add_hls_input_options
  FFMPEG_CMD+=(
    -i "$video_url"
    -thread_queue_size 2048
    -f lavfi
    -i "anullsrc=channel_layout=stereo:sample_rate=48000"
    -filter_complex "[0:v:0]split=3[v480src][v360src][v180src];[v480src]scale=-2:480:flags=fast_bilinear,fps=20,setpts=N/(20*TB)[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=15,setpts=N/(15*TB)[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=12,setpts=N/(12*TB)[v180];[1:a:0]asetpts=N/SR/TB,asplit=3[a480][a360][a180]"
    -map "[v480]" -map "[a480]"
    -map "[v360]" -map "[a360]"
    -map "[v180]" -map "[a180]"
  )
  append_common_output_options
  "${FFMPEG_CMD[@]}" &
}

resolve_pluto_source_url() {
  local page_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local chromium_output=""
  local chromium_url=""
  local chromium_timeout_cmd=( )

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    chromium_output="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 PLUTO_SKIP_VERIFY="$PLUTO_SKIP_VERIFY" PLUTO_TARGET_BANDWIDTH="$WEB10_TARGET_BANDWIDTH" python3 "$chromium_resolver" "$page_url" "$PLUTO_CHROMIUM_TIMEOUT_SECONDS" 2>&1 || true; } 9>&-)"

    chromium_url="$(printf '%s\n' "$chromium_output" | awk '/^https?:\/\//{u=$0} END{print u}')"
    if [ -z "$chromium_url" ]; then
      chromium_url="$(printf '%s\n' "$chromium_output" | grep -Eo 'https?://[^[:space:]]+' | grep -E '/(playlist|master)\.m3u8' | tail -n1 || true)"
    fi

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      echo "[ffmpeg_web10_proxy] Chromium resolvio URL HLS para Pluto." >&2
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  if [ "$PLUTO_REQUIRE_CHROMIUM" = "1" ]; then
    echo "[ffmpeg_web10_proxy] Chromium no resolvio URL valida para Pluto; reintentando sin fallback directo." >&2
    return 1
  fi

  python3 - "$page_url" "$PLUTO_TARGET_BANDWIDTH" <<'PY'
import re
import sys
import uuid
import urllib.parse
import urllib.request

page_url = sys.argv[1]
target_bandwidth = int(sys.argv[2])

match = re.search(r'/live-tv/([a-f0-9]{24})', page_url)
if not match:
  raise SystemExit(f'URL de Pluto no valida: {page_url}')

channel_id = match.group(1)
sid = str(uuid.uuid4())
device_id = str(uuid.uuid4())
query = urllib.parse.urlencode({
  'deviceType': 'web',
  'deviceMake': 'Chrome',
  'deviceModel': 'Chrome',
  'deviceVersion': '124.0.0.0',
  'appName': 'web',
  'appVersion': 'unknown',
  'buildVersion': 'unknown',
  'sid': sid,
  'deviceDNT': '0',
  'deviceId': device_id,
  'advertisingId': '',
  'userId': '',
  'clientTime': '0',
  'serverSideAds': 'true',
  'terminate': 'false',
  'includeExtendedEvents': 'false',
})
master_url = (
  'https://service-stitcher.clusters.pluto.tv/v1/stitch/embed/hls/'
  f'channel/{channel_id}/master.m3u8?{query}'
)

request = urllib.request.Request(master_url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(request, timeout=30) as response:
  final_url = response.geturl()
  text = response.read().decode('utf-8', 'ignore')

best_url = None
best_score = None
pending_bandwidth = None

for raw_line in text.splitlines():
  line = raw_line.strip()
  if not line:
    continue
  if line.startswith('#EXT-X-STREAM-INF:'):
    match = re.search(r'BANDWIDTH=(\d+)', line)
    pending_bandwidth = int(match.group(1)) if match else None
    continue
  if line.startswith('#'):
    continue
  if pending_bandwidth is None:
    continue

  score = abs(pending_bandwidth - target_bandwidth)
  if best_score is None or score < best_score:
    best_score = score
    best_url = urllib.parse.urljoin(final_url, line)
  pending_bandwidth = None

if not best_url:
  print(final_url)
  raise SystemExit(0)

variant_request = urllib.request.Request(best_url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(variant_request, timeout=30) as response:
  variant_text = response.read().decode('utf-8', 'ignore')

if 'ptv_takedownslates' in variant_text:
  raise SystemExit('Pluto devolvio takedown slate para este canal; no hay stream reproducible desde este servidor')

print(best_url)
PY
}

update_resolved_url_in_config() {
  local resolved_url="$1"
  local config_file tmp_file

  case "$resolved_url" in
    *osm.sr.roku.com/osm/v1/hls/master/*) ;;
    *)
      return 0
      ;;
  esac

  config_file="$(get_config_file 2>/dev/null || true)"
  if [ -z "$config_file" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  grep -v '^WEB10_RESOLVED_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB10_RESOLVED_URL="%s"\n' "$resolved_url" >> "$tmp_file"
  mv "$tmp_file" "$config_file"
  chmod 664 "$config_file" 2>/dev/null || true
}

update_variant_url_in_config() {
  local variant_url="$1"
  local config_file tmp_file

  case "$variant_url" in
    *osm-*.sr.roku.com/osm/v1/hls/*/variant/*/live_*.m3u8|*osm-use2.sr.roku.com/osm/v1/hls/*/variant/*/live_*.m3u8) ;;
    *)
      return 0
      ;;
  esac

  config_file="$(get_config_file 2>/dev/null || true)"
  if [ -z "$config_file" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  grep -v '^WEB10_VARIANT_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB10_VARIANT_URL="%s"\n' "$variant_url" >> "$tmp_file"
  mv "$tmp_file" "$config_file"
  chmod 664 "$config_file" 2>/dev/null || true
}

find_plex_query_template() {
  local config_file line value

  if [[ "$SRC_URL" == *X-Plex-Token=* ]]; then
    printf '%s\n' "${SRC_URL#*\?}"
    return 0
  fi

  config_file="$(get_config_file 2>/dev/null || true)"
  if [ -z "$config_file" ]; then
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      *=*X-Plex-Token=*)
        value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        printf '%s\n' "${value#*\?}"
        return 0
        ;;
    esac
  done < "$config_file"

  return 1
}

resolve_plex_watch_url() {
  local source_url="$1"
  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*)
      return 1
      ;;
  esac

  printf '%s\n' "$source_url"
}

resolve_roku_variant_url() {
  local source_url="$1"

  case "$source_url" in
    *osm.sr.roku.com/osm/v1/hls/master/*) ;;
    *)
      printf '%s\n' "$source_url"
      return 0
      ;;
  esac

  python3 - "$source_url" <<'PY'
import os
import re
import sys
import urllib.request
from urllib.parse import urljoin

source_url = sys.argv[1]
target_bandwidth = int(os.environ.get('ROKU_TARGET_BANDWIDTH', '700000'))
req = urllib.request.Request(source_url, headers={'User-Agent': 'Mozilla/5.0'})
with urllib.request.urlopen(req, timeout=30) as response:
    final_url = response.geturl()
    text = response.read().decode('utf-8', 'ignore')
best_url = None
best_score = None
pending_bandwidth = None

for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line.startswith('#EXT-X-STREAM-INF:'):
        match = re.search(r'BANDWIDTH=(\d+)', line)
        pending_bandwidth = int(match.group(1)) if match else None
        continue
    if line.startswith('#'):
        continue
    if pending_bandwidth is None:
        continue

    score = abs(pending_bandwidth - target_bandwidth)
    if best_score is None or score < best_score:
        best_score = score
        best_url = urljoin(final_url, line)
    pending_bandwidth = None

if not best_url:
    raise SystemExit(1)

print(best_url)
PY
}

resolve_roku_watch_url() {
  local source_url="$1"

  case "$source_url" in
  *therokuchannel.roku.com/watch/*) ;;
  *)
    printf '%s\n' "$source_url"
    return 0
    ;;
  esac

  python3 - "$source_url" <<'PY'
import json
import re
import sys
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

source_url = sys.argv[1]
match = re.search(r'/watch/([A-Za-z0-9]+)', source_url)
if not match:
  raise SystemExit(1)
content_id = match.group(1)

jar = CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def request(url, data=None, extra_headers=None):
  headers = {'User-Agent': 'Mozilla/5.0'}
  if extra_headers:
    headers.update(extra_headers)
  req = urllib.request.Request(url, data=data, headers=headers)
  with opener.open(req, timeout=30) as response:
    body = response.read().decode('utf-8', 'ignore')
  return body

try:
  request(source_url)
except Exception:
  raise SystemExit(1)


try:
  init_data = json.loads(request('https://therokuchannel.roku.com/api/v2/init')).get('init', {})
  content_data = json.loads(request(f'https://therokuchannel.roku.com/api/v2/content/roku-trc/{content_id}'))
except Exception:
  raise SystemExit(1)

view_options = content_data.get('viewOptions') or []
view_opt = view_options[0] if view_options else {}

  try:
    response_json = json.loads(response_body)
  except Exception:
    continue

  url = response_json.get('url', '')
  if url and 'osm.sr.roku.com/osm/v1/hls/master/' in url:
    print(url)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

ensure_fresh_roku_master_url() {
  local source_url="$1"
  local refresh_window

  refresh_window="${ROKU_REFRESH_WINDOW_SECONDS:-600}"

  case "$source_url" in
    *osm.sr.roku.com/osm/v1/hls/master/*) ;;
    *)
      printf '%s\n' "$source_url"
      return 0
      ;;
  esac

  python3 - "$source_url" "$refresh_window" <<'PY'
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

source_url = sys.argv[1]
refresh_window = int(sys.argv[2])

def b64url_decode(value):
  padding = '=' * (-len(value) % 4)
  return base64.urlsafe_b64decode((value + padding).encode('ascii'))

def parse_jwt_claims(url):
  match = re.search(r'[?&]jwt=([^&]+)', url)
  if not match:
    return {}
  token = match.group(1)
  parts = token.split('.')
  if len(parts) < 2:
    return {}
  try:
    payload = b64url_decode(parts[1]).decode('utf-8', 'ignore')
    return json.loads(payload)
  except Exception:
    return {}

claims = parse_jwt_claims(source_url)
content_id = claims.get('contentId', '')
exp = int(claims.get('exp', 0) or 0)
now = int(time.time())

if not content_id:
  print(source_url)
  raise SystemExit(0)

if exp > 0 and (exp - now) > refresh_window:
  print(source_url)
  raise SystemExit(0)

jar = CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def request(url, data=None, extra_headers=None):
  headers = {'User-Agent': 'Mozilla/5.0'}
  if extra_headers:
    headers.update(extra_headers)
  req = urllib.request.Request(url, data=data, headers=headers)
  with opener.open(req, timeout=30) as response:
    return response.read().decode('utf-8', 'ignore')

prefetch_urls = [
  'https://therokuchannel.roku.com/',
  f'https://therokuchannel.roku.com/watch/{content_id}',
]

for pre_url in prefetch_urls:
  try:
    request(pre_url)
    break
  except Exception:
    continue

try:
  init_data = json.loads(request('https://therokuchannel.roku.com/api/v2/init')).get('init', {})
except Exception:
  print(source_url)
  raise SystemExit(0)

play_id = ''
provider_id = ''
try:
  content_data = json.loads(request(f'https://therokuchannel.roku.com/api/v2/content/roku-trc/{content_id}'))
  view_options = content_data.get('viewOptions') or []
  view_opt = view_options[0] if view_options else {}
  play_id = view_opt.get('playId') or ''
  provider_id = view_opt.get('providerId') or ''
except Exception:
  pass

payload_candidates = [
  {'id': content_id},
  {'id': content_id, 'playId': play_id},
  {'id': content_id, 'playId': play_id, 'providerId': provider_id},
  {'id': content_id, 'playId': play_id, 'providerId': provider_id, 'mediaFormat': 'hls'},
]

rida = init_data.get('rida', '')
lat = '1' if init_data.get('lat') else '0'

for payload in payload_candidates:
  clean_payload = {k: v for k, v in payload.items() if v}
  body = json.dumps(clean_payload).encode('utf-8')
  headers = {
    'Content-Type': 'application/json',
    'Origin': 'https://therokuchannel.roku.com',
    'Referer': f'https://therokuchannel.roku.com/watch/{content_id}',
    'x-roku-reserved-time-zone-offset': '360',
    'x-roku-reserved-rida': rida,
    'x-roku-reserved-lat': lat,
  }
  try:
    response_body = request('https://therokuchannel.roku.com/api/v3/playback', data=body, extra_headers=headers)
  except urllib.error.HTTPError:
    continue
  except Exception:
    continue

  try:
    response_json = json.loads(response_body)
  except Exception:
    continue

  url = response_json.get('url', '')
  if url and 'osm.sr.roku.com/osm/v1/hls/master/' in url:
    print(url)
    raise SystemExit(0)

print(source_url)
PY
}

resolve_source_url() {
  local source_url="$1"
  local resolved_url
  local original_resolved_url
  local best_variant_url

  case "$source_url" in
    https://pluto.tv/*/live-tv/*)
      resolve_pluto_source_url "$source_url"
      return $?
      ;;
    *jmp2.uk/plu-*.m3u8*)
      if best_variant_url="$(select_best_hls_variant "$source_url" 2>/dev/null)"; then
        echo "[ffmpeg_web10_proxy] Variante HLS seleccionada desde jmp2: $best_variant_url" >&2
        printf '%s\n' "$best_variant_url"
      else
        echo "[ffmpeg_web10_proxy] No se pudo seleccionar variante jmp2; usando master original." >&2
        printf '%s\n' "$source_url"
      fi
      return 0
      ;;
  esac

  if ! resolved_url="$(resolve_plex_watch_url "$source_url")"; then
    return 1
  fi

  if ! resolved_url="$(resolve_roku_watch_url "$resolved_url")"; then
    return 1
  fi

  if ! resolved_url="$(ensure_fresh_roku_master_url "$resolved_url")"; then
    return 1
  fi

  update_resolved_url_in_config "$resolved_url"

  if ! resolved_url="$(resolve_roku_variant_url "$resolved_url")"; then
    return 1
  fi

  original_resolved_url="$resolved_url"
  if best_variant_url="$(select_best_hls_variant "$resolved_url" 2>/dev/null)"; then
    resolved_url="$best_variant_url"
    echo "[ffmpeg_web10_proxy] Variante HLS seleccionada desde URL fuente: $resolved_url" >&2

    if ! url_has_video_stream "$resolved_url"; then
      echo "[ffmpeg_web10_proxy] Variante seleccionada no tiene video; usando manifest original." >&2
      resolved_url="$original_resolved_url"
    fi
  fi

  update_variant_url_in_config "$resolved_url"
  CONFIG_VARIANT_URL="$resolved_url"

  printf '%s\n' "$resolved_url"
}

auto_repair_send_alarm() {
  local level="$1"
  local message="$2"

  if [ -x "$AUTO_REPAIR_ALARM_SCRIPT" ]; then
    bash "$AUTO_REPAIR_ALARM_SCRIPT" web10 "$level" "$message" >/dev/null 2>&1 || true
  fi
}

auto_repair_cleanup_artifacts() {
  find "$OUT" -maxdepth 2 -type f -name "*.tmp" -delete 2>/dev/null || true
  find "$OUT" -maxdepth 2 -type f -name "seg_*.ts" -size 0 -delete 2>/dev/null || true
}

auto_repair_after_ffmpeg_exit() {
  local reason="$1"
  local rc="$2"
  local run_seconds="$3"
  local now_ts

  if [ "$AUTO_REPAIR_ENABLED" != "1" ]; then
    sleep 5
    return 0
  fi

  now_ts="$(date +%s)"

  if [ "$reason" = "ffmpeg salio" ] && [ "$run_seconds" -ge "$AUTO_REPAIR_HEALTHY_RESET_SECONDS" ]; then
    repair_failure_count=0
    repair_window_start_ts=0
    auto_repair_send_alarm "OK" "web10 estable tras ${run_seconds}s; autoreparacion rearmada"
    sleep 5
    return 0
  fi

  if [ "$repair_window_start_ts" -eq 0 ] || [ $(( now_ts - repair_window_start_ts )) -gt "$AUTO_REPAIR_WINDOW_SECONDS" ]; then
    repair_window_start_ts="$now_ts"
    repair_failure_count=0
  fi

  repair_failure_count=$(( repair_failure_count + 1 ))
  echo "[ffmpeg_web10_proxy] Autoreparacion web10: reason=$reason rc=$rc run=${run_seconds}s intento=$repair_failure_count/${AUTO_REPAIR_MAX_RESTARTS}" >&2
  auto_repair_send_alarm "ALARM" "web10 autoreparacion: $reason (intento=$repair_failure_count, rc=$rc, run=${run_seconds}s)"

  auto_repair_cleanup_artifacts

  if [ -n "$CONFIG_WATCH_URL" ]; then
    SRC_URL="$CONFIG_WATCH_URL"
  fi

  if [ "$repair_failure_count" -ge "$AUTO_REPAIR_MAX_RESTARTS" ]; then
    repair_failure_count=0
    repair_window_start_ts="$now_ts"
    echo "[ffmpeg_web10_proxy] Autoreparacion escalada: refrescando fuente y continuando dentro del servicio" >&2
    auto_repair_send_alarm "ALARM" "web10 autoreparacion escalada: refrescando fuente dentro del servicio"
    sleep "$AUTO_REPAIR_BACKOFF_SECONDS"
    return 0
  fi

  sleep "$AUTO_REPAIR_BACKOFF_SECONDS"
}


should_use_browser_restream() {
  local source_url="$1"

  if [ "$WEB10_BROWSER_RESTREAM" != "1" ]; then
    return 1
  fi

  if [ "$WEB10_PLUTO_DIRECT_HLS" = "1" ]; then
    case "$source_url" in
      https://pluto.tv/*/live-tv/*|https://*.pluto.tv/*/live-tv/*)
        echo "[ffmpeg_web10_proxy] Pluto directo tipo web7 activo; no se usa browser-restream." >&2
        return 1
        ;;
    esac
  fi

  case "$source_url" in
    https://pluto.tv/*/live-tv/*|https://*.pluto.tv/*/live-tv/*)
      ;;
    *)
      return 1
      ;;
  esac

  if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "[ffmpeg_web10_proxy] browser-restream no disponible: falta xvfb-run" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[ffmpeg_web10_proxy] browser-restream no disponible: falta python3" >&2
    return 1
  fi

  if [ ! -x "$SCRIPT_DIR/bin/web4_browser_restream_runner.sh" ]; then
    echo "[ffmpeg_web10_proxy] browser-restream no disponible: falta runner" >&2
    return 1
  fi

  return 0
}

run_browser_restream_session() {
  local start_number="$1"
  local browser_runner="$SCRIPT_DIR/bin/web4_browser_restream_runner.sh"
  local browser_screen_height=$((WEB10_BROWSER_HEIGHT + WEB10_BROWSER_TRIM_TOP))
  local use_direct_audio=0
  local direct_audio_url=""

  case "$WEB10_BROWSER_AUDIO_MODE" in
    direct|hls)
      use_direct_audio=1
      ;;
    *)
      use_direct_audio=0
      ;;
  esac

  if [ "$use_direct_audio" = "1" ]; then
    if [ -s /tmp/web10_pluto_audio_url.txt ]; then
      direct_audio_url="$(tail -n1 /tmp/web10_pluto_audio_url.txt 2>/dev/null || true)"
    fi

    if [ -z "$direct_audio_url" ]; then
      direct_audio_url="$(resolve_source_url "$SRC_URL" 2>/dev/null || true)"
      if [ -n "$direct_audio_url" ]; then
        printf '%s\n' "$direct_audio_url" > /tmp/web10_pluto_audio_url.txt 2>/dev/null || true
      fi
    fi
  fi

  xvfb-run -a \
    --server-args="-screen 0 ${WEB10_BROWSER_WIDTH}x${browser_screen_height}x24 -ac +extension RANDR" \
    env \
      WEB4_MULTI_VARIANT=1 \
      WEB4_MULTI_360_FPS="$WEB10_BROWSER_360_FPS" \
      WEB4_MULTI_180_FPS="$WEB10_BROWSER_180_FPS" \
      WEB4_USE_DIRECT_AUDIO="$use_direct_audio" \
      WEB4_AUDIO_MODE="$WEB10_BROWSER_AUDIO_MODE" \
      WEB4_BROWSER_ALSA_OUTPUT_DEVICE="$WEB10_BROWSER_ALSA_OUTPUT_DEVICE" \
      WEB4_BROWSER_FIFO_ID="$WEB10_BROWSER_FIFO_ID" \
      WEB4_BROWSER_BOOT_SECONDS="$WEB10_BROWSER_BOOT_SECONDS" \
      WEB4_AUDIO_GUARD=1 \
      WEB4_AUDIO_GUARD_STALE_SECONDS=25 \
      WEB4_VISUAL_GUARD=1 \
      WEB4_VISUAL_GUARD_INTERVAL=20 \
      WEB4_VISUAL_GUARD_MAX_SECONDS=90 \
      WEB4_VISUAL_GUARD_MIN_SAMPLES=3 \
      WEB4_DIRECT_AUDIO_URL="$direct_audio_url" \
      PLUTO_CACHED_AUDIO_URL_FILE=/tmp/web10_pluto_audio_url.txt \
      WEB4_AUDIO_DELAY_MS="$WEB10_BROWSER_AUDIO_DELAY_MS" \
      WEB4_VIDEO_DELAY_MS="$WEB10_BROWSER_VIDEO_DELAY_MS" \
      WEB4_OUTPUT_SCALE_HEIGHT=480 \
      WEB4_OUTPUT_SCALE_FLAGS=fast_bilinear \
      WEB4_OUTPUT_PRESET=ultrafast \
      WEB4_OUTPUT_PROFILE=baseline \
      WEB4_OUTPUT_LEVEL=3.1 \
      WEB4_MULTI_480_BITRATE=800k \
      WEB4_MULTI_480_MAXRATE=950k \
      WEB4_MULTI_480_BUFSIZE=1900k \
      WEB4_MULTI_360_BITRATE=500k \
      WEB4_MULTI_360_MAXRATE=650k \
      WEB4_MULTI_360_BUFSIZE=1300k \
      WEB4_MULTI_180_BITRATE=250k \
      WEB4_MULTI_180_MAXRATE=350k \
      WEB4_MULTI_180_BUFSIZE=700k \
      WEB4_OUTPUT_GOP=100 \
      bash "$browser_runner" \
        "$SRC_URL" \
        "$OUT" \
        "$HLS_TIME" \
        "$HLS_LIST_SIZE" \
        "$start_number" \
        "$WEB10_BROWSER_WIDTH" \
        "$WEB10_BROWSER_HEIGHT" \
        "$WEB10_BROWSER_FPS" \
        "$WEB10_BROWSER_SESSION_SECONDS" \
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
        "$WEB10_BROWSER_CAPTURE_TOP" \
        "$WEB10_BROWSER_CAPTURE_LEFT" \
        "$browser_screen_height" \
        "$WEB10_BROWSER_TRIM_TOP" \
        9>&-
}
repair_failure_count=0
repair_window_start_ts=0

while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  RUN_ID="$(date +%s)"
  START_NUMBER="$RUN_ID"

  if should_use_browser_restream "$SRC_URL"; then
    echo "[ffmpeg_web10_proxy] Usando browser-restream Chromium para Pluto: variantes=480p/360p/180p audio=$WEB10_BROWSER_AUDIO_MODE" >&2
    ffmpeg_started_ts="$(date +%s)"
    run_browser_restream_session "$START_NUMBER"
    rc=$?
    run_seconds=$(( $(date +%s) - ffmpeg_started_ts ))
    set -e
    echo "[ffmpeg_web10_proxy] browser-restream salio con codigo $rc. Reintentando con autoreparacion..." >&2
    auto_repair_after_ffmpeg_exit "browser-restream salio" "$rc" "$run_seconds"
    continue
  fi

  case "$SRC_URL" in
    *jmp2.uk/plu-61b793ccf571b80007b7a610.m3u8*)
      if [ "$WEB10_JMP2_PASSTHROUGH" = "1" ]; then
        ffmpeg_started_ts="$(date +%s)"
        run_jmp2_master_passthrough_loop "$SRC_URL"
        rc=$?
        run_seconds=$(( $(date +%s) - ffmpeg_started_ts ))
        set -e
        echo "[ffmpeg_web10_proxy] passthrough master jmp2 salio con codigo $rc. Reintentando con autoreparacion..." >&2
        auto_repair_after_ffmpeg_exit "passthrough master jmp2 salio" "$rc" "$run_seconds"
        continue
      fi
      ;;
  esac

  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    if [ -n "$CONFIG_WATCH_URL" ] && [ "$SRC_URL" != "$CONFIG_WATCH_URL" ]; then
      echo "[ffmpeg_web10_proxy] Resolucion con URL guardada fallo; intentando refrescar desde WEB10_URL..." >&2
      if INPUT_URL="$(resolve_source_url "$CONFIG_WATCH_URL")"; then
        SRC_URL="$CONFIG_WATCH_URL"
      elif [ -n "$CONFIG_VARIANT_URL" ]; then
        echo "[ffmpeg_web10_proxy] Roku API no respondio; usando fallback WEB10_VARIANT_URL guardada..." >&2
        INPUT_URL="$CONFIG_VARIANT_URL"
      else
        repair_reason="fallo resolucion origen"
        auto_repair_after_ffmpeg_exit "$repair_reason" "resolve" "0"
        set -e
        continue
      fi
    elif [ -n "$CONFIG_VARIANT_URL" ]; then
      echo "[ffmpeg_web10_proxy] Resolucion fallo; usando fallback WEB10_VARIANT_URL guardada..." >&2
      INPUT_URL="$CONFIG_VARIANT_URL"
    else
      repair_reason="fallo resolucion origen"
      auto_repair_after_ffmpeg_exit "$repair_reason" "resolve" "0"
      set -e
      continue
    fi
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web10_proxy] Origen intermedio resuelto a stream HLS directo." >&2
  fi

  resolved_audio_url=""
  case "$INPUT_URL" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv*/playlist.m3u8*|*stitcher-ipv4.pluto.tv/v2/stitch/embed/hls/channel/*/playlist.m3u8*)
      if ! url_has_audio_stream "$INPUT_URL"; then
        resolved_audio_url="$(derive_pluto_audio_url "$INPUT_URL" || true)"
      fi
      ;;
  esac

  segment_repeat_limit="$MAX_SEGMENT_REPEAT_SECONDS"
  stale_limit="$MAX_STALE_SECONDS"
  case "$INPUT_URL" in
    *pluto.tv*|*plutotv.net*|*jmp2.uk/plu-*)
      segment_repeat_limit="$PLUTO_SOURCE_SWITCH_GRACE_SECONDS"
      stale_limit="$PLUTO_STALE_GRACE_SECONDS"
      echo "[ffmpeg_web10_proxy] Gracia Pluto activa: cambio_fuente=${segment_repeat_limit}s stale=${stale_limit}s" >&2
      ;;
  esac

  if [ -n "$resolved_audio_url" ]; then
    case "$INPUT_URL" in
      *stitcher-ipv4.pluto.tv/v2/stitch/embed/hls/channel/*/[0-9]*/playlist.m3u8*)
        if [ "$WEB10_SYNTH_AUDIO_ON_STITCHER" = "1" ]; then
          run_ffmpeg_from_video_with_synthetic_audio "$INPUT_URL"
        else
          run_ffmpeg_from_dual_url "$INPUT_URL" "$resolved_audio_url"
        fi
        ;;
      *)
        run_ffmpeg_from_dual_url "$INPUT_URL" "$resolved_audio_url"
        ;;
    esac
  else
    run_ffmpeg_from_direct_url "$INPUT_URL"
  fi

  ffmpeg_pid=$!
  ffmpeg_started_ts="$(date +%s)"
  repair_reason="ffmpeg salio"

  last_ok_ts="$(date +%s)"
  last_segment_change_ts="$last_ok_ts"
  last_segment_line=""
  last_visual_hash=""
  last_visual_probe_ts=0
  visual_same_since_ts=0
  visual_same_samples=0
  saw_endlist=0
  if [ -f "$OUT/480p/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/480p/index.m3u8")"
    last_segment_line="$(grep -E '^seg_.*\.ts$' "$OUT/480p/index.m3u8" | tail -n1 || true)"
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL_SECONDS"

    if [ -f "$OUT/480p/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT/480p/index.m3u8")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi

      if grep -q '^#EXT-X-ENDLIST' "$OUT/480p/index.m3u8"; then
        saw_endlist=1
      fi

      current_segment_line="$(grep -E '^seg_.*\.ts$' "$OUT/480p/index.m3u8" | tail -n1 || true)"
      if [ -n "$current_segment_line" ] && [ "$current_segment_line" != "$last_segment_line" ]; then
        last_segment_line="$current_segment_line"
        last_segment_change_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))
    segment_repeat_seconds=$(( now_ts - last_segment_change_ts ))

    if [ "$VISUAL_FREEZE_ENABLED" = "1" ] && \
      [ -n "$last_segment_line" ] && \
      [ $(( now_ts - last_visual_probe_ts )) -ge "$VISUAL_FREEZE_SAMPLE_INTERVAL_SECONDS" ]; then
      current_visual_hash="$(compute_visual_hash || true)"
      last_visual_probe_ts="$now_ts"

      if [ -n "$current_visual_hash" ]; then
        if [ -n "$last_visual_hash" ] && [ "$current_visual_hash" = "$last_visual_hash" ]; then
          visual_same_samples=$(( visual_same_samples + 1 ))
          if [ "$visual_same_since_ts" -eq 0 ]; then
            visual_same_since_ts="$now_ts"
          fi
        else
          last_visual_hash="$current_visual_hash"
          visual_same_since_ts=0
          visual_same_samples=1
        fi

        if [ "$visual_same_since_ts" -gt 0 ] && \
          [ "$visual_same_samples" -ge "$VISUAL_FREEZE_MIN_SAMPLES" ] && \
          [ $(( now_ts - visual_same_since_ts )) -ge "$VISUAL_FREEZE_MAX_SECONDS" ]; then
          repair_reason="huella visual congelada por $(( now_ts - visual_same_since_ts ))s"
          echo "[ffmpeg_web10_proxy] Huella visual congelada por $(( now_ts - visual_same_since_ts )) s (muestras=$visual_same_samples, segmento=$last_segment_line), reiniciando ffmpeg ($ffmpeg_pid)" >&2
          stop_ffmpeg "$ffmpeg_pid"
          sleep 2
          break
        fi
      fi
    fi

    if [ "$saw_endlist" -eq 1 ]; then
      repair_reason="ENDLIST en salida local"
      echo "[ffmpeg_web10_proxy] Detectado ENDLIST en salida local, reiniciando ffmpeg ($ffmpeg_pid)" >&2
      stop_ffmpeg "$ffmpeg_pid"
      sleep 2
      break
    fi

    if [ -n "$last_segment_line" ] && [ "$segment_repeat_seconds" -ge "$segment_repeat_limit" ]; then
      repair_reason="segmento sin cambio por ${segment_repeat_seconds}s"
      echo "[ffmpeg_web10_proxy] Ultimo segmento sin cambio por $segment_repeat_seconds s ($last_segment_line), reiniciando ffmpeg ($ffmpeg_pid)" >&2
      stop_ffmpeg "$ffmpeg_pid"
      sleep 2
      break
    fi

    if [ "$stale_seconds" -ge "$stale_limit" ]; then
      repair_reason="480p/index.m3u8 stale por ${stale_seconds}s"
      echo "[ffmpeg_web10_proxy] 480p/index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      stop_ffmpeg "$ffmpeg_pid"
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  run_seconds=$(( $(date +%s) - ffmpeg_started_ts ))
  set -e

  echo "[ffmpeg_web10_proxy] ffmpeg salio con codigo $rc. Reintentando con autoreparacion..." >&2
  auto_repair_after_ffmpeg_exit "$repair_reason" "$rc" "$run_seconds"
done
