#!/usr/bin/env bash

# Proxy HLS desde una URL remota a un HLS local servido por Apache.
# Entrada:  http://tv.proyectox.vip:8080/ELLtdmaiz204fj/ScMZEQzYga/9724
# Salida:   /var/www/html/hls/web1/index.m3u8 (accesible como /hls/web1/index.m3u8)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

OUT="${OUT:-/var/www/html/hls/web1}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
ROKU_TARGET_BANDWIDTH="${ROKU_TARGET_BANDWIDTH:-1000000}"
PLUTO_TARGET_BANDWIDTH="${PLUTO_TARGET_BANDWIDTH:-1577180}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
PLUTO_CHROMIUM_TIMEOUT_SECONDS="${PLUTO_CHROMIUM_TIMEOUT_SECONDS:-8}"
PLUTO_REQUIRE_CHROMIUM="${PLUTO_REQUIRE_CHROMIUM:-0}"
PLUTO_SKIP_VERIFY="${PLUTO_SKIP_VERIFY:-1}"
CONFIG_SRC_URL=""
CONFIG_WATCH_URL=""
CONFIG_VARIANT_URL=""

if [ -f "$PRIMARY_CONFIG" ]; then
  # shellcheck source=/var/www/html/logs/web_sources.env
  . "$PRIMARY_CONFIG"
  CONFIG_WATCH_URL="${WEB1_URL:-}"
  CONFIG_SRC_URL="${WEB1_RESOLVED_URL:-${WEB1_URL:-}}"
  CONFIG_VARIANT_URL="${WEB1_VARIANT_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_WATCH_URL="${WEB1_URL:-}"
  CONFIG_SRC_URL="${WEB1_RESOLVED_URL:-${WEB1_URL:-}}"
  CONFIG_VARIANT_URL="${WEB1_VARIANT_URL:-}"
fi

if [[ "$CONFIG_WATCH_URL" != https://pluto.tv/*/live-tv/* ]] && [ -f "$LEGACY_CONFIG" ]; then
  legacy_web1_url="$(awk -F '"' '/^WEB1_URL=/{print $2; exit}' "$LEGACY_CONFIG")"
  if [[ "$legacy_web1_url" == https://pluto.tv/*/live-tv/* ]]; then
    CONFIG_WATCH_URL="$legacy_web1_url"
    CONFIG_SRC_URL="$legacy_web1_url"
    CONFIG_VARIANT_URL=""
  fi
fi

if [[ "$CONFIG_WATCH_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/([a-f0-9]{24})(livestitch)?/ ]]; then
  CONFIG_WATCH_URL="https://pluto.tv/latam/live-tv/${BASH_REMATCH[1]}"
fi

SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-http://tv.proyectox.vip:8080/ELLtdmaiz204fj/ScMZEQzYga/9724}}"
HLS_TIME="${HLS_TIME:-5}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-24}"
VIDEO_BITRATE="${VIDEO_BITRATE:-850k}"
VIDEO_MAXRATE="${VIDEO_MAXRATE:-1000k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-2400k}"
VIDEO_GOP="${VIDEO_GOP:-60}"
OUTPUT_FPS="${OUTPUT_FPS:-24}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-20}"
WATCHDOG_INTERVAL_SECONDS="${WATCHDOG_INTERVAL_SECONDS:-4}"
MIN_GOOD_RUN_SECONDS="${MIN_GOOD_RUN_SECONDS:-8}"
REFRESH_SHORT_FAIL_STREAK="${REFRESH_SHORT_FAIL_STREAK:-2}"

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
  grep -v '^WEB1_RESOLVED_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB1_RESOLVED_URL="%s"\n' "$resolved_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$config_file"
}

update_roku_master_urls_in_config() {
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
  awk -v url="$resolved_url" '
    BEGIN {
      have_web1_url = 0
      have_resolved = 0
    }
    /^WEB1_URL=/ {
      have_web1_url = 1
      value = $0
      sub(/^WEB1_URL="?/, "", value)
      sub(/"?$/, "", value)
      if (value ~ /osm\.sr\.roku\.com\/osm\/v1\/hls\/master\//) {
        print "WEB1_URL=\"" url "\""
      } else {
        print $0
      }
      next
    }
    /^WEB1_RESOLVED_URL=/ {
      have_resolved = 1
      print "WEB1_RESOLVED_URL=\"" url "\""
      next
    }
    { print }
    END {
      if (!have_web1_url) {
        print "WEB1_URL=\"" url "\""
      }
      if (!have_resolved) {
        print "WEB1_RESOLVED_URL=\"" url "\""
      }
    }
  ' "$config_file" > "$tmp_file"

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
  grep -v '^WEB1_VARIANT_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB1_VARIANT_URL="%s"\n' "$variant_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$config_file"
}

update_pluto_resolved_url_in_config() {
  local resolved_url="$1"
  local config_file tmp_file

  case "$resolved_url" in
    https://cfd-v4-service-channel-stitcher-*/v2/stitch/hls/channel/*/playlist.m3u8*|https://cfd-v4-service-channel-stitcher-*/v2/stitch/hls/channel/*/master.m3u8*) ;;
    *)
      return 0
      ;;
  esac

  config_file="$(get_config_file 2>/dev/null || true)"
  if [ -z "$config_file" ]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  grep -v '^WEB1_RESOLVED_URL=' "$config_file" > "$tmp_file" || true
  printf 'WEB1_RESOLVED_URL="%s"\n' "$resolved_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$config_file"
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

find_plex_query_template() {
  local candidate config_file line value

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
    echo "[ffmpeg_web1_proxy] No se encontró un token Plex reutilizable para resolver $source_url" >&2
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
    echo "[ffmpeg_web1_proxy] No se encontró el stream HLS asociado a $source_url" >&2
    return 1
  fi

  printf 'https://epg.provider.plex.tv/%s?%s\n' "$part_path" "$query_template"
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

resolve_pluto_source_url() {
  local page_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local chromium_url=""
  local chromium_timeout_cmd=( )

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$((PLUTO_CHROMIUM_TIMEOUT_SECONDS + 12))")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    # En este host el modo headless directo es mas estable que xvfb-run.
    chromium_url="$({ "${chromium_timeout_cmd[@]}" env PW_HEADLESS=1 PLUTO_SKIP_VERIFY="$PLUTO_SKIP_VERIFY" python3 "$chromium_resolver" "$page_url" "$PLUTO_CHROMIUM_TIMEOUT_SECONDS" | tail -n1; } 9>&-)"

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      update_pluto_resolved_url_in_config "$chromium_url"
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  if [ "$PLUTO_REQUIRE_CHROMIUM" = "1" ]; then
    echo "[ffmpeg_web1_proxy] Chromium no resolvio URL valida para Pluto; reintentando sin fallback directo." >&2
    return 1
  fi

  resolved_url="$(python3 - "$page_url" "$PLUTO_TARGET_BANDWIDTH" <<'PY'
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
    raise SystemExit(
        'Pluto devolvio takedown slate para este canal; no hay stream reproducible desde este servidor'
    )

print(best_url)
PY
  )" || return 1

  update_pluto_resolved_url_in_config "$resolved_url"
  printf '%s\n' "$resolved_url"
}

resolve_source_url() {
  local source_url="$1"
  local resolved_url

  if [[ "$source_url" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/([a-f0-9]{24})(livestitch)?/ ]]; then
    resolve_pluto_source_url "https://pluto.tv/latam/live-tv/${BASH_REMATCH[1]}"
    return $?
  fi

  case "$source_url" in
    https://pluto.tv/*/live-tv/*)
      if resolved_url="$(resolve_pluto_source_url "$source_url")"; then
        printf '%s\n' "$resolved_url"
        return 0
      fi

      if [[ "$CONFIG_SRC_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/[a-f0-9]{24}(livestitch)?/ ]]; then
        echo "[ffmpeg_web1_proxy] Pluto devolvio slate; reutilizando la última playlist HLS buena." >&2
        printf '%s\n' "$CONFIG_SRC_URL"
        return 0
      fi

      return 1
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

  if [ "$resolved_url" != "$source_url" ]; then
    echo "[ffmpeg_web1_proxy] URL Roku renovada automáticamente." >&2
  fi

  update_roku_master_urls_in_config "$resolved_url"
  update_resolved_url_in_config "$resolved_url"

  if ! resolved_url="$(resolve_roku_variant_url "$resolved_url")"; then
    return 1
  fi

  update_variant_url_in_config "$resolved_url"
  CONFIG_VARIANT_URL="$resolved_url"

  printf '%s\n' "$resolved_url"
}

# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
CACHED_INPUT_URL=""
SHORT_FAIL_STREAK=0
while true; do
  set +e

  if [[ "$CONFIG_WATCH_URL" == https://pluto.tv/*/live-tv/* ]]; then
    CONFIG_VARIANT_URL=""
  fi

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  # Recodificar a un perfil más liviano pero compatible
  # Video ~1.0 Mbps H.264 baseline, Audio AAC 96 kbps
  START_NUMBER="$(date +%s)"
  INPUT_URL=""

  # Para Pluto reutilizamos temporalmente la URL resuelta para recortar downtime
  # en reconexiones rápidas por fallos transitorios del upstream.
  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* || "$SRC_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/[a-f0-9]{24}(livestitch)?/ ]] && [ -n "$CACHED_INPUT_URL" ]; then
    INPUT_URL="$CACHED_INPUT_URL"
  fi

  if [ -z "$INPUT_URL" ] && [[ "$SRC_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/[a-f0-9]{24}(livestitch)?/ ]]; then
    # Si WEB1_URL ya es playlist directa tokenizada, arrancar inmediato con ella.
    INPUT_URL="$SRC_URL"
  fi

  if [ -z "$INPUT_URL" ] && ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    if [ -n "$CONFIG_WATCH_URL" ] && [ "$SRC_URL" != "$CONFIG_WATCH_URL" ]; then
      echo "[ffmpeg_web1_proxy] Resolución con URL guardada falló; intentando refrescar desde WEB1_URL..." >&2
      if INPUT_URL="$(resolve_source_url "$CONFIG_WATCH_URL")"; then
        SRC_URL="$CONFIG_WATCH_URL"
      elif [ -n "$CONFIG_VARIANT_URL" ]; then
        echo "[ffmpeg_web1_proxy] Roku API no respondió; usando fallback WEB1_VARIANT_URL guardada..." >&2
        INPUT_URL="$CONFIG_VARIANT_URL"
      else
        set -e
        echo "[ffmpeg_web1_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
        sleep 5
        continue
      fi
    elif [ -n "$CONFIG_VARIANT_URL" ]; then
      echo "[ffmpeg_web1_proxy] Resolución falló; usando fallback WEB1_VARIANT_URL guardada..." >&2
      INPUT_URL="$CONFIG_VARIANT_URL"
    else
      set -e
      echo "[ffmpeg_web1_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
      sleep 5
      continue
    fi
  fi

  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* || "$SRC_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/[a-f0-9]{24}(livestitch)?/ ]]; then
    CACHED_INPUT_URL="$INPUT_URL"
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web1_proxy] Origen intermedio resuelto a stream HLS directo." >&2
  fi

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
    -allowed_extensions ALL \
    -allowed_segment_extensions ALL \
    -i "$INPUT_URL" \
    -c:v libx264 \
    -preset superfast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -r "$OUTPUT_FPS" \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_MAXRATE" \
    -bufsize "$VIDEO_BUFSIZE" \
    -max_muxing_queue_size 2048 \
    -g "$VIDEO_GOP" \
    -keyint_min "$VIDEO_GOP" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*$HLS_TIME)" \
    -avoid_negative_ts make_zero \
    -c:a aac \
    -ac 2 \
    -b:a "$AUDIO_BITRATE" \
    -af aresample=async=1:first_pts=0 \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_allow_cache 0 \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist+split_by_time \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!
  run_started_ts="$(date +%s)"

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
      echo "[ffmpeg_web1_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  run_elapsed=$(( $(date +%s) - run_started_ts ))

  # Si Pluto termina muy rápido, forzamos refresco de URL para el siguiente ciclo.
  if [[ "$SRC_URL" == https://pluto.tv/*/live-tv/* || "$SRC_URL" =~ ^https://cfd-v4-service-channel-stitcher-[^/]+/v2/stitch/hls/channel/[a-f0-9]{24}(livestitch)?/ ]] && [ "$run_elapsed" -lt "$MIN_GOOD_RUN_SECONDS" ]; then
    SHORT_FAIL_STREAK=$((SHORT_FAIL_STREAK + 1))
    CACHED_INPUT_URL=""
  else
    SHORT_FAIL_STREAK=0
  fi

  if [ "$SHORT_FAIL_STREAK" -ge "$REFRESH_SHORT_FAIL_STREAK" ] && [ -n "$CONFIG_WATCH_URL" ]; then
    echo "[ffmpeg_web1_proxy] Detectados $SHORT_FAIL_STREAK cortes cortos consecutivos; forzando refresh desde URL watch." >&2
    SRC_URL="$CONFIG_WATCH_URL"
    CACHED_INPUT_URL=""
    SHORT_FAIL_STREAK=0
  fi
  set -e

  echo "[ffmpeg_web1_proxy] ffmpeg salió con código $rc tras ${run_elapsed}s. Reintentando en 1 segundo..." >&2
  sleep 1
done
