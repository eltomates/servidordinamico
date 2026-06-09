#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV (canal web7) a un HLS local servido por Apache.
# Entrada:  https://jmp2.uk/plu-646cce4d1593940008a33f09.m3u8
# Salida:   /var/www/html/hls/web7/index.m3u8 (accesible como /hls/web7/index.m3u8)

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
  CONFIG_SRC_URL="${WEB7_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB7_URL:-}"
fi

OUT="${OUT:-/var/www/html/hls/web7}"
SRC_URL="${SRC_URL:-${CONFIG_SRC_URL:-https://www.canela.tv/player/channel/canela-cinema2}}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-30}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-120}"

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
    echo "[ffmpeg_web7_proxy] No se encontró un token Plex reutilizable para resolver $source_url" >&2
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
    echo "[ffmpeg_web7_proxy] No se encontró el stream HLS asociado a $source_url" >&2
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

  playlist_text="$(curl -fsSL --connect-timeout 15 --max-time 30 "$master_url" | tr -d '\r')" || return 1

  best_variant="$(printf '%s\n' "$playlist_text" | awk '
    /^#EXT-X-STREAM-INF:/ {
      bw = 0
      count = split($0, attrs, ",")

      for (i = 1; i <= count; i++) {
        if (attrs[i] ~ /AVERAGE-BANDWIDTH=/) {
          sub(/.*AVERAGE-BANDWIDTH=/, "", attrs[i])
          bw = attrs[i] + 0
        } else if (bw == 0 && attrs[i] ~ /BANDWIDTH=/) {
          sub(/.*BANDWIDTH=/, "", attrs[i])
          bw = attrs[i] + 0
        }
      }

      if (getline uri_line > 0 && uri_line !~ /^#/) {
        if (bw >= best_bw) {
          best_bw = bw
          best_uri = uri_line
        }
      }
    }
    END {
      if (best_uri != "") {
        print best_uri
      }
    }
  ')"

  if [ -z "$best_variant" ]; then
    return 1
  fi

  build_absolute_url "$master_url" "$best_variant"
}

url_has_video_stream() {
  local test_url="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    return 0
  fi

  timeout 8 ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

resolve_source_url() {
  local source_url="$1"
  local candidate_url=""
  local original_candidate_url=""
  local skip_variant_selection=0
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_vix_chromium.py"
  local pluto_resolver="$SCRIPT_DIR/bin/resolve_pluto_chromium.py"
  local chromium_output=""
  local base_part=""
  local query_part=""

  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*)
      resolve_plex_watch_url "$source_url" || return 1
      return 0
      ;;
    https://pluto.tv/*/live-tv/*)
      if [ -f "$pluto_resolver" ] && command -v python3 >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
          chromium_output="$(timeout 30 env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$pluto_resolver" "$source_url" 12 2>&1 || true)"
        else
          chromium_output="$(env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$pluto_resolver" "$source_url" 12 2>&1 || true)"
        fi

        candidate_url="$(printf '%s\n' "$chromium_output" | awk '/^https?:\/\//{u=$0} END{print u}')"
        if [ -n "$candidate_url" ] && printf '%s' "$candidate_url" | grep -Eq '^https?://'; then
          printf '%s\n' "$candidate_url"
          return 0
        fi
      fi

      echo "[ffmpeg_web7_proxy] No se pudo resolver Pluto desde $source_url" >&2
      return 1
      ;;
    https://www.canela.tv/*|https://canela.tv/*)
      if [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
          chromium_output="$(timeout 120 python3 "$chromium_resolver" "$source_url" 30 2>&1 || true)"
        else
          chromium_output="$(python3 "$chromium_resolver" "$source_url" 30 2>&1 || true)"
        fi

        candidate_url="$(printf '%s\n' "$chromium_output" | awk '/^https?:\/\//{u=$0} END{print u}')"
        if [ -z "$candidate_url" ]; then
          candidate_url="$(printf '%s\n' "$chromium_output" | grep -Eo 'https?://[^[:space:]]+' | grep -E 'content\.m3u8([?][^[:space:]]*)?$' | tail -n1 || true)"
        fi
        if [ -z "$candidate_url" ]; then
          candidate_url="$(printf '%s\n' "$chromium_output" | grep -Eo 'https?://[^[:space:]]+' | grep -E '\.m3u8([?][^[:space:]]*)?$' | tail -n1 || true)"
        fi

        if [[ "$candidate_url" == *"/default_"*"/media.m3u8"* ]]; then
          base_part="${candidate_url%%/default_*}"
          query_part=""
          if [[ "$candidate_url" == *\?* ]]; then
            query_part="?${candidate_url#*\?}"
          fi
          candidate_url="${base_part}/content.m3u8${query_part}"
          echo "[ffmpeg_web7_proxy] Normalizada variante default_* a manifest content.m3u8" >&2
        fi

        if [[ "$candidate_url" == *"/content.m3u8"* ]]; then
          skip_variant_selection=1
        fi
      fi
      ;;
    *)
      candidate_url="$source_url"
      ;;
  esac

  if [ -z "$candidate_url" ]; then
    candidate_url="$source_url"
  fi

  original_candidate_url="$candidate_url"

  if [ "$skip_variant_selection" -ne 1 ] && best_variant_url="$(select_best_hls_variant "$candidate_url" 2>/dev/null)"; then
    candidate_url="$best_variant_url"
    echo "[ffmpeg_web7_proxy] Variante HLS seleccionada: $candidate_url" >&2

    if ! url_has_video_stream "$candidate_url"; then
      echo "[ffmpeg_web7_proxy] Variante seleccionada no tiene video; usando manifest original." >&2
      candidate_url="$original_candidate_url"
    fi
  fi

  printf '%s\n' "$candidate_url"
}

# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"
  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    set -e
    echo "[ffmpeg_web7_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
    sleep 5
    continue
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web7_proxy] URL fuente resuelta a stream HLS directo." >&2
  fi

  ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -rw_timeout 15000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -fflags +genpts+discardcorrupt \
    -err_detect ignore_err \
    -user_agent "$USER_AGENT" \
    -i "$INPUT_URL" \
    -map 0:v:0 \
    -map 0:a:0? \
    -vf "scale=-2:720:flags=lanczos" \
    -c:v libx264 \
    -preset veryfast \
    -tune zerolatency \
    -profile:v high \
    -level 4.0 \
    -b:v 2500k \
    -maxrate 3200k \
    -bufsize 6400k \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
    -af "aresample=async=1:first_pts=0" \
    -f hls \
    -hls_time 6 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_filename "$OUT/seg_%06d.ts" \
    "$OUT/index.m3u8" &

  ffmpeg_pid=$!

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
      echo "[ffmpeg_web7_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web7_proxy] ffmpeg salio con codigo $rc. Reintentando en 5 segundos..." >&2
  sleep 5
done
