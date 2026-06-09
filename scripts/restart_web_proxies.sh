#!/usr/bin/env bash

# CGI sencillo para reiniciar los proxys web1-web16

set -euo pipefail

echo "Content-Type: text/plain"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="$SCRIPT_DIR/start_all_proxies.sh"
TMP_LOG="$(mktemp /tmp/restart_web_proxies.XXXXXX)"

cleanup() {
  rm -f "$TMP_LOG" 2>/dev/null || true
}
trap cleanup EXIT

if bash "$ORCHESTRATOR" >"$TMP_LOG" 2>&1; then
  echo "OK: Proxys web1-web16 reiniciados."
  exit 0
fi

if command -v sudo >/dev/null 2>&1; then
  if sudo -n "$ORCHESTRATOR" >"$TMP_LOG" 2>&1; then
    echo "OK: Proxys web1-web16 reiniciados (via sudo)."
    exit 0
  fi
fi

last_msg="$(tail -n 1 "$TMP_LOG" 2>/dev/null || true)"
if printf '%s' "$last_msg" | grep -qi "sudo: a password is required"; then
  echo "ERROR: No se pudo reiniciar los proxys web1-web16. Falta permiso sudo NOPASSWD para www-data sobre start_all_proxies.sh"
  exit 0
fi
if [ -n "$last_msg" ]; then
  echo "ERROR: No se pudo reiniciar los proxys web1-web16. Detalle: $last_msg"
else
  echo "ERROR: No se pudo reiniciar los proxys web1-web16."
fi
