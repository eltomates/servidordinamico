#!/usr/bin/env bash

OUT="${OUT:-/var/www/html/hls/hdmi1}"
# Primer dongle USB (puerto pci-0000:00:14.0) expuesto como /dev/video0
VIDEO_DEV="${VIDEO_DEV:-/dev/v4l/by-path/pci-0000:00:14.0-usb-0:8:1.0-video-index0}"
# Audio estable del primer dongle por nombre ALSA (evita renumeraciones)
AUDIO_DEV="${AUDIO_DEV:-plughw:CARD=U0x345f0x2109,DEV=0}"
INPUT_FPS="${INPUT_FPS:-25}"
OUTPUT_480_FPS="${OUTPUT_480_FPS:-$INPUT_FPS}"
OUTPUT_360_FPS="${OUTPUT_360_FPS:-20}"
OUTPUT_180_FPS="${OUTPUT_180_FPS:-15}"
GOP_SIZE="${GOP_SIZE:-100}"
X264_PRESET="${X264_PRESET:-ultrafast}"

LOCK_DIR="/var/www/html/logs/locks"
LOCK_FILE="$LOCK_DIR/hdmi1_ffmpeg.lock"
mkdir -p "$OUT/480p" "$OUT/360p" "$OUT/180p" "$LOCK_DIR"
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
  -filter_complex "[0:v]split=3[v480src][v360src][v180src];[v480src]scale=854:480:flags=fast_bilinear,fps=${OUTPUT_480_FPS}[v480];[v360src]scale=640:360:flags=fast_bilinear,fps=${OUTPUT_360_FPS}[v360];[v180src]scale=320:180:flags=fast_bilinear,fps=${OUTPUT_180_FPS}[v180];[1:a]aresample=async=1000:min_hard_comp=0.100:first_pts=0,asplit=3[a480][a360][a180]" \
  -map "[v480]" -map "[a480]" \
  -map "[v360]" -map "[a360]" \
  -map "[v180]" -map "[a180]" \
  -c:v libx264 -preset "$X264_PRESET" -tune zerolatency \
  -pix_fmt yuv420p \
  -b:v:0 950k -maxrate:v:0 1100k -bufsize:v:0 2200k \
  -b:v:1 700k -maxrate:v:1 850k -bufsize:v:1 1700k \
  -b:v:2 350k -maxrate:v:2 450k -bufsize:v:2 900k \
  -g "$GOP_SIZE" -keyint_min "$GOP_SIZE" -sc_threshold 0 \
  -x264-params "nal-hrd=cbr:force-cfr=1:sliced-threads=1" \
  -fps_mode cfr \
  -c:a aac -b:a:0 96k -b:a:1 96k -b:a:2 64k -ac 2 -ar 48000 \
  -f hls \
  -hls_time 4 \
  -hls_list_size 10 \
  -hls_delete_threshold 32 \
  -hls_flags delete_segments+program_date_time+independent_segments+temp_file+omit_endlist \
  -var_stream_map "v:0,a:0,name:480p v:1,a:1,name:360p v:2,a:2,name:180p" \
  -master_pl_name index.m3u8 \
  -hls_segment_filename "$OUT/%v/seg_%06d.ts" \
  "$OUT/%v/index.m3u8"
