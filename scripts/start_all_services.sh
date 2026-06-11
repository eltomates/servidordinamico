#!/usr/bin/env bash

# Arranca todos los proxys HLS web y el monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"

mkdir -p "$LOG_DIR"

start_hdmi_channel() {
  local channel="$1"
  local script="$SCRIPT_DIR/ffmpeg_${channel}.sh"
  local log_file="$LOG_DIR/ffmpeg_${channel}.log"

  if [ ! -x "$script" ]; then
    echo "[start_all_services] Aviso: $script no encontrado o sin permisos de ejecución, saltando $channel." >&2
    return
  fi

  if pgrep -f "ffmpeg_${channel}.sh" >/dev/null 2>&1 || pgrep -f "ffmpeg .*hls/${channel}" >/dev/null 2>&1; then
    echo "[start_all_services] $channel ya está en ejecución."
    return
  fi

  echo "[start_all_services] Lanzando $channel..."
  nohup bash "$script" > "$log_file" 2>&1 &
}

echo "[start_all_services] Arrancando capturas HDMI (hdmi1-hdmi4)..."
start_hdmi_channel "hdmi1"
start_hdmi_channel "hdmi2"
start_hdmi_channel "hdmi3"
start_hdmi_channel "hdmi4"

# Reiniciar proxys HLS existentes
if [ -x "$SCRIPT_DIR/start_all_proxies.sh" ]; then
  echo "[start_all_services] Reiniciando proxys HLS web..."
  bash "$SCRIPT_DIR/start_all_proxies.sh"
else
  echo "[start_all_services] Aviso: start_all_proxies.sh no encontrado o no es ejecutable, saltando proxys HLS." >&2
fi

MONITOR_WEB_SCRIPT="$SCRIPT_DIR/monitor_web_proxies.sh"
if [ -x "$MONITOR_WEB_SCRIPT" ]; then
  if ! pgrep -f "monitor_web_proxies.sh" >/dev/null 2>&1; then
    echo "[start_all_services] Lanzando monitor de proxys HLS..."
    nohup bash "$MONITOR_WEB_SCRIPT" > "$LOG_DIR/monitor_web_proxies.log" 2>&1 &
  else
    echo "[start_all_services] Monitor de proxys HLS ya está en ejecución."
  fi
else
  echo "[start_all_services] Aviso: monitor_web_proxies.sh no encontrado o no es ejecutable, no se lanza el monitor." >&2
fi

WEB12_GUARDIAN_SCRIPT="$SCRIPT_DIR/web12_guardian.sh"
if [ -x "$WEB12_GUARDIAN_SCRIPT" ]; then
  if ! pgrep -f "web12_guardian.sh" >/dev/null 2>&1; then
    echo "[start_all_services] Lanzando guardian de web12..."
    nohup bash "$WEB12_GUARDIAN_SCRIPT" > "$LOG_DIR/web12_guardian.log" 2>&1 &
  else
    echo "[start_all_services] Guardian de web12 ya está en ejecución."
  fi
else
  echo "[start_all_services] Aviso: web12_guardian.sh no encontrado o no es ejecutable, no se lanza el guardian." >&2
fi

WEB14_GUARDIAN_SCRIPT="$SCRIPT_DIR/web14_guardian.sh"
if [ -x "$WEB14_GUARDIAN_SCRIPT" ]; then
  if ! pgrep -f "web14_guardian.sh" >/dev/null 2>&1; then
    echo "[start_all_services] Lanzando guardian de web14..."
    nohup bash "$WEB14_GUARDIAN_SCRIPT" > "$LOG_DIR/web14_guardian.log" 2>&1 &
  else
    echo "[start_all_services] Guardian de web14 ya está en ejecución."
  fi
else
  echo "[start_all_services] Aviso: web14_guardian.sh no encontrado o no es ejecutable, no se lanza el guardian." >&2
fi

HDMI4_GUARDIAN_SCRIPT="$SCRIPT_DIR/hdmi4_guardian.sh"
if [ -x "$HDMI4_GUARDIAN_SCRIPT" ]; then
  if ! pgrep -f "hdmi4_guardian.sh" >/dev/null 2>&1; then
    echo "[start_all_services] Lanzando guardian de hdmi4..."
    nohup bash "$HDMI4_GUARDIAN_SCRIPT" > "$LOG_DIR/hdmi4_guardian.log" 2>&1 &
  else
    echo "[start_all_services] Guardian de hdmi4 ya está en ejecución."
  fi
else
  echo "[start_all_services] Aviso: hdmi4_guardian.sh no encontrado o no es ejecutable, no se lanza el guardian." >&2
fi

echo "[start_all_services] Todo iniciado (capturas HDMI + proxys HLS + monitor + guardian web12/web14/hdmi4)."
