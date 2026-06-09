#!/usr/bin/env bash
set -e

cd /var/www

exec ffmpeg \
  -f v4l2 -framerate 25 -video_size 1280x720 -i /dev/video0 \
  -vf format=yuvj420p \
  -q:v 5 \
  -f mpjpeg -fflags nobuffer \
  -listen 1 http://0.0.0.0:8000/cam1.mjpg
