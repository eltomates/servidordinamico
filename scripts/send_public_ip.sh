#!/usr/bin/env bash

# Envía la IP pública exactamente en el formato requerido:
#   IP=$(curl -s https://ifconfig.me)
#   curl -X POST -d "ip=$IP" https://cablestar.giize.com/listas/receive_ip.php

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
LOG_FILE="$LOG_DIR/send_public_ip.log"
HISTORY_FILE="$LOG_DIR/send_public_ip_history.log"

mkdir -p "$LOG_DIR"

DEST_URL="https://cablestar.giize.com/api/receive_ip.php"

log_history_entry() {
  local status="$1"
  local tmp_file

  tmp_file="$(mktemp "$LOG_DIR/send_public_ip_history.XXXXXX")"

  {
    if [[ -f "$HISTORY_FILE" ]]; then
      cat "$HISTORY_FILE"
    fi
    printf '%s | IP=%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$IP" "$status"
  } | tail -n 3 > "$tmp_file"

  mv "$tmp_file" "$HISTORY_FILE"
}

# Forzar IPv4 al obtener la IP pública
IP="$(curl -4 -s https://ifconfig.me || true)"

if [[ -z "${IP}" ]]; then
  echo "[send_public_ip] No se pudo obtener la IP pública" | tee -a "$LOG_FILE" >&2
  exit 1
fi

echo "[send_public_ip] Enviando IP pública $IP a $DEST_URL" | tee -a "$LOG_FILE"

if RESPONSE="$(curl -4 -fsS -X POST -d "ip=$IP" "$DEST_URL" 2>&1)"; then
  if [[ -n "$RESPONSE" ]]; then
    echo "[send_public_ip] Respuesta del servidor: $RESPONSE" | tee -a "$LOG_FILE"
  fi
  echo "[send_public_ip] Envío correcto" | tee -a "$LOG_FILE"
  log_history_entry "Envio exitoso"
  exit 0
else
  STATUS=$?
  echo "[send_public_ip] Error al enviar la IP a $DEST_URL: $RESPONSE" | tee -a "$LOG_FILE" >&2
  exit "$STATUS"
fi
