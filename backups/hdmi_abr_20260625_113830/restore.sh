#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="/var/www/html/scripts"
cp -a "$BACKUP_DIR"/ffmpeg_hdmi*.sh "$SCRIPT_DIR"/
if [ -f "$BACKUP_DIR"/hdmi4_guardian.sh ]; then
  cp -a "$BACKUP_DIR"/hdmi4_guardian.sh "$SCRIPT_DIR"/
fi
echo "Restaurados scripts HDMI desde $BACKUP_DIR"
