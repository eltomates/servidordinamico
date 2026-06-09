#!/usr/bin/env bash

# Arranca todos los proxys HLS web1, web2, web3, web4, web5, web6, web7, web8, web9, web10, web11, web12, web13, web14, web15 y web16

set -e

LOCK_DIR="${WEB_HLS_LOCK_DIR:-/var/www/html/logs/locks}"
mkdir -p "$LOCK_DIR"
chmod 777 "$LOCK_DIR" 2>/dev/null || true

LOCK_FILE="$LOCK_DIR/web_proxies_orchestrator.lock"
if [ ! -e "$LOCK_FILE" ]; then
	: >"$LOCK_FILE"
fi
chmod 666 "$LOCK_FILE" 2>/dev/null || true
exec 8<>"$LOCK_FILE"
if ! flock -n 8; then
	echo "[start_all_proxies] ya hay otra ejecucion en curso; saliendo."
	exit 0
fi

CHANNEL_ONLY=""
OVERRIDE_URL="${SRC_URL_OVERRIDE:-}"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--channel)
			CHANNEL_ONLY="${2:-}"
			shift 2
			;;
		--url)
			OVERRIDE_URL="${2:-}"
			shift 2
			;;
		*)
			echo "Uso: $0 [--channel webN] [--url URL]" >&2
			exit 1
			;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/www/html/logs"
PRIMARY_CONFIG="$LOG_DIR/web_sources.env"
LEGACY_CONFIG="$SCRIPT_DIR/web_sources.env"

if [ -f "$PRIMARY_CONFIG" ]; then
	CONFIG_FILE="$PRIMARY_CONFIG"
elif [ -f "$LEGACY_CONFIG" ]; then
	CONFIG_FILE="$LEGACY_CONFIG"
else
	CONFIG_FILE=""
fi

if [ -n "$CONFIG_FILE" ]; then
	# Carga variables WEB1_URL, WEB2_URL, ... si existen
	# shellcheck source=/var/www/html/logs/web_sources.env
	# shellcheck source=/var/www/html/scripts/web_sources.env
	. "$CONFIG_FILE"
fi

mkdir -p "$LOG_DIR"

CHANNELS=(web1 web2 web3 web4 web5 web6 web7 web8 web9 web10 web11 web12 web13 web14 web15 web16)

runtime_user_for_channels() {
	local owner

	if [ "$(id -u)" -ne 0 ]; then
		printf '%s' "$(id -un)"
		return 0
	fi

	owner="$(stat -c '%U' "$LOG_DIR" 2>/dev/null || true)"
	if [ -n "$owner" ] && [ "$owner" != "root" ] && id "$owner" >/dev/null 2>&1; then
		printf '%s' "$owner"
		return 0
	fi

	printf '%s' "root"
}

launch_channel_process() {
	local runtime_user="$1"
	local script="$2"
	local log_file="$3"
	local src_url="$4"
	local launch_prefix=""
	local runtime_uid
	local runtime_gid
	local runtime_home
	local env_prefix=( )

	runtime_home="$(getent passwd "$runtime_user" | cut -d: -f6 2>/dev/null || true)"
	if [ -z "$runtime_home" ]; then
		runtime_home="/root"
	fi
	env_prefix=(env "HOME=$runtime_home" "USER=$runtime_user" "LOGNAME=$runtime_user")

	if [ "$(id -u)" -eq 0 ] && [ "$runtime_user" != "root" ]; then
		if command -v setpriv >/dev/null 2>&1; then
			runtime_uid="$(id -u "$runtime_user" 2>/dev/null || true)"
			runtime_gid="$(id -g "$runtime_user" 2>/dev/null || true)"
			if [ -n "$runtime_uid" ] && [ -n "$runtime_gid" ]; then
				launch_prefix="setpriv --reuid=$runtime_uid --regid=$runtime_gid --init-groups"
			fi
		fi

		if [ -z "$launch_prefix" ] && command -v runuser >/dev/null 2>&1; then
			launch_prefix="runuser -u $runtime_user --"
		fi
	fi

	if [ -n "$src_url" ]; then
		if [ -n "$launch_prefix" ]; then
			SRC_URL="$src_url" nohup "${env_prefix[@]}" $launch_prefix bash "$script" 8>&- > "$log_file" 2>&1 &
		else
			SRC_URL="$src_url" nohup "${env_prefix[@]}" bash "$script" 8>&- > "$log_file" 2>&1 &
		fi
	else
		if [ -n "$launch_prefix" ]; then
			nohup "${env_prefix[@]}" $launch_prefix bash "$script" 8>&- > "$log_file" 2>&1 &
		else
			nohup "${env_prefix[@]}" bash "$script" 8>&- > "$log_file" 2>&1 &
		fi
	fi
}

channel_url_from_config() {
	local channel="$1"
	local var_name
	local resolved_var_name
	local watch_url
	local legacy_watch_url
	var_name="$(echo "$channel" | tr 'a-z' 'A-Z')_URL"
	resolved_var_name="$(echo "$channel" | tr 'a-z' 'A-Z')_RESOLVED_URL"
	watch_url="${!var_name:-}"

	if [ "$channel" = "web7" ] || [ "$channel" = "web10" ]; then
		printf '%s' "${!var_name:-}"
		return 0
	fi

	if [ -n "$LEGACY_CONFIG" ] && [ -f "$LEGACY_CONFIG" ] && [[ "$watch_url" != https://watch.plex.tv/*/live-tv/channel/* && "$watch_url" != https://watch.plex.tv/live-tv/channel/* ]]; then
		legacy_watch_url="$(awk -F '"' -v key="$var_name" '$1 == key"=" {print $2; exit}' "$LEGACY_CONFIG")"
		case "$legacy_watch_url" in
			https://watch.plex.tv/*/live-tv/channel/*|https://watch.plex.tv/live-tv/channel/*)
				printf '%s' "$legacy_watch_url"
				return 0
				;;
		esac
	fi

	case "$watch_url" in
		https://watch.plex.tv/*/live-tv/channel/*|https://watch.plex.tv/live-tv/channel/*)
			printf '%s' "$watch_url"
			return 0
			;;
	esac

	printf '%s' "${!resolved_var_name:-${!var_name:-}}"
}

restart_one_channel() {
	local channel="$1"
	local forced_url="${2:-}"
	local script="$SCRIPT_DIR/ffmpeg_${channel}_proxy.sh"
	local log_file="$LOG_DIR/ffmpeg_${channel}.log"
	local src_url="$forced_url"
	local runtime_user
	local stopped="0"
	local i
	local pattern_script="ffmpeg_${channel}_proxy.sh"
	local pattern_ffmpeg="ffmpeg .*hls/${channel}/"

	if [ ! -x "$script" ]; then
		echo "[start_all_proxies] Aviso: $script no encontrado o sin permisos de ejecucion." >&2
		return 1
	fi

	pkill -f "$pattern_script" 2>/dev/null || true
	pkill -f "$pattern_ffmpeg" 2>/dev/null || true

	# Espera breve para evitar carrera con flock al reiniciar inmediatamente.
	for i in $(seq 1 20); do
		if ! pgrep -f "$pattern_script" >/dev/null 2>&1 && \
			! pgrep -f "$pattern_ffmpeg" >/dev/null 2>&1; then
			stopped="1"
			break
		fi

		# Si siguen vivos tras ~5s, escalar a SIGKILL para evitar reinicios fallidos.
		if [ "$i" -eq 10 ]; then
			pkill -9 -f "$pattern_script" 2>/dev/null || true
			pkill -9 -f "$pattern_ffmpeg" 2>/dev/null || true
		fi
		sleep 0.5
	done

	if [ "$stopped" != "1" ]; then
		echo "[start_all_proxies] Aviso: no se pudo detener por completo ${channel}; reinicio cancelado." >&2
		return 1
	fi

	# Eliminar lock file después de confirmar que todos los procesos murieron.
	# Los hijos (chromium, ffmpeg) pueden haber heredado el fd del flock y mantenerlo
	# activo aunque el script principal ya esté muerto (lock fantasma).
	local lock_file="${LOCK_DIR}/ffmpeg_${channel}_proxy.sh.lock"
	rm -f "$lock_file" 2>/dev/null || true

	if [ -z "$src_url" ]; then
		src_url="$(channel_url_from_config "$channel")"
	fi

	runtime_user="$(runtime_user_for_channels)"

	launch_channel_process "$runtime_user" "$script" "$log_file" "$src_url"

	return 0
}

if [ -n "$CHANNEL_ONLY" ]; then
	case "$CHANNEL_ONLY" in
		web1|web2|web3|web4|web5|web6|web7|web8|web9|web10|web11|web12|web13|web14|web15|web16) ;;
		*)
			echo "[start_all_proxies] ERROR: canal invalido: $CHANNEL_ONLY" >&2
			exit 1
			;;
	esac

	restart_one_channel "$CHANNEL_ONLY" "$OVERRIDE_URL"
	echo "[start_all_proxies] Canal $CHANNEL_ONLY reiniciado."
	exit 0
fi

for channel in "${CHANNELS[@]}"; do
	restart_one_channel "$channel" ""
done

echo "[start_all_proxies] Proxys web1-web16 iniciados."