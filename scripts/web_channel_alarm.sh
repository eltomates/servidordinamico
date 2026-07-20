#!/usr/bin/env bash

# Registra alarmas de canales web y mantiene un estado JSON simple.
# Uso: web_channel_alarm.sh <canal> <ALARM|OK> <mensaje>

set -euo pipefail

CHANNEL="${1:-}"
LEVEL="${2:-ALARM}"
MESSAGE="${3:-}"

if [ -z "$CHANNEL" ]; then
  echo "Uso: $0 <canal> <ALARM|OK> <mensaje>" >&2
  exit 1
fi

LOG_DIR="/var/www/html/logs"
ALARM_LOG="$LOG_DIR/web_alarm.log"
STATUS_FILE="$LOG_DIR/web_alarm_status.json"
EMAIL_THROTTLE_FILE="$LOG_DIR/web_alarm_email_throttle.json"
EMAIL_ENV_PRIMARY="$LOG_DIR/web_alarm_email.env"
EMAIL_ENV_FALLBACK="/var/www/html/scripts/web_alarm_email.env"

mkdir -p "$LOG_DIR"

NOW_EPOCH="$(date +%s)"
NOW_HUMAN="$(date '+%F %T')"

echo "[web_alarm] $NOW_HUMAN channel=$CHANNEL level=$LEVEL msg=$MESSAGE" >> "$ALARM_LOG"

is_recoverable_guardian_flap() {
    if [ "$LEVEL" != "ALARM" ]; then
        return 1
    fi

    case "$CHANNEL:$MESSAGE" in
        web12:"web12 congelado ("*|web14:"web14 congelado ("*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if is_recoverable_guardian_flap; then
    echo "[web_alarm] $NOW_HUMAN alarma suprimida por flap recuperable channel=$CHANNEL level=$LEVEL" >> "$ALARM_LOG"
    exit 0
fi

if [ -f "$EMAIL_ENV_PRIMARY" ]; then
    # shellcheck source=/var/www/html/logs/web_alarm_email.env
    set -a
    . "$EMAIL_ENV_PRIMARY"
    set +a
elif [ -f "$EMAIL_ENV_FALLBACK" ]; then
    # shellcheck source=/var/www/html/scripts/web_alarm_email.env
    set -a
    . "$EMAIL_ENV_FALLBACK"
    set +a
fi

python3 - "$STATUS_FILE" "$CHANNEL" "$LEVEL" "$MESSAGE" "$NOW_EPOCH" <<'PY'
import json
import os
import sys

status_file, channel, level, message, now_epoch = sys.argv[1:]
now_epoch = int(now_epoch)

data = {"timestamp": now_epoch, "channels": {}}
if os.path.exists(status_file):
    try:
        with open(status_file, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data.update(loaded)
            if not isinstance(data.get("channels"), dict):
                data["channels"] = {}
    except Exception:
        pass

data["timestamp"] = now_epoch
entry = data["channels"].get(channel, {})
if not isinstance(entry, dict):
    entry = {}

entry["level"] = level
entry["message"] = message
entry["updated_at"] = now_epoch
data["channels"][channel] = entry

tmp = status_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=True, separators=(",", ":"))
os.replace(tmp, status_file)
PY

email_event_is_extreme() {
    if [ "$LEVEL" != "ALARM" ]; then
        return 0
    fi

    if [ "${EMAIL_ALARM_MODE:-extreme}" = "all" ]; then
        return 0
    fi

    case "$MESSAGE" in
        *"sin actualizar tras reinicio"*|*"degradado tras reinicio"*|*"no levantó tras reinicio"*|*"caido/congelado"*|*"congelado"*|*"detenido"*)
            return 0
            ;;
        *)
            echo "[web_alarm] $NOW_HUMAN email filtrado no extremo channel=$CHANNEL level=$LEVEL" >> "$ALARM_LOG"
            return 1
            ;;
    esac
}

email_event_is_throttled() {
    if [ "$LEVEL" != "ALARM" ]; then
        return 1
    fi

    local cooldown="${EMAIL_CHANNEL_COOLDOWN_SECONDS:-1800}"
    if ! [[ "$cooldown" =~ ^[0-9]+$ ]] || [ "$cooldown" -le 0 ]; then
        return 1
    fi

    python3 - "$EMAIL_THROTTLE_FILE" "$CHANNEL" "$NOW_EPOCH" "$cooldown" <<'PY'
import json
import os
import sys

throttle_file, channel, now_epoch, cooldown = sys.argv[1:]
now_epoch = int(now_epoch)
cooldown = int(cooldown)

data = {}
if os.path.exists(throttle_file):
    try:
        with open(throttle_file, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data = loaded
    except Exception:
        data = {}

last_sent = int(data.get(channel, 0) or 0)
if last_sent and now_epoch - last_sent < cooldown:
    raise SystemExit(0)

raise SystemExit(1)
PY
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[web_alarm] $NOW_HUMAN email en cooldown channel=$CHANNEL level=$LEVEL cooldown=${cooldown}s" >> "$ALARM_LOG"
        return 0
    fi

    return 1
}

mark_email_sent() {
    python3 - "$EMAIL_THROTTLE_FILE" "$CHANNEL" "$NOW_EPOCH" <<'PY'
import json
import os
import sys

throttle_file, channel, now_epoch = sys.argv[1:]
now_epoch = int(now_epoch)

data = {}
if os.path.exists(throttle_file):
    try:
        with open(throttle_file, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data = loaded
    except Exception:
        data = {}

data[channel] = now_epoch
tmp = throttle_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=True, separators=(",", ":"))
os.replace(tmp, throttle_file)
PY
}

send_email_alert() {
    if [ "${ENABLE_EMAIL_ALERTS:-0}" != "1" ]; then
        return 2
    fi

    if ! email_event_is_extreme; then
        return 2
    fi

    if email_event_is_throttled; then
        return 2
    fi

    if [ -z "${EMAIL_TO:-}" ] || [ -z "${SMTP_HOST:-}" ] || [ -z "${SMTP_USER:-}" ] || [ -z "${SMTP_PASS:-}" ]; then
        echo "[web_alarm] $NOW_HUMAN email no configurado completamente; se omite envio." >> "$ALARM_LOG"
        return 2
    fi

    if [ "$LEVEL" != "ALARM" ] && [ "${EMAIL_SEND_OK:-0}" != "1" ]; then
        return 2
    fi

    python3 - "$CHANNEL" "$LEVEL" "$MESSAGE" "$NOW_HUMAN" <<'PY'
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

channel, level, message, now_human = sys.argv[1:]

smtp_host = os.getenv("SMTP_HOST", "").strip()
smtp_port = int(os.getenv("SMTP_PORT", "587").strip() or "587")
smtp_user = os.getenv("SMTP_USER", "").strip()
smtp_pass = os.getenv("SMTP_PASS", "")
smtp_from = os.getenv("EMAIL_FROM", smtp_user).strip()
email_to = [x.strip() for x in os.getenv("EMAIL_TO", "").split(",") if x.strip()]
subject_prefix = os.getenv("EMAIL_SUBJECT_PREFIX", "WEB-HLS")
starttls = os.getenv("SMTP_STARTTLS", "1").strip() == "1"

if not (smtp_host and smtp_user and smtp_pass and smtp_from and email_to):
        raise SystemExit(0)

msg = EmailMessage()
msg["From"] = smtp_from
msg["To"] = ", ".join(email_to)
msg["Subject"] = f"[{subject_prefix}] {level} {channel}"
msg.set_content(
        f"Hora: {now_human}\n"
        f"Canal: {channel}\n"
        f"Nivel: {level}\n"
        f"Mensaje: {message}\n"
)

context = ssl.create_default_context()
with smtplib.SMTP(smtp_host, smtp_port, timeout=20) as server:
        if starttls:
                server.starttls(context=context)
        server.login(smtp_user, smtp_pass)
        server.send_message(msg)
PY
    mark_email_sent || true
}

if send_email_alert; then
    echo "[web_alarm] $NOW_HUMAN email enviado channel=$CHANNEL level=$LEVEL" >> "$ALARM_LOG"
else
    rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "[web_alarm] $NOW_HUMAN email omitido channel=$CHANNEL level=$LEVEL" >> "$ALARM_LOG"
    else
        echo "[web_alarm] $NOW_HUMAN fallo al enviar email channel=$CHANNEL level=$LEVEL" >> "$ALARM_LOG"
    fi
fi
