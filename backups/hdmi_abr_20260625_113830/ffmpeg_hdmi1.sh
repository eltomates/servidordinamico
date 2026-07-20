#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi1}"
# Primer dongle USB (puerto pci-0000:00:14.0) expuesto como /dev/video0
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:8:1.0-video-index0}"
# Audio estable del primer dongle por nombre ALSA (evita renumeraciones)
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109,DEV=0}"
INPUT_FPS="${INPUT_FPS:-25}"
GOP_SIZE="${GOP_SIZE:-50}"

LOCK_DIR="/var/www/html/logs/locks"
LOCK_FILE="$LOCK_DIR/hdmi1_ffmpeg.lock"
mkdir -p "$OUT" "$LOCK_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[ffmpeg_hdmi1] ya hay otra instancia activa; saliendo." >&2
  exit 0
fi

exec ffmpeg \
  -thread_queue_size 2048 \
  -f v4l2 -input_format mjpeg -framerate "$INPUT_FPS" -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 2048 \
  -f alsa -i "$AUDIO_DEV" \
  -fflags +genpts \
  -c:v libx264 -preset faster -tune zerolatency \
  -pix_fmt yuv420p -b:v 1200k -maxrate 1400k -bufsize 2800k \
  -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1:sliced-threads=0" \
  -vf "scale=960:540:flags=lanczos" \
  -r "$INPUT_FPS" -fps_mode cfr \
  -c:a aac -b:a 96k -ac 2 -ar 48000 \
  -af "aresample=async=1000:min_hard_comp=0.100:first_pts=0" \
  -f hls \
  -hls_time 4 \
  -hls_list_size 10 \
  -hls_delete_threshold 32 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -hls_segment_filename "$OUT/seg_%06d.ts" \
  "$OUT/index.m3u8"
