#!/usr/bin/env bash

# CGI para arrancar todos los proxys HLS y contenedores Docker de video

echo "Content-Type: text/plain"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if bash "$SCRIPT_DIR/start_all_services.sh"; then
  echo "OK: Proxys HLS y contenedores Docker arrancados."
else
  echo "ERROR: No se pudieron arrancar todos los servicios."
fi
