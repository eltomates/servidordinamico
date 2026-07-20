#!/usr/bin/env bash

# Proxy HLS para paginas o streams remotos que requieren extraccion previa.
# Entrada:  https://pluto.tv/latam/live-tv/645952687cb4b100084ed52e
# Salida:   /var/www/html/hls/web12/index.m3u8 (accesible como /hls/web12/index.m3u8)

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
  CONFIG_SRC_URL="${WEB12_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB12_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web12}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-https://pluto.tv/latam/live-tv/645952687cb4b100084ed52e}}"
YT_FORMAT_SELECTOR="${YT_FORMAT_SELECTOR:-bv*[vcodec^=avc1][height<=720][ext=mp4]+ba[ext=mp4]/bv*[vcodec^=avc1][ext=mp4]+ba[ext=mp4]/b}"
PLUTO_TARGET_BANDWIDTH="${PLUTO_TARGET_BANDWIDTH:-1200000}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-60}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-15}"
FFMPEG_USER_AGENT="${FFMPEG_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLUTO_CHROMIUM_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_TIMEOUT_SECONDS:-15}"
PLUTO_REQUIRE_CHROMIUM="${PLUTO_REQUIRE_CHROMIUM:-1}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
HLS_DELETE_THRESHOLD="${HLS_DELETE_THRESHOLD:-2}"
AUDIO_RESAMPLE_ASYNC="${AUDIO_RESAMPLE_ASYNC:-1}"
LAST_RESOLVED_FILE="${LAST_RESOLVED_FILE:-/var/www/html/logs/web12_last_resolved.url}"
USE_LAST_RESOLVED_ON_START="${USE_LAST_RESOLVED_ON_START:-0}"
FFMPEG_REFERER="${FFMPEG_REFERER:-https://pluto.tv/}"
MIN_GOOD_RUN_SECONDS="${MIN_GOOD_RUN_SECONDS:-8}"
REFRESH_SHORT_FAIL_STREAK="${REFRESH_SHORT_FAIL_STREAK:-2}"

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

derive_pluto_audio_url() {
  local video_url="$1"

  case "$video_url" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*)
      printf "%s\n" "$(printf "%s" "$video_url" | sed -E "s#/([0-9]+)/playlist\.m3u8#/audio/audio/English/audio.m3u8#")"
      ;;
    *)
      return 1
      ;;
  esac
}

cache_resolved_url() {
  local resolved_url="$1"

  case "$resolved_url" in
    https://cfd-v4-service-channel-stitcher-*/v2/stitch/hls/channel/*)
      printf '%s\n' "$resolved_url" > "$LAST_RESOLVED_FILE.tmp"
      command mv -f "$LAST_RESOLVED_FILE.tmp" "$LAST_RESOLVED_FILE"
      ;;
  esac
}

read_cached_resolved_url() {
  if [ "$USE_LAST_RESOLVED_ON_START" != "1" ] || [ ! -s "$LAST_RESOLVED_FILE" ]; then
    return 1
  fi

  head -n1 "$LAST_RESOLVED_FILE"
}

clear_cached_resolved_url() {
  rm -f "$LAST_RESOLVED_FILE" "$LAST_RESOLVED_FILE.tmp" 2>/dev/null || true
}

resolve_pluto_source_url() {
  local page_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local chromium_url=""
  local chromium_output=""
  local chromium_timeout_cmd=( )

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$((PLUTO_CHROMIUM_TIMEOUT_SECONDS + 60))")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    # En este host el modo headless directo es más estable que xvfb-run.
    chromium_output="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 PLUTO_TARGET_BANDWIDTH="$PLUTO_TARGET_BANDWIDTH" python3 "$chromium_resolver" "$page_url" "$PLUTO_CHROMIUM_TIMEOUT_SECONDS"; } 9>&-)"
    chromium_url="$(printf "%s\n" "$chromium_output" | tail -n1)"

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  if [ "$PLUTO_REQUIRE_CHROMIUM" = "1" ]; then
    echo "[ffmpeg_web12_proxy] Chromium no resolvio URL valida para Pluto; reintentando sin fallback directo." >&2
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

run_ffmpeg_from_direct_url() {
  local input_url="$1"

  echo "[ffmpeg_web12_proxy] Usando origen directo: $input_url" >&2

  ffmpeg \
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -referer "$FFMPEG_REFERER" \
    -user_agent "$FFMPEG_USER_AGENT" \
    -re \
    -i "$input_url" \
    -map 0:v:0 \
    -map 0:a:0? \
    -dn \
    -sn \
    -vf "scale=-2:360:flags=bicubic" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -fps_mode:v cfr \
    -r 20 \
    -b:v 800k \
    -maxrate 900k \
    -bufsize 2400k \
    -max_muxing_queue_size 2048 \
    -g 40 \
    -keyint_min 40 \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*4)" \
    -c:a aac \
    -ac 2 \
    -b:a 96k \
    -af "aresample=async=${AUDIO_RESAMPLE_ASYNC}:first_pts=0" \
    -f hls \
    -hls_time 4 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_delete_threshold "$HLS_DELETE_THRESHOLD" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" 9>&- &
}

run_ffmpeg_from_dual_url() {
  local video_url="$1"
  local audio_url="$2"

  echo "[ffmpeg_web12_proxy] Usando video + audio Pluto: $video_url | $audio_url" >&2

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
    -reconnect_delay_max 5 \
    -http_persistent 0 \
    -referer "$FFMPEG_REFERER" \
    -user_agent "$FFMPEG_USER_AGENT" \
    -re \
    -i "$video_url" \
    -thread_queue_size 1024 \
    -i "$audio_url" \
    -map 0:v:0 \
    -map 1:a:0 \
    -dn \
    -sn \
    -vf "scale=-2:360:flags=bicubic" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -fps_mode:v cfr \
    -r 20 \
    -b:v 800k \
    -maxrate 900k \
    -bufsize 2400k \
    -max_muxing_queue_size 2048 \
    -g 40 \
    -keyint_min 40 \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*4)" \
    -c:a aac \
    -ac 2 \
    -b:a 96k \
    -af "aresample=async=${AUDIO_RESAMPLE_ASYNC}:first_pts=0" \
    -f hls \
    -hls_time 4 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_delete_threshold "$HLS_DELETE_THRESHOLD" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" 9>&- &
}

run_ffmpeg_from_ytdlp() {
  local source_url="$1"

  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "[ffmpeg_web12_proxy] yt-dlp no esta instalado; no se puede resolver $source_url" >&2
    return 1
  fi

  echo "[ffmpeg_web12_proxy] Resolviendo y enviando por tuberia: $source_url" >&2

  set -o pipefail
  yt-dlp --no-warnings --no-playlist -f "$YT_FORMAT_SELECTOR" -o - "$source_url" 9>&- | \
    ffmpeg \
      -loglevel info \
      -fflags +discardcorrupt+genpts \
      -err_detect ignore_err \
      -i pipe:0 \
      -dn \
      -sn \
      -vf "scale=-2:360:flags=bicubic" \
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
      -sc_threshold 0 \
      -force_key_frames "expr:gte(t,n_forced*4)" \
      -c:a aac \
      -ac 2 \
      -b:a 96k \
      -f hls \
      -hls_time 4 \
      -hls_list_size "$HLS_LIST_SIZE" \
      -hls_delete_threshold "$HLS_DELETE_THRESHOLD" \
      -start_number "$START_NUMBER" \
      -hls_flags delete_segments+independent_segments+temp_file+omit_endlist \
      -hls_segment_filename "$OUT/seg_%06d.ts" \
      "$OUT/index.m3u8" 9>&-
}

LAST_RESOLVED_BOOT_USED=0
SHORT_FAIL_STREAK=0
FORCE_FRESH_RESOLVE=0

while true; do
  set +e

  START_NUMBER="$(date +%s)"
  resolve_rc=0

  if [ "$FORCE_FRESH_RESOLVE" -eq 0 ] && [ "$USE_LAST_RESOLVED_ON_START" = "1" ] && [ "$LAST_RESOLVED_BOOT_USED" -eq 0 ]; then
    RESOLVED_SRC_URL="$(read_cached_resolved_url || true)"
    if [ -n "$RESOLVED_SRC_URL" ]; then
      echo "[ffmpeg_web12_proxy] Usando ultimo origen resuelto en cache: $RESOLVED_SRC_URL" >&2
      LAST_RESOLVED_BOOT_USED=1
      resolve_rc=0
    else
      RESOLVED_SRC_URL="$(resolve_source_url "$SRC_URL")"
      resolve_rc=$?
      LAST_RESOLVED_BOOT_USED=1
    fi
  else
    if [ "$FORCE_FRESH_RESOLVE" -eq 1 ]; then
      echo "[ffmpeg_web12_proxy] Forzando resolucion fresca de Pluto tras fallo del stream." >&2
    fi
    RESOLVED_SRC_URL="$(resolve_source_url "$SRC_URL")"
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

  if { [ "$resolve_rc" -ne 0 ] || [ -z "$RESOLVED_SRC_URL" ]; } && [ "$allow_cached_fallback" = "1" ]; then
    RESOLVED_SRC_URL="$(read_cached_resolved_url || true)"
    if [ -n "$RESOLVED_SRC_URL" ]; then
      echo "[ffmpeg_web12_proxy] Usando ultimo origen resuelto en cache: $RESOLVED_SRC_URL" >&2
      resolve_rc=0
    fi
  fi

  if [ "$resolve_rc" -eq 0 ] && [ -n "$RESOLVED_SRC_URL" ] && is_direct_stream_url "$RESOLVED_SRC_URL"; then
    cache_resolved_url "$RESOLVED_SRC_URL"
    clear_published_output

    if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]] && PLUTO_AUDIO_URL="$(derive_pluto_audio_url "$RESOLVED_SRC_URL" 2>/dev/null)" && [ -n "$PLUTO_AUDIO_URL" ]; then
      run_ffmpeg_from_dual_url "$RESOLVED_SRC_URL" "$PLUTO_AUDIO_URL"
    else
      run_ffmpeg_from_direct_url "$RESOLVED_SRC_URL"
    fi
    ffmpeg_pid=$!
    ffmpeg_started_ts="$(date +%s)"
  else
    clear_published_output

    echo "[ffmpeg_web12_proxy] No se pudo resolver una URL reproducible para $SRC_URL" >&2

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
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL_SECONDS"

    if [ -f "$OUT/index.m3u8" ] && grep -q '^#EXT-X-ENDLIST' "$OUT/index.m3u8" 2>/dev/null; then
      echo "[ffmpeg_web12_proxy] index.m3u8 contiene #EXT-X-ENDLIST, reiniciando ffmpeg ($ffmpeg_pid)" >&2
      FORCE_FRESH_RESOLVE=1
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
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web12_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      FORCE_FRESH_RESOLVE=1
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  run_elapsed=$(( $(date +%s) - ffmpeg_started_ts ))

  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* ]] && [ "$run_elapsed" -lt "$MIN_GOOD_RUN_SECONDS" ]; then
    SHORT_FAIL_STREAK=$((SHORT_FAIL_STREAK + 1))
    FORCE_FRESH_RESOLVE=1
    clear_cached_resolved_url
  else
    SHORT_FAIL_STREAK=0
  fi

  if [ "$SHORT_FAIL_STREAK" -ge "$REFRESH_SHORT_FAIL_STREAK" ]; then
    echo "[ffmpeg_web12_proxy] Detectados $SHORT_FAIL_STREAK fallos cortos consecutivos; limpiando cache de Pluto." >&2
    FORCE_FRESH_RESOLVE=1
    clear_cached_resolved_url
    SHORT_FAIL_STREAK=0
  fi

  set -e

  echo "[ffmpeg_web12_proxy] ffmpeg salio con codigo $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
