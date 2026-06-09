#!/usr/bin/env bash

# Proxy HLS desde la página pública de Azteca 7 a un HLS local servido por Apache.
# Entrada:  https://www.tvazteca.com/azteca7/
# Salida:   /var/www/html/hls/web5/index.m3u8 (accesible como /hls/web5/index.m3u8)

set -e
umask 000

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
  CONFIG_SRC_URL="${WEB5_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB5_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web5}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-https://www.tvazteca.com/azteca7/}}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
DEFAULT_USER_AGENT="${FFMPEG_USER_AGENT:-VLC/3.0.20 LibVLC/3.0.20}"
HLS_TIME="${HLS_TIME:-6}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-15}"
HLS_DELETE_THRESHOLD="${HLS_DELETE_THRESHOLD:-8}"
MDSTRM_TARGET_BANDWIDTH="${MDSTRM_TARGET_BANDWIDTH:-915200}"
FPS="${FPS:-}"
GOP="${GOP:-180}"
KEYFRAME_INTERVAL="${KEYFRAME_INTERVAL:-$HLS_TIME}"
VIDEO_FPS_MODE="${VIDEO_FPS_MODE:-passthrough}"
VIDEO_BITRATE="${VIDEO_BITRATE:-900k}"
VBV_MAX="${VBV_MAX:-1000k}"
VBV_BUF="${VBV_BUF:-3000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
VIDEO_CODEC="${VIDEO_CODEC:-copy}"
AUDIO_CODEC="${AUDIO_CODEC:-aac}"
X264_PRESET="${X264_PRESET:-superfast}"
INPUT_LIVE_START_INDEX="${INPUT_LIVE_START_INDEX:--8}"
REALTIME_PACE="${REALTIME_PACE:-1}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-0}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-45}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"
WATCHDOG_KILL_GRACE_SECONDS="${WATCHDOG_KILL_GRACE_SECONDS:-2}"
WATCHDOG_STARTUP_GRACE_SECONDS="${WATCHDOG_STARTUP_GRACE_SECONDS:-20}"
HTTP_RW_TIMEOUT_US="${HTTP_RW_TIMEOUT_US:-15000000}"
HTTP_REFERER="${HTTP_REFERER:-https://mdstrm.com/}"
HTTP_ORIGIN="${HTTP_ORIGIN:-https://mdstrm.com}"

resolve_tvazteca_entry_url() {
  local page_url="$1"

  case "$page_url" in
    *"/envivo"*)
      printf '%s\n' "$page_url"
      return 0
      ;;
  esac

  python3 - "$page_url" <<'PY'
import re
import sys
import urllib.parse
import urllib.request

page_url = sys.argv[1]
headers = {'User-Agent': 'Mozilla/5.0'}
request = urllib.request.Request(page_url, headers=headers)

with urllib.request.urlopen(request, timeout=30) as response:
    html = response.read().decode('utf-8', 'ignore')

patterns = [
    r'href="([^"]*/azteca7[^"#?]*/envivo(?:\?[^"#]*)?)"',
    r'href="([^"]*/envivo(?:\?[^"#]*)?)"',
]

for pattern in patterns:
    match = re.search(pattern, html, flags=re.IGNORECASE)
    if match:
        candidate = match.group(1)
        print(urllib.parse.urljoin(page_url, candidate))
        raise SystemExit(0)

print(page_url.rstrip('/') + '/envivo')
PY
}

resolve_tvazteca_live_url() {
  local page_url="$1"

  python3 - "$page_url" <<'PY'
import html
import http.cookiejar
import json
import re
import sys
import urllib.parse
import urllib.request

page_url = sys.argv[1]
user_agent = "Mozilla/5.0"
cookie_jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))


def open_url(url, data=None, content_type=None):
  headers = {"User-Agent": user_agent}
  if content_type:
    headers["Content-Type"] = content_type
  request = urllib.request.Request(url, data=data, headers=headers)
  return opener.open(request, timeout=30)


page_html = open_url(page_url).read().decode("utf-8", "ignore")
config_match = re.search(r'data-safe-mode-config="([^"]+)"', page_html)
player_match = re.search(r'data-player-id="([^"]+)"', page_html)

if not config_match or not player_match:
  raise SystemExit("No se encontró la configuración de TV Azteca en la página")

safe_mode_config = json.loads(html.unescape(config_match.group(1)))
token_body = json.loads(safe_mode_config["bodyJson"])
asset_id = token_body["asset_id"]
player_id = player_match.group(1)

token_response = open_url(
  safe_mode_config["domain"],
  data=json.dumps(token_body).encode("utf-8"),
  content_type="application/json",
)
access_token = json.loads(token_response.read().decode("utf-8"))["access_token"]

mdstrm_url = (
  f"https://mdstrm.com/live-stream/{asset_id}?"
  f"jsapi=true&show_controls_on_ad=true&autoplay=true&volume=0&"
  f"player={urllib.parse.quote(player_id)}&show_title=false&"
  f"access_token={urllib.parse.quote(access_token)}"
)
open_url(mdstrm_url).read()

uid = None
sid = None
for cookie in cookie_jar:
  if cookie.name == "MDSTRMUID":
    uid = cookie.value
  elif cookie.name == "MDSTRMSID":
    sid = cookie.value

if not uid or not sid:
  raise SystemExit("No se obtuvieron cookies MDSTRMUID/MDSTRMSID")

playlist_url = (
  f"https://mdstrm.com/live-stream-playlist/{asset_id}.m3u8?"
  f"uid={urllib.parse.quote(uid)}&sid={urllib.parse.quote(sid)}&"
  f"access_token={urllib.parse.quote(access_token)}"
)
final_response = open_url(playlist_url)
print(final_response.geturl())
PY
}

resolve_source_url() {
  local src_url="$1"
  local entry_url
  local resolved_url

  case "$src_url" in
  https://www.tvazteca.com/azteca7/*)
    entry_url="$(resolve_tvazteca_entry_url "$src_url")" || return 1
    resolved_url="$(resolve_tvazteca_live_url "$entry_url")" || return 1
    ;;
  *)
    resolved_url="$src_url"
    ;;
  esac

  if ! resolved_url="$(resolve_mdstrm_variant_url "$resolved_url")"; then
    return 1
  fi

  printf '%s\n' "$resolved_url"
}

resolve_mdstrm_variant_url() {
  local source_url="$1"

  case "$source_url" in
    *.m3u8*) ;;
    *)
      printf '%s\n' "$source_url"
      return 0
      ;;
  esac

  python3 - "$source_url" "$MDSTRM_TARGET_BANDWIDTH" <<'PY'
import re
import sys
import urllib.request
from urllib.parse import urljoin, urlparse

source_url = sys.argv[1]
target_bandwidth = int(sys.argv[2])

try:
    req = urllib.request.Request(source_url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=30) as response:
        final_url = response.geturl()
        text = response.read().decode('utf-8', 'ignore')
except Exception:
    print(source_url)
    raise SystemExit(0)

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
        parsed_final = urlparse(final_url)
        if line.startswith(':///'):
            best_url = f"{parsed_final.scheme}://{parsed_final.netloc}/{line[4:]}"
        else:
            best_url = urljoin(final_url, line)

        if best_url:
            parsed_best = urlparse(best_url)
            if not parsed_best.query and parsed_final.query:
                best_url = best_url.rstrip('?') + '?' + parsed_final.query

    pending_bandwidth = None

if not best_url:
    print(source_url)
    raise SystemExit(0)

print(best_url)
PY
}
mkdir -p "$OUT"
chmod 777 "$OUT" 2>/dev/null || true

while true; do
  set +e

  RESOLVED_SRC_URL="$(resolve_source_url "$SRC_URL")"
  if [ $? -ne 0 ] || [ -z "$RESOLVED_SRC_URL" ]; then
    set -e
    echo "[ffmpeg_web5_proxy] No se pudo resolver la URL fuente de web5: $SRC_URL" >&2
    sleep 10
    continue
  fi

  CURRENT_USER_AGENT="$DEFAULT_USER_AGENT"
  if [ "$RESOLVED_SRC_URL" != "$SRC_URL" ]; then
    CURRENT_USER_AGENT="Mozilla/5.0"
  fi

  # Mantener algunos segmentos previos ayuda al reproductor cuando hay reinicios del upstream.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  RUN_ID="$(date +%s)"
  START_NUMBER="$RUN_ID"
  HLS_FLAGS="delete_segments+temp_file"

  ffmpeg_cmd=(
    ffmpeg
    -loglevel info
    -fflags +discardcorrupt+genpts
    -err_detect ignore_err
    -rw_timeout "$HTTP_RW_TIMEOUT_US"
    -reconnect 1
    -reconnect_at_eof 1
    -reconnect_streamed 1
    -reconnect_on_network_error 1
    -reconnect_on_http_error 4xx,5xx
    -reconnect_delay_max 5
    -http_persistent 0
    -referer "$HTTP_REFERER"
    -headers "Origin: $HTTP_ORIGIN\r\n"
    -user_agent "$CURRENT_USER_AGENT"
  )

  if [ "$REALTIME_PACE" = "1" ]; then
    ffmpeg_cmd+=( -re )
  fi

  if [ -n "$INPUT_LIVE_START_INDEX" ]; then
    ffmpeg_cmd+=( -live_start_index "$INPUT_LIVE_START_INDEX" )
  fi

  ffmpeg_cmd+=(
    -i "$RESOLVED_SRC_URL"
    -map 0:v:0
    -map 0:a:0?
    -dn
    -sn
    -max_muxing_queue_size 2048
    -f hls
    -hls_time "$HLS_TIME"
    -hls_list_size "$HLS_LIST_SIZE"
    -start_number "$START_NUMBER"
    -hls_allow_cache 0
    -hls_delete_threshold "$HLS_DELETE_THRESHOLD"
    -hls_segment_filename "$OUT/seg_${RUN_ID}_%06d.ts"
  )

  if [ "$VIDEO_CODEC" = "copy" ]; then
    ffmpeg_cmd+=( -c:v copy )
  else
    ffmpeg_cmd+=(
      -c:v libx264
      -preset "$X264_PRESET"
      -tune zerolatency
      -profile:v baseline
      -level 3.1
      -fps_mode:v "$VIDEO_FPS_MODE"
      -b:v "$VIDEO_BITRATE"
      -maxrate "$VBV_MAX"
      -bufsize "$VBV_BUF"
      -g "$GOP"
      -keyint_min "$GOP"
      -force_key_frames "expr:gte(t,n_forced*$KEYFRAME_INTERVAL)"
    )
    HLS_FLAGS+="+independent_segments"
  fi

  if [ "$AUDIO_CODEC" = "copy" ]; then
    ffmpeg_cmd+=( -c:a copy )
  else
    ffmpeg_cmd+=(
      -c:a aac
      -ac 2
      -b:a "$AUDIO_BITRATE"
      -af aresample=async=1:first_pts=0
    )
  fi

  ffmpeg_cmd+=( -hls_flags "$HLS_FLAGS" "$OUT/index.m3u8" )

  if [ -n "$FPS" ]; then
    ffmpeg_cmd+=( -r "$FPS" )
  fi

  "${ffmpeg_cmd[@]}" &

    ffmpeg_pid=$!
    ffmpeg_started_ts="$(date +%s)"

    last_ok_ts="$(date +%s)"
    last_media_sequence=""
    last_segment_name=""

    if [ -f "$OUT/index.m3u8" ]; then
      last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
      last_media_sequence="$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE://p' "$OUT/index.m3u8" | head -n1)"
      last_segment_name="$(grep -E '^seg_.*\.ts$' "$OUT/index.m3u8" 2>/dev/null | tail -n1)"
    else
      last_mtime="$last_ok_ts"
    fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL_SECONDS"
    # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
    # Limpia segmentos heredados para evitar acumulación antes de reiniciar ffmpeg

      if [ -f "$OUT/index.m3u8" ]; then
        current_mtime="$(stat -c %Y "$OUT/index.m3u8")"
        current_media_sequence="$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE://p' "$OUT/index.m3u8" | head -n1)"
        current_segment_name="$(grep -E '^seg_.*\.ts$' "$OUT/index.m3u8" 2>/dev/null | tail -n1)"

      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
      fi
        if [ -n "$current_media_sequence" ] && [ "$current_media_sequence" != "$last_media_sequence" ]; then
        last_media_sequence="$current_media_sequence"
        last_ok_ts="$(date +%s)"
      fi
        if [ -n "$current_segment_name" ] && [ "$current_segment_name" != "$last_segment_name" ]; then
          last_segment_name="$current_segment_name"
          last_ok_ts="$(date +%s)"
        fi
    fi

    now_ts="$(date +%s)"
    if [ $(( now_ts - ffmpeg_started_ts )) -lt "$WATCHDOG_STARTUP_GRACE_SECONDS" ]; then
      continue
    fi
    stale_seconds=$(( now_ts - last_ok_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web5_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null || true
      sleep "$WATCHDOG_KILL_GRACE_SECONDS"
      if kill -0 "$ffmpeg_pid" 2>/dev/null; then
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
      fi
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

    echo "[ffmpeg_web5_proxy] ffmpeg salió con código $rc. Reintentando en 2 segundos..." >&2
    sleep 2
done
