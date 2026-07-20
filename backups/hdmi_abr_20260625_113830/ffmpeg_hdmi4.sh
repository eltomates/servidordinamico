#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi4}"
# Cuarto dongle USB: prioriza ruta histórica, pero se autodetecta si cambió de puerto.
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:9.2:1.0-video-index0}"
# Audio estable del cuarto dongle por nombre ALSA (card 3).
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109_3,DEV=0}"

pick_video_dev() {
  local candidate

  if [ -e "$VIDEO_DEV" ]; then
    echo "$VIDEO_DEV"
    return 0
  fi

  # Excluir puertos ya asignados a hdmi1/2/3.
  for candidate in /dev/v4l/by-path/*-video-index0; do
    [ -e "$candidate" ] || continue
    case "$candidate" in
      *-usb-0:8:1.0-video-index0|*-usb-0:10:1.0-video-index0|*-usb-0:11:1.0-video-index0|*-usbv2-0:8:1.0-video-index0|*-usbv2-0:10:1.0-video-index0|*-usbv2-0:11:1.0-video-index0)
        continue
        ;;
    esac
    echo "$candidate"
    return 0
  done

  # Si no hay candidato libre, reportar claramente para diagnóstico.
  echo "[ffmpeg_hdmi4] ERROR: no se encontró dispositivo de video para hdmi4." >&2
  echo "[ffmpeg_hdmi4] Esperado por defecto: $VIDEO_DEV" >&2
  ls -1 /dev/v4l/by-path/*-video-index0 2>/dev/null >&2 || true
  return 1
}

VIDEO_DEV="$(pick_video_dev)" || exit 1

mkdir -p "$OUT"

exec ffmpeg \
  -thread_queue_size 512 \
  -f v4l2 -framerate 25 -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 512 \
  -f alsa -i "$AUDIO_DEV" \
  -c:v libx264 -preset faster -tune zerolatency \
  -pix_fmt yuv420p -b:v 1200k -maxrate 1400k -bufsize 2800k \
  -g 50 -keyint_min 50 -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1" \
  -vf "scale=960:540:flags=lanczos" \
  -c:a aac -b:a 96k -ac 2 -ar 48000 \
  -f hls \
  -hls_time 4 \
  -hls_list_size 10 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -hls_segment_filename "$OUT/seg_%06d.ts" \
  "$OUT/index.m3u8"
