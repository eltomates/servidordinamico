#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi1}"
# Primer dongle USB (puerto pci-0000:00:14.0) expuesto como /dev/video0
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:8:1.0-video-index0}"
# Audio estable del primer dongle por nombre ALSA (evita renumeraciones)
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109,DEV=0}"

mkdir -p "$OUT"

exec ffmpeg \
  -thread_queue_size 512 \
  -f v4l2 -framerate 25 -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 512 \
  -f alsa -i "$AUDIO_DEV" \
  -c:v libx264 -preset faster -tune zerolatency \
  -pix_fmt yuv420p -b:v 2M -maxrate 2M -bufsize 4M \
  -g 50 -keyint_min 50 -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1" \
  -vf "scale=960:540:flags=lanczos" \
  -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -f hls \
  -hls_time 2 \
  -hls_list_size 16 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -hls_segment_filename "$OUT/seg_%06d.ts" \
  "$OUT/index.m3u8"
