#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi3}"
# Tercer dongle USB: puerto usb-0:11, índice 0 (ruta estable)
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:11:1.0-video-index0}"
# Audio del tercer dongle por nombre ALSA (card 2)
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109_2,DEV=0}"

LOCK_DIR="/var/www/html/logs/locks"
LOCK_FILE="$LOCK_DIR/hdmi3_ffmpeg.lock"
mkdir -p "$OUT" "$LOCK_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[ffmpeg_hdmi3] ya hay otra instancia activa; saliendo." >&2
  exit 0
fi

exec ffmpeg \
  -thread_queue_size 1024 \
  -f v4l2 -input_format mjpeg -framerate 30 -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 4096 \
  -f alsa -i "$AUDIO_DEV" \
  -fflags +genpts \
  -c:v libx264 -preset faster -tune zerolatency \
  -pix_fmt yuv420p -b:v 2M -maxrate 2M -bufsize 4M \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1:sliced-threads=0" \
  -vf "scale=960:540:flags=lanczos" \
  -r 30 -fps_mode cfr \
  -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -af "aresample=async=1000:min_hard_comp=0.100:first_pts=0" \
  -f hls \
  -hls_time 2 \
  -hls_list_size 16 \
  -hls_delete_threshold 32 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -hls_segment_filename "$OUT/seg_%06d.ts" \
  "$OUT/index.m3u8"

