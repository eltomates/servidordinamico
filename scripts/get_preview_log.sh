#!/usr/bin/env bash

# CGI sencillo que devuelve las últimas N líneas del log de vista previa

set -e

printf '%s\n' "Content-Type: text/plain; charset=utf-8"
printf '\n'

LOG_FILE="/var/www/html/logs/ffmpeg_preview.log"
DEFAULT_LINES=15
MAX_LINES=100

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

LINES="$DEFAULT_LINES"
QS="${QUERY_STRING:-}"

IFS='&' read -r -a pairs <<< "$QS"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  case "$key" in
    lines)
      decoded="$(urldecode "$val" 2>/dev/null || true)"
      if [[ "$decoded" =~ ^[0-9]+$ ]]; then
        if [ "$decoded" -lt 1 ]; then
          decoded=1
        elif [ "$decoded" -gt "$MAX_LINES" ]; then
          decoded="$MAX_LINES"
        fi
        LINES="$decoded"
      fi
      ;;
  esac
 done

if [ ! -f "$LOG_FILE" ]; then
  echo "Sin log de vista previa aún."
  exit 0
fi

# Mostrar solo las últimas N líneas
tail -n "$LINES" "$LOG_FILE" 2>/dev/null || echo "No se pudieron leer los logs."
