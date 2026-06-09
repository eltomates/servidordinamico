#!/usr/bin/env bash

# CGI para actualizar la URL de origen de un canal web (web1-web16)
# Admite tanto URLs directas HLS como URLs intermedias (android3.php, etc.):
# se resuelve el redireccionamiento con curl y se guarda la URL final.

set -e

echo "Content-Type: text/plain"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
CONFIG_FILE="$LOG_DIR/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$CONFIG_FILE")"

if [ ! -f "$CONFIG_FILE" ] && [ -f "$LEGACY_CONFIG" ]; then
  cp "$LEGACY_CONFIG" "$CONFIG_FILE"
fi

replace_config_file() {
  local tmp_file="$1"
  local target_file="$2"
  local target_dir owner group

  target_dir="$(dirname "$target_file")"

  if [ "$(id -u)" -eq 0 ] && [ -d "$target_dir" ]; then
    owner="$(stat -c '%U' "$target_dir" 2>/dev/null || true)"
    group="$(stat -c '%G' "$target_dir" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ -n "$group" ]; then
      chown "$owner:$group" "$tmp_file" 2>/dev/null || true
    fi
  fi

  chmod 664 "$tmp_file" 2>/dev/null || true
  command mv -f "$tmp_file" "$target_file"
  chmod 664 "$target_file" 2>/dev/null || true
}

write_channel_url() {
  local target_file="$1"
  local var_name="$2"
  local final_url="$3"
  local tmp_file

  [ -n "$target_file" ] || return 0

  tmp_file="$(mktemp)"
  if [ -f "$target_file" ]; then
    grep -Ev "^${var_name}=|^${var_name%_URL}_RESOLVED_URL=|^${var_name%_URL}_VARIANT_URL=" "$target_file" > "$tmp_file" || true
  fi
  printf '%s="%s"\n' "$var_name" "$final_url" >> "$tmp_file"
  replace_config_file "$tmp_file" "$target_file"
}

restart_channel() {
  local channel="$1"
  local orchestrator="$SCRIPT_DIR/start_all_proxies.sh"

  if [ ! -x "$orchestrator" ]; then
    echo "AVISO: Script $orchestrator no encontrado o sin permisos de ejecucion."
    return 1
  fi

  if bash "$orchestrator" --channel "$channel" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

QS="${QUERY_STRING:-}"
channel=""
url_raw=""

IFS='&' read -r -a pairs <<< "$QS"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  case "$key" in
    ch) channel="$(urldecode "$val")" ;;
    url) url_raw="$(urldecode "$val")" ;;
  esac
done

if [ -z "$channel" ] || [ -z "$url_raw" ]; then
  echo "ERROR: Parámetros ch y url son requeridos."
  exit 0
fi

case "$channel" in
  web1|web2|web3|web4|web5|web6|web7|web8|web9|web10|web11|web12|web13|web14|web15|web16) ;;
  *)
    echo "ERROR: Canal inválido: $channel"
    exit 0
    ;;
esac

# Resolver redirecciones para enlaces intermedios basados en PHP.
# Para URLs HLS directas (.m3u8, .ts con token, etc.) se mantiene la URL tal cual
# para evitar quedar apuntando a un único segmento que luego devuelve 406.
final_url="$url_raw"
case "$url_raw" in
  *.php*|*/phpcode/*)
    tmp="$(curl -Ls -o /dev/null -w '%{url_effective}' "$url_raw" 2>/dev/null || true)"
    if [ -n "$tmp" ]; then
      final_url="$tmp"
    fi
    ;;
esac

var_name="$(echo "$channel" | tr 'a-z' 'A-Z')_URL"

tmp_file="$(mktemp)"
rm -f "$tmp_file"

write_channel_url "$CONFIG_FILE" "$var_name" "$final_url"
write_channel_url "$LEGACY_CONFIG" "$var_name" "$final_url"

if restart_channel "$channel"; then
  echo "OK: $channel actualizado a $final_url y reiniciado."
else
  echo "AVISO: Se guardó la URL ($final_url) pero no se pudo reiniciar $channel automáticamente. Reinícialo manualmente."
fi
