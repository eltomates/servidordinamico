#!/usr/bin/env bash

# CGI para lanzar el proxy de vista previa (ffmpeg_preview_proxy.sh)
# a partir de una URL remota seleccionada en el panel (incluye URLs .ts).

set -e

printf '%s\n' "Content-Type: text/plain; charset=utf-8"
printf '\n'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
mkdir -p "$LOG_DIR"

CURL_BIN="$(command -v curl || true)"

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

QS="${QUERY_STRING:-}"
url_raw=""

IFS='&' read -r -a pairs <<< "$QS"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  case "$key" in
    url) url_raw="$(urldecode "$val" 2>/dev/null || true)" ;;
  esac
 done

if [ -z "$url_raw" ]; then
  echo "ERROR: Parámetro url es requerido."
  exit 0
fi

# Resolver redirecciones solo para acortadores tipo android*.php, etc.
# Para URLs HLS directas (.m3u8, .ts con token, etc.) se mantiene la URL tal cual.
final_url="$url_raw"
case "$url_raw" in
  *android*.php*|*.php?*android*|*/android.php*|*/android3.php*)
    if [ -n "$CURL_BIN" ]; then
      tmp="$($CURL_BIN -Ls -o /dev/null -w '%{url_effective}' "$url_raw" 2>/dev/null || true)"
      if [ -n "$tmp" ]; then
        final_url="$tmp"
      fi
    fi
    ;;
esac

preview_script="$SCRIPT_DIR/ffmpeg_preview_proxy.sh"
log_file="$LOG_DIR/ffmpeg_preview.log"
preview_dir="/var/www/html/hls/preview"

if [ ! -f "$preview_script" ]; then
  echo "ERROR: Script $preview_script no encontrado."
  exit 0
fi

# Matar cualquier instancia previa del proxy de vista previa
pkill -f "ffmpeg_preview_proxy.sh" 2>/dev/null || true
pkill -f "ffmpeg .*hls/preview" 2>/dev/null || true

# Limpiar completamente los segmentos antiguos e index de preview
if [ -d "$preview_dir" ]; then
  rm -f "$preview_dir"/seg_*.ts "$preview_dir"/index.m3u8 2>/dev/null || true
fi

# Lanzar nuevo proxy con la URL indicada
SRC_URL="$final_url" nohup bash "$preview_script" >> "$log_file" 2>&1 &

echo "OK: vista previa reiniciada con $final_url. Se borraron segmentos antiguos y se generará un nuevo /hls/preview/index.m3u8 en unos segundos."
