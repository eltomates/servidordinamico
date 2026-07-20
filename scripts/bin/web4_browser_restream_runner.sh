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
PLUTO_RESOLVER_SCRIPT="$SCRIPT_DIR/resolve_pluto_chromium.py"
CACHED_AUDIO_URL_FILE="${CACHED_AUDIO_URL_FILE:-/tmp/web4_audio_url.txt}"
PLUTO_CACHED_AUDIO_URL_FILE="${PLUTO_CACHED_AUDIO_URL_FILE:-/tmp/web4_pluto_audio_url.txt}"
WEB4_USE_DIRECT_AUDIO="${WEB4_USE_DIRECT_AUDIO:-1}"
WEB4_AUDIO_MODE="${WEB4_AUDIO_MODE:-direct}"
WEB4_BROWSER_FIFO_ID="${WEB4_BROWSER_FIFO_ID:-$(basename "$OUT_DIR")}"
WEB4_BROWSER_FIFO_DIR="${WEB4_BROWSER_FIFO_DIR:-/tmp}"
WEB4_BROWSER_FIFO_PATH="${WEB4_BROWSER_FIFO_PATH:-$WEB4_BROWSER_FIFO_DIR/${WEB4_BROWSER_FIFO_ID}_browser_audio.raw}"
WEB4_BROWSER_ALSA_CONFIG_PATH="${WEB4_BROWSER_ALSA_CONFIG_PATH:-$WEB4_BROWSER_FIFO_DIR/${WEB4_BROWSER_FIFO_ID}_browser_asoundrc}"
WEB4_BROWSER_ALSA_OUTPUT_DEVICE="${WEB4_BROWSER_ALSA_OUTPUT_DEVICE:-browser_fifo}"
WEB4_BROWSER_FIFO_RATE="${WEB4_BROWSER_FIFO_RATE:-48000}"
WEB4_BROWSER_FIFO_CHANNELS="${WEB4_BROWSER_FIFO_CHANNELS:-2}"
WEB4_AUDIO_RESOLUTION="${WEB4_AUDIO_RESOLUTION:-640x360}"
WEB4_AUDIO_DELAY_MS="${WEB4_AUDIO_DELAY_MS:-500}"
WEB4_VIDEO_DELAY_MS="${WEB4_VIDEO_DELAY_MS:-0}"
WEB4_DIRECT_AUDIO_URL="${WEB4_DIRECT_AUDIO_URL:-}"
WEB4_OUTPUT_SCALE_HEIGHT="${WEB4_OUTPUT_SCALE_HEIGHT:-480}"
WEB4_OUTPUT_SCALE_FLAGS="${WEB4_OUTPUT_SCALE_FLAGS:-bicubic}"
WEB4_OUTPUT_PRESET="${WEB4_OUTPUT_PRESET:-ultrafast}"
WEB4_OUTPUT_PROFILE="${WEB4_OUTPUT_PROFILE:-baseline}"
WEB4_OUTPUT_LEVEL="${WEB4_OUTPUT_LEVEL:-3.1}"
WEB4_OUTPUT_BITRATE="${WEB4_OUTPUT_BITRATE:-1200k}"
WEB4_OUTPUT_MAXRATE="${WEB4_OUTPUT_MAXRATE:-1600k}"
WEB4_OUTPUT_BUFSIZE="${WEB4_OUTPUT_BUFSIZE:-3200k}"
WEB4_OUTPUT_GOP="${WEB4_OUTPUT_GOP:-40}"
WEB4_FORCE_KEY_SECONDS="${WEB4_FORCE_KEY_SECONDS:-$HLS_TIME}"
WEB4_MULTI_VARIANT="${WEB4_MULTI_VARIANT:-0}"
WEB4_MULTI_360_FPS="${WEB4_MULTI_360_FPS:-20}"
WEB4_MULTI_180_FPS="${WEB4_MULTI_180_FPS:-15}"
WEB4_MULTI_480_BITRATE="${WEB4_MULTI_480_BITRATE:-950k}"
WEB4_MULTI_480_MAXRATE="${WEB4_MULTI_480_MAXRATE:-1100k}"
WEB4_MULTI_480_BUFSIZE="${WEB4_MULTI_480_BUFSIZE:-2200k}"
WEB4_MULTI_360_BITRATE="${WEB4_MULTI_360_BITRATE:-700k}"
WEB4_MULTI_360_MAXRATE="${WEB4_MULTI_360_MAXRATE:-850k}"
WEB4_MULTI_360_BUFSIZE="${WEB4_MULTI_360_BUFSIZE:-1700k}"
WEB4_MULTI_180_BITRATE="${WEB4_MULTI_180_BITRATE:-350k}"
WEB4_MULTI_180_MAXRATE="${WEB4_MULTI_180_MAXRATE:-450k}"
WEB4_MULTI_180_BUFSIZE="${WEB4_MULTI_180_BUFSIZE:-900k}"
WEB4_MULTI_VAR_STREAM_MAP="${WEB4_MULTI_VAR_STREAM_MAP:-v:0,a:0,name:480p v:1,a:1,name:360p v:2,a:2,name:180p}"
WEB4_ALLOW_SILENT_FALLBACK="${WEB4_ALLOW_SILENT_FALLBACK:-1}"
WEB4_AUDIO_GUARD="${WEB4_AUDIO_GUARD:-0}"
WEB4_AUDIO_GUARD_INTERVAL="${WEB4_AUDIO_GUARD_INTERVAL:-12}"
WEB4_AUDIO_GUARD_MAX_BAD="${WEB4_AUDIO_GUARD_MAX_BAD:-3}"
WEB4_AUDIO_GUARD_STALE_SECONDS="${WEB4_AUDIO_GUARD_STALE_SECONDS:-45}"
WEB4_AUDIO_GUARD_MIN_MAX_VOLUME_DB="${WEB4_AUDIO_GUARD_MIN_MAX_VOLUME_DB:--55}"
WEB4_VISUAL_GUARD="${WEB4_VISUAL_GUARD:-0}"
WEB4_VISUAL_GUARD_INTERVAL="${WEB4_VISUAL_GUARD_INTERVAL:-20}"
WEB4_VISUAL_GUARD_MAX_SECONDS="${WEB4_VISUAL_GUARD_MAX_SECONDS:-120}"
WEB4_VISUAL_GUARD_MIN_SAMPLES="${WEB4_VISUAL_GUARD_MIN_SAMPLES:-4}"
WEB4_VISUAL_GUARD_PROBE_TIMEOUT_SECONDS="${WEB4_VISUAL_GUARD_PROBE_TIMEOUT_SECONDS:-8}"

if [ "$TRIM_TOP" -gt 0 ] 2>/dev/null; then
  CAPTURE_HEIGHT="$WINDOW_HEIGHT"
fi

if [ ! -f "$PLAYER_SCRIPT" ]; then
  echo "[web4_browser_restream] ERROR: no existe $PLAYER_SCRIPT" >&2
  exit 1
fi

setup_browser_fifo_audio() {
  rm -f "$WEB4_BROWSER_FIFO_PATH"
  mkfifo "$WEB4_BROWSER_FIFO_PATH"
  printf "%s\n" \
    "<confdir:alsa.conf>" \
    "pcm.browser_fifo_raw {" \
    "  type file" \
    "  slave.pcm \"null\"" \
    "  file \"$WEB4_BROWSER_FIFO_PATH\"" \
    "  format \"raw\"" \
    "}" \
    "pcm.browser_fifo {" \
    "  type plug" \
    "  slave {" \
    "    pcm \"browser_fifo_raw\"" \
    "    format S16_LE" \
    "    rate $WEB4_BROWSER_FIFO_RATE" \
    "    channels $WEB4_BROWSER_FIFO_CHANNELS" \
    "  }" \
    "}" > "$WEB4_BROWSER_ALSA_CONFIG_PATH"
}

if [ "$WEB4_AUDIO_MODE" = "browser-fifo" ]; then
  WEB4_USE_DIRECT_AUDIO=0
  setup_browser_fifo_audio
  env \
    ALSA_CONFIG_PATH="$WEB4_BROWSER_ALSA_CONFIG_PATH" \
    BROWSER_ALSA_OUTPUT_DEVICE="$WEB4_BROWSER_ALSA_OUTPUT_DEVICE" \
    python3 "$PLAYER_SCRIPT" "$PAGE_URL" "$WIDTH" "$WINDOW_HEIGHT" "$USER_AGENT" &
else
  python3 "$PLAYER_SCRIPT" "$PAGE_URL" "$WIDTH" "$WINDOW_HEIGHT" "$USER_AGENT" &
fi
player_pid=$!

cleanup() {
  kill "$player_pid" 2>/dev/null || true
  wait "$player_pid" 2>/dev/null || true
  if [ "$WEB4_AUDIO_MODE" = "browser-fifo" ]; then
    rm -f "$WEB4_BROWSER_FIFO_PATH" "$WEB4_BROWSER_ALSA_CONFIG_PATH" 2>/dev/null || true
  fi
}
trap cleanup EXIT

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

audio_url_has_stream() {
  local test_url="$1"

  timeout 12s ffprobe -v error -allowed_extensions ALL -allowed_segment_extensions ALL -extension_picky 0 -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$test_url" 2>/dev/null | grep -q .
}

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


segment_has_audio_level() {
  local segment_path="$1"
  local volume_output=""
  local max_volume=""

  if [ ! -s "$segment_path" ]; then
    return 1
  fi

  if ! ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$segment_path" 2>/dev/null | grep -q audio; then
    return 1
  fi

  volume_output="$(timeout 5s ffmpeg -hide_banner -loglevel info -i "$segment_path" -vn -af volumedetect -f null - 2>&1 || true)"
  max_volume="$(printf "%s\n" "$volume_output" | sed -n "s/.*max_volume: \([-0-9.]*\) dB.*/\1/p" | tail -n1)"

  if [ -z "$max_volume" ]; then
    return 1
  fi

  awk -v max="$max_volume" -v min="$WEB4_AUDIO_GUARD_MIN_MAX_VOLUME_DB" "BEGIN { exit !(max > min) }"
}

compute_visual_hash() {
  local playlist="$OUT_DIR/480p/index.m3u8"
  local timeout_cmd=( )

  if [ "$WEB4_VISUAL_GUARD" != "1" ] || [ ! -f "$playlist" ]; then
    return 1
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout "$WEB4_VISUAL_GUARD_PROBE_TIMEOUT_SECONDS")
  fi

  "${timeout_cmd[@]}" ffmpeg \
    -v error \
    -nostdin \
    -hide_banner \
    -fflags nobuffer \
    -i "$playlist" \
    -an \
    -frames:v 1 \
    -vf "scale=32:18:flags=fast_bilinear,format=gray" \
    -f md5 - 2>/dev/null | awk -F= "/^MD5=/{print \$2; exit}"
}

audio_guard_loop() {
  local ffmpeg_pid="$1"
  local bad_audio_count=0
  local last_mtime=0
  local last_ok_ts=""
  local now_ts=""
  local current_mtime=""
  local segment_name=""
  local segment_path=""
  local last_visual_probe_ts=0
  local last_visual_hash=""
  local current_visual_hash=""
  local visual_same_since_ts=0
  local visual_same_samples=0

  last_ok_ts="$(date +%s)"

  while kill -0 "$ffmpeg_pid" 2>/dev/null; do
    sleep "$WEB4_AUDIO_GUARD_INTERVAL"

    if [ -f "$OUT_DIR/480p/index.m3u8" ]; then
      current_mtime="$(stat -c %Y "$OUT_DIR/480p/index.m3u8" 2>/dev/null || printf "0")"
      if [ "$current_mtime" != "$last_mtime" ]; then
        last_mtime="$current_mtime"
        last_ok_ts="$(date +%s)"
      fi
    fi

    now_ts="$(date +%s)"
    if [ $(( now_ts - last_ok_ts )) -ge "$WEB4_AUDIO_GUARD_STALE_SECONDS" ]; then
      echo "[web4_browser_restream] 480p/index.m3u8 stale; reiniciando restream." >&2
      kill "$ffmpeg_pid" 2>/dev/null || true
      return
    fi

    if [ "$WEB4_AUDIO_GUARD" = "1" ]; then
      segment_name="$(grep -E "^seg_.*\.ts$" "$OUT_DIR/480p/index.m3u8" 2>/dev/null | tail -n1 || true)"
      if [ -n "$segment_name" ]; then
        segment_path="$OUT_DIR/480p/$segment_name"
        if segment_has_audio_level "$segment_path"; then
          bad_audio_count=0
        else
          bad_audio_count=$(( bad_audio_count + 1 ))
          echo "[web4_browser_restream] Segmento sin audio util ($bad_audio_count/$WEB4_AUDIO_GUARD_MAX_BAD): $segment_name" >&2
          if [ "$bad_audio_count" -ge "$WEB4_AUDIO_GUARD_MAX_BAD" ]; then
            echo "[web4_browser_restream] Audio mudo repetido; reiniciando restream." >&2
            kill "$ffmpeg_pid" 2>/dev/null || true
            return
          fi
        fi
      fi
    fi

    if [ "$WEB4_VISUAL_GUARD" = "1" ] && [ $(( now_ts - last_visual_probe_ts )) -ge "$WEB4_VISUAL_GUARD_INTERVAL" ]; then
      current_visual_hash="$(compute_visual_hash || true)"
      last_visual_probe_ts="$now_ts"

      if [ -n "$current_visual_hash" ]; then
        if [ -n "$last_visual_hash" ] && [ "$current_visual_hash" = "$last_visual_hash" ]; then
          visual_same_samples=$(( visual_same_samples + 1 ))
          if [ "$visual_same_since_ts" -eq 0 ]; then
            visual_same_since_ts="$now_ts"
          fi
        else
          last_visual_hash="$current_visual_hash"
          visual_same_since_ts=0
          visual_same_samples=1
        fi

        if [ "$visual_same_since_ts" -gt 0 ] && \
          [ "$visual_same_samples" -ge "$WEB4_VISUAL_GUARD_MIN_SAMPLES" ] && \
          [ $(( now_ts - visual_same_since_ts )) -ge "$WEB4_VISUAL_GUARD_MAX_SECONDS" ]; then
          echo "[web4_browser_restream] Imagen congelada por $(( now_ts - visual_same_since_ts )) s; reiniciando restream." >&2
          kill "$ffmpeg_pid" 2>/dev/null || true
          return
        fi
      fi
    fi
  done
}

sleep "${WEB4_BROWSER_BOOT_SECONDS:-8}"

AUDIO_URL="$WEB4_DIRECT_AUDIO_URL"
case "$AUDIO_URL" in
  */audio/audio/*) AUDIO_URL="" ;;
esac
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

if [ -z "$AUDIO_URL" ] && [ "$WEB4_USE_DIRECT_AUDIO" = "1" ] && [[ "$PAGE_URL" == https://pluto.tv/*/live-tv/* || "$PAGE_URL" == https://*.pluto.tv/*/live-tv/* ]]; then
  if [ -f "$PLUTO_CACHED_AUDIO_URL_FILE" ]; then
    AUDIO_URL="$(tail -n1 "$PLUTO_CACHED_AUDIO_URL_FILE" 2>/dev/null || true)"
  fi

  case "$AUDIO_URL" in
    */audio/audio/*) AUDIO_URL="" ;;
  esac

  if [ -f "$PLUTO_RESOLVER_SCRIPT" ]; then
    if [ -z "$AUDIO_URL" ]; then
      resolved_once="$(timeout 45s env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$PLUTO_RESOLVER_SCRIPT" "$PAGE_URL" 25 2>/dev/null | tail -n1 || true)"
      if [ -n "$resolved_once" ]; then
        AUDIO_URL="$resolved_once"
        printf '%s\n' "$resolved_once" > "$PLUTO_CACHED_AUDIO_URL_FILE" 2>/dev/null || true
      fi
    fi

    if ! pgrep -af "resolve_pluto_chromium.py $PAGE_URL" >/dev/null 2>&1; then
      (
        resolved_url="$(timeout 45s env PW_HEADLESS=1 PLUTO_SKIP_VERIFY=1 python3 "$PLUTO_RESOLVER_SCRIPT" "$PAGE_URL" 25 2>/dev/null | tail -n1 || true)"
        if [ -n "$resolved_url" ]; then
          printf '%s\n' "$resolved_url" > "$PLUTO_CACHED_AUDIO_URL_FILE" 2>/dev/null || true
        fi
      ) >/dev/null 2>&1 &
    fi
  fi
fi

if [ -n "$AUDIO_URL" ]; then
  case "$AUDIO_URL" in
    *.prd.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*)
      :
      ;;
    *)
      AUDIO_URL="$(resolve_audio_variant_url "$AUDIO_URL")"
      ;;
  esac
fi

if [ -n "$AUDIO_URL" ]; then
  if ! audio_url_has_stream "$AUDIO_URL"; then
    PLUTO_AUDIO_URL="$(derive_pluto_audio_url "$AUDIO_URL" 2>/dev/null || true)"
    if [ -n "$PLUTO_AUDIO_URL" ] && audio_url_has_stream "$PLUTO_AUDIO_URL"; then
      echo "[web4_browser_restream] Usando audio Pluto derivado desde playlist separada." >&2
      AUDIO_URL="$PLUTO_AUDIO_URL"
      printf '%s\n' "$AUDIO_URL" > "$PLUTO_CACHED_AUDIO_URL_FILE" 2>/dev/null || true
    else
      AUDIO_URL=""
    fi
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

if [ "$WEB4_AUDIO_MODE" = "browser-fifo" ]; then
  echo "[web4_browser_restream] Usando audio real de Chromium via ALSA FIFO: $WEB4_BROWSER_FIFO_PATH" >&2
  FFMPEG_INPUT_ARGS+=(
    -thread_queue_size 1024
    -f s16le
    -ar "$WEB4_BROWSER_FIFO_RATE"
    -ac "$WEB4_BROWSER_FIFO_CHANNELS"
    -i "$WEB4_BROWSER_FIFO_PATH"
  )
elif [ -n "$AUDIO_URL" ]; then
  echo "[web4_browser_restream] Usando audio directo desde HLS resuelto." >&2
  FFMPEG_INPUT_ARGS+=(
    -allowed_extensions ALL
    -allowed_segment_extensions ALL
    -extension_picky 0
    -fflags +discardcorrupt+genpts
    -err_detect ignore_err
    -probesize 1000000
    -analyzeduration 1000000
    -rw_timeout 15000000
    -max_reload 100000
    -m3u8_hold_counters 100000
    -seg_max_retry 8
    -http_persistent 0
    -http_multiple 0
    -http_seekable 0
    -reconnect 1
    -reconnect_streamed 1
    -reconnect_on_network_error 1
    -reconnect_on_http_error 4xx,5xx
    -reconnect_delay_max 5
    -reconnect_max_retries -1
    -reconnect_delay_total_max 180
    -respect_retry_after 0
    -thread_queue_size 512
    -i "$AUDIO_URL"
  )
else
  if [ "$WEB4_ALLOW_SILENT_FALLBACK" != "1" ]; then
    echo "[web4_browser_restream] ERROR: no se pudo resolver audio real; reiniciando sin publicar silencio." >&2
    exit 2
  fi
  echo "[web4_browser_restream] No se pudo resolver audio; usando audio silencioso." >&2
  FFMPEG_INPUT_ARGS+=(
    -f lavfi
    -i "anullsrc=channel_layout=stereo:sample_rate=48000"
  )
fi


if [ "$WEB4_MULTI_VARIANT" = "1" ]; then
  mkdir -p "$OUT_DIR/480p" "$OUT_DIR/360p" "$OUT_DIR/180p"

  if [ "$TRIM_TOP" -gt 0 ] 2>/dev/null; then
    MULTI_VIDEO_FILTER="[0:v]crop=in_w:in_h-${TRIM_TOP}:0:${TRIM_TOP},setpts=N/(${FPS}*TB)+${WEB4_VIDEO_DELAY_MS}/1000/TB,split=3[v480src][v360src][v180src]"
  else
    MULTI_VIDEO_FILTER="[0:v]setpts=N/(${FPS}*TB)+${WEB4_VIDEO_DELAY_MS}/1000/TB,split=3[v480src][v360src][v180src]"
  fi

  FFMPEG_OUTPUT_ARGS=(
    -filter_complex "${MULTI_VIDEO_FILTER};[v480src]scale=-2:480:flags=${WEB4_OUTPUT_SCALE_FLAGS},fps=${FPS}[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=${WEB4_MULTI_360_FPS}[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=${WEB4_MULTI_180_FPS}[v180];[1:a:0]aresample=async=1000:first_pts=0,adelay=${WEB4_AUDIO_DELAY_MS}:all=1,asetpts=N/SR/TB,asplit=3[a480][a360][a180]"
    -map "[v480]" -map "[a480]"
    -map "[v360]" -map "[a360]"
    -map "[v180]" -map "[a180]"
    -c:v libx264
    -preset "$WEB4_OUTPUT_PRESET"
    -tune zerolatency
    -profile:v "$WEB4_OUTPUT_PROFILE"
    -level "$WEB4_OUTPUT_LEVEL"
    -pix_fmt yuv420p
    -b:v:0 "$WEB4_MULTI_480_BITRATE" -maxrate:v:0 "$WEB4_MULTI_480_MAXRATE" -bufsize:v:0 "$WEB4_MULTI_480_BUFSIZE"
    -b:v:1 "$WEB4_MULTI_360_BITRATE" -maxrate:v:1 "$WEB4_MULTI_360_MAXRATE" -bufsize:v:1 "$WEB4_MULTI_360_BUFSIZE"
    -b:v:2 "$WEB4_MULTI_180_BITRATE" -maxrate:v:2 "$WEB4_MULTI_180_MAXRATE" -bufsize:v:2 "$WEB4_MULTI_180_BUFSIZE"
    -max_muxing_queue_size 4096
    -g "$WEB4_OUTPUT_GOP"
    -keyint_min "$WEB4_OUTPUT_GOP"
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*${WEB4_FORCE_KEY_SECONDS})"
    -c:a aac
    -ac 2
    -b:a:0 96k -b:a:1 96k -b:a:2 64k
    -f hls
    -hls_time "$HLS_TIME"
    -hls_list_size "$HLS_LIST_SIZE"
    -hls_delete_threshold 2
    -start_number "$START_NUMBER"
    -hls_flags "delete_segments+program_date_time+independent_segments+temp_file+omit_endlist"
    -var_stream_map "$WEB4_MULTI_VAR_STREAM_MAP"
    -master_pl_name index.m3u8
    -hls_segment_filename "$OUT_DIR/%v/seg_%06d.ts"
  )

  if [ "$SESSION_SECONDS" -gt 0 ] 2>/dev/null; then
    FFMPEG_OUTPUT_ARGS+=( -t "$SESSION_SECONDS" )
  fi

  FFMPEG_OUTPUT_ARGS+=("$OUT_DIR/%v/index.m3u8")

  if [ "$WEB4_AUDIO_GUARD" = "1" ] || [ "$WEB4_VISUAL_GUARD" = "1" ]; then
    ffmpeg "${FFMPEG_INPUT_ARGS[@]}" "${FFMPEG_OUTPUT_ARGS[@]}" &
    ffmpeg_pid=$!
    audio_guard_loop "$ffmpeg_pid" &
    guard_pid=$!

    set +e
    wait "$ffmpeg_pid"
    rc=$?
    set -e

    kill "$guard_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
    exit "$rc"
  fi

  ffmpeg "${FFMPEG_INPUT_ARGS[@]}" "${FFMPEG_OUTPUT_ARGS[@]}"
  exit $?
fi
FFMPEG_OUTPUT_ARGS=(
  -map 0:v:0
  -map 1:a:0
  -vf "scale=-2:${WEB4_OUTPUT_SCALE_HEIGHT}:flags=${WEB4_OUTPUT_SCALE_FLAGS},fps=${FPS},setpts=N/(${FPS}*TB)+${WEB4_VIDEO_DELAY_MS}/1000/TB"
  -af "aresample=async=1000:first_pts=0,adelay=${WEB4_AUDIO_DELAY_MS}:all=1,asetpts=N/SR/TB"
  -r "$FPS"
  -fps_mode cfr
  -c:v libx264
  -preset "$WEB4_OUTPUT_PRESET"
  -tune zerolatency
  -profile:v "$WEB4_OUTPUT_PROFILE"
  -level "$WEB4_OUTPUT_LEVEL"
  -pix_fmt yuv420p
  -b:v "$WEB4_OUTPUT_BITRATE"
  -maxrate "$WEB4_OUTPUT_MAXRATE"
  -bufsize "$WEB4_OUTPUT_BUFSIZE"
  -g "$WEB4_OUTPUT_GOP"
  -keyint_min "$WEB4_OUTPUT_GOP"
  -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*${WEB4_FORCE_KEY_SECONDS})"
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
    -vf "crop=in_w:in_h-${TRIM_TOP}:0:${TRIM_TOP},scale=-2:${WEB4_OUTPUT_SCALE_HEIGHT}:flags=${WEB4_OUTPUT_SCALE_FLAGS},fps=${FPS},setpts=N/(${FPS}*TB)+${WEB4_VIDEO_DELAY_MS}/1000/TB"
    -af "aresample=async=1000:first_pts=0,adelay=${WEB4_AUDIO_DELAY_MS}:all=1,asetpts=N/SR/TB"
    -r "$FPS"
    -fps_mode cfr
    -c:v libx264
    -preset "$WEB4_OUTPUT_PRESET"
    -tune zerolatency
    -profile:v "$WEB4_OUTPUT_PROFILE"
    -level "$WEB4_OUTPUT_LEVEL"
    -pix_fmt yuv420p
    -b:v "$WEB4_OUTPUT_BITRATE"
    -maxrate "$WEB4_OUTPUT_MAXRATE"
    -bufsize "$WEB4_OUTPUT_BUFSIZE"
    -g "$WEB4_OUTPUT_GOP"
    -keyint_min "$WEB4_OUTPUT_GOP"
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*${WEB4_FORCE_KEY_SECONDS})"
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
