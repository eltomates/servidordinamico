#!/usr/bin/env bash

# Proxy HLS desde una URL remota IPTV (canal web7) a un HLS local servido por Apache.
# Entrada:  https://jmp2.uk/plu-5dcb62e63d4d8f0009f36881.m3u8
# Salida:   /var/www/html/hls/web7/index.m3u8 (master HLS accesible como /hls/web7/index.m3u8)

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
HLS_LIST_SIZE="${HLS_LIST_SIZE:-10}"
HLS_TIME="${HLS_TIME:-4}"
WEB7_TARGET_BANDWIDTH="${WEB7_TARGET_BANDWIDTH:-1200000}"
MAX_STALE_SECONDS="${MAX_STALE_SECONDS:-18}"
WEB7_STALE_CHECK_INTERVAL="${WEB7_STALE_CHECK_INTERVAL:-5}"
WEB7_BROWSER_RESTREAM="${WEB7_BROWSER_RESTREAM:-0}"
WEB7_PLUTO_DIRECT_HLS="${WEB7_PLUTO_DIRECT_HLS:-0}"
WEB7_PLUTO_DIRECT_MODE="${WEB7_PLUTO_DIRECT_MODE:-pair}"
WEB7_PLUTO_RESOLVE_SECONDS="${WEB7_PLUTO_RESOLVE_SECONDS:-20}"
WEB7_BROWSER_WIDTH="${WEB7_BROWSER_WIDTH:-960}"
WEB7_BROWSER_HEIGHT="${WEB7_BROWSER_HEIGHT:-540}"
WEB7_BROWSER_FPS="${WEB7_BROWSER_FPS:-25}"
WEB7_BROWSER_360_FPS="${WEB7_BROWSER_360_FPS:-20}"
WEB7_BROWSER_180_FPS="${WEB7_BROWSER_180_FPS:-15}"
WEB7_BROWSER_SESSION_SECONDS="${WEB7_BROWSER_SESSION_SECONDS:-0}"
WEB7_BROWSER_CAPTURE_TOP="${WEB7_BROWSER_CAPTURE_TOP:-0}"
WEB7_BROWSER_CAPTURE_LEFT="${WEB7_BROWSER_CAPTURE_LEFT:-0}"
WEB7_BROWSER_TRIM_TOP="${WEB7_BROWSER_TRIM_TOP:-86}"
WEB7_BROWSER_AUDIO_MODE="${WEB7_BROWSER_AUDIO_MODE:-browser-fifo}"
WEB7_BROWSER_AUDIO_DELAY_MS="${WEB7_BROWSER_AUDIO_DELAY_MS:-0}"
WEB7_BROWSER_VIDEO_DELAY_MS="${WEB7_BROWSER_VIDEO_DELAY_MS:-400}"
WEB7_BROWSER_ALSA_OUTPUT_DEVICE="${WEB7_BROWSER_ALSA_OUTPUT_DEVICE:-browser_fifo}"
WEB7_BROWSER_FIFO_ID="${WEB7_BROWSER_FIFO_ID:-web7}"
WEB7_BROWSER_BOOT_SECONDS="${WEB7_BROWSER_BOOT_SECONDS:-1}"
WEB7_BROWSER_LIGHT_TRIGGER_SECONDS="${WEB7_BROWSER_LIGHT_TRIGGER_SECONDS:-600}"
WEB7_BROWSER_LIGHT_HOLD_SECONDS="${WEB7_BROWSER_LIGHT_HOLD_SECONDS:-1200}"
WEB7_BROWSER_LIGHT_AFTER_FAILURES="${WEB7_BROWSER_LIGHT_AFTER_FAILURES:-1}"
WEB7_BROWSER_LIGHT_STATE_FILE="${WEB7_BROWSER_LIGHT_STATE_FILE:-/var/www/html/logs/web7_light_mode.state}"
WEB7_BROWSER_LIGHT_WIDTH="${WEB7_BROWSER_LIGHT_WIDTH:-854}"
WEB7_BROWSER_LIGHT_HEIGHT="${WEB7_BROWSER_LIGHT_HEIGHT:-480}"
WEB7_BROWSER_LIGHT_FPS="${WEB7_BROWSER_LIGHT_FPS:-20}"
WEB7_BROWSER_LIGHT_360_FPS="${WEB7_BROWSER_LIGHT_360_FPS:-15}"
WEB7_BROWSER_LIGHT_180_FPS="${WEB7_BROWSER_LIGHT_180_FPS:-12}"
WEB7_BROWSER_LIGHT_480_BITRATE="${WEB7_BROWSER_LIGHT_480_BITRATE:-650k}"
WEB7_BROWSER_LIGHT_480_MAXRATE="${WEB7_BROWSER_LIGHT_480_MAXRATE:-780k}"
WEB7_BROWSER_LIGHT_480_BUFSIZE="${WEB7_BROWSER_LIGHT_480_BUFSIZE:-1600k}"
WEB7_BROWSER_LIGHT_360_BITRATE="${WEB7_BROWSER_LIGHT_360_BITRATE:-420k}"
WEB7_BROWSER_LIGHT_360_MAXRATE="${WEB7_BROWSER_LIGHT_360_MAXRATE:-520k}"
WEB7_BROWSER_LIGHT_360_BUFSIZE="${WEB7_BROWSER_LIGHT_360_BUFSIZE:-1100k}"
WEB7_BROWSER_LIGHT_180_BITRATE="${WEB7_BROWSER_LIGHT_180_BITRATE:-220k}"
WEB7_BROWSER_LIGHT_180_MAXRATE="${WEB7_BROWSER_LIGHT_180_MAXRATE:-300k}"
WEB7_BROWSER_LIGHT_180_BUFSIZE="${WEB7_BROWSER_LIGHT_180_BUFSIZE:-700k}"
MAX_SEGMENT_REPEAT_SECONDS="${MAX_SEGMENT_REPEAT_SECONDS:-30}"
AUTO_REPAIR_ENABLED="${AUTO_REPAIR_ENABLED:-1}"
AUTO_REPAIR_MAX_RESTARTS="${AUTO_REPAIR_MAX_RESTARTS:-3}"
AUTO_REPAIR_WINDOW_SECONDS="${AUTO_REPAIR_WINDOW_SECONDS:-900}"
AUTO_REPAIR_HEALTHY_RESET_SECONDS="${AUTO_REPAIR_HEALTHY_RESET_SECONDS:-600}"
AUTO_REPAIR_BACKOFF_SECONDS="${AUTO_REPAIR_BACKOFF_SECONDS:-6}"
AUTO_REPAIR_ALARM_SCRIPT="${AUTO_REPAIR_ALARM_SCRIPT:-$SCRIPT_DIR/web_channel_alarm.sh}"


mkdir -p "$OUT" "$OUT/480p" "$OUT/360p" "$OUT/180p"

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

pluto_master_from_variant() {
  local playlist_url="$1"

  case "$playlist_url" in
    *"/v2/stitch/hls/channel/"*"/playlist.m3u8"*|*"/v2/stitch/hls/channel/"*"/master.m3u8"*)
      printf "%s\n" "$playlist_url" | sed -E "s#/v2/stitch/hls/channel/([^/?]+)/[0-9]+/playlist\.m3u8#/v2/stitch/hls/channel/\1/master.m3u8#"
      ;;
    *)
      return 1
      ;;
  esac
}

pluto_audio_from_variant() {
  local playlist_url="$1"

  case "$playlist_url" in
    *"/v2/stitch/hls/channel/"*"/playlist.m3u8"*|*"/v2/stitch/hls/channel/"*"/master.m3u8"*)
      printf "%s\n" "$playlist_url" | sed -E "s#/v2/stitch/hls/channel/([^/?]+)/(master|[0-9]+/playlist)\.m3u8#/v2/stitch/hls/channel/\1/audio/audio/English/audio.m3u8#"
      ;;
    *)
      return 1
      ;;
  esac
}

select_best_hls_variant() {
  local master_url="$1"
  local playlist_text=""
  local best_variant=""

  playlist_text="$(curl -fsSL --connect-timeout 15 --max-time 30 "$master_url" | tr -d '\r')" || return 1

  best_variant="$(printf '%s\n' "$playlist_text" | awk -v target="$WEB7_TARGET_BANDWIDTH" '
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
        score = bw - target
        if (score < 0) score = -score
        if (best_uri == "" || score < best_score) {
          best_score = score
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
  local master_candidate=""
  local variant_candidate=""

  case "$source_url" in
    *watch.plex.tv/*/live-tv/channel/*|*watch.plex.tv/live-tv/channel/*)
      resolve_plex_watch_url "$source_url" || return 1
      return 0
      ;;
    https://pluto.tv/*/live-tv/*)
      if [ -f "$pluto_resolver" ] && command -v python3 >/dev/null 2>&1; then
        if [ "$WEB7_PLUTO_DIRECT_HLS" = "1" ]; then
          if [ "$WEB7_PLUTO_DIRECT_MODE" = "master" ]; then
            skip_variant_selection=1
            if command -v timeout >/dev/null 2>&1; then
              chromium_output="$({ timeout 60 env PW_HEADLESS=1 PLUTO_PREFER_MASTER=1 PLUTO_TARGET_BANDWIDTH="$WEB7_TARGET_BANDWIDTH" python3 "$pluto_resolver" "$source_url" "$WEB7_PLUTO_RESOLVE_SECONDS" 2>&1 || true; } 9>&-)"
            else
              chromium_output="$({ env PW_HEADLESS=1 PLUTO_PREFER_MASTER=1 PLUTO_TARGET_BANDWIDTH="$WEB7_TARGET_BANDWIDTH" python3 "$pluto_resolver" "$source_url" "$WEB7_PLUTO_RESOLVE_SECONDS" 2>&1 || true; } 9>&-)"
            fi
          else
            skip_variant_selection=0
            if command -v timeout >/dev/null 2>&1; then
              chromium_output="$({ timeout 45 env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 PLUTO_TARGET_BANDWIDTH="$WEB7_TARGET_BANDWIDTH" python3 "$pluto_resolver" "$source_url" "$WEB7_PLUTO_RESOLVE_SECONDS" 2>&1 || true; } 9>&-)"
            else
              chromium_output="$({ env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 PLUTO_TARGET_BANDWIDTH="$WEB7_TARGET_BANDWIDTH" python3 "$pluto_resolver" "$source_url" "$WEB7_PLUTO_RESOLVE_SECONDS" 2>&1 || true; } 9>&-)"
            fi
          fi
        else
        if command -v timeout >/dev/null 2>&1; then
          chromium_output="$({ timeout 45 env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$pluto_resolver" "$source_url" 20 2>&1 || true; } 9>&-)"
        else
          chromium_output="$({ env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$pluto_resolver" "$source_url" 20 2>&1 || true; } 9>&-)"
        fi
        fi

        candidate_url="$(printf '%s\n' "$chromium_output" | awk '/^https?:\/\//{u=$0} END{print u}')"
        if [ -n "$candidate_url" ] && printf '%s' "$candidate_url" | grep -Eq '^https?://'; then
          if [ "$WEB7_PLUTO_DIRECT_HLS" = "1" ] && [ "$WEB7_PLUTO_DIRECT_MODE" = "master" ] && [[ "$candidate_url" != *"/master.m3u8"* ]]; then
            master_candidate="$(pluto_master_from_variant "$candidate_url" 2>/dev/null || true)"
            if [ -n "$master_candidate" ]; then
              candidate_url="$master_candidate"
              echo "[ffmpeg_web7_proxy] Normalizada variante Pluto a master.m3u8 para conservar audio/video juntos." >&2
            fi
          fi
          if [ "$WEB7_PLUTO_DIRECT_HLS" = "1" ] && [ "$WEB7_PLUTO_DIRECT_MODE" = "pair" ] && [[ "$candidate_url" == *"/master.m3u8"* ]]; then
            variant_candidate="$(select_best_hls_variant "$candidate_url" 2>/dev/null || true)"
            if [ -n "$variant_candidate" ]; then
              candidate_url="$variant_candidate"
              echo "[ffmpeg_web7_proxy] Pluto HLS pair: variante seleccionada desde master." >&2
            fi
          fi
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
    *jmp2.uk/plu-*.m3u8*)
      candidate_url="$source_url"
      skip_variant_selection=1
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


stop_ffmpeg() {
  local pid="$1"
  local i

  kill "$pid" 2>/dev/null || return 0
  for i in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo "[ffmpeg_web7_proxy] ffmpeg no terminó con SIGTERM; enviando SIGKILL ($pid)" >&2
  kill -9 "$pid" 2>/dev/null || true
}

auto_repair_send_alarm() {
  local level="$1"
  local message="$2"

  if [ -x "$AUTO_REPAIR_ALARM_SCRIPT" ]; then
    bash "$AUTO_REPAIR_ALARM_SCRIPT" web7 "$level" "$message" >/dev/null 2>&1 || true
  fi
}

auto_repair_cleanup_artifacts() {
  find "$OUT" -maxdepth 2 -type f -name "*.tmp" -delete 2>/dev/null || true
  find "$OUT" -maxdepth 2 -type f -name "seg_*.ts" -size 0 -delete 2>/dev/null || true
}

auto_repair_after_ffmpeg_exit() {
  local reason="$1"
  local rc="$2"
  local run_seconds="$3"
  local now_ts

  if [ "$AUTO_REPAIR_ENABLED" != "1" ]; then
    sleep 5
    return 0
  fi

  now_ts="$(date +%s)"

  if [ "$reason" = "ffmpeg salio" ] && [ "$run_seconds" -ge "$AUTO_REPAIR_HEALTHY_RESET_SECONDS" ]; then
    repair_failure_count=0
    repair_window_start_ts=0
    auto_repair_send_alarm "OK" "web7 estable tras ${run_seconds}s; autoreparacion rearmada"
    sleep 5
    return 0
  fi

  if [ "$repair_window_start_ts" -eq 0 ] || [ $(( now_ts - repair_window_start_ts )) -gt "$AUTO_REPAIR_WINDOW_SECONDS" ]; then
    repair_window_start_ts="$now_ts"
    repair_failure_count=0
  fi

  repair_failure_count=$(( repair_failure_count + 1 ))
  echo "[ffmpeg_web7_proxy] Autoreparacion web7: reason=$reason rc=$rc run=${run_seconds}s intento=$repair_failure_count/${AUTO_REPAIR_MAX_RESTARTS}" >&2
  auto_repair_send_alarm "ALARM" "web7 autoreparacion: $reason (intento=$repair_failure_count, rc=$rc, run=${run_seconds}s)"
  auto_repair_cleanup_artifacts

  if [ "$repair_failure_count" -ge "$AUTO_REPAIR_MAX_RESTARTS" ]; then
    repair_failure_count=0
    repair_window_start_ts="$now_ts"
    echo "[ffmpeg_web7_proxy] Autoreparacion escalada: refrescando fuente dentro del servicio" >&2
    auto_repair_send_alarm "ALARM" "web7 autoreparacion escalada: refrescando fuente dentro del servicio"
  fi

  sleep "$AUTO_REPAIR_BACKOFF_SECONDS"
}

should_use_browser_restream() {
  local source_url="$1"

  if [ "$WEB7_BROWSER_RESTREAM" != "1" ]; then
    return 1
  fi

  case "$source_url" in
    https://pluto.tv/*/live-tv/*|https://*.pluto.tv/*/live-tv/*) ;;
    *) return 1 ;;
  esac

  if [ "$WEB7_PLUTO_DIRECT_HLS" = "1" ]; then
    return 1
  fi

  if ! command -v xvfb-run >/dev/null 2>&1; then
    echo "[ffmpeg_web7_proxy] browser-restream no disponible: falta xvfb-run" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[ffmpeg_web7_proxy] browser-restream no disponible: falta python3" >&2
    return 1
  fi

  if [ ! -x "$SCRIPT_DIR/bin/web4_browser_restream_runner.sh" ]; then
    echo "[ffmpeg_web7_proxy] browser-restream no disponible: falta runner" >&2
    return 1
  fi

  return 0
}

read_web7_light_until_ts() {
  local value

  value="$(tail -n1 "$WEB7_BROWSER_LIGHT_STATE_FILE" 2>/dev/null || true)"
  case "$value" in
    ""|*[!0-9]*) printf "0\n" ;;
    *) printf "%s\n" "$value" ;;
  esac
}

write_web7_light_until_ts() {
  local value="$1"

  printf "%s\n" "$value" > "$WEB7_BROWSER_LIGHT_STATE_FILE" 2>/dev/null || true
}

web7_browser_profile() {
  local now_ts light_until_ts

  now_ts="$(date +%s)"
  light_until_ts="$(read_web7_light_until_ts)"
  if [ "$light_until_ts" -gt "$now_ts" ] 2>/dev/null; then
    printf "light\n"
  else
    printf "normal\n"
  fi
}

web7_note_browser_exit() {
  local run_seconds="$1"
  local now_ts light_until_ts

  if [ "$run_seconds" -ge "$WEB7_BROWSER_LIGHT_TRIGGER_SECONDS" ] 2>/dev/null; then
    browser_short_failure_count=0
    return 0
  fi

  browser_short_failure_count=$(( browser_short_failure_count + 1 ))
  echo "[ffmpeg_web7_proxy] browser-restream termino pronto (${run_seconds}s), contador modo ligero=${browser_short_failure_count}/${WEB7_BROWSER_LIGHT_AFTER_FAILURES}" >&2

  if [ "$browser_short_failure_count" -ge "$WEB7_BROWSER_LIGHT_AFTER_FAILURES" ] 2>/dev/null; then
    now_ts="$(date +%s)"
    light_until_ts=$(( now_ts + WEB7_BROWSER_LIGHT_HOLD_SECONDS ))
    write_web7_light_until_ts "$light_until_ts"
    browser_short_failure_count=0
    echo "[ffmpeg_web7_proxy] Activando modo ligero hasta epoch $light_until_ts por reinicio/congelamiento temprano." >&2
    auto_repair_send_alarm "ALARM" "web7 cambio a modo ligero por reinicio/congelamiento temprano (${run_seconds}s)"
  fi
}

run_browser_restream_session() {
  local start_number="$1"
  local profile="${2:-normal}"
  local browser_runner="$SCRIPT_DIR/bin/web4_browser_restream_runner.sh"
  local browser_width="$WEB7_BROWSER_WIDTH"
  local browser_height="$WEB7_BROWSER_HEIGHT"
  local browser_fps="$WEB7_BROWSER_FPS"
  local browser_360_fps="$WEB7_BROWSER_360_FPS"
  local browser_180_fps="$WEB7_BROWSER_180_FPS"
  local browser_gop=100
  local browser_480_bitrate=950k
  local browser_480_maxrate=1100k
  local browser_480_bufsize=2200k
  local browser_360_bitrate=700k
  local browser_360_maxrate=850k
  local browser_360_bufsize=1700k
  local browser_180_bitrate=350k
  local browser_180_maxrate=450k
  local browser_180_bufsize=900k
  local browser_var_stream_map="v:0,a:0,name:480p v:1,a:1,name:360p v:2,a:2,name:180p"
  local browser_screen_height
  local use_direct_audio=0
  local direct_audio_url=""

  if [ "$profile" = "light" ]; then
    browser_width="$WEB7_BROWSER_LIGHT_WIDTH"
    browser_height="$WEB7_BROWSER_LIGHT_HEIGHT"
    browser_fps="$WEB7_BROWSER_LIGHT_FPS"
    browser_360_fps="$WEB7_BROWSER_LIGHT_360_FPS"
    browser_180_fps="$WEB7_BROWSER_LIGHT_180_FPS"
    browser_gop=$(( browser_fps * HLS_TIME ))
    browser_480_bitrate="$WEB7_BROWSER_LIGHT_480_BITRATE"
    browser_480_maxrate="$WEB7_BROWSER_LIGHT_480_MAXRATE"
    browser_480_bufsize="$WEB7_BROWSER_LIGHT_480_BUFSIZE"
    browser_360_bitrate="$WEB7_BROWSER_LIGHT_360_BITRATE"
    browser_360_maxrate="$WEB7_BROWSER_LIGHT_360_MAXRATE"
    browser_360_bufsize="$WEB7_BROWSER_LIGHT_360_BUFSIZE"
    browser_180_bitrate="$WEB7_BROWSER_LIGHT_180_BITRATE"
    browser_180_maxrate="$WEB7_BROWSER_LIGHT_180_MAXRATE"
    browser_180_bufsize="$WEB7_BROWSER_LIGHT_180_BUFSIZE"
    browser_var_stream_map="v:1,a:1,name:360p v:2,a:2,name:180p v:0,a:0,name:480p"
  fi

  browser_screen_height=$(( browser_height + WEB7_BROWSER_TRIM_TOP ))

  case "$WEB7_BROWSER_AUDIO_MODE" in
    direct|hls)
      use_direct_audio=1
      ;;
    *)
      use_direct_audio=0
      ;;
  esac

  if [ "$use_direct_audio" = "1" ]; then
    cached_audio_url=""
    if [ -s /tmp/web7_pluto_audio_url.txt ]; then
      cached_audio_url="$(tail -n1 /tmp/web7_pluto_audio_url.txt 2>/dev/null || true)"
    fi

    case "$cached_audio_url" in
      */audio/audio/*) cached_audio_url="" ;;
    esac

    resolved_audio_url="$(resolve_source_url "$SRC_URL" 2>/dev/null || true)"
    case "$resolved_audio_url" in
      */audio/audio/*) resolved_audio_url="" ;;
    esac

    if [ -n "$resolved_audio_url" ]; then
      direct_audio_url="$resolved_audio_url"
      printf "%s\n" "$direct_audio_url" > /tmp/web7_pluto_audio_url.txt 2>/dev/null || true
    else
      direct_audio_url="$cached_audio_url"
    fi
  fi

  xvfb-run -a \
    --server-args="-screen 0 ${browser_width}x${browser_screen_height}x24 -ac +extension RANDR" \
    env \
      WEB4_MULTI_VARIANT=1 \
      WEB4_MULTI_360_FPS="$browser_360_fps" \
      WEB4_MULTI_180_FPS="$browser_180_fps" \
      WEB4_MULTI_480_BITRATE="$browser_480_bitrate" \
      WEB4_MULTI_480_MAXRATE="$browser_480_maxrate" \
      WEB4_MULTI_480_BUFSIZE="$browser_480_bufsize" \
      WEB4_MULTI_360_BITRATE="$browser_360_bitrate" \
      WEB4_MULTI_360_MAXRATE="$browser_360_maxrate" \
      WEB4_MULTI_360_BUFSIZE="$browser_360_bufsize" \
      WEB4_MULTI_180_BITRATE="$browser_180_bitrate" \
      WEB4_MULTI_180_MAXRATE="$browser_180_maxrate" \
      WEB4_MULTI_180_BUFSIZE="$browser_180_bufsize" \
      WEB4_MULTI_VAR_STREAM_MAP="$browser_var_stream_map" \
      WEB4_USE_DIRECT_AUDIO="$use_direct_audio" \
      WEB4_AUDIO_MODE="$WEB7_BROWSER_AUDIO_MODE" \
      WEB4_BROWSER_ALSA_OUTPUT_DEVICE="$WEB7_BROWSER_ALSA_OUTPUT_DEVICE" \
      WEB4_BROWSER_FIFO_ID="$WEB7_BROWSER_FIFO_ID" \
      WEB4_BROWSER_BOOT_SECONDS="$WEB7_BROWSER_BOOT_SECONDS" \
      WEB4_ALLOW_SILENT_FALLBACK=0 \
      WEB4_AUDIO_GUARD=1 \
      WEB4_AUDIO_GUARD_MAX_BAD=3 \
      WEB4_AUDIO_GUARD_STALE_SECONDS=45 \
      WEB4_VISUAL_GUARD=1 \
      WEB4_VISUAL_GUARD_INTERVAL=20 \
      WEB4_VISUAL_GUARD_MAX_SECONDS=90 \
      WEB4_VISUAL_GUARD_MIN_SAMPLES=3 \
      WEB4_DIRECT_AUDIO_URL="$direct_audio_url" \
      PLUTO_CACHED_AUDIO_URL_FILE=/tmp/web7_pluto_audio_url.txt \
      WEB4_AUDIO_DELAY_MS="$WEB7_BROWSER_AUDIO_DELAY_MS" \
      WEB4_VIDEO_DELAY_MS="$WEB7_BROWSER_VIDEO_DELAY_MS" \
      WEB4_OUTPUT_SCALE_HEIGHT=480 \
      WEB4_OUTPUT_SCALE_FLAGS=fast_bilinear \
      WEB4_OUTPUT_PRESET=ultrafast \
      WEB4_OUTPUT_PROFILE=baseline \
      WEB4_OUTPUT_LEVEL=3.1 \
      WEB4_OUTPUT_BITRATE=950k \
      WEB4_OUTPUT_MAXRATE=1100k \
      WEB4_OUTPUT_BUFSIZE=2200k \
      WEB4_OUTPUT_GOP="$browser_gop" \
      bash "$browser_runner" \
        "$SRC_URL" \
        "$OUT" \
        "$HLS_TIME" \
        "$HLS_LIST_SIZE" \
        "$start_number" \
        "$browser_width" \
        "$browser_height" \
        "$browser_fps" \
        "$WEB7_BROWSER_SESSION_SECONDS" \
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
        "$WEB7_BROWSER_CAPTURE_TOP" \
        "$WEB7_BROWSER_CAPTURE_LEFT" \
        "$browser_screen_height" \
        "$WEB7_BROWSER_TRIM_TOP" \
        9>&-
}

# Bucle de reconexión automática en caso de corte del origen o fallo de ffmpeg
repair_failure_count=0
repair_window_start_ts=0
browser_short_failure_count=0

while true; do
  set +e

  # Mantener los segmentos previos permite que el reproductor conserve buffer tras reinicios.
  trim_hls_segments "$OUT" "$KEEP_SEGMENTS"

  RUN_ID="$(date +%s)"
  START_NUMBER="$RUN_ID"


  if should_use_browser_restream "$SRC_URL"; then
    browser_profile="$(web7_browser_profile)"
    echo "[ffmpeg_web7_proxy] Usando browser-restream Chromium para Pluto: perfil=$browser_profile variantes=480p/360p/180p audio=$WEB7_BROWSER_AUDIO_MODE" >&2
    ffmpeg_started_ts="$(date +%s)"
    run_browser_restream_session "$START_NUMBER" "$browser_profile"
    rc=$?
    run_seconds=$(( $(date +%s) - ffmpeg_started_ts ))
    set -e
    web7_note_browser_exit "$run_seconds"
    echo "[ffmpeg_web7_proxy] browser-restream salio con codigo $rc. Reintentando con autoreparacion..." >&2
    auto_repair_after_ffmpeg_exit "browser-restream salio" "$rc" "$run_seconds"
    continue
  fi
  if ! INPUT_URL="$(resolve_source_url "$SRC_URL")"; then
    set -e
    echo "[ffmpeg_web7_proxy] Falló la resolución del origen. Reintentando en 5 segundos..." >&2
    sleep 5
    continue
  fi

  if [ "$INPUT_URL" != "$SRC_URL" ]; then
    echo "[ffmpeg_web7_proxy] URL fuente resuelta a stream HLS directo." >&2
  fi

  AUDIO_INPUT_URL=""
  AUDIO_FILTER_INPUT="[0:a:0]"
  FFMPEG_AUDIO_INPUT_ARGS=( )
  if [ "$WEB7_PLUTO_DIRECT_HLS" = "1" ] && [ "$WEB7_PLUTO_DIRECT_MODE" = "pair" ]; then
    AUDIO_INPUT_URL="$(pluto_audio_from_variant "$INPUT_URL" 2>/dev/null || true)"
    if [ -n "$AUDIO_INPUT_URL" ]; then
      AUDIO_FILTER_INPUT="[1:a:0]"
      FFMPEG_AUDIO_INPUT_ARGS=(
        -allowed_extensions ALL
        -allowed_segment_extensions ALL
        -extension_picky 0
        -rw_timeout 5000000
        -reconnect 1
        -reconnect_streamed 1
        -reconnect_on_network_error 1
        -reconnect_on_http_error 4xx,5xx
        -reconnect_delay_max 10
        -user_agent "$USER_AGENT"
        -i "$AUDIO_INPUT_URL"
      )
      echo "[ffmpeg_web7_proxy] Pluto HLS pair: video variante + audio de la misma sesion." >&2
    fi
  fi

  ffmpeg \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -ignore_unknown \
    -allowed_extensions ALL \
    -allowed_segment_extensions ALL \
    -extension_picky 0 \
    -max_reload 100000 \
    -m3u8_hold_counters 100000 \
    -seg_max_retry 8 \
    -http_persistent 0 \
    -http_multiple 0 \
    -http_seekable 0 \
    -probesize 1000000 \
    -analyzeduration 1000000 \
    -rw_timeout 5000000 \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx \
    -reconnect_delay_max 10 \
    -reconnect_at_eof 0 \
    -reconnect_max_retries -1 \
    -reconnect_delay_total_max 180 \
    -respect_retry_after 0 \
    -fflags +genpts+discardcorrupt \
    -err_detect ignore_err \
    -live_start_index -3 \
    -user_agent "$USER_AGENT" \
    -i "$INPUT_URL" \
    "${FFMPEG_AUDIO_INPUT_ARGS[@]}" \
    -filter_complex "[0:v:0]split=3[v480src][v360src][v180src];[v480src]scale=-2:480:flags=fast_bilinear,fps=20,setpts=N/(20*TB)[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=15,setpts=N/(15*TB)[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=12,setpts=N/(12*TB)[v180];${AUDIO_FILTER_INPUT}aresample=async=1000:first_pts=0,asetpts=N/SR/TB,asplit=3[a480][a360][a180]" \
    -map "[v480]" -map "[a480]" \
    -map "[v360]" -map "[a360]" \
    -map "[v180]" -map "[a180]" \
    -dn \
    -sn \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.1 \
    -b:v:0 650k -maxrate:v:0 780k -bufsize:v:0 1600k \
    -b:v:1 420k -maxrate:v:1 520k -bufsize:v:1 1100k \
    -b:v:2 220k -maxrate:v:2 300k -bufsize:v:2 700k \
    -max_muxing_queue_size 4096 \
    -max_interleave_delta 3000000 \
    -r:v:0 20 \
    -r:v:1 15 \
    -r:v:2 12 \
    -g 80 \
    -keyint_min 80 \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*4)" \
    -c:a aac \
    -ac 2 \
    -b:a:0 96k -b:a:1 96k -b:a:2 64k \
    -f hls \
    -hls_time 4 \
    -hls_list_size "$HLS_LIST_SIZE" \
    -start_number "$START_NUMBER" \
    -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
    -var_stream_map "v:1,a:1,name:360p v:2,a:2,name:180p v:0,a:0,name:480p" \
    -master_pl_name index.m3u8 \
    -hls_segment_filename "$OUT/%v/seg_${RUN_ID}_%06d.ts" \
    "$OUT/%v/index.m3u8" 9>&- &

  ffmpeg_pid=$!
  ffmpeg_started_ts="$(date +%s)"
  repair_reason="ffmpeg salio"

  last_ok_ts="$(date +%s)"
  last_segment_change_ts="$last_ok_ts"
  last_segment_line=""
  if [ -f "$OUT/480p/index.m3u8" ]; then
    last_mtime="$(stat -c %Y "$OUT/480p/index.m3u8")"
    last_segment_line="$(grep -E "^seg_.*\.ts$" "$OUT/480p/index.m3u8" | tail -n1 || true)"
  else
    last_mtime="$last_ok_ts"
  fi

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WEB7_STALE_CHECK_INTERVAL"

    if [ -f "$OUT/480p/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT/480p/index.m3u8")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi

      if grep -q "^#EXT-X-ENDLIST" "$OUT/480p/index.m3u8"; then
        repair_reason="ENDLIST en salida local"
        echo "[ffmpeg_web7_proxy] Detectado ENDLIST en salida local, reiniciando ffmpeg ($ffmpeg_pid)" >&2
        stop_ffmpeg "$ffmpeg_pid"
        sleep 2
        break
      fi

      current_segment_line="$(grep -E "^seg_.*\.ts$" "$OUT/480p/index.m3u8" | tail -n1 || true)"
      if [ -n "$current_segment_line" ] && [ "$current_segment_line" != "$last_segment_line" ]; then
        last_segment_line="$current_segment_line"
        last_segment_change_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    stale_seconds=$(( now_ts - last_ok_ts ))
    segment_repeat_seconds=$(( now_ts - last_segment_change_ts ))

    if [ -n "$last_segment_line" ] && [ "$segment_repeat_seconds" -ge "$MAX_SEGMENT_REPEAT_SECONDS" ]; then
      repair_reason="segmento sin cambio por ${segment_repeat_seconds}s"
      echo "[ffmpeg_web7_proxy] Ultimo segmento sin cambio por $segment_repeat_seconds s ($last_segment_line), reiniciando ffmpeg ($ffmpeg_pid)" >&2
      stop_ffmpeg "$ffmpeg_pid"
      sleep 2
      break
    fi

    if [ "$stale_seconds" -ge "$MAX_STALE_SECONDS" ]; then
      repair_reason="480p/index.m3u8 stale por ${stale_seconds}s"
      echo "[ffmpeg_web7_proxy] 480p/index.m3u8 lleva $stale_seconds s sin actualizarse, matando ffmpeg ($ffmpeg_pid)" >&2
      stop_ffmpeg "$ffmpeg_pid"
      sleep 2
      break
    fi
  done

  wait "$ffmpeg_pid"
  rc=$?
  run_seconds=$(( $(date +%s) - ffmpeg_started_ts ))
  set -e

  echo "[ffmpeg_web7_proxy] ffmpeg salio con codigo $rc. Reintentando con autoreparacion..." >&2
  auto_repair_after_ffmpeg_exit "$repair_reason" "$rc" "$run_seconds"
done
