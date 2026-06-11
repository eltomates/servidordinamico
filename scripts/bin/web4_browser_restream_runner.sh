#!/usr/bin/env bash

set -euo pipefail

PAGE_URL="${1:?missing page url}"
OUT_DIR="${2:?missing out dir}"
HLS_TIME="${3:?missing hls time}"
HLS_LIST_SIZE="${4:?missing hls list size}"
START_NUMBER="${5:?missing start number}"
WIDTH="${6:?missing width}"
HEIGHT="${7:?missing height}"
FPS="${8:?missing fps}"
SESSION_SECONDS="${9:?missing session seconds}"
USER_AGENT="${10:?missing user agent}"
CAPTURE_TOP="${11:-0}"
CAPTURE_LEFT="${12:-0}"
WINDOW_HEIGHT="${13:-$HEIGHT}"
TRIM_TOP="${14:-0}"
CAPTURE_HEIGHT="$HEIGHT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYER_SCRIPT="$SCRIPT_DIR/browser_player_keepalive.py"
RESOLVER_SCRIPT="$SCRIPT_DIR/resolve_vix_chromium.py"
CACHED_AUDIO_URL_FILE="/tmp/web4_audio_url.txt"
WEB4_USE_DIRECT_AUDIO="${WEB4_USE_DIRECT_AUDIO:-1}"
WEB4_AUDIO_RESOLUTION="${WEB4_AUDIO_RESOLUTION:-640x360}"
WEB4_AUDIO_DELAY_MS="${WEB4_AUDIO_DELAY_MS:-500}"

if [ "$TRIM_TOP" -gt 0 ] 2>/dev/null; then
  CAPTURE_HEIGHT="$WINDOW_HEIGHT"
fi

if [ ! -f "$PLAYER_SCRIPT" ]; then
  echo "[web4_browser_restream] ERROR: no existe $PLAYER_SCRIPT" >&2
  exit 1
fi

python3 "$PLAYER_SCRIPT" "$PAGE_URL" "$WIDTH" "$WINDOW_HEIGHT" "$USER_AGENT" &
player_pid=$!

cleanup() {
  kill "$player_pid" 2>/dev/null || true
  wait "$player_pid" 2>/dev/null || true
}
trap cleanup EXIT

resolve_audio_variant_url() {
  local master_url="$1"
  local playlist=""
  local variant_url=""

  if ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' "$master_url"
    return 0
  fi

  playlist="$(curl -fsSL --connect-timeout 8 --max-time 15 "$master_url" | tr -d '\r' 2>/dev/null || true)"
  if [ -z "$playlist" ]; then
    printf '%s\n' "$master_url"
    return 0
  fi

  variant_url="$(printf '%s\n' "$playlist" | awk -v preferred="$WEB4_AUDIO_RESOLUTION" '
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
  ' | tail -n1)"

  if [ -z "$variant_url" ]; then
    printf '%s\n' "$master_url"
    return 0
  fi

  case "$variant_url" in
    http://*|https://*) printf '%s\n' "$variant_url" ;;
    /*)
      printf '%s://%s%s\n' "${master_url%%://*}" "${master_url#*://}" "$variant_url" | sed 's#\(https\?://[^/]*\)/.*\(/.*\)#\1\2#'
      ;;
    *)
      printf '%s/%s\n' "${master_url%/*}" "$variant_url"
      ;;
  esac
}

sleep "${WEB4_BROWSER_BOOT_SECONDS:-8}"

AUDIO_URL=""
if [ "$WEB4_USE_DIRECT_AUDIO" = "1" ] && [[ "$PAGE_URL" == https://www.canela.tv/* || "$PAGE_URL" == https://canela.tv/* ]]; then
  if [ -f "$CACHED_AUDIO_URL_FILE" ]; then
    AUDIO_URL="$(tail -n1 "$CACHED_AUDIO_URL_FILE" 2>/dev/null || true)"
  fi

  # Refresca cache en segundo plano sin bloquear el arranque del restream.
  if [ -f "$RESOLVER_SCRIPT" ]; then
    if [ -z "$AUDIO_URL" ]; then
      resolved_once="$(timeout 15s python3 "$RESOLVER_SCRIPT" "$PAGE_URL" 20 2>/dev/null | tail -n1 || true)"
      if [ -n "$resolved_once" ]; then
        AUDIO_URL="$resolved_once"
        printf '%s\n' "$resolved_once" > "$CACHED_AUDIO_URL_FILE" 2>/dev/null || true
      fi
    fi

    if ! pgrep -af "resolve_vix_chromium.py $PAGE_URL" >/dev/null 2>&1; then
      (
        resolved_url="$(timeout 20s python3 "$RESOLVER_SCRIPT" "$PAGE_URL" 20 2>/dev/null | tail -n1 || true)"
        if [ -n "$resolved_url" ]; then
          printf '%s\n' "$resolved_url" > "$CACHED_AUDIO_URL_FILE" 2>/dev/null || true
        fi
      ) >/dev/null 2>&1 &
    fi
  fi
fi

if [ -n "$AUDIO_URL" ]; then
  AUDIO_URL="$(resolve_audio_variant_url "$AUDIO_URL")"
fi

if [ -n "$AUDIO_URL" ]; then
  if ! timeout 12s ffprobe -v error -allowed_extensions ALL -allowed_segment_extensions ALL -extension_picky 0 -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$AUDIO_URL" >/dev/null 2>&1; then
    AUDIO_URL=""
  fi
fi

FFMPEG_INPUT_ARGS=(
  -loglevel info
  -f x11grab
  -video_size "${WIDTH}x${CAPTURE_HEIGHT}"
  -framerate "$FPS"
  -draw_mouse 0
  -i "${DISPLAY}.0+${CAPTURE_LEFT},${CAPTURE_TOP}"
)

if [ -n "$AUDIO_URL" ]; then
  echo "[web4_browser_restream] Usando audio directo desde HLS resuelto." >&2
  FFMPEG_INPUT_ARGS+=(
    -re
    -allowed_extensions ALL
    -allowed_segment_extensions ALL
    -extension_picky 0
    -fflags nobuffer
    -probesize 32768
    -analyzeduration 0
    -rw_timeout 15000000
    -thread_queue_size 512
    -i "$AUDIO_URL"
  )
else
  echo "[web4_browser_restream] No se pudo resolver audio; usando audio silencioso." >&2
  FFMPEG_INPUT_ARGS+=(
    -f lavfi
    -i "anullsrc=channel_layout=stereo:sample_rate=48000"
  )
fi

FFMPEG_OUTPUT_ARGS=(
  -map 0:v:0
  -map 1:a:0
  -vf "scale=-2:720:flags=bicubic,fps=${FPS},setpts=N/(${FPS}*TB)"
  -af "asetpts=PTS-STARTPTS,adelay=${WEB4_AUDIO_DELAY_MS}:all=1,aresample=async=1:first_pts=0"
  -r "$FPS"
  -fps_mode cfr
  -c:v libx264
  -preset superfast
  -tune zerolatency
  -profile:v high
  -level 4.0
  -pix_fmt yuv420p
  -b:v 2500k
  -maxrate 3200k
  -bufsize 6400k
  -g 60
  -keyint_min 60
  -sc_threshold 0
  -c:a aac
  -ac 2
  -b:a 128k
  -f hls
  -hls_time "$HLS_TIME"
  -hls_list_size "$HLS_LIST_SIZE"
  -hls_delete_threshold 2
  -start_number "$START_NUMBER"
  -hls_flags "delete_segments+independent_segments+temp_file+omit_endlist"
  -hls_segment_filename "$OUT_DIR/seg_%06d.ts"
)

if [ "$SESSION_SECONDS" -gt 0 ] 2>/dev/null; then
  FFMPEG_OUTPUT_ARGS+=( -t "$SESSION_SECONDS" )
fi

if [ "$TRIM_TOP" -gt 0 ] 2>/dev/null; then
  FFMPEG_OUTPUT_ARGS=(
    -map 0:v:0
    -map 1:a:0
    -vf "crop=in_w:in_h-${TRIM_TOP}:0:${TRIM_TOP},scale=-2:720:flags=bicubic,fps=${FPS},setpts=N/(${FPS}*TB)"
    -af "asetpts=PTS-STARTPTS,adelay=${WEB4_AUDIO_DELAY_MS}:all=1,aresample=async=1:first_pts=0"
    -r "$FPS"
    -fps_mode cfr
    -c:v libx264
    -preset superfast
    -tune zerolatency
    -profile:v high
    -level 4.0
    -pix_fmt yuv420p
    -b:v 2500k
    -maxrate 3200k
    -bufsize 6400k
    -g 60
    -keyint_min 60
    -sc_threshold 0
    -c:a aac
    -ac 2
    -b:a 128k
    -f hls
    -hls_time "$HLS_TIME"
    -hls_list_size "$HLS_LIST_SIZE"
    -hls_delete_threshold 2
    -start_number "$START_NUMBER"
    -hls_flags "delete_segments+independent_segments+temp_file+omit_endlist"
    -hls_segment_filename "$OUT_DIR/seg_%06d.ts"
  )

  if [ "$SESSION_SECONDS" -gt 0 ] 2>/dev/null; then
    FFMPEG_OUTPUT_ARGS+=( -t "$SESSION_SECONDS" )
  fi
fi

FFMPEG_OUTPUT_ARGS+=("$OUT_DIR/index.m3u8")

ffmpeg "${FFMPEG_INPUT_ARGS[@]}" "${FFMPEG_OUTPUT_ARGS[@]}"
