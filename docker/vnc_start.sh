#!/usr/bin/env bash
set -e

# --- Configuración de Entorno ---
DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
export DISPLAY=":${DISPLAY_NUMBER}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
# Resolución del escritorio (noVNC) en 720p
SCREEN_RESOLUTION="1280x720x24"
VIDEO_URL="${VIDEO_URL:-}"
HLS_OUTPUT_DIR="${HLS_OUTPUT_DIR:-}"
HLS_SEGMENT_SECONDS="${HLS_SEGMENT_SECONDS:-4}"
# FPS para HLS (compromiso fluidez/carga)
CAPTURE_FRAMERATE="${CAPTURE_FRAMERATE:-20}"

# Tamaño de captura HLS independiente de la resolución del escritorio
IFS='x' read -r CAP_WIDTH CAP_HEIGHT _ <<<"${SCREEN_RESOLUTION}"
# 480p ancho (bueno para internet, menos consumo): 854x480
CAPTURE_WIDTH="${CAPTURE_WIDTH:-854}"
CAPTURE_HEIGHT="${CAPTURE_HEIGHT:-480}"
CAPTURE_SIZE="${CAPTURE_WIDTH}x${CAPTURE_HEIGHT}"

# --- Limpieza de Procesos y Archivos de Bloqueo Anteriores ---
LOCK_FILE="/tmp/.X${DISPLAY_NUMBER}-lock"
SOCKET_FILE="/tmp/.X11-unix/X${DISPLAY_NUMBER}"

echo "[vnc_start] Limpiando procesos y archivos de bloqueo anteriores para DISPLAY=${DISPLAY}..."
rm -rf /tmp/.X11-unix || true
mkdir -p /tmp/.X11-unix || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "$LOCK_FILE" "$SOCKET_FILE"
pkill -f Xvfb || true
pkill -f x11vnc || true
pkill -f websockify || true
sleep 1

echo "[vnc_start] Iniciando servidor de audio PulseAudio (fuente 'default')"
pulseaudio -D --exit-idle-time=-1 2>/dev/null || echo "[vnc_start] Aviso: no se pudo iniciar PulseAudio" >&2
sleep 2

# Usar la fuente de audio por defecto de PulseAudio
AUDIO_SOURCE="${AUDIO_SOURCE:-default}"

# --- Iniciar Servicios en Segundo Plano ---

# 1. Iniciar servidor de pantalla virtual (Xvfb)
echo "[vnc_start] Lanzando Xvfb en ${DISPLAY} con resolución ${SCREEN_RESOLUTION}"
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_RESOLUTION}" -nolisten tcp &
XVFB_PID=$!
sleep 1 # Dar tiempo a que Xvfb se inicie

if ! kill -0 "$XVFB_PID" >/dev/null 2>&1; then
	echo "[vnc_start] ERROR: Xvfb falló al iniciar. Revisar locks en /tmp/.X11-unix." >&2
	exit 1
fi

# 2. Iniciar servidor VNC (x11vnc)
echo "[vnc_start] Lanzando x11vnc en el puerto VNC ${VNC_PORT}"
x11vnc -display "${DISPLAY}" -nopw -forever -shared -rfbport "${VNC_PORT}" &
X11VNC_PID=$!

# 3. Iniciar el proxy de noVNC (websockify)
echo "[vnc_start] Lanzando noVNC en el puerto HTTP ${NOVNC_PORT}"
websockify --web=/usr/share/novnc "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
NOVNC_PID=$!

start_hls_capture() {
	if [ -z "$HLS_OUTPUT_DIR" ]; then
		return
	fi

	mkdir -p "$HLS_OUTPUT_DIR"
	echo "[vnc_start] Iniciando captura HLS en ${HLS_OUTPUT_DIR}"

	(
		set +e
		while true; do
			ffmpeg \
				-loglevel warning \
				-f x11grab -framerate "$CAPTURE_FRAMERATE" -video_size "$CAPTURE_SIZE" -i "${DISPLAY}.0" \
				-f pulse -i "${AUDIO_SOURCE}" \
				-c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
				-g 80 -keyint_min 80 -sc_threshold 0 \
				-b:v 900k -maxrate 1100k -bufsize 1800k \
				-c:a aac -b:a 128k \
				-map 0:v:0 -map 1:a:0 \
				-f hls \
				-hls_time "$HLS_SEGMENT_SECONDS" -hls_list_size 6 \
				-hls_flags delete_segments+program_date_time+independent_segments \
				-hls_segment_filename "$HLS_OUTPUT_DIR/seg_%06d.ts" \
				"$HLS_OUTPUT_DIR/index.m3u8"

			FFMPEG_RC=$?
			if [ "$FFMPEG_RC" -ne 0 ]; then
				echo "[vnc_start] ffmpeg de captura salió con código $FFMPEG_RC. Reintentando en 2s..." >&2
			fi
			sleep 2
		done
	) &
	FFMPEG_PID=$!
}

start_hls_capture

# 4. Lanzar Chromium hacia VIDEO_URL si está definido; si no, un xterm
if [ -n "$VIDEO_URL" ] && [ "$VIDEO_URL" != "about:blank" ]; then
	echo "[vnc_start] Lanzando Chromium hacia ${VIDEO_URL}"
	chromium \
		--no-sandbox \
		--autoplay-policy=no-user-gesture-required \
		--ignore-certificate-errors \
		--disable-dev-shm-usage \
		--disable-gpu \
		--no-first-run \
		--disable-infobars \
		--disable-notifications \
		--disable-translate \
		--window-size="${CAP_WIDTH},${CAP_HEIGHT}" \
		--start-fullscreen \
		"$VIDEO_URL" &
	APP_PID=$!
	APP_DESC="Chromium"
else
	echo "[vnc_start] Lanzando xterm en ${DISPLAY}"
	DISPLAY=${DISPLAY} xterm &
	APP_PID=$!
	APP_DESC="xterm"
fi

echo "[vnc_start] Servicios iniciados. PIDs: Xvfb=${XVFB_PID}, x11vnc=${X11VNC_PID}, noVNC=${NOVNC_PID}, app=${APP_PID} (${APP_DESC})"

# Mantener el contenedor vivo mientras la aplicación principal siga abierta
wait $APP_PID

echo "[vnc_start] ${APP_DESC} finalizado. Deteniendo servicios..."
kill $NOVNC_PID $X11VNC_PID $XVFB_PID 2>/dev/null || true
if [ -n "${FFMPEG_PID:-}" ]; then
	kill $FFMPEG_PID 2>/dev/null || true
fi
echo "[vnc_start] Contenedor detenido."
