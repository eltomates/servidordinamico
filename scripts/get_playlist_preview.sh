#!/usr/bin/env bash

# Devuelve una vista previa (limitada) de una lista M3U remota.

set -euo pipefail

DEFAULT_URL="http://tv.diablotv.net:8080/get.php?username=avedano1&password=0ee550e405a6&type=m3u_plus"
MAX_BYTES=600000
CURL_BIN="$(command -v curl || true)"
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
ALLOW_INSECURE=0
FORCED_TLS_PROFILE=""

printf '%s\n' "Content-Type: text/plain; charset=utf-8"
printf '%s\n' "Cache-Control: no-store"
printf '\n'

if [ -z "$CURL_BIN" ]; then
  printf '%s\n' "ERROR: curl no está disponible en el servidor."
  exit 0
fi

urldecode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

QS="${QUERY_STRING:-}"
TARGET_URL="$DEFAULT_URL"

IFS='&' read -r -a pairs <<< "$QS"
for pair in "${pairs[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  decoded="$(urldecode "$val" 2>/dev/null || true)"
  case "$key" in
    target)
      if [[ "$decoded" =~ ^https?:// ]]; then
        TARGET_URL="$decoded"
      fi
      ;;
    insecure)
      case "$decoded" in
        1|true|yes) ALLOW_INSECURE=1 ;;
      esac
      ;;
    tls)
      lower="${decoded,,}"
      case "$lower" in
        strict|compat|legacy)
          FORCED_TLS_PROFILE="$lower"
          ;;
      esac
      ;;
    limit)
      if [[ "$decoded" =~ ^[0-9]+$ ]]; then
        local_limit="$decoded"
        if [ "$local_limit" -lt 50000 ]; then
          local_limit=50000
        elif [ "$local_limit" -gt 2000000 ]; then
          local_limit=2000000
        fi
        MAX_BYTES="$local_limit"
      fi
      ;;
  esac
done

TMP_FILE="$(mktemp)"
TMP_ERR="$(mktemp)"
cleanup() {
  rm -f "$TMP_FILE" "$TMP_ERR"
}
trap cleanup EXIT

profile_label() {
  case "$1" in
    compat) echo "modo compatible" ;;
    legacy) echo "modo legado" ;;
    *) echo "modo estricto" ;;
  esac
}

run_fetch() {
  local profile="$1"
  local extra_opts=()
  case "$profile" in
    compat)
      extra_opts+=("-k" "--tls-max" "1.2" "--http1.1")
      ;;
    legacy)
      extra_opts+=("-k" "--tlsv1.0" "--ciphers" "DEFAULT@SECLEVEL=0" "--http1.1")
      ;;
  esac

  "$CURL_BIN" -sSL \
    --max-time 20 \
    --retry 2 \
    --retry-delay 2 \
    -A "$USER_AGENT" \
    "${extra_opts[@]}" \
    -o "$TMP_FILE" \
    -w '%{http_code}' \
    "$TARGET_URL" 2>"$TMP_ERR"
}

build_profile_order() {
  local order=()
  if [ -n "$FORCED_TLS_PROFILE" ]; then
    order=("$FORCED_TLS_PROFILE")
  else
    if [ "$ALLOW_INSECURE" -eq 1 ]; then
      order=("compat" "legacy")
    else
      order=("strict" "compat" "legacy")
    fi
  fi
  printf '%s\n' "${order[*]}"
}

PROFILE_SEQUENCE=( $(build_profile_order) )
SUCCESS_PROFILE=""
LAST_PROFILE=""
HTTP_STATUS="000"
CURL_EXIT=1

for profile in "${PROFILE_SEQUENCE[@]}"; do
  LAST_PROFILE="$profile"
  set +e
  HTTP_STATUS="$(run_fetch "$profile")"
  CURL_EXIT=$?
  set -e
  if [ "$CURL_EXIT" -eq 0 ] && [ "$HTTP_STATUS" = "200" ]; then
    SUCCESS_PROFILE="$profile"
    break
  fi
done

if [ -z "$SUCCESS_PROFILE" ]; then
  if [ -n "$FORCED_TLS_PROFILE" ]; then
    printf 'ERROR: No se pudo obtener la lista usando el perfil TLS forzado (%s). HTTP %s.\n' "$(profile_label "$FORCED_TLS_PROFILE")" "$HTTP_STATUS"
  else
    printf 'ERROR: No se pudo obtener la lista tras probar perfiles TLS (último intento %s, HTTP %s).\n' "$(profile_label "$LAST_PROFILE")" "$HTTP_STATUS"
  fi
  if [ -s "$TMP_ERR" ]; then
    printf '\nDETALLE curl:\n'
    head -n 5 "$TMP_ERR"
    printf '\nTIP: prueba con el parámetro tls=legacy o verifica que el servidor permita conexiones TLS estándar.\n'
  fi
  exit 0
fi

if [ ! -s "$TMP_FILE" ]; then
  printf '%s\n' "ERROR: La respuesta llegó vacía."
  exit 0
fi

TOTAL_BYTES="$(wc -c < "$TMP_FILE" | tr -d ' ')"
head -c "$MAX_BYTES" "$TMP_FILE"

if [ "$TOTAL_BYTES" -gt "$MAX_BYTES" ]; then
  printf '\n\n---\n(La salida se recortó a los primeros %s bytes. Envía limit=%s para ampliar.)\n' "$MAX_BYTES" "$MAX_BYTES"
fi
