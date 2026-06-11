#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV (canal web4) a un HLS local servido por Apache.
# Entrada:  https://jmp2.uk/plu-646cce4d1593940008a33f09.m3u8
# Salida:   /var/www/html/hls/web4/index.m3u8 (accesible como /hls/web4/index.m3u8)

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
  CONFIG_SRC_URL="${WEB4_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB4_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web4}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-https://www.canela.tv/player/channel/canela-clasicos}}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"
HTTP_REFERER="${HTTP_REFERER:-https://www.canela.tv/}"
HTTP_ORIGIN="${HTTP_ORIGIN:-https://www.canela.tv}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-30}"
HLS_TIME="${HLS_TIME:-4}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-45}"
FORCE_RESTART_SECONDS="${FORCE_RESTART_SECONDS:-0}"
WEB4_CANELA_DIRECT_AV="${WEB4_CANELA_DIRECT_AV:-1}"
WEB4_CANELA_DIRECT_RESOLUTION="${WEB4_CANELA_DIRECT_RESOLUTION:-1280x720}"
WEB4_BROWSER_RESTREAM="${WEB4_BROWSER_RESTREAM:-1}"
WEB4_BROWSER_WIDTH="${WEB4_BROWSER_WIDTH:-1280}"
WEB4_BROWSER_HEIGHT="${WEB4_BROWSER_HEIGHT:-720}"
WEB4_BROWSER_FPS="${WEB4_BROWSER_FPS:-30}"
WEB4_BROWSER_SESSION_SECONDS="${WEB4_BROWSER_SESSION_SECONDS:-0}"
WEB4_BROWSER_CAPTURE_TOP="${WEB4_BROWSER_CAPTURE_TOP:-0}"
WEB4_BROWSER_CAPTURE_LEFT="${WEB4_BROWSER_CAPTURE_LEFT:-0}"
WEB4_BROWSER_TRIM_TOP="${WEB4_BROWSER_TRIM_TOP:-160}"

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
    echo "[ffmpeg_web4_proxy] No se encontró un token Plex reutilizable para resolver $source_url" >&2
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

title_patterns = [
  r'Azteca Internacional\\",\\"channelId\\":\\"(?P<id>[^\\"]+)',
  r'favoriteChannel.*?Azteca%20Internacional.*?/favorites/(?P<id>[^?\\]+)',
]

for pattern in title_patterns:
    match = re.search(pattern, html, re.S)
    if match:
        value = match.groupdict().get('id')
        if value:
            print(f'library/parts/{value}.m3u8')
            raise SystemExit(0)

raise SystemExit(1)
PY
  )" || true
  if [ -z "$part_path" ]; then
    echo "[ffmpeg_web4_proxy] No se encontró el stream HLS asociado a $source_url" >&2
    return 1
  fi

  printf 'https://epg.provider.plex.tv/%s?%s\n' "$part_path" "$query_template"
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
  local playlist_text=""
  local best_variant=""
  local any_variant=""
  local variant_playlist=""
  local first_segment=""
  local first_segment_url=""
  local segment_probe_size=""

  playlist_text="$(curl -fsSL --connect-timeout 15 --max-time 30 "$master_url" | tr -d '\r')" || return 1

  best_variant="$(printf '%s\n' "$playlist_text" | awk '
    function get_bandwidth(attrs, count,   i, bw) {
      bw = 0
      for (i = 1; i <= count; i++) {
        if (attrs[i] ~ /AVERAGE-BANDWIDTH=/) {
          sub(/.*AVERAGE-BANDWIDTH=/, "", attrs[i])
          bw = attrs[i] + 0
        } else if (bw == 0 && attrs[i] ~ /BANDWIDTH=/) {
          sub(/.*BANDWIDTH=/, "", attrs[i])
          bw = attrs[i] + 0
        }
      }
      return bw
    }

    /^#EXT-X-STREAM-INF:/ {
      count = split($0, attrs, ",")
      bw = get_bandwidth(attrs, count)

      if (getline uri_line > 0 && uri_line !~ /^#/) {
        print bw "\t" uri_line
      }
    }
  ' | sort -nr -k1,1)"

  if [ -z "$best_variant" ]; then
    return 1
  fi

  while IFS=$'\t' read -r bandwidth variant_uri; do
    [ -n "$variant_uri" ] || continue

    variant_url="$(build_absolute_url "$master_url" "$variant_uri")"
    [ -n "$any_variant" ] || any_variant="$variant_url"

    variant_playlist="$(curl -fsSL --connect-timeout 10 --max-time 20 "$variant_url" | tr -d '\r' 2>/dev/null)" || continue

    if printf '%s\n' "$variant_playlist" | grep -q '^#EXT-X-ENDLIST'; then
      continue
    fi

    if printf '%s\n' "$variant_playlist" | grep -q '/beacon/'; then
      continue
    fi

    if ! printf '%s\n' "$variant_playlist" | grep -q '^#EXTINF:'; then
      continue
    fi

    first_segment="$(printf '%s\n' "$variant_playlist" | awk '$0 !~ /^#/ { print; exit }')"
    [ -n "$first_segment" ] || continue

    first_segment_url="$(build_absolute_url "$variant_url" "$first_segment")"
    segment_probe_size="$(curl -fsSL --connect-timeout 8 --max-time 15 --range 0-4095 "$first_segment_url" 2>/dev/null | wc -c | tr -d ' ')"
    if [ -z "$segment_probe_size" ] || [ "$segment_probe_size" -lt 64 ]; then
      continue
    fi

    printf '%s\n' "$variant_url"
    return 0
  done <<< "$best_variant"

  if [ -n "$any_variant" ]; then
    printf '%s\n' "$any_variant"
    return 0
  fi

  return 1
}

select_hls_variant_by_resolution() {
  local master_url="$1"
  local preferred_resolution="$2"
  local playlist_text=""
  local variant_uri=""

  playlist_text="$(curl -fsSL --connect-timeout 15 --max-time 30 "$master_url" | tr -d '\r')" || return 1

  variant_uri="$(printf '%s\n' "$playlist_text" | awk -v preferred="$preferred_resolution" '
    /^#EXT-X-STREAM-INF:/ {
      info=$0
      if (getline uri <= 0) next
      if (info ~ "RESOLUTION=" preferred) {
        print uri
        found=1
        exit
      }
      if (fallback == "") fallback=uri
    }
    END { if (!found && fallback != "") print fallback }
  ')"

  [ -n "$variant_uri" ] || return 1
  build_absolute_url "$master_url" "$variant_uri"
}

resolve_source_url() {
  local source_url="$1"
  local candidate_url=""
  local candidate_json=""
  local parsed_fields=""
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_vix_chromium.py"
  local pluto_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local skip_variant_selection=0

  RESOLVED_REFERER=""
  RESOLVED_USER_AGENT=""
  RESOLVED_COOKIE=""

  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*)
      resolve_plex_watch_url "$source_url" || return 1
      return 0
      ;;
    https://www.canela.tv/*|https://canela.tv/*)
      if [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
        candidate_json="$(VIX_OUTPUT=json python3 "$chromium_resolver" "$source_url" 30 2>/dev/null | tail -n1)"
        if [ -n "$candidate_json" ]; then
          parsed_fields="$(python3 - "$candidate_json" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

stream = str(data.get("stream_url", "")).replace("\n", " ")
referer = str(data.get("referer", "")).replace("\n", " ")
ua = str(data.get("user_agent", "")).replace("\n", " ")
cookie = str(data.get("cookie", "")).replace("\n", " ")
print("\t".join([stream, referer, ua, cookie]))
PY
          )"

          if [ -n "$parsed_fields" ]; then
            IFS=$'\t' read -r candidate_url RESOLVED_REFERER RESOLVED_USER_AGENT RESOLVED_COOKIE <<< "$parsed_fields"
          fi
        fi

        if [ -z "$candidate_url" ]; then
          candidate_url="$(python3 "$chromium_resolver" "$source_url" 30 2>/dev/null | tail -n1)"
        fi

        if [ "$WEB4_CANELA_DIRECT_AV" = "1" ]; then
          skip_variant_selection=1
          if direct_variant_url="$(select_hls_variant_by_resolution "$candidate_url" "$WEB4_CANELA_DIRECT_RESOLUTION" 2>/dev/null)"; then
            candidate_url="$direct_variant_url"
            echo "[ffmpeg_web4_proxy] Variante Canela AV seleccionada: $candidate_url" >&2
          fi
        else
          skip_variant_selection=1
        fi
      fi
      ;;
    https://pluto.tv/*|https://*.pluto.tv/*)
      if [ -f "$pluto_resolver" ] && command -v python3 >/dev/null 2>&1; then
        candidate_url="$(python3 "$pluto_resolver" "$source_url" 20 2>/dev/null | tail -n1)"
      fi
      ;;
    *)
      candidate_url="$source_url"
      ;;
  esac

  if [ -z "$candidate_url" ]; then
    candidate_url="$source_url"
  fi

  if [ "$skip_variant_selection" -ne 1 ]; then
    if best_variant_url="$(select_best_hls_variant "$candidate_url" 2>/dev/null)"; then
      candidate_url="$best_variant_url"
      echo "[ffmpeg_web4_proxy] Variante HLS seleccionada: $candidate_url" >&2
    fi
  fi

  printf '%s\n' "$candidate_url"
}

should_use_browser_restream() {
  local source_url="$1"

  if [ "$WEB4_CANELA_DIRECT_AV" = "1" ]; then
    case "$source_url" in
      https://www.canela.tv/*|https://canela.tv/*)
        return 1
        ;;
    esac
  fi

  if [ "$WEB4_BROWSER_RESTREAM" != "1" ]; then
    return 1
  fi

  case "$source_url" in
    https://www.canela.tv/*|https://canela.tv/*)
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
  local browser_screen_height=$((WEB4_BROWSER_HEIGHT + WEB4_BROWSER_TRIM_TOP))

  xvfb-run -a \
    --server-args="-screen 0 ${WEB4_BROWSER_WIDTH}x${browser_screen_height}x24 -ac +extension RANDR" \
    bash "$browser_runner" \
      "$SRC_URL" \
      "$OUT" \
      "$HLS_TIME" \
      "$HLS_LIST_SIZE" \
      "$start_number" \
      "$WEB4_BROWSER_WIDTH" \
      "$WEB4_BROWSER_HEIGHT" \
      "$WEB4_BROWSER_FPS" \
      "$WEB4_BROWSER_SESSION_SECONDS" \
      "$USER_AGENT" \
      "$WEB4_BROWSER_CAPTURE_TOP" \
      "$WEB4_BROWSER_CAPTURE_LEFT" \
      "$browser_screen_height" \
      "$WEB4_BROWSER_TRIM_TOP"
}

# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"

  if should_use_browser_restream "$SRC_URL"; then
    echo "[ffmpeg_web4_proxy] Usando browser-restream real para Canela." >&2
    run_browser_restream_session "$START_NUMBER"
    rc=$?
    set -e
    echo "[ffmpeg_web4_proxy] browser-restream salio con codigo $rc. Reintentando en 5 segundos..." >&2
    sleep 5
    continue
  fi

  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    set -e
    echo "[ffmpeg_web4_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
    sleep 5
    continue
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web4_proxy] URL fuente resuelta a stream HLS directo." >&2
  fi

  INPUT_REFERER="$HTTP_REFERER"
  INPUT_USER_AGENT="$USER_AGENT"
  INPUT_HEADERS=""

  if [ -n "${RESOLVED_USER_AGENT:-}" ]; then
    INPUT_USER_AGENT="$RESOLVED_USER_AGENT"
  fi

  if [ -n "${RESOLVED_REFERER:-}" ]; then
    INPUT_REFERER="$RESOLVED_REFERER"
  fi

  if [ -n "${RESOLVED_COOKIE:-}" ]; then
    INPUT_HEADERS="Cookie: $RESOLVED_COOKIE"
  fi

  case "$SRC_URL" in
    https://pluto.tv/*|https://*.pluto.tv/*)
      INPUT_REFERER="https://pluto.tv/"
      ;;
    https://www.canela.tv/*|https://canela.tv/*)
      if [ -z "${RESOLVED_REFERER:-}" ]; then
        INPUT_REFERER="https://www.canela.tv/player/channel/canela-clasicos"
      fi
      ;;
  esac

  EXTRA_HEADERS_ARGS=()
  if [ -n "$INPUT_HEADERS" ]; then
    EXTRA_HEADERS_ARGS=(-headers "$INPUT_HEADERS")
  fi

  INPUT_RATE_ARGS=()
  INPUT_HLS_ARGS=(-extension_picky 0 -allowed_extensions ALL -allowed_segment_extensions ALL -rw_timeout 15000000)
  INPUT_RECONNECT_ARGS=(
    -reconnect 1
    -reconnect_at_eof 1
    -reconnect_streamed 1
    -reconnect_on_network_error 1
    -reconnect_on_http_error 4xx,5xx
    -reconnect_delay_max 10
    -http_persistent 0
  )

  case "$SRC_URL" in
    https://www.canela.tv/*|https://canela.tv/*)
      if [ "$WEB4_CANELA_DIRECT_AV" = "1" ]; then
        INPUT_RATE_ARGS=(-re)
        INPUT_HLS_ARGS=(-extension_picky 0 -allowed_extensions ALL -allowed_segment_extensions ALL -rw_timeout 15000000)
        INPUT_RECONNECT_ARGS=()
      fi
      ;;
  esac

  ffmpeg \
    -loglevel info \
    "${INPUT_RATE_ARGS[@]}" \
    "${INPUT_HLS_ARGS[@]}" \
    "${INPUT_RECONNECT_ARGS[@]}" \
    -fflags +genpts+discardcorrupt \
    -err_detect ignore_err \
    -referer "$INPUT_REFERER" \
    -user_agent "$INPUT_USER_AGENT" \
    "${EXTRA_HEADERS_ARGS[@]}" \
    -i "$INPUT_URL" \
    -map 0:v:0 \
    -map 0:a:0 \
    -vf "scale=-2:720:flags=bicubic" \
    -c:v libx264 \
    -preset superfast \
    -tune zerolatency \
    -profile:v high \
    -level 4.0 \
    -b:v 2500k \
    -maxrate 3200k \
    -bufsize 6400k \
    -fps_mode:v cfr \
    -max_muxing_queue_size 2048 \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -af "aresample=async=1:first_pts=0" \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_delete_threshold 2 \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+independent_segments+temp_file+omit_endlist \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!
  ffmpeg_started_ts="$(date +%s)"

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
      echo "[ffmpeg_web4_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi

    if [ "$FORCE_RESTART_SECONDS" -gt 0 ]; then
      runtime_seconds=$(( now_ts - ffmpeg_started_ts ))
      if [ "$runtime_seconds" -ge "$FORCE_RESTART_SECONDS" ]; then
        echo "[ffmpeg_web4_proxy] Reinicio preventivo tras $runtime_seconds s para refrescar URL/tokens ($ffmpeg_pid)" >&2
        kill "$ffmpeg_pid" 2>/dev/null
        sleep 2
        break
      fi
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web4_proxy] ffmpeg salio con codigo $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
