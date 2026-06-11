#!/usr/bin/env bash

# Monitor de proxys HLS web1-web16.
# - Revisa periódicamente los segmentos .ts de cada canal.
# - Si un canal deja de actualizarse, reinicia solo ese proxy ffmpeg.
# - Si tras el reinicio sigue sin generar segmentos, lo marca como "con problemas"
#   en un fichero JSON accesible desde el panel web: /logs/web_status.json.

set -euo pipefail

BASE_HLS_DIR="/var/www/html/hls"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
STATUS_FILE="$LOG_DIR/web_status.json"
ALARM_SCRIPT="$SCRIPT_DIR/web_channel_alarm.sh"
LOCK_DIR="$LOG_DIR/locks"
LOCK_FILE="$LOCK_DIR/monitor_web_proxies.lock"
PRIMARY_CONFIG="$LOG_DIR/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"

if [ -f "$PRIMARY_CONFIG" ]; then
  CONFIG_FILE="$PRIMARY_CONFIG"
elif [ -f "$LEGACY_CONFIG" ]; then
  CONFIG_FILE="$LEGACY_CONFIG"
else
  CONFIG_FILE=""
fi

# Umbral para considerar que un canal está "parado" (en segundos)
STALE_SECONDS="${STALE_SECONDS:-300}"
# Tiempo de espera tras reiniciar un canal antes de volver a comprobarlo
RECHECK_DELAY="${RECHECK_DELAY:-60}"
# Intervalo entre rondas de chequeo (por defecto, 5 minutos)
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
MIN_SEGMENTS_HEALTH="${MIN_SEGMENTS_HEALTH:-5}"
LOW_SEGMENTS_GRACE="${LOW_SEGMENTS_GRACE:-180}"
ERROR_LOG_LINES="${ERROR_LOG_LINES:-80}"
ERROR_LOG_PATTERNS="${ERROR_LOG_PATTERNS:-HTTP error|Error opening input|Failed to reload playlist}"
MAX_ERROR_HITS="${MAX_ERROR_HITS:-3}"
ALARM_AFTER_SECONDS="${ALARM_AFTER_SECONDS:-60}"

declare -A LOW_SEGMENT_SINCE=()
declare -A ERROR_ALARM_ACTIVE=()
declare -A STALE_ALARM_ACTIVE=()
declare -A ERROR_FAIL_SINCE=()
declare -A STALE_FAIL_SINCE=()

mkdir -p "$LOG_DIR"
mkdir -p "$LOCK_DIR"

if [ ! -e "$LOCK_FILE" ]; then
  : >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true
exec 9<>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[monitor_web_proxies] $(date '+%F %T') ya hay otra instancia activa; saliendo." >> "$LOG_DIR/monitor_web_proxies.log"
  exit 0
fi

# Evita que procesos hijos hereden el lock y dejen bloqueos fantasma.
python3 - <<'PY' 2>/dev/null || true
import fcntl

flags = fcntl.fcntl(9, fcntl.F_GETFD)
fcntl.fcntl(9, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
PY

log() {
  echo "[monitor_web_proxies] $(date '+%F %T') $*" >> "$LOG_DIR/monitor_web_proxies.log"
}

get_last_ts_mtime() {
  local dir="$1"
  local latest

  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi

  latest=$(ls -1t "$dir"/*.ts 2>/dev/null | head -n1 || true)
  if [ -z "$latest" ]; then
    echo 0
    return
  fi

  stat -c %Y "$latest" 2>/dev/null || echo 0
}

count_segments() {
  local dir="$1"

  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi

  shopt -s nullglob
  local files=("$dir"/seg_*.ts)
  shopt -u nullglob
  echo "${#files[@]}"
}

recent_error_hits() {
  local channel="$1"
  local log_file="$LOG_DIR/ffmpeg_${channel}.log"

  if [ ! -f "$log_file" ]; then
    echo 0
    return
  fi

  tail -n "$ERROR_LOG_LINES" "$log_file" 2>/dev/null | grep -E -c "$ERROR_LOG_PATTERNS" || true
}

restart_channel() {
  local channel="$1"   # p.ej. "web3"
  local orchestrator="$SCRIPT_DIR/start_all_proxies.sh"

  log "Reiniciando $channel via start_all_proxies..."

  # Delegar a start_all_proxies.sh que: mata procesos hijos (chromium/ffmpeg),
  # espera a que mueran, borra el lock file y relanza limpiamente.
  if [ -x "$orchestrator" ]; then
    bash "$orchestrator" --channel "$channel" >> "$LOG_DIR/monitor_web_proxies.log" 2>&1 &
  else
    log "Aviso: $orchestrator no existe o no es ejecutable, no se puede reiniciar $channel."
  fi
}

send_alarm() {
  local channel="$1"
  local level="$2"
  local message="$3"

  if [ -x "$ALARM_SCRIPT" ]; then
    bash "$ALARM_SCRIPT" "$channel" "$level" "$message" >> "$LOG_DIR/monitor_web_proxies.log" 2>&1 || true
  fi
}

set_error_alarm_state() {
  local channel="$1"
  local state="$2"
  ERROR_ALARM_ACTIVE["$channel"]="$state"
}

set_stale_alarm_state() {
  local channel="$1"
  local state="$2"
  STALE_ALARM_ACTIVE["$channel"]="$state"
}

write_status_file() {
  local now_ts="$1"
  shift
  local -a not_updating=("$@")

  # Construir JSON sencillo a mano para no depender de jq
  {
    printf '{ "timestamp": %s, "channels_not_updating": [' "$now_ts"
    if [ "${#not_updating[@]}" -gt 0 ]; then
      printf '"%s"' "${not_updating[0]}"
      local i
      for ((i=1; i<${#not_updating[@]}; i++)); do
        printf ',"%s"' "${not_updating[i]}"
      done
    fi
    printf '] }\n'
  } > "$STATUS_FILE.tmp"

  # Evitar prompts interactivos por alias mv -i (usamos command mv -f)
  command mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

init_ts="$(date +%s)"
write_status_file "$init_ts"
log "Monitor de proxys HLS iniciado (STALE_SECONDS=$STALE_SECONDS, RECHECK_DELAY=$RECHECK_DELAY, CHECK_INTERVAL=$CHECK_INTERVAL)."

while true; do
  now_ts="$(date +%s)"
  # Lista de canales que actualmente no están actualizando segmentos
  failed_after_restart=()

  for n in $(seq 1 16); do
    channel="web$n"

    dir="$BASE_HLS_DIR/$channel"

    last_mtime="$(get_last_ts_mtime "$dir")"
    segment_count="$(count_segments "$dir")"
    error_hits="$(recent_error_hits "$channel")"

    if [ "$error_hits" -ge "$MAX_ERROR_HITS" ]; then
      log "$channel presenta $error_hits errores recientes en el log ffmpeg (patrones: $ERROR_LOG_PATTERNS), pero se usará el estado real de los segmentos para el panel."

      error_since="${ERROR_FAIL_SINCE[$channel]:-0}"
      if [ "$error_since" -eq 0 ]; then
        ERROR_FAIL_SINCE["$channel"]="$now_ts"
        error_since="$now_ts"
      fi

      if [ $(( now_ts - error_since )) -ge "$ALARM_AFTER_SECONDS" ] && [ "${ERROR_ALARM_ACTIVE[$channel]:-0}" != "1" ]; then
        send_alarm "$channel" "ALARM" "$channel reporta errores de fuente por mas de $ALARM_AFTER_SECONDS s ($error_hits hits recientes)"
        set_error_alarm_state "$channel" "1"
      fi
    else
      unset 'ERROR_FAIL_SINCE[$channel]'
      if [ "${ERROR_ALARM_ACTIVE[$channel]:-0}" = "1" ]; then
        send_alarm "$channel" "OK" "$channel sin errores recientes de fuente"
        set_error_alarm_state "$channel" "0"
      fi
    fi

    if [ "$segment_count" -gt 0 ] && [ "$segment_count" -lt "$MIN_SEGMENTS_HEALTH" ]; then
      since_ts="${LOW_SEGMENT_SINCE[$channel]:-0}"
      if [ "$since_ts" -eq 0 ]; then
        LOW_SEGMENT_SINCE[$channel]="$now_ts"
        log "$channel detectado con buffer reducido (segmentos=$segment_count)."
      fi

      if [ $(( now_ts - LOW_SEGMENT_SINCE[$channel] )) -ge "$LOW_SEGMENTS_GRACE" ]; then
        log "$channel lleva más de $LOW_SEGMENTS_GRACE s con menos de $MIN_SEGMENTS_HEALTH segmentos; intentando reinicio..."

        stale_since="${STALE_FAIL_SINCE[$channel]:-0}"
        if [ "$stale_since" -eq 0 ]; then
          STALE_FAIL_SINCE["$channel"]="$now_ts"
          stale_since="$now_ts"
        fi

        if [ $(( now_ts - stale_since )) -ge "$ALARM_AFTER_SECONDS" ] && [ "${STALE_ALARM_ACTIVE[$channel]:-0}" != "1" ]; then
          send_alarm "$channel" "ALARM" "$channel degradado por mas de $ALARM_AFTER_SECONDS s (segmentos=$segment_count)"
          set_stale_alarm_state "$channel" "1"
        fi

        restart_channel "$channel"

        # Esperar un tiempo y volver a comprobar el canal tras el reinicio.
        sleep "$RECHECK_DELAY"
        now_ts2="$(date +%s)"
        last_mtime2="$(get_last_ts_mtime "$dir")"
        segment_count2="$(count_segments "$dir")"

        if [ "$last_mtime2" -eq 0 ] || [ $(( now_ts2 - last_mtime2 )) -ge "$STALE_SECONDS" ] || [ "$segment_count2" -lt "$MIN_SEGMENTS_HEALTH" ]; then
          failed_after_restart+=("$channel")
          write_status_file "$now_ts2" "${failed_after_restart[@]}"
            log "$channel sigue degradado tras reinicio (last_mtime2=$last_mtime2, segmentos2=$segment_count2, now2=$now_ts2)."
            if [ "${STALE_ALARM_ACTIVE[$channel]:-0}" != "1" ]; then
              send_alarm "$channel" "ALARM" "$channel degradado tras reinicio (segmentos=$segment_count2, edad=$(( now_ts2 - last_mtime2 ))s)"
              set_stale_alarm_state "$channel" "1"
            fi
        else
          log "$channel volvió a un estado saludable tras el reinicio (segmentos2=$segment_count2)."
            send_alarm "$channel" "OK" "$channel recuperado tras reinicio (segmentos=$segment_count2)"
            set_stale_alarm_state "$channel" "0"
          unset 'STALE_FAIL_SINCE[$channel]'
          unset 'LOW_SEGMENT_SINCE[$channel]'
        fi
      fi

      continue
    else
      unset 'LOW_SEGMENT_SINCE[$channel]'
    fi

    # Si nunca se ha generado un segmento o han pasado demasiados segundos, consideramos el canal "parado"
    if [ "$last_mtime" -eq 0 ] || [ $(( now_ts - last_mtime )) -ge "$STALE_SECONDS" ]; then
      log "$channel detectado sin actualizar (last_mtime=$last_mtime, now=$now_ts). Intentando reinicio..."

      stale_since="${STALE_FAIL_SINCE[$channel]:-0}"
      if [ "$stale_since" -eq 0 ]; then
        STALE_FAIL_SINCE["$channel"]="$now_ts"
        stale_since="$now_ts"
      fi

      if [ $(( now_ts - stale_since )) -ge "$ALARM_AFTER_SECONDS" ] && [ "${STALE_ALARM_ACTIVE[$channel]:-0}" != "1" ]; then
        send_alarm "$channel" "ALARM" "$channel sin actualizar por mas de $ALARM_AFTER_SECONDS s (edad_actual=$(( now_ts - last_mtime ))s)"
        set_stale_alarm_state "$channel" "1"
      fi

      restart_channel "$channel"

      # Esperar un tiempo y volver a comprobar solo este canal
      sleep "$RECHECK_DELAY"
      now_ts2="$(date +%s)"
      last_mtime2="$(get_last_ts_mtime "$dir")"

      # Solo si después del reinicio sigue parado lo marcamos como "no actualizando"
      if [ "$last_mtime2" -eq 0 ] || [ $(( now_ts2 - last_mtime2 )) -ge "$STALE_SECONDS" ]; then
        failed_after_restart+=("$channel")
        write_status_file "$now_ts2" "${failed_after_restart[@]}"
          log "$channel sigue sin actualizar tras reinicio (last_mtime2=$last_mtime2, now2=$now_ts2)."
          if [ "${STALE_ALARM_ACTIVE[$channel]:-0}" != "1" ]; then
            send_alarm "$channel" "ALARM" "$channel sin actualizar tras reinicio (edad=$(( now_ts2 - last_mtime2 ))s)"
            set_stale_alarm_state "$channel" "1"
          fi
      else
        log "$channel volvió a generar segmentos tras el reinicio."
          send_alarm "$channel" "OK" "$channel recuperado; volvió a generar segmentos"
          set_stale_alarm_state "$channel" "0"
          unset 'STALE_FAIL_SINCE[$channel]'
      fi
    else
      unset 'STALE_FAIL_SINCE[$channel]'
      if [ "${STALE_ALARM_ACTIVE[$channel]:-0}" = "1" ]; then
        send_alarm "$channel" "OK" "$channel estable; segmentos actualizándose"
        set_stale_alarm_state "$channel" "0"
      fi
    fi
  done

  write_status_file "$now_ts" "${failed_after_restart[@]}"

  sleep "$CHECK_INTERVAL"
done
