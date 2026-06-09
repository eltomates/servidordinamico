#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV a un HLS local servido por Apache.
# Entrada:  http://38.49.128.38:8000/play/a0n6/index.m3u8
# Salida:   /var/www/html/hls/web10/index.m3u8 (accesible como /hls/web10/index.m3u8)

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
HLS_LIST_SIZE="${HLS_LIST_SIZE:-20}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-60}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-5}"
MAX_SEGMENT_REPEAT_SECONDS="${MAX_SEGMENT_REPEAT_SECONDS:-45}"
FPS="${FPS:-15}"
GOP="${GOP:-30}"
VBV_MAX="${VBV_MAX:-700k}"
VBV_BUF="${VBV_BUF:-1800k}"
VIDEO_BITRATE="${VIDEO_BITRATE:-600k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"
ROKU_TARGET_BANDWIDTH="${ROKU_TARGET_BANDWIDTH:-700000}"
ROKU_REFRESH_WINDOW_SECONDS="${ROKU_REFRESH_WINDOW_SECONDS:-600}"
YT_FORMAT_SELECTOR="${YT_FORMAT_SELECTOR:-bv*[vcodec^=avc1][height<=720][ext=mp4]+ba[ext=mp4]/bv*[vcodec^=avc1][ext=mp4]+ba[ext=mp4]/b}"
PLUTO_TARGET_BANDWIDTH="${PLUTO_TARGET_BANDWIDTH:-1577180}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLUTO_CHROMIUM_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_TIMEOUT_SECONDS:-15}"
PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_HARD_TIMEOUT_SECONDS:-210}"
PLUTO_REQUIRE_CHROMIUM="${PLUTO_REQUIRE_CHROMIUM:-0}"
PLUTO_SKIP_VERIFY="${PLUTO_SKIP_VERIFY:-1}"
PLUTO_AUDIO_OFFSET_SECONDS="${PLUTO_AUDIO_OFFSET_SECONDS:-0}"

mkdir -p "$OUT"
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

  timeout 8 ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

run_ffmpeg_from_direct_url() {
  local input_url="$1"

  ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -rw_timeout 15000000 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -user_agent "Mozilla/5.0" \
    -i "$input_url" \
    -map 0:v:0? \
    -map 0:a:0? \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r 24 \
    -b:v 1200k \
    -maxrate 1600k \
    -bufsize 3200k \
    -max_muxing_queue_size 2048 \
    -g 60 \
    -keyint_min 60 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time 6 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &
}

run_ffmpeg_from_dual_url() {
  local video_url="$1"
  local audio_url="$2"

  echo "[ffmpeg_web10_proxy] Usando video + audio Pluto: $video_url | $audio_url" >&2

  ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -rw_timeout 15000000 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -user_agent "Mozilla/5.0" \
    -i "$video_url" \
    -thread_queue_size 1024 \
    -itsoffset "$PLUTO_AUDIO_OFFSET_SECONDS" \
    -i "$audio_url" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r 24 \
    -b:v 1200k \
    -maxrate 1600k \
    -bufsize 3200k \
    -max_muxing_queue_size 2048 \
    -g 60 \
    -keyint_min 60 \
    -c:a aac \
    -af "aresample=async=1:first_pts=0" \
    -ac 2 \
    -b:a 128k \
    -f hls \
    -hls_time 6 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &
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
    chromium_output="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 PLUTO_SKIP_VERIFY="$PLUTO_SKIP_VERIFY" python3 "$chromium_resolver" "$page_url" "$PLUTO_CHROMIUM_TIMEOUT_SECONDS" 2>&1 || true; } 9>&-)"

    chromium_url="$(printf '%s\n' "$chromium_output" | awk '/^https?:\/\//{u=$0} END{print u}')"
    if [ -z "$chromium_url" ]; then
      chromium_url="$(printf '%s\n' "$chromium_output" | grep -Eo 'https?://[^[:space:]]+' | grep -E '/(playlist|master)\.m3u8' | tail -n1 || true)"
    fi

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
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

  case "$source_url" in
    https://pluto.tv/*/live-tv/*)
      resolve_pluto_source_url "$source_url"
      return $?
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

  update_variant_url_in_config "$resolved_url"
  CONFIG_VARIANT_URL="$resolved_url"

  printf '%s\n' "$resolved_url"
}

while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"
  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    if [ -n "$CONFIG_WATCH_URL" ] && [ "$SRC_URL" != "$CONFIG_WATCH_URL" ]; then
      echo "[ffmpeg_web10_proxy] Resolución con URL guardada falló; intentando refrescar desde WEB10_URL..." >&2
      if INPUT_URL="$(resolve_source_url "$CONFIG_WATCH_URL")"; then
        SRC_URL="$CONFIG_WATCH_URL"
      elif [ -n "$CONFIG_VARIANT_URL" ]; then
        echo "[ffmpeg_web10_proxy] Roku API no respondió; usando fallback WEB10_VARIANT_URL guardada..." >&2
        INPUT_URL="$CONFIG_VARIANT_URL"
      else
        set -e
        echo "[ffmpeg_web10_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
        sleep 5
        continue
      fi
    elif [ -n "$CONFIG_VARIANT_URL" ]; then
      echo "[ffmpeg_web10_proxy] Resolución falló; usando fallback WEB10_VARIANT_URL guardada..." >&2
      INPUT_URL="$CONFIG_VARIANT_URL"
    else
      set -e
      echo "[ffmpeg_web10_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
      sleep 5
      continue
    fi
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web10_proxy] Origen intermedio resuelto a stream HLS directo." >&2
  fi

  resolved_audio_url=""
  case "$INPUT_URL" in
    *cfd-v4-service-channel-stitcher*.prd.pluto.tv*/playlist.m3u8*)
      if ! url_has_audio_stream "$INPUT_URL"; then
        resolved_audio_url="$(derive_pluto_audio_url "$INPUT_URL" || true)"
      fi
      ;;
  esac

  if [ -n "$resolved_audio_url" ]; then
    run_ffmpeg_from_dual_url "$INPUT_URL" "$resolved_audio_url"
  else
    run_ffmpeg_from_direct_url "$INPUT_URL"
  fi

  ffmpeg_pid=$!

  last_ok_ts="$(date +%s)"
  last_segment_change_ts="$last_ok_ts"
  last_segment_line=""
  saw_endlist=0
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
    last_segment_line="$(grep -E 'seg_[0-9]+\.ts$' "$OUT/index.m3u8" | tail -n1 || true)"
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

      if grep -q '^#EXT-X-ENDLIST' "$OUT/index.m3u8"; then
        saw_endlist=1
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

    if [ "$saw_endlist" -eq 1 ]; then
      echo "[ffmpeg_web10_proxy] Detectado ENDLIST en salida local, reiniciando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ -n "$last_segment_line" ] && [ "$segment_repeat_seconds" -ge "$MAX_SEGMENT_REPEAT_SECONDS" ]; then
      echo "[ffmpeg_web10_proxy] Último segmento sin cambio por $segment_repeat_seconds s ($last_segment_line), reiniciando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web10_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web10_proxy] ffmpeg salió con código $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
