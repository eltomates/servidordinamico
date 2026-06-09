#!/usr/bin/env bash

# CGI para reiniciar un solo proxy web (web1-web16) sin cambiar su URL.

set -euo pipefail

echo "Content-Type: text/plain"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="$SCRIPT_DIR/start_all_proxies.sh"
UPDATE_CHANNEL="$SCRIPT_DIR/update_web_channel.sh"
HLS_DIR="/var/www/html/hls"
STALE_SECONDS="${RESTART_STALE_SECONDS:-120}"
RECHECK_DELAY="${RESTART_RECHECK_DELAY:-25}"
SECOND_RECHECK_DELAY="${RESTART_SECOND_RECHECK_DELAY:-45}"

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

run_orchestrator_restart() {
  local channel="$1"
  local output_file="$2"

  if bash "$ORCHESTRATOR" --channel "$channel" >"$output_file" 2>&1; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    if sudo -n "$ORCHESTRATOR" --channel "$channel" >"$output_file" 2>&1; then
      return 0
    fi
  fi

  return 1
}

get_index_mtime() {
  local channel="$1"
  local index_file="$HLS_DIR/$channel/index.m3u8"

  if [ ! -f "$index_file" ]; then
    echo 0
    return
  fi

  stat -c %Y "$index_file" 2>/dev/null || echo 0
}

channel_is_stale() {
  local channel="$1"
  local now_ts
  local mtime

  now_ts="$(date +%s)"
  mtime="$(get_index_mtime "$channel")"

  if [ "$mtime" -eq 0 ]; then
    return 0
  fi

  if [ $(( now_ts - mtime )) -ge "$STALE_SECONDS" ]; then
    return 0
  fi

  return 1
}

get_config_file() {
  if [ -f "/var/www/html/logs/web_sources.env" ]; then
    printf '%s\n' "/var/www/html/logs/web_sources.env"
    return 0
  fi

  if [ -f "$SCRIPT_DIR/web_sources.env" ]; then
    printf '%s\n' "$SCRIPT_DIR/web_sources.env"
    return 0
  fi

  return 1
}

get_channel_url_from_config() {
  local channel="$1"
  local config_file
  local var_name

  if ! config_file="$(get_config_file)"; then
    echo ""
    return 0
  fi

  var_name="$(echo "$channel" | tr 'a-z' 'A-Z')_URL"
  awk -F '"' -v key="$var_name" '$1 == key"=" {print $2; exit}' "$config_file"
}

derive_stable_url() {
  local raw_url="$1"
  local channel_id=""

  case "$raw_url" in
    https://cfd-v4-service-channel-stitcher*.pluto.tv/v2/stitch/hls/channel/*/playlist.m3u8*|https://service-stitcher.clusters.pluto.tv/v1/stitch/embed/hls/channel/*/master.m3u8*)
      channel_id="$(printf '%s' "$raw_url" | sed -n 's#.*channel/\([^/]*\)/.*#\1#p' | head -n1)"
      if [ -n "$channel_id" ]; then
        printf 'https://pluto.tv/latam/live-tv/%s\n' "$channel_id"
        return 0
      fi
      ;;
  esac

  return 1
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

run_update_channel() {
  local channel="$1"
  local url="$2"
  local output_file="$3"
  local encoded_url

  if [ ! -x "$UPDATE_CHANNEL" ]; then
    return 1
  fi

  encoded_url="$(urlencode "$url")"

  if QUERY_STRING="ch=${channel}&url=${encoded_url}" bash "$UPDATE_CHANNEL" >"$output_file" 2>&1; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    if sudo -n env QUERY_STRING="ch=${channel}&url=${encoded_url}" bash "$UPDATE_CHANNEL" >"$output_file" 2>&1; then
      return 0
    fi
  fi

  return 1
}

auto_refresh_and_restart_if_needed() {
  local channel="$1"
  local restart_log="$2"
  local update_log="$3"
  local current_url
  local stable_url

  sleep "$RECHECK_DELAY"
  if ! channel_is_stale "$channel"; then
    return 2
  fi

  # Ventana adicional: algunos canales tardan en volver a escribir index tras reinicio.
  sleep "$SECOND_RECHECK_DELAY"
  if ! channel_is_stale "$channel"; then
    return 2
  fi

  current_url="$(get_channel_url_from_config "$channel")"
  if [ -z "$current_url" ]; then
    return 1
  fi

  if ! stable_url="$(derive_stable_url "$current_url")"; then
    return 1
  fi

  if [ "$stable_url" = "$current_url" ]; then
    return 1
  fi

  if ! run_update_channel "$channel" "$stable_url" "$update_log"; then
    return 1
  fi

  # update_web_channel ya reinicia el canal; validar recuperación breve.
  sleep "$RECHECK_DELAY"
  if channel_is_stale "$channel"; then
    return 1
  fi

  return 0
}

QS="${QUERY_STRING:-}"
channel=""

IFS='&' read -r -a pairs <<< "$QS"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  case "$key" in
    ch) channel="$(urldecode "$val")" ;;
  esac
done

if [ -z "$channel" ]; then
  echo "ERROR: Parámetro ch es requerido."
  exit 0
fi

case "$channel" in
  web1|web2|web3|web4|web5|web6|web7|web8|web9|web10|web11|web12|web13|web14|web15|web16) ;;
  *)
    echo "ERROR: Canal inválido: $channel"
    exit 0
    ;;
esac

if [ ! -x "$ORCHESTRATOR" ]; then
  echo "ERROR: Script $ORCHESTRATOR no encontrado o sin permisos de ejecución."
  exit 0
fi

TMP_LOG="$(mktemp /tmp/restart_web_channel.XXXXXX)"
TMP_UPDATE_LOG="$(mktemp /tmp/restart_web_channel_update.XXXXXX)"
cleanup() {
  rm -f "$TMP_LOG" 2>/dev/null || true
  rm -f "$TMP_UPDATE_LOG" 2>/dev/null || true
}
trap cleanup EXIT

if run_orchestrator_restart "$channel" "$TMP_LOG"; then
  if auto_refresh_and_restart_if_needed "$channel" "$TMP_LOG" "$TMP_UPDATE_LOG"; then
    echo "OK: $channel reiniciado y recuperado con auto-refresh de URL."
    exit 0
  fi

  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "OK: $channel reiniciado."
    exit 0
  fi

  echo "OK: $channel reiniciado (sin auto-refresh aplicable)."
  exit 0
fi

last_msg="$(tail -n 1 "$TMP_LOG" 2>/dev/null || true)"
if printf '%s' "$last_msg" | grep -qi "sudo: a password is required"; then
  echo "AVISO: No se pudo reiniciar $channel automáticamente. Falta permiso sudo NOPASSWD para www-data sobre start_all_proxies.sh."
  exit 0
fi
if [ -n "$last_msg" ]; then
  echo "AVISO: No se pudo reiniciar $channel automáticamente. Detalle: $last_msg"
else
  echo "AVISO: No se pudo reiniciar $channel automáticamente."
fi
