#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV a un HLS local servido por Apache.
# Entrada:  http://tv.proyectox.vip:8080/ELLtdmaiz204fj/ScMZEQzYga/162014
# Salida:   /var/www/html/hls/web9/index.m3u8 (accesible como /hls/web9/index.m3u8)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web9}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
ROKU_TARGET_BANDWIDTH="${ROKU_TARGET_BANDWIDTH:-1000000}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLEX_CHROMIUM_TIMEOUT_SECONDS="${PLEX_CHROMIUM_TIMEOUT_SECONDS:-12}"
PLEX_CHROMIUM_HARD_TIMEOUT_SECONDS="${PLEX_CHROMIUM_HARD_TIMEOUT_SECONDS:-35}"
PLEX_REQUIRE_CHROMIUM="${PLEX_REQUIRE_CHROMIUM:-1}"
PLEX_PLAYLIST_REFRESH_SECONDS="${PLEX_PLAYLIST_REFRESH_SECONDS:-4}"
PLEX_TARGET_BANDWIDTH="${PLEX_TARGET_BANDWIDTH:-1500000}"
PLEX_LOCAL_PLAYLIST="${PLEX_LOCAL_PLAYLIST:-/var/www/html/logs/web9_plex_direct.m3u8}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
FPS="${FPS:-}"
GOP="${GOP:-180}"
KEYFRAME_INTERVAL="${KEYFRAME_INTERVAL:-$HLS_TIME}"
VIDEO_FPS_MODE="${VIDEO_FPS_MODE:-passthrough}"
VIDEO_BITRATE="${VIDEO_BITRATE:-450k}"
VBV_MAX="${VBV_MAX:-550k}"
VBV_BUF="${VBV_BUF:-1400k}"
ROKU_REFRESH_WINDOW_SECONDS="${ROKU_REFRESH_WINDOW_SECONDS:-600}"
CONFIG_SRC_URL=""
CONFIG_WATCH_URL=""
CONFIG_VARIANT_URL=""

if [ -f "$PRIMARY_CONFIG" ]; then
  # shellcheck source=/var/www/html/logs/web_sources.env
  . "$PRIMARY_CONFIG"
  CONFIG_WATCH_URL="${WEB9_URL:-}"
  CONFIG_SRC_URL="${WEB9_RESOLVED_URL:-${WEB9_URL:-}}"
  CONFIG_VARIANT_URL="${WEB9_VARIANT_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_WATCH_URL="${WEB9_URL:-}"
  CONFIG_SRC_URL="${WEB9_RESOLVED_URL:-${WEB9_URL:-}}"
  CONFIG_VARIANT_URL="${WEB9_VARIANT_URL:-}"
fi

if [[ "$CONFIG_WATCH_URL" != *watch.plex.tv/*/live-tv/channel/* && "$CONFIG_WATCH_URL" != *watch.plex.tv/live-tv/channel/* ]] && [ -f "$LEGACY_CONFIG" ]; then
  legacy_web9_url="$(awk -F '"' '/^WEB9_URL=/{print $2; exit}' "$LEGACY_CONFIG")"
  if [[ "$legacy_web9_url" == https://watch.plex.tv/*/live-tv/channel/* || "$legacy_web9_url" == https://watch.plex.tv/live-tv/channel/* ]]; then
    CONFIG_WATCH_URL="$legacy_web9_url"
    CONFIG_SRC_URL="$legacy_web9_url"
    CONFIG_VARIANT_URL=""
  fi
fi

if [[ "$CONFIG_WATCH_URL" == *watch.plex.tv/*/live-tv/channel/* || "$CONFIG_WATCH_URL" == *watch.plex.tv/live-tv/channel/* ]]; then
  CONFIG_SRC_URL="$CONFIG_WATCH_URL"
  CONFIG_VARIANT_URL=""
fi

SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-http://tv.proyectox.vip:8080/ELLtdmaiz204fj/ScMZEQzYga/162014}}"

mkdir -p "$OUT"

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
  grep -v '^WEB9_RESOLVED_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB9_RESOLVED_URL="%s"\n' "$resolved_url" >> "$tmp_file"
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
  grep -v '^WEB9_VARIANT_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB9_VARIANT_URL="%s"\n' "$variant_url" >> "$tmp_file"
  mv "$tmp_file" "$config_file"
  chmod 664 "$config_file" 2>/dev/null || true
}

is_plex_master_url() {
  case "$1" in
    *epg.provider.plex.tv*/library/parts/*.m3u8*includeAllStreams=1*|*epg-ipv4.provider.plex.tv*/library/parts/*.m3u8*includeAllStreams=1*)
      return 0
      ;;
  esac

  return 1
}

refresh_plex_local_playlist_once() {
  local master_url="$1"
  local playlist_builder="$SCRIPT_DIR/bin/refresh_plex_direct_playlist.py"

  if [ ! -f "$playlist_builder" ] || ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 "$playlist_builder" "$master_url" "$PLEX_LOCAL_PLAYLIST" "$PLEX_TARGET_BANDWIDTH" >/dev/null
}

start_plex_local_playlist_refresher() {
  local master_url="$1"

  (
    while true; do
      refresh_plex_local_playlist_once "$master_url" >/dev/null 2>&1 || true
      sleep "$PLEX_PLAYLIST_REFRESH_SECONDS"
    done
  ) >/dev/null 2>&1 &

  printf '%s\n' "$!"
}

stop_background_pid() {
  local pid="$1"

  if [ -z "$pid" ]; then
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
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
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_plex_chromium.py"
  local chromium_url=""
  local chromium_timeout_cmd=( )

  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*) ;;
    *)
      printf '%s\n' "$source_url"
      return 0
      ;;
  esac

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$PLEX_CHROMIUM_HARD_TIMEOUT_SECONDS")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    chromium_url="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 python3 "$chromium_resolver" "$source_url" "$PLEX_CHROMIUM_TIMEOUT_SECONDS" 2>/dev/null | tail -n1; } 9>&-)"

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  echo "[ffmpeg_web9_proxy] Chromium no resolvio URL valida para Plex; reintentando sin fallback directo." >&2
  return 1
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
play_id = view_opt.get('playId')
provider_id = view_opt.get('providerId')

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
    'Referer': source_url,
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
target_bandwidth = int(os.environ.get('ROKU_TARGET_BANDWIDTH', '1000000'))
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

resolve_source_url() {
  local source_url="$1"
  local resolved_url

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

  if [[ "$CONFIG_WATCH_URL" == *watch.plex.tv/*/live-tv/channel/* || "$CONFIG_WATCH_URL" == *watch.plex.tv/live-tv/channel/* ]]; then
    CONFIG_VARIANT_URL=""
    SRC_URL="$CONFIG_WATCH_URL"
  fi

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"
  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    if [ -n "$CONFIG_WATCH_URL" ] && [ "$SRC_URL" != "$CONFIG_WATCH_URL" ]; then
      echo "[ffmpeg_web9_proxy] Resolución con URL guardada falló; intentando refrescar desde WEB9_URL..." >&2
      if INPUT_URL="$(resolve_source_url "$CONFIG_WATCH_URL")"; then
        SRC_URL="$CONFIG_WATCH_URL"
      elif [ "$PLEX_REQUIRE_CHROMIUM" = "1" ] && [[ "$CONFIG_WATCH_URL" == *watch.plex.tv/*/live-tv/channel/* || "$CONFIG_WATCH_URL" == *watch.plex.tv/live-tv/channel/* ]]; then
        set -e
        echo "[ffmpeg_web9_proxy] Falló la resolución Plex vía Chromium. Reintentando en 5 segundos..." >&2
        sleep 5
        continue
      elif [ -n "$CONFIG_VARIANT_URL" ]; then
        echo "[ffmpeg_web9_proxy] Roku API no respondió; usando fallback WEB9_VARIANT_URL guardada..." >&2
        INPUT_URL="$CONFIG_VARIANT_URL"
      else
        set -e
        echo "[ffmpeg_web9_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
        sleep 5
        continue
      fi
    elif [ -n "$CONFIG_VARIANT_URL" ] && ! { [ "$PLEX_REQUIRE_CHROMIUM" = "1" ] && [[ "$CONFIG_WATCH_URL" == *watch.plex.tv/*/live-tv/channel/* || "$CONFIG_WATCH_URL" == *watch.plex.tv/live-tv/channel/* ]]; }; then
      echo "[ffmpeg_web9_proxy] Resolución falló; usando fallback WEB9_VARIANT_URL guardada..." >&2
      INPUT_URL="$CONFIG_VARIANT_URL"
    else
      set -e
      echo "[ffmpeg_web9_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
      sleep 5
      continue
    fi
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web9_proxy] Origen intermedio resuelto a stream HLS directo." >&2
  fi

  playlist_refresher_pid=""
  if is_plex_master_url "$INPUT_URL"; then
    if ! refresh_plex_local_playlist_once "$INPUT_URL"; then
      set -e
      echo "[ffmpeg_web9_proxy] Falló la preparación de la playlist local Plex. Reintentando en 5 segundos..." >&2
      sleep 5
      continue
    fi

    playlist_refresher_pid="$(start_plex_local_playlist_refresher "$INPUT_URL")"
    INPUT_URL="$PLEX_LOCAL_PLAYLIST"
    echo "[ffmpeg_web9_proxy] Usando playlist Plex local: $INPUT_URL (refresher pid: $playlist_refresher_pid)" >&2
  fi

  ffmpeg_input_opts=(
    -protocol_whitelist file,http,https,tcp,tls,crypto,data
    -allowed_extensions ALL
    -allowed_segment_extensions ALL
  )

  if [ "$INPUT_URL" != "$PLEX_LOCAL_PLAYLIST" ]; then
    ffmpeg_input_opts+=(
      -user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    )
  fi

  ffmpeg_cmd=(
    ffmpeg
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    "${ffmpeg_input_opts[@]}" \
    -i "$INPUT_URL" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -vf "scale=-2:320" \
    -fps_mode:v "$VIDEO_FPS_MODE" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VBV_MAX" \
    -bufsize "$VBV_BUF" \
    -max_muxing_queue_size 2048 \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -force_key_frames "expr:gte(t,n_forced*$KEYFRAME_INTERVAL)" \
    -c:a copy \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8"
  )

  if [ -n "$FPS" ]; then
    ffmpeg_cmd+=( -r "$FPS" )
  fi

  "${ffmpeg_cmd[@]}" &

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
      echo "[ffmpeg_web9_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  stop_background_pid "$playlist_refresher_pid"
  set -e

  echo "[ffmpeg_web9_proxy] ffmpeg salió con código $rc. Reintentando en 10 segundos..." >&2
  sleep 10

done
