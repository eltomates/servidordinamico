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
# Intervalo entre rondas de chequeo (por defecto, 1 minuto)
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
# Ventana para confirmar que un proxy realmente desapareció antes de reiniciar.
NO_PROXY_GRACE_SECONDS="${NO_PROXY_GRACE_SECONDS:-45}"
MIN_SEGMENTS_HEALTH="${MIN_SEGMENTS_HEALTH:-5}"
LOW_SEGMENTS_GRACE="${LOW_SEGMENTS_GRACE:-180}"
ERROR_LOG_LINES="${ERROR_LOG_LINES:-80}"
ERROR_LOG_PATTERNS="${ERROR_LOG_PATTERNS:-HTTP error|Error opening input|Failed to reload playlist}"
MAX_ERROR_HITS="${MAX_ERROR_HITS:-3}"
RESTART_ALERT_WINDOW_SECONDS="${RESTART_ALERT_WINDOW_SECONDS:-21600}"
RESTART_ALERT_THRESHOLD="${RESTART_ALERT_THRESHOLD:-3}"
PROXY_PRESENCE_CHANNELS="${PROXY_PRESENCE_CHANNELS:-web5 web13 web15}"
TVAZTECA_CHANNELS="${TVAZTECA_CHANNELS:-web5 web15}"
TVAZTECA_STALE_SECONDS="${TVAZTECA_STALE_SECONDS:-90}"
DISABLED_CHANNELS="${DISABLED_CHANNELS:-web1 web11}"
DEFAULT_MONITORED_CHANNELS="web1 web2 web3 web4 web5 web6 web7 web8 web9 web10 web11 web12 web13 web14 web15 web16"
MONITORED_CHANNELS="${MONITORED_CHANNELS:-$DEFAULT_MONITORED_CHANNELS}"
FALLBACK_FLAG_DIR="${FALLBACK_FLAG_DIR:-$LOG_DIR/channel_fallback_flags}"

declare -A LOW_SEGMENT_SINCE=()
declare -A MISSING_PROXY_SINCE=()
declare -A RESTART_HISTORY=()
declare -A RESTART_STORM_ALERTED_AT=()

mkdir -p "$LOG_DIR"
mkdir -p "$FALLBACK_FLAG_DIR"

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

  latest=$(find "$dir" -maxdepth 2 -type f -name "seg_*.ts" -printf "%T@ %p
" 2>/dev/null | sort -nr | cut -d" " -f2- | head -n1 || true)
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

  find "$dir" -maxdepth 2 -type f -name "seg_*.ts" 2>/dev/null | wc -l
}

channel_has_fresh_master_playlist() {
  local channel="$1"
  local dir="$2"
  local now_ts="$3"
  local master="$dir/index.m3u8"
  local master_mtime
  local variant_uri

  case "$channel" in
    web10) ;;
    *) return 1 ;;
  esac

  if [ ! -f "$master" ]; then
    return 1
  fi

  master_mtime="$(stat -c %Y "$master" 2>/dev/null || echo 0)"
  if [ "$master_mtime" -eq 0 ] || [ $(( now_ts - master_mtime )) -ge "$STALE_SECONDS" ]; then
    return 1
  fi

  if ! grep -q '^#EXT-X-STREAM-INF:' "$master"; then
    return 1
  fi

  variant_uri="$(awk '
    /^#EXT-X-STREAM-INF:/ { want = 1; next }
    want && $0 !~ /^#/ && NF { print; exit }
  ' "$master")"

  if [ -z "$variant_uri" ]; then
    return 1
  fi

  case "$variant_uri" in
    http://*|https://*)
      return 1
      ;;
  esac

  [ -f "$dir/$variant_uri" ]
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

channel_in_list() {
  local channel="$1"
  local list="$2"

  case " $list " in
    *" $channel "*) return 0 ;;
    *) return 1 ;;
  esac
}

effective_stale_seconds() {
  local channel="$1"

  if channel_in_list "$channel" "$TVAZTECA_CHANNELS"; then
    echo "$TVAZTECA_STALE_SECONDS"
    return
  fi

  echo "$STALE_SECONDS"
}

stale_age_message() {
  local last_mtime="$1"
  local now_ts="$2"

  if [ "$last_mtime" -le 0 ] 2>/dev/null; then
    echo "sin segmentos"
    return
  fi

  echo "edad=$(( now_ts - last_mtime ))s"
}

prune_restart_history() {
  local channel="$1"
  local now_ts="$2"
  local ts
  local -a kept=()

  for ts in ${RESTART_HISTORY[$channel]:-}; do
    if [ $(( now_ts - ts )) -lt "$RESTART_ALERT_WINDOW_SECONDS" ]; then
      kept+=("$ts")
    fi
  done

  RESTART_HISTORY[$channel]="${kept[*]:-}"
}

record_restart_attempt() {
  local channel="$1"
  local now_ts="$2"
  local history

  prune_restart_history "$channel" "$now_ts"
  history="${RESTART_HISTORY[$channel]:-}"

  if [ -n "$history" ]; then
    RESTART_HISTORY[$channel]="$history $now_ts"
  else
    RESTART_HISTORY[$channel]="$now_ts"
  fi
}

restart_attempt_count() {
  local channel="$1"
  local now_ts="$2"

  prune_restart_history "$channel" "$now_ts"
  if [ -z "${RESTART_HISTORY[$channel]:-}" ]; then
    echo 0
    return
  fi

  set -- ${RESTART_HISTORY[$channel]}
  echo $#
}

enable_preventive_fallback() {
  local channel="$1"
  local now_ts="$2"
  local flag_file

  case "$channel" in
    web13) ;;
    *) return 0 ;;
  esac

  flag_file="$FALLBACK_FLAG_DIR/${channel}.force_fallback"
  printf '%s
' "$now_ts" > "$flag_file"
  log "$channel marcado para fallback preventivo en $flag_file."
}

maybe_alert_restart_storm() {
  local channel="$1"
  local now_ts="$2"
  local reason="$3"
  local restart_count
  local last_alert

  restart_count="$(restart_attempt_count "$channel" "$now_ts")"
  if [ "$restart_count" -lt "$RESTART_ALERT_THRESHOLD" ]; then
    return
  fi

  last_alert="${RESTART_STORM_ALERTED_AT[$channel]:-0}"
  if [ "$last_alert" -gt 0 ] && [ $(( now_ts - last_alert )) -lt "$RESTART_ALERT_WINDOW_SECONDS" ]; then
    return
  fi

  RESTART_STORM_ALERTED_AT[$channel]="$now_ts"
  enable_preventive_fallback "$channel" "$now_ts"
  log "$channel acumula $restart_count reinicios automaticos dentro de ${RESTART_ALERT_WINDOW_SECONDS}s ($reason)."
  send_alarm "$channel" "ALARM" "$channel requiere atencion; $restart_count reinicios automaticos en ${RESTART_ALERT_WINDOW_SECONDS}s ($reason)"
}

channel_has_running_proxy() {
  local channel="$1"

  pgrep -f "ffmpeg_${channel}_proxy.sh" >/dev/null 2>&1 ||     pgrep -f "ffmpeg .*hls/${channel}/" >/dev/null 2>&1
}

restart_channel() {
  local channel="$1"
  local orchestrator="$SCRIPT_DIR/start_all_proxies.sh"

  log "Reiniciando $channel via start_all_proxies..."

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

channel_is_disabled() {
  case " $DISABLED_CHANNELS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

write_status_file() {
  local now_ts="$1"
  shift
  local -a not_updating=("$@")

  {
    printf '{ "timestamp": %s, "channels_not_updating": [' "$now_ts"
    if [ "${#not_updating[@]}" -gt 0 ]; then
      printf '"%s"' "${not_updating[0]}"
      local i
      for ((i=1; i<${#not_updating[@]}; i++)); do
        printf ',"%s"' "${not_updating[i]}"
      done
    fi
    printf '] }
'
  } > "$STATUS_FILE.tmp"

  command mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

init_ts="$(date +%s)"
write_status_file "$init_ts"
log "Monitor de proxys HLS iniciado (STALE_SECONDS=$STALE_SECONDS, RECHECK_DELAY=$RECHECK_DELAY, CHECK_INTERVAL=$CHECK_INTERVAL, NO_PROXY_GRACE_SECONDS=$NO_PROXY_GRACE_SECONDS, RESTART_ALERT_THRESHOLD=$RESTART_ALERT_THRESHOLD, RESTART_ALERT_WINDOW_SECONDS=$RESTART_ALERT_WINDOW_SECONDS, PROXY_PRESENCE_CHANNELS=$PROXY_PRESENCE_CHANNELS, MONITORED_CHANNELS=$MONITORED_CHANNELS, DISABLED_CHANNELS=$DISABLED_CHANNELS)."

while true; do
  now_ts="$(date +%s)"
  failed_after_restart=()

  for channel in $MONITORED_CHANNELS; do
    case "$channel" in
      web[1-9]|web1[0-6]) ;;
      *)
        log "Ignorando canal invalido en MONITORED_CHANNELS: $channel"
        continue
        ;;
    esac

    if channel_is_disabled "$channel"; then
      unset 'LOW_SEGMENT_SINCE[$channel]'
      unset 'MISSING_PROXY_SINCE[$channel]'
      continue
    fi

    dir="$BASE_HLS_DIR/$channel"
    last_mtime="$(get_last_ts_mtime "$dir")"
    segment_count="$(count_segments "$dir")"
    error_hits="$(recent_error_hits "$channel")"
    stale_seconds="$(effective_stale_seconds "$channel")"
    proxy_running=0

    if channel_in_list "$channel" "$PROXY_PRESENCE_CHANNELS"; then
      if channel_has_running_proxy "$channel"; then
        proxy_running=1
        unset 'MISSING_PROXY_SINCE[$channel]'
      else
        missing_since="${MISSING_PROXY_SINCE[$channel]:-0}"
        if [ "$missing_since" -eq 0 ]; then
          MISSING_PROXY_SINCE[$channel]="$now_ts"
          missing_since="$now_ts"
          log "$channel detectado sin proceso proxy activo; esperando ${NO_PROXY_GRACE_SECONDS}s antes de reiniciar."
        fi
      fi
    else
      proxy_running=1
      unset 'MISSING_PROXY_SINCE[$channel]'
    fi

    if [ "$proxy_running" -eq 0 ]; then
      missing_grace="$NO_PROXY_GRACE_SECONDS"
      if channel_in_list "$channel" "$TVAZTECA_CHANNELS"; then
        missing_grace=0
      fi

      if [ $(( now_ts - missing_since )) -lt "$missing_grace" ]; then
        continue
      fi

      log "$channel no tiene proceso proxy/ffmpeg activo; reinicio completo preventivo..."
      send_alarm "$channel" "ALARM" "$channel sin proceso proxy activo; intentando reinicio completo"
      record_restart_attempt "$channel" "$now_ts"
      maybe_alert_restart_storm "$channel" "$now_ts" "proxy ausente"
      restart_channel "$channel"

      sleep "$RECHECK_DELAY"
      now_ts2="$(date +%s)"
      last_mtime2="$(get_last_ts_mtime "$dir")"

      if [ "$last_mtime2" -eq 0 ] || [ $(( now_ts2 - last_mtime2 )) -ge "$stale_seconds" ] || ! channel_has_running_proxy "$channel"; then
        failed_after_restart+=("$channel")
        write_status_file "$now_ts2" "${failed_after_restart[@]}"
        log "$channel no levantó tras reinicio completo (last_mtime2=$last_mtime2, now2=$now_ts2, stale_seconds=$stale_seconds)."
        send_alarm "$channel" "ALARM" "$channel no levantó tras reinicio completo ($(stale_age_message "$last_mtime2" "$now_ts2"))"
      else
        log "$channel levantó tras reinicio completo preventivo."
        send_alarm "$channel" "OK" "$channel recuperado tras reinicio completo preventivo"
        unset 'MISSING_PROXY_SINCE[$channel]'
      fi

      continue
    fi

    if [ "$error_hits" -ge "$MAX_ERROR_HITS" ]; then
      log "$channel presenta $error_hits errores recientes en el log ffmpeg (patrones: $ERROR_LOG_PATTERNS), pero se usará el estado real de los segmentos para el panel."
    fi

    if [ "$segment_count" -gt 0 ] && [ "$segment_count" -lt "$MIN_SEGMENTS_HEALTH" ]; then
      since_ts="${LOW_SEGMENT_SINCE[$channel]:-0}"
      if [ "$since_ts" -eq 0 ]; then
        LOW_SEGMENT_SINCE[$channel]="$now_ts"
        log "$channel detectado con buffer reducido (segmentos=$segment_count)."
      fi

      if [ $(( now_ts - LOW_SEGMENT_SINCE[$channel] )) -ge "$LOW_SEGMENTS_GRACE" ]; then
        log "$channel lleva más de $LOW_SEGMENTS_GRACE s con menos de $MIN_SEGMENTS_HEALTH segmentos; intentando reinicio..."
        send_alarm "$channel" "ALARM" "$channel degradado; intentando reinicio (segmentos=$segment_count)"
        record_restart_attempt "$channel" "$now_ts"
        maybe_alert_restart_storm "$channel" "$now_ts" "buffer reducido"
        restart_channel "$channel"

        sleep "$RECHECK_DELAY"
        now_ts2="$(date +%s)"
        last_mtime2="$(get_last_ts_mtime "$dir")"
        segment_count2="$(count_segments "$dir")"

        if [ "$last_mtime2" -eq 0 ] || [ $(( now_ts2 - last_mtime2 )) -ge "$stale_seconds" ] || [ "$segment_count2" -lt "$MIN_SEGMENTS_HEALTH" ]; then
          failed_after_restart+=("$channel")
          write_status_file "$now_ts2" "${failed_after_restart[@]}"
          log "$channel sigue degradado tras reinicio (last_mtime2=$last_mtime2, segmentos2=$segment_count2, now2=$now_ts2)."
          send_alarm "$channel" "ALARM" "$channel degradado tras reinicio (segmentos=$segment_count2, $(stale_age_message "$last_mtime2" "$now_ts2"))"
        else
          log "$channel volvió a un estado saludable tras el reinicio (segmentos2=$segment_count2)."
          send_alarm "$channel" "OK" "$channel recuperado tras reinicio (segmentos=$segment_count2)"
          unset 'LOW_SEGMENT_SINCE[$channel]'
        fi
      fi

      continue
    else
      unset 'LOW_SEGMENT_SINCE[$channel]'
    fi

    if [ "$last_mtime" -eq 0 ] || [ $(( now_ts - last_mtime )) -ge "$stale_seconds" ]; then
      if channel_has_fresh_master_playlist "$channel" "$dir" "$now_ts"; then
        log "$channel saludable por master playlist passthrough fresco; se omite reinicio por segmentos locales."
        send_alarm "$channel" "OK" "$channel saludable por master playlist passthrough"
        continue
      fi

      log "$channel detectado sin actualizar (last_mtime=$last_mtime, now=$now_ts). Intentando reinicio..."
      if [ "$last_mtime" -eq 0 ]; then
        send_alarm "$channel" "ALARM" "$channel sin actualizar; intentando reinicio (sin segmentos)"
      else
        send_alarm "$channel" "ALARM" "$channel sin actualizar; intentando reinicio (edad=$(( now_ts - last_mtime ))s)"
      fi
      record_restart_attempt "$channel" "$now_ts"
      maybe_alert_restart_storm "$channel" "$now_ts" "sin segmentos frescos"
      restart_channel "$channel"

      sleep "$RECHECK_DELAY"
      now_ts2="$(date +%s)"
      last_mtime2="$(get_last_ts_mtime "$dir")"

      if channel_has_fresh_master_playlist "$channel" "$dir" "$now_ts2"; then
        log "$channel recuperado por master playlist passthrough fresco tras reinicio."
        send_alarm "$channel" "OK" "$channel saludable por master playlist passthrough"
      elif [ "$last_mtime2" -eq 0 ] || [ $(( now_ts2 - last_mtime2 )) -ge "$stale_seconds" ]; then
        failed_after_restart+=("$channel")
        write_status_file "$now_ts2" "${failed_after_restart[@]}"
        log "$channel sigue sin actualizar tras reinicio (last_mtime2=$last_mtime2, now2=$now_ts2)."
        send_alarm "$channel" "ALARM" "$channel sin actualizar tras reinicio ($(stale_age_message "$last_mtime2" "$now_ts2"))"
      else
        log "$channel volvió a generar segmentos tras el reinicio."
        send_alarm "$channel" "OK" "$channel recuperado; volvió a generar segmentos"
      fi
    fi
  done

  write_status_file "$now_ts" "${failed_after_restart[@]}"
  sleep "$CHECK_INTERVAL"
done
