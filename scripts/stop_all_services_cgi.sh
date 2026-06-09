#!/usr/bin/env bash

# CGI para parar todos los proxys HLS y contenedores Docker de video

echo "Content-Type: text/plain"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if bash "$SCRIPT_DIR/stop_all_services.sh"; then
  echo "OK: Proxys HLS y contenedores Docker parados."
else
  echo "ERROR: No se pudieron parar todos los servicios."
fi
