#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/update_web_channel.sh"

usage() {
  cat <<'EOF'
Uso:
  samsung_tvplus_channels.sh list [mx|us] [filtro]
  samsung_tvplus_channels.sh add webN [mx|us] filtro

Ejemplos:
  bash scripts/samsung_tvplus_channels.sh list mx
  bash scripts/samsung_tvplus_channels.sh list us movie
  bash scripts/samsung_tvplus_channels.sh add web10 mx "MyTime"

Notas:
  - list muestra: numero | nombre | url
  - add toma la primera coincidencia del filtro y actualiza WEBN_URL con update_web_channel.sh
EOF
}

playlist_url() {
  case "${1:-mx}" in
    mx) printf '%s\n' 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/mx_samsung.m3u' ;;
    us) printf '%s\n' 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_samsung.m3u' ;;
    *) return 1 ;;
  esac
}

urlencode() {
  python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
}

channels() {
  local country="$1"
  local filter="${2:-}"
  local source_url

  source_url="$(playlist_url "$country")" || {
    echo "Pais invalido: $country (usa mx o us)" >&2
    return 1
  }

  curl -fsSL --connect-timeout 10 --max-time 30 "$source_url" | tr -d '\r' | awk -v filter="$filter" '
    BEGIN { channel_count = 0; filter_lc = tolower(filter) }
    /^#EXTINF:/ {
      name = $0
      sub(/^.*,/, "", name)
      next
    }
    /^https?:\/\// {
      if (name == "") next
      if (filter == "" || index(tolower(name), filter_lc) > 0) {
        channel_count++
        printf "%03d\t%s\t%s\n", channel_count, name, $0
      }
      name = ""
    }
  '
}

add_channel() {
  local channel="$1"
  local country="$2"
  local filter="$3"
  local selected name url encoded_url

  case "$channel" in
    web1|web2|web3|web4|web5|web6|web7|web8|web9|web10|web11|web12|web13|web14|web15|web16) ;;
    *) echo "Canal invalido: $channel" >&2; return 1 ;;
  esac

  selected="$(channels "$country" "$filter" | head -n1)"
  if [ -z "$selected" ]; then
    echo "No encontre canales para filtro: $filter" >&2
    return 1
  fi

  name="$(printf '%s' "$selected" | awk -F '\t' '{print $2}')"
  url="$(printf '%s' "$selected" | awk -F '\t' '{print $3}')"
  encoded_url="$(urlencode "$url")"

  echo "Canal seleccionado: $name"
  echo "URL: $url"
  QUERY_STRING="ch=${channel}&url=${encoded_url}" bash "$UPDATE_SCRIPT"
}

cmd="${1:-}"
case "$cmd" in
  list)
    channels "${2:-mx}" "${3:-}"
    ;;
  add)
    if [ "$#" -lt 4 ]; then
      usage >&2
      exit 1
    fi
    add_channel "$2" "$3" "$4"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac