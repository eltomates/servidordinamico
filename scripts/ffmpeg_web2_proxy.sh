#!/usr/bin/env bash

# Proxy HLS desde una URL remota a un HLS local servido por Apache.
# Entrada:  http://38.49.128.38:8000/play/a0ou/index.m3u8
# Salida:   /var/www/html/hls/web2/index.m3u8 (accesible como /hls/web2/index.m3u8)

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
  CONFIG_WATCH_URL="${WEB2_URL:-}"
  CONFIG_SRC_URL="${WEB2_RESOLVED_URL:-${WEB2_URL:-}}"
  CONFIG_VARIANT_URL="${WEB2_VARIANT_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_WATCH_URL="${WEB2_URL:-}"
  CONFIG_SRC_URL="${WEB2_RESOLVED_URL:-${WEB2_URL:-}}"
  CONFIG_VARIANT_URL="${WEB2_VARIANT_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web2}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-http://38.49.128.38:8000/play/a0c5/index.m3u8}}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-30}"
HLS_TIME="${HLS_TIME:-4}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
FPS="${FPS:-}"
GOP="${GOP:-60}"
KEYFRAME_INTERVAL="${KEYFRAME_INTERVAL:-$HLS_TIME}"
VIDEO_FPS_MODE="${VIDEO_FPS_MODE:-passthrough}"
VBV_MAX="${VBV_MAX:-1200k}"
VBV_BUF="${VBV_BUF:-2800k}"
VIDEO_BITRATE="${VIDEO_BITRATE:-1000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-8}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-2}"
WATCHDOG_KILL_GRACE_SECONDS="${WATCHDOG_KILL_GRACE_SECONDS:-1}"
ROKU_TARGET_BANDWIDTH="${ROKU_TARGET_BANDWIDTH:-1000000}"
ROKU_REFRESH_WINDOW_SECONDS="${ROKU_REFRESH_WINDOW_SECONDS:-600}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
ROKU_CHROMIUM_TIMEOUT_SECONDS="${ROKU_CHROMIUM_TIMEOUT_SECONDS:-20}"
PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"

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

replace_config_file() {
  local tmp_file="$1"
  local config_file="$2"
  local config_dir owner group

  config_dir="$(dirname "$config_file")"

  if [ "$(id -u)" -eq 0 ] && [ -d "$config_dir" ]; then
    owner="$(stat -c '%U' "$config_dir" 2>/dev/null || true)"
    group="$(stat -c '%G' "$config_dir" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ -n "$group" ]; then
      chown "$owner:$group" "$tmp_file" 2>/dev/null || true
    fi
  fi

  chmod 664 "$tmp_file" 2>/dev/null || true
  command mv -f "$tmp_file" "$config_file"
  chmod 664 "$config_file" 2>/dev/null || true
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
  grep -v '^WEB2_RESOLVED_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB2_RESOLVED_URL="%s"\n' "$resolved_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$config_file"
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
  grep -v '^WEB2_VARIANT_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB2_VARIANT_URL="%s"\n' "$variant_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$config_file"
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
  local part_path query_template

  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*) ;;
    *)
      printf '%s\n' "$source_url"
      return 0
      ;;
  esac

  query_template="$(find_plex_query_template)" || {
    echo "[ffmpeg_web2_proxy] No se encontró un token Plex reutilizable para resolver $source_url" >&2
    return 1
  }

  part_path="$(python3 - "$source_url" <<'PY'
import re
import sys
import urllib.request
from urllib.parse import urlsplit

source_url = sys.argv[1]
slug = urlsplit(source_url).path.rstrip('/').rsplit('/', 1)[-1]

req = urllib.request.Request(source_url, headers={'User-Agent': 'Mozilla/5.0'})
html = urllib.request.urlopen(req, timeout=30).read().decode('utf-8', 'ignore')

slug_re = re.escape(slug)
patterns = [
  rf'\\"slug\\":\\"{slug_re}\\".*?\\"key\\":\\"(?P<key>/library/parts/[^\\"]+\.m3u8)\\"',
  rf'\\"watchUrl\\":\\"https://watch\.plex\.tv/(?:es/)?live-tv/channel/{slug_re}\\".*?\\"contentId\\":\\"(?P<content>/library/parts/[^\\"]+\.m3u8)\\"',
]

for pattern in patterns:
    match = re.search(pattern, html, re.S)
    if match:
        value = match.groupdict().get('key') or match.groupdict().get('content')
        if value:
            print(value.lstrip('/'))
            raise SystemExit(0)

raise SystemExit(1)
PY
  )" || true
  if [ -z "$part_path" ]; then
    echo "[ffmpeg_web2_proxy] No se encontró el stream HLS asociado a $source_url" >&2
    return 1
  fi

  printf 'https://epg.provider.plex.tv/%s?%s\n' "$part_path" "$query_template"
}

resolve_roku_watch_url() {
  local source_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_roku_chromium.py"
  local chromium_url=""

  case "$source_url" in
  *therokuchannel.roku.com/watch/*) ;;
  *)
    printf '%s\n' "$source_url"
    return 0
    ;;
  esac

  # Primer intento: resolver con navegador Chromium real para obtener URLs firmadas vigentes.
  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    if command -v xvfb-run >/dev/null 2>&1; then
      chromium_url="$(PW_HEADLESS=1 xvfb-run -a -s "-screen 0 1280x720x24" python3 "$chromium_resolver" "$source_url" "$ROKU_CHROMIUM_TIMEOUT_SECONDS" 2>/dev/null | tail -n1)"
    else
      chromium_url="$(PW_HEADLESS=1 python3 "$chromium_resolver" "$source_url" "$ROKU_CHROMIUM_TIMEOUT_SECONDS" 2>/dev/null | tail -n1)"
    fi
    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  python3 - "$source_url" <<'PY'
import json
import re
import sys
import urllib.error
import urllib.parse
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
  local pre_refresh_resolved

  if ! resolved_url="$(resolve_plex_watch_url "$source_url")"; then
    return 1
  fi

  if ! resolved_url="$(resolve_roku_watch_url "$resolved_url")"; then
    return 1
  fi

  pre_refresh_resolved="$resolved_url"
  if ! resolved_url="$(ensure_fresh_roku_master_url "$resolved_url")"; then
    # Si falla el refresh JWT, continuar con la URL previa y dejar que ffmpeg valide.
    resolved_url="$pre_refresh_resolved"
  fi

  update_resolved_url_in_config "$resolved_url"

  if ! resolved_url="$(resolve_roku_variant_url "$resolved_url")"; then
    return 1
  fi

  update_variant_url_in_config "$resolved_url"
  CONFIG_VARIANT_URL="$resolved_url"

  printf '%s\n' "$resolved_url"
}

is_hls_url_usable() {
  local candidate_url="$1"

  [ -n "$candidate_url" ] || return 1

  python3 - "$candidate_url" <<'PY'
import sys
import urllib.error
import urllib.request

url = sys.argv[1]

headers = {
  'User-Agent': 'Mozilla/5.0',
  'Accept': 'application/vnd.apple.mpegurl,application/x-mpegURL,text/plain,*/*',
}

req = urllib.request.Request(url, headers=headers)

try:
  with urllib.request.urlopen(req, timeout=12) as resp:
    status = getattr(resp, 'status', 200)
    body = resp.read(512).decode('utf-8', 'ignore')
except urllib.error.HTTPError as exc:
  if exc.code in (401, 403, 404, 410, 472):
    raise SystemExit(1)
  raise SystemExit(0)
except Exception:
  raise SystemExit(1)

if status >= 400:
  raise SystemExit(1)

if '#EXTM3U' not in body:
  raise SystemExit(1)

raise SystemExit(0)
PY
}


# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  # Usar un identificador único por reinicio para evitar reuso de caché en clientes.
  RUN_ID="$(date +%s)"
  START_NUMBER="$RUN_ID"

  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    if [ -n "$CONFIG_WATCH_URL" ] && [ "$SRC_URL" != "$CONFIG_WATCH_URL" ]; then
      echo "[ffmpeg_web2_proxy] Resolución con URL guardada falló; intentando refrescar desde WEB2_URL..." >&2
      if INPUT_URL="$(resolve_source_url "$CONFIG_WATCH_URL")"; then
        SRC_URL="$CONFIG_WATCH_URL"
      elif [ -n "$CONFIG_SRC_URL" ] && is_hls_url_usable "$CONFIG_SRC_URL"; then
        echo "[ffmpeg_web2_proxy] Roku API no respondió; usando fallback WEB2_RESOLVED_URL validada..." >&2
        INPUT_URL="$CONFIG_SRC_URL"
      elif [ -n "$CONFIG_VARIANT_URL" ]; then
        if is_hls_url_usable "$CONFIG_VARIANT_URL"; then
          echo "[ffmpeg_web2_proxy] Roku API no respondió; usando fallback WEB2_VARIANT_URL validada..." >&2
          INPUT_URL="$CONFIG_VARIANT_URL"
        else
          echo "[ffmpeg_web2_proxy] WEB2_VARIANT_URL guardada no es usable (expirada o no autorizada)." >&2
          set -e
          sleep 5
          continue
        fi
      else
        set -e
        echo "[ffmpeg_web2_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
        sleep 5
        continue
      fi
    elif [ -n "$CONFIG_SRC_URL" ] && is_hls_url_usable "$CONFIG_SRC_URL"; then
      echo "[ffmpeg_web2_proxy] Resolución falló; usando fallback WEB2_RESOLVED_URL validada..." >&2
      INPUT_URL="$CONFIG_SRC_URL"
    elif [ -n "$CONFIG_VARIANT_URL" ]; then
      if is_hls_url_usable "$CONFIG_VARIANT_URL"; then
        echo "[ffmpeg_web2_proxy] Resolución falló; usando fallback WEB2_VARIANT_URL validada..." >&2
        INPUT_URL="$CONFIG_VARIANT_URL"
      else
        echo "[ffmpeg_web2_proxy] WEB2_VARIANT_URL guardada no es usable (expirada o no autorizada)." >&2
        set -e
        sleep 5
        continue
      fi
    else
      set -e
      echo "[ffmpeg_web2_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
      sleep 5
      continue
    fi
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web2_proxy] Origen intermedio resuelto a stream HLS directo." >&2
  fi

  ffmpeg_cmd=(
    ffmpeg
    -loglevel info \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 5 \
    -user_agent "VLC/3.0.20 LibVLC/3.0.20" \
    -i "$INPUT_URL" \
    -map 0:v:0 \
    -map 0:a:0? \
    -dn \
    -sn \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -fps_mode:v "$VIDEO_FPS_MODE" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VBV_MAX" \
    -bufsize "$VBV_BUF" \
    -max_muxing_queue_size 2048 \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -force_key_frames "expr:gte(t,n_forced*$KEYFRAME_INTERVAL)" \
    -c:a aac \
    -ac 2 \
    -b:a "$AUDIO_BITRATE" \
    -af aresample=async=1:first_pts=0 \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_allow_cache 0 \
    -hls_delete_threshold 24 \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file \
    -hls_segment_filename "$OUT/seg_${RUN_ID}_%06d.ts" \
    "$OUT/index.m3u8"
  )

  if [ -n "$FPS" ]; then
    ffmpeg_cmd+=( -r "$FPS" )
  fi

  "${ffmpeg_cmd[@]}" &

  ffmpeg_pid=$!

  last_ok_ts="$(date +%s)"
  if [ -f "$OUT/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/index.m3u8")"
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
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      echo "[ffmpeg_web2_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null || true
      sleep "$WATCHDOG_KILL_GRACE_SECONDS"
      if kill -0 "$ffmpeg_pid" 2>/dev/null; then
        echo "[ffmpeg_web2_proxy] ffmpeg ($ffmpeg_pid) sigue vivo tras SIGTERM; enviando SIGKILL" >&2
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
      fi
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web2_proxy] ffmpeg salió con código $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
