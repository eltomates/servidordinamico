#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi3}"
# Tercer dongle USB: puerto usb-0:11, índice 0 (ruta estable)
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:11:1.0-video-index0}"
# Audio del tercer dongle por nombre ALSA (card 2)
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109_2,DEV=0}"

mkdir -p "$OUT/v0" "$OUT/v1"

exec ffmpeg \
  -thread_queue_size 512 \
  -f v4l2 -framerate 25 -video_size 1280x720 -i "$VIDEO_DEV" \
  -thread_queue_size 512 \
  -f alsa -i "$AUDIO_DEV" \
  -filter_complex "[0:v]split=2[v540][v360];[v540]scale=960:540:flags=bicubic[vout540];[v360]scale=640:360:flags=bicubic[vout360]" \
  -map "[vout540]" -map 1:a:0 \
  -map "[vout360]" -map 1:a:0 \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p \
  -g 50 -keyint_min 50 -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1" \
  -b:v:0 1800k -maxrate:v:0 2200k -bufsize:v:0 4400k \
  -b:v:1 900k -maxrate:v:1 1100k -bufsize:v:1 2200k \
  -c:a aac -ac 2 -ar 48000 \
  -b:a:0 128k -b:a:1 96k \
  -f hls \
  -hls_time 2 \
  -hls_list_size 16 \
  -hls_delete_threshold 32 \
  -hls_flags delete_segments+program_date_time+independent_segments \
  -master_pl_publish_rate 1 \
  -master_pl_name index.m3u8 \
  -var_stream_map "v:0,a:0 v:1,a:1" \
  -hls_segment_filename "$OUT/v%v/seg_%06d.ts" \
  "$OUT/v%v/index.m3u8"
