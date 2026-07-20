#!/usr/bin/env bash

# Proxy HLS para paginas o streams remotos que requieren extraccion previa.
# Entrada:  https://pluto.tv/latam/live-tv/609059dc63be6e0007b4eca6
# Salida:   /var/www/html/hls/web6/index.m3u8 (accesible como /hls/web6/index.m3u8)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
CONFIG_SRC_URL=""

if [ -f "$PRIMARY_CONFIG" ]; then
  # shellcheck source=/var/www/html/logs/web_sources.env
  . "$PRIMARY_CONFIG"
  CONFIG_SRC_URL="${WEB6_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB6_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web6}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-https://pluto.tv/latam/live-tv/609059dc63be6e0007b4eca6}}"
YT_FORMAT_SELECTOR="${YT_FORMAT_SELECTOR:-bv*[vcodec^=avc1][height<=720][ext=mp4]+ba[ext=mp4]/bv*[vcodec^=avc1][ext=mp4]+ba[ext=mp4]/b}"
PLUTO_TARGET_BANDWIDTH="${PLUTO_TARGET_BANDWIDTH:-850000}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-60}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"
FFMPEG_USER_AGENT="${FFMPEG_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLUTO_CHROMIUM_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_TIMEOUT_SECONDS:-15}"
PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS:-210}"
PLUTO_REQUIRE_CHROMIUM="${PLUTO_REQUIRE_CHROMIUM:-0}"
PLUTO_SKIP_VERIFY="${PLUTO_SKIP_VERIFY:-1}"
PLUTO_AUDIO_OFFSET_SECONDS="${PLUTO_AUDIO_OFFSET_SECONDS:-0}"
RESOLVE_TIMEOUT_SECONDS="${RESOLVE_TIMEOUT_SECONDS:-45}"
LAST_RESOLVED_FILE="${LAST_RESOLVED_FILE:-/var/www/html/logs/web6_last_resolved.url}"
USE_LAST_RESOLVED_ON_START="${USE_LAST_RESOLVED_ON_START:-0}"
FORCE_RESTART_SECONDS="${FORCE_RESTART_SECONDS:-0}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
HLS_DELETE_THRESHOLD="${HLS_DELETE_THRESHOLD:-2}"
FFMPEG_REFERER="${FFMPEG_REFERER:-https://pluto.tv/}"
OUTPUT_FPS="${OUTPUT_FPS:-20}"
OUTPUT_SCALE_HEIGHT="${OUTPUT_SCALE_HEIGHT:-480}"
VIDEO_BITRATE="${VIDEO_BITRATE:-850k}"
VIDEO_MAXRATE="${VIDEO_MAXRATE:-1100k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-2400k}"
VIDEO_GOP="${VIDEO_GOP:-100}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"
MAX_SEGMENT_REPEAT_SECONDS="${MAX_SEGMENT_REPEAT_SECONDS:-45}"
MIN_GOOD_RUN_SECONDS="${MIN_GOOD_RUN_SECONDS:-8}"
REFRESH_SHORT_FAIL_STREAK="${REFRESH_SHORT_FAIL_STREAK:-2}"
WEB6_BROWSER_RESTREAM="${WEB6_BROWSER_RESTREAM:-0}"
WEB6_BROWSER_WIDTH="${WEB6_BROWSER_WIDTH:-960}"
WEB6_BROWSER_HEIGHT="${WEB6_BROWSER_HEIGHT:-540}"
WEB6_BROWSER_FPS="${WEB6_BROWSER_FPS:-20}"
WEB6_BROWSER_SESSION_SECONDS="${WEB6_BROWSER_SESSION_SECONDS:-0}"
WEB6_BROWSER_CAPTURE_TOP="${WEB6_BROWSER_CAPTURE_TOP:-0}"
WEB6_BROWSER_CAPTURE_LEFT="${WEB6_BROWSER_CAPTURE_LEFT:-0}"
WEB6_BROWSER_TRIM_TOP="${WEB6_BROWSER_TRIM_TOP:-66}"
WEB6_BROWSER_AUDIO_DELAY_MS="${WEB6_BROWSER_AUDIO_DELAY_MS:-120}"

mkdir -p "$OUT"

clear_published_output() {
  find "$OUT" -maxdepth 1 -type f \( -name 'index.m3u8' -o -name 'seg_*.ts' \) -delete 2>/dev/null || true
}

is_direct_stream_url() {
  case "$1" in
    *.m3u8*|*.mpd*) return 0 ;;
    *) return 1 ;;
  esac
}

is_ephemeral_pluto_variant_url() {
  case "$1" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*) return 0 ;;
    *) return 1 ;;
  esac
}

cached_resolved_url_allowed() {
  local cached_url="$1"

  case "$SRC_URL" in
    https://pluto.tv/*/live-tv/*)
      if is_ephemeral_pluto_variant_url "$cached_url"; then
        return 1
      fi
      ;;
  esac

  return 0
}

derive_pluto_audio_url() {
  local video_url="$1"

  case "$video_url" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*)
      printf '%s\n' "$(printf '%s' "$video_url" | sed -E 's#/([0-9]+)/playlist\.m3u8#/audio/audio/English/audio.m3u8#')"
      ;;
    *)
      return 1
      ;;
  esac
}

url_has_audio_stream() {
  local test_url="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    return 0
  fi

  timeout 8 ffprobe -v error \
    -allowed_extensions ALL \
    -allowed_segment_extensions ALL \
    -extension_picky 0 \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

resolve_pluto_source_url() {
  local page_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local chromium_url=""
  local chromium_timeout_cmd=( )

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    chromium_url="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 PLUTO_SKIP_VERIFY="$PLUTO_SKIP_VERIFY" python3 "$chromium_resolver" "$page_url" "$PLUTO_CHROMIUM_TIMEOUT_SECONDS" 2>/dev/null | tail -n1; } 9>&-)"

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  if [ "$PLUTO_REQUIRE_CHROMIUM" = "1" ]; then
    echo "[ffmpeg_web6_proxy] Chromium no resolvio URL valida para Pluto; reintentando sin fallback directo." >&2
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
    raise SystemExit(f"URL de Pluto no valida: {page_url}")

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
        band_match = re.search(r'BANDWIDTH=(\d+)', line)
        pending_bandwidth = int(band_match.group(1)) if band_match else None
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
    raise SystemExit(
        'Pluto devolvio takedown slate para este canal; no hay stream reproducible desde este servidor'
    )

print(best_url)
PY
}

resolve_source_url() {
  local src_url="$1"

  case "$src_url" in
    https://pluto.tv/*/live-tv/*)
      resolve_pluto_source_url "$src_url"
      ;;
    *)
      printf '%s\n' "$src_url"
      ;;
  esac
}

resolve_source_url_with_timeout() {
  local src_url="$1"
  local tmp_file
  local resolve_pid
  local waited=0
  local rc=1

  tmp_file="$(mktemp /tmp/web6_resolve.XXXXXX)" || return 1

  ( resolve_source_url "$src_url" ) >"$tmp_file" &
  resolve_pid=$!

  while kill -0 "$resolve_pid" 2>/dev/null; do
    if [ "$waited" -ge "$RESOLVE_TIMEOUT_SECONDS" ]; then
      echo "[ffmpeg_web6_proxy] Resolucion de origen tardo mas de ${RESOLVE_TIMEOUT_SECONDS}s; cancelando intento." >&2
      pkill -TERM -P "$resolve_pid" 2>/dev/null || true
      kill -TERM "$resolve_pid" 2>/dev/null || true
      sleep 2
      pkill -KILL -P "$resolve_pid" 2>/dev/null || true
      kill -KILL "$resolve_pid" 2>/dev/null || true
      wait "$resolve_pid" 2>/dev/null || true
      rm -f "$tmp_file"
      return 124
    fi

    sleep 1
    waited=$(( waited + 1 ))
  done

  wait "$resolve_pid"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    cat "$tmp_file"
  fi
  rm -f "$tmp_file"
  return "$rc"
}

run_ffmpeg_from_direct_url() {
  local input_url="$1"

  echo "[ffmpeg_web6_proxy] Usando origen directo: $input_url" >&2

  ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -allowed_extensions ALL \
    -allowed_segment_extensions ALL \
    -rw_timeout 15000000 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -http_persistent 0 \
    -referer "$FFMPEG_REFERER" \
    -user_agent "$FFMPEG_USER_AGENT" \
    -i "$input_url" \
    -map 0:v:0? \
    -map 0:a:0? \
    -c:v libx264 \
    -vf "scale=-2:${OUTPUT_SCALE_HEIGHT}:flags=fast_bilinear,fps=${OUTPUT_FPS}" \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r "$OUTPUT_FPS" \
    -fps_mode cfr \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_MAXRATE" \
    -bufsize "$VIDEO_BUFSIZE" \
    -max_muxing_queue_size 2048 \
    -g "$VIDEO_GOP" \
    -keyint_min "$VIDEO_GOP" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
    -c:a aac \
    -ac 2 \
    -b:a 96k \
    -af "aresample=async=1:first_pts=0" \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" 9>&- &
}

  run_ffmpeg_from_dual_url() {
    local video_url="$1"
    local audio_url="$2"

    echo "[ffmpeg_web6_proxy] Usando video + audio Pluto: $video_url | $audio_url" >&2

    ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -allowed_extensions ALL \
    -allowed_segment_extensions ALL \
    -rw_timeout 15000000 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -http_persistent 0 \
    -referer "$FFMPEG_REFERER" \
    -user_agent "$FFMPEG_USER_AGENT" \
    -i "$video_url" \
    -thread_queue_size 1024 \
    -itsoffset "$PLUTO_AUDIO_OFFSET_SECONDS" \
    -i "$audio_url" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v libx264 \
    -vf "scale=-2:${OUTPUT_SCALE_HEIGHT}:flags=fast_bilinear,fps=${OUTPUT_FPS}" \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r "$OUTPUT_FPS" \
    -fps_mode cfr \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_MAXRATE" \
    -bufsize "$VIDEO_BUFSIZE" \
    -max_muxing_queue_size 2048 \
    -g "$VIDEO_GOP" \
    -keyint_min "$VIDEO_GOP" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
    -c:a aac \
    -af "aresample=async=1:first_pts=0" \
    -ac 2 \
    -b:a 96k \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" 9>&- &
  }

run_ffmpeg_from_ytdlp() {
  local source_url="$1"

  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "[ffmpeg_web6_proxy] yt-dlp no esta instalado; no se puede resolver $source_url" >&2
    return 1
  fi

  echo "[ffmpeg_web6_proxy] Resolviendo y enviando por tuberia: $source_url" >&2

  set -o pipefail
  yt-dlp --no-warnings --no-playlist -f "$YT_FORMAT_SELECTOR" -o - "$source_url" 9>&- | \
    ffmpeg \
      -loglevel info \
      -fflags +discardcorrupt+genpts \
      -err_detect ignore_err \
      -i pipe:0 \
      -c:v libx264 \
      -preset veryfast \
      -tune zerolatency \
      -profile:v baseline \
      -level 3.1 \
      -r 20 \
      -b:v 800k \
      -maxrate 900k \
      -bufsize 2400k \
      -max_muxing_queue_size 2048 \
      -g 40 \
      -keyint_min 40 \
      -c:a aac \
      -ac 2 \
      -b:a 96k \
      -f hls \
      -hls_time 4 \
      -hls_list_size "$HLS_LIST_SIZE" \
      -start_number "$START_NUMBER" \
      -hls_flags append_list+program_date_time+independent_segments+omit_endlist \
      -hls_segment_filename "$OUT/seg_%06d.ts" \
      "$OUT/index.m3u8" 9>&-
}

should_use_browser_restream() {
  local source_url="$1"

  if [ "$WEB6_BROWSER_RESTREAM" != "1" ]; then
    return 1
  fi

  case "$source_url" in
    https://pluto.tv/*/live-tv/*|https://*.pluto.tv/*/live-tv/*)
      ;;
    *)
      return 1
      ;;
  esac

  if ! command -v xvfb-run >/dev/null 2>&1; then
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  if [ ! -x "$SCRIPT_DIR/bin/web4_browser_restream_runner.sh" ]; then
    return 1
  fi

  return 0
}

run_browser_restream_session() {
  local start_number="$1"
  local browser_runner="$SCRIPT_DIR/bin/web4_browser_restream_runner.sh"
  local browser_screen_height=$((WEB6_BROWSER_HEIGHT + WEB6_BROWSER_TRIM_TOP))
  local direct_audio_url=""

  if [ -n "$CACHED_INPUT_URL" ]; then
    direct_audio_url="$CACHED_INPUT_URL"
  elif [ -s "$LAST_RESOLVED_FILE" ]; then
    direct_audio_url="$(cat "$LAST_RESOLVED_FILE")"
  else
    direct_audio_url="$(resolve_source_url_with_timeout "$SRC_URL" 2>/dev/null || true)"
  fi

  xvfb-run -a \
    --server-args="-screen 0 ${WEB6_BROWSER_WIDTH}x${browser_screen_height}x24 -ac +extension RANDR" \
    env \
      WEB4_USE_DIRECT_AUDIO=1 \
      WEB4_AUDIO_DELAY_MS="$WEB6_BROWSER_AUDIO_DELAY_MS" \
      WEB4_DIRECT_AUDIO_URL="$direct_audio_url" \
      WEB4_OUTPUT_SCALE_HEIGHT=480 \
      WEB4_OUTPUT_SCALE_FLAGS=fast_bilinear \
      WEB4_OUTPUT_PRESET=ultrafast \
      WEB4_OUTPUT_PROFILE=baseline \
      WEB4_OUTPUT_LEVEL=3.1 \
      WEB4_OUTPUT_BITRATE=950k \
      WEB4_OUTPUT_MAXRATE=1200k \
      WEB4_OUTPUT_BUFSIZE=2400k \
      WEB4_OUTPUT_GOP=40 \
      bash "$browser_runner" \
        "$SRC_URL" \
        "$OUT" \
        "$HLS_TIME" \
        "$HLS_LIST_SIZE" \
        "$start_number" \
        "$WEB6_BROWSER_WIDTH" \
        "$WEB6_BROWSER_HEIGHT" \
        "$WEB6_BROWSER_FPS" \
        "$WEB6_BROWSER_SESSION_SECONDS" \
        "$FFMPEG_USER_AGENT" \
        "$WEB6_BROWSER_CAPTURE_TOP" \
        "$WEB6_BROWSER_CAPTURE_LEFT" \
        "$browser_screen_height" \
        "$WEB6_BROWSER_TRIM_TOP"
}

LAST_RESOLVED_BOOT_USED=0
CACHED_INPUT_URL=""
SHORT_FAIL_STREAK=0
FORCE_FRESH_RESOLVE=0

while true; do
  set +e

  # Mantener una ventana previa evita dejar el canal sin playlist durante
  # resoluciones/reintentos de Pluto y le da mas margen al reproductor.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"

  if should_use_browser_restream "$SRC_URL"; then
    echo "[ffmpeg_web6_proxy] Usando browser-restream para Pluto." >&2
    ffmpeg_started_ts="$(date +%s)"
    run_browser_restream_session "$START_NUMBER"
    rc=$?
    run_elapsed=$(( $(date +%s) - ffmpeg_started_ts ))

    if [ "$run_elapsed" -lt "$MIN_GOOD_RUN_SECONDS" ]; then
      SHORT_FAIL_STREAK=$((SHORT_FAIL_STREAK + 1))
    else
      SHORT_FAIL_STREAK=0
    fi

    set -e
    echo "[ffmpeg_web6_proxy] browser-restream salio con codigo $rc. Reintentando en 5 segundos..." >&2
    sleep 5
    continue
  fi

  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]] && [ "$FORCE_FRESH_RESOLVE" -eq 0 ] && [ -n "$CACHED_INPUT_URL" ]; then
    RESOLVED_SRC_URL="$CACHED_INPUT_URL"
    echo "[ffmpeg_web6_proxy] Reutilizando URL HLS cacheada para reinicio rapido." >&2
    resolve_rc=0
  elif [ "$FORCE_FRESH_RESOLVE" -eq 0 ] && [ "$USE_LAST_RESOLVED_ON_START" = "1" ] && [ "$LAST_RESOLVED_BOOT_USED" -eq 0 ] && [ -s "$LAST_RESOLVED_FILE" ]; then
    RESOLVED_SRC_URL="$(cat "$LAST_RESOLVED_FILE")"
    if cached_resolved_url_allowed "$RESOLVED_SRC_URL"; then
      echo "[ffmpeg_web6_proxy] Usando ultima URL HLS buena para arrancar rapido." >&2
      LAST_RESOLVED_BOOT_USED=1
      resolve_rc=0
    else
      echo "[ffmpeg_web6_proxy] Ignorando URL HLS cacheada temporal de Pluto; resolviendo fresco." >&2
      rm -f "$LAST_RESOLVED_FILE" 2>/dev/null || true
      RESOLVED_SRC_URL="$(resolve_source_url_with_timeout "$SRC_URL")"
      resolve_rc=$?
      FORCE_FRESH_RESOLVE=0
      LAST_RESOLVED_BOOT_USED=1
    fi
  else
    if [ "$FORCE_FRESH_RESOLVE" -eq 1 ]; then
      echo "[ffmpeg_web6_proxy] Forzando resolucion fresca de Pluto tras detectar stream atascado." >&2
    fi
    RESOLVED_SRC_URL="$(resolve_source_url_with_timeout "$SRC_URL")"
    resolve_rc=$?
    FORCE_FRESH_RESOLVE=0
  fi

  allow_cached_fallback=1
  case "$SRC_URL" in
    https://pluto.tv/*/live-tv/*)
      if [ "$PLUTO_REQUIRE_CHROMIUM" = "1" ]; then
        allow_cached_fallback=0
      fi
      ;;
  esac

  if { [ "$resolve_rc" -ne 0 ] || [ -z "$RESOLVED_SRC_URL" ]; } && [ "$allow_cached_fallback" = "1" ] && [ -s "$LAST_RESOLVED_FILE" ]; then
    RESOLVED_SRC_URL="$(cat "$LAST_RESOLVED_FILE")"
    if cached_resolved_url_allowed "$RESOLVED_SRC_URL"; then
      echo "[ffmpeg_web6_proxy] Usando ultima URL HLS buena tras fallo de resolucion." >&2
      resolve_rc=0
    else
      echo "[ffmpeg_web6_proxy] No uso fallback cacheado temporal de Pluto tras fallo de resolucion." >&2
      rm -f "$LAST_RESOLVED_FILE" 2>/dev/null || true
    fi
  fi

  if [ "$resolve_rc" -eq 0 ] && [ -n "$RESOLVED_SRC_URL" ] && is_direct_stream_url "$RESOLVED_SRC_URL"; then
    printf '%s\n' "$RESOLVED_SRC_URL" >"$LAST_RESOLVED_FILE" 2>/dev/null || true
    if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]]; then
      CACHED_INPUT_URL="$RESOLVED_SRC_URL"
    fi

    if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]] && ! url_has_audio_stream "$RESOLVED_SRC_URL"; then
      if PLUTO_AUDIO_URL="$(derive_pluto_audio_url "$RESOLVED_SRC_URL" 2>/dev/null)" && [ -n "$PLUTO_AUDIO_URL" ]; then
        run_ffmpeg_from_dual_url "$RESOLVED_SRC_URL" "$PLUTO_AUDIO_URL"
      else
        run_ffmpeg_from_direct_url "$RESOLVED_SRC_URL"
      fi
    else
      run_ffmpeg_from_direct_url "$RESOLVED_SRC_URL"
    fi
    ffmpeg_pid=$!
    ffmpeg_started_ts="$(date +%s)"
  else
    echo "[ffmpeg_web6_proxy] No se pudo resolver una URL reproducible para $SRC_URL" >&2

    case "$SRC_URL" in
      https://pluto.tv/*/live-tv/*)
        set -e
        sleep 10
        continue
        ;;
    esac

    run_ffmpeg_from_ytdlp "$SRC_URL" &
    ffmpeg_pid=$!
    ffmpeg_started_ts="$(date +%s)"
  fi

  last_ok_ts="$(date +%s)"
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
    last_segment_line="$(grep -E 'seg_[0-9]+\.ts$' "$OUT/index.m3u8" | tail -n1 || true)"
  else
    last_mtime="$last_ok_ts"
    last_segment_line=""
  fi
  last_segment_change_ts="$last_ok_ts"

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL_SECONDS"

    if [ -f "$OUT/index.m3u8" ] && grep -q '^#EXT-X-ENDLIST' "$OUT/index.m3u8" 2>/dev/null; then
      echo "[ffmpeg_web6_proxy] index.m3u8 contiene #EXT-X-ENDLIST, reiniciando ffmpeg ($ffmpeg_pid)" >&2
      FORCE_FRESH_RESOLVE=1
      CACHED_INPUT_URL=""
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ -f "$OUT/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT/index.m3u8")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi

      current_segment_line="$(grep -E 'seg_[0-9]+\.ts$' "$OUT/index.m3u8" | tail -n1 || true)"
      if [ -n "$current_segment_line" ] && [ "$current_segment_line" != "$last_segment_line" ]; then
        last_segment_line="$current_segment_line"
        last_segment_change_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))
    segment_repeat_seconds=$(( now_ts - last_segment_change_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web6_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      FORCE_FRESH_RESOLVE=1
      CACHED_INPUT_URL=""
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ -n "$last_segment_line" ] && [ "$segment_repeat_seconds" -ge "$MAX_SEGMENT_REPEAT_SECONDS" ]; then
      echo "[ffmpeg_web6_proxy] Ultimo segmento sin cambio por $segment_repeat_seconds s ($last_segment_line), reiniciando ffmpeg ($ffmpeg_pid)" >&2
      FORCE_FRESH_RESOLVE=1
      CACHED_INPUT_URL=""
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ "$FORCE_RESTART_SECONDS" -gt 0 ]; then
      runtime_seconds=$(( now_ts - ffmpeg_started_ts ))
      if [ "$runtime_seconds" -ge "$FORCE_RESTART_SECONDS" ]; then
        echo "[ffmpeg_web6_proxy] Reinicio preventivo tras $runtime_seconds s para refrescar URL/tokens ($ffmpeg_pid)" >&2
        kill "$ffmpeg_pid" 2>/dev/null
        sleep 2
        break
      fi
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  run_elapsed=$(( $(date +%s) - ffmpeg_started_ts ))

  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]] && [ "$run_elapsed" -lt "$MIN_GOOD_RUN_SECONDS" ]; then
    SHORT_FAIL_STREAK=$((SHORT_FAIL_STREAK + 1))
    CACHED_INPUT_URL=""
    rm -f "$LAST_RESOLVED_FILE" 2>/dev/null || true
  else
    SHORT_FAIL_STREAK=0
  fi

  if [ "$SHORT_FAIL_STREAK" -ge "$REFRESH_SHORT_FAIL_STREAK" ]; then
    echo "[ffmpeg_web6_proxy] Detectados $SHORT_FAIL_STREAK cortes cortos consecutivos; forzando refresh completo de Pluto." >&2
    CACHED_INPUT_URL=""
    rm -f "$LAST_RESOLVED_FILE" 2>/dev/null || true
    SHORT_FAIL_STREAK=0
  fi

  set -e

  echo "[ffmpeg_web6_proxy] ffmpeg salio con codigo $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
