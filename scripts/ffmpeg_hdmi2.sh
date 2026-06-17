#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi2}"
# Segundo dongle USB (actualmente en pci-0000:00:14.0 puerto 0:10)
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:10:1.0-video-index0}"
# Audio estable del segundo dongle por nombre ALSA
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109_1,DEV=0}"
INPUT_FPS="${INPUT_FPS:-25}"

mkdir -p "$OUT"

exec ffmpeg \
  -thread_queue_size 1024 \
  -f v4l2 -framerate "$INPUT_FPS" -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 4096 \
  -f alsa -i "$AUDIO_DEV" \
  -fflags +genpts \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p -b:v 2M -maxrate 2M -bufsize 4M \
  -g 50 -keyint_min 50 -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1" \
  -vf "scale=960:540:flags=lanczos" \
  -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -af "aresample=async=1000:min_hard_comp=0.100:first_pts=0" \
  -f hls \
  -hls_time 2 \
  -hls_list_size 16 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -hls_segment_filename "$OUT/seg_%06d.ts" \
  "$OUT/index.m3u8"
