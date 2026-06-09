#!/usr/bin/env bash

# Proxy HLS de prueba para web16.
# Este canal esta preparado para pruebas con ViX y lectura de credenciales locales.
# Salida: /var/www/html/hls/web16/index.m3u8

set -e
umask 000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/var/www/html/scripts/lib_web_hls.sh
. "$SCRIPT_DIR/lib_web_hls.sh"
acquire_single_instance_lock "${BASH_SOURCE[0]}" || exit 0

PRIMARY_CONFIG="/var/www/html/logs/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"
AUTH_FILE_DEFAULT="/var/www/html/logs/web16_auth.env"
CONFIG_SRC_URL=""
CONFIG_RESOLVED_URL=""

if [ -f "$PRIMARY_CONFIG" ]; then
  # shellcheck source=/var/www/html/logs/web_sources.env
  . "$PRIMARY_CONFIG"
  CONFIG_SRC_URL="${WEB16_URL:-}"
  CONFIG_RESOLVED_URL="${WEB16_RESOLVED_URL:-}"
elif [ -f "$LEGACY_CONFIG" ]; then
  # shellcheck source=/var/www/html/scripts/web_sources.env
  . "$LEGACY_CONFIG"
  CONFIG_SRC_URL="${WEB16_URL:-}"
  CONFIG_RESOLVED_URL="${WEB16_RESOLVED_URL:-}"
fi

AUTH_FILE="${WEB16_AUTH_FILE:-$AUTH_FILE_DEFAULT}"
if [ -f "$AUTH_FILE" ]; then
  # shellcheck source=/var/www/html/logs/web16_auth.env
  . "$AUTH_FILE"
fi

OUT="${OUT:-/var/www/html/hls/web16}"
# Si existe una URL resuelta (m3u8 final), se prioriza para pruebas.
SRC_URL="${SRC_URL:-${CONFIG_RESOLVED_URL:-${CONFIG_SRC_URL:-https://vix.com/es-es/canales/premium/channel-callsign-NU9VE}}}"
KEEP_SEGMENTS="${KEEP_SEGMENTS:-20}"
HLS_LIST_SIZE="${HLS_LIST_SIZE:-30}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-120}"
DEFAULT_USER_AGENT="${FFMPEG_USER_AGENT:-Mozilla/5.0}"
USE_CHROMIUM_RESOLVER="${USE_CHROMIUM_RESOLVER:-1}"
VIX_CHROMIUM_TIMEOUT_SECONDS="${VIX_CHROMIUM_TIMEOUT_SECONDS:-30}"
VIX_CHROMIUM_HARD_TIMEOUT_SECONDS="${VIX_CHROMIUM_HARD_TIMEOUT_SECONDS:-90}"
PW_HEADLESS="${PW_HEADLESS:-1}"

resolve_vix_source_url() {
  local page_url="$1"
  local chromium_resolver="$SCRIPT_DIR/bin/resolve_vix_chromium.py"
  local chromium_url=""
  local chromium_output=""
  local chromium_timeout_cmd=( )

  if command -v timeout >/dev/null 2>&1; then
    chromium_timeout_cmd=(timeout "$VIX_CHROMIUM_HARD_TIMEOUT_SECONDS")
  fi

  if [ "$USE_CHROMIUM_RESOLVER" = "1" ] && [ -f "$chromium_resolver" ] && command -v python3 >/dev/null 2>&1; then
    chromium_output="$({
      export PW_HEADLESS
      export VIX_USER="${WEB16_USER:-${WEB16_USERNAME:-}}"
      export VIX_PASSWORD="${WEB16_PASSWORD:-}"
      "${chromium_timeout_cmd[@]}" python3 "$chromium_resolver" "$page_url" "$VIX_CHROMIUM_TIMEOUT_SECONDS" 2>&1 || true
    } 9>&-)"

    chromium_url="$(printf '%s\n' "$chromium_output" | tail -n1)"

    if [ -n "$chromium_output" ]; then
      printf '%s\n' "$chromium_output" | sed 's/^/[ffmpeg_web16_proxy][resolver] /' >&2
    fi

    if [ -n "$chromium_url" ] && printf '%s' "$chromium_url" | grep -Eq '^https?://'; then
      printf '%s\n' "$chromium_url"
      return 0
    fi
  fi

  return 1
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

resolve_source_url() {
  local src_url="$1"
  local candidate_url=""

  case "$src_url" in
    https://vix.com/*)
      resolve_vix_source_url "$src_url" || return 1
      ;;
    *)
      candidate_url="$src_url"
      ;;
  esac

  if [ -z "$candidate_url" ]; then
    return 1
  fi

  if best_variant_url="$(select_best_hls_variant "$candidate_url" 2>/dev/null)"; then
    candidate_url="$best_variant_url"
    echo "[ffmpeg_web16_proxy] Variante HLS seleccionada: $candidate_url" >&2
  fi

  printf '%s\n' "$candidate_url"
}

mkdir -p "$OUT"

if [ -n "${WEB16_USER:-}" ] || [ -n "${WEB16_USERNAME:-}" ]; then
  echo "[ffmpeg_web16_proxy] Credenciales de web16 cargadas desde archivo local." >&2
fi

while true; do
  set +e

  resolved_url="$SRC_URL"
  if ! resolved_url="$(resolve_source_url "$SRC_URL")"; then
    echo "[ffmpeg_web16_proxy] No se pudo resolver URL para web16. Reintentando en 15 segundos..." >&2
    set -e
    sleep 15
    continue
  fi

  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  START_NUMBER="$(date +%s)"

  ffmpeg \
    -loglevel info \
    -extension_picky 0 \
    -rw_timeout 15000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -fflags +discardcorrupt+genpts \
    -err_detect ignore_err \
    -user_agent "$DEFAULT_USER_AGENT" \
    -i "$resolved_url" \
    -map 0:v:0? \
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
    -max_muxing_queue_size 2048 \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -ac 2 \
    -b:a 128k \
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
      echo "[ffmpeg_web16_proxy] index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      kill "$ffmpeg_pid" 2>/dev/null
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  set -e

  echo "[ffmpeg_web16_proxy] ffmpeg salio con codigo $rc. Reintentando en 10 segundos..." >&2
  sleep 10
done
