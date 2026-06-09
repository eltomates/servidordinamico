#!/usr/bin/env bash

# CGI para detener el proxy de vista previa (ffmpeg_preview_proxy.sh)
# y opcionalmente limpiar los segmentos generados.

set -e

printf '%s\n' "Content-Type: text/plain; charset=utf-8"
printf '\n'

PREVIEW_DIR="/var/www/html/hls/preview"
LOG_FILE="/var/www/html/logs/ffmpeg_preview.log"

# Matar cualquier instancia previa del proxy de vista previa
pkill -f "ffmpeg_preview_proxy.sh" 2>/dev/null || true
pkill -f "ffmpeg .*hls/preview" 2>/dev/null || true

# Limpiar todos los .ts e index.m3u8 para dejar el directorio en blanco
if [ -d "$PREVIEW_DIR" ]; then
  rm -f "$PREVIEW_DIR"/*.ts "$PREVIEW_DIR"/index.m3u8 2>/dev/null || true
fi

echo "OK: servicio de vista previa detenido y segmentos limpiados."
