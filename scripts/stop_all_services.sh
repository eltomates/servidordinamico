#!/usr/bin/env bash

# Para todos los proxys HLS (web1-web16)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parar proxys HLS (ffmpeg_web*_proxy.sh y ffmpeg asociados)
echo "[stop_all_services] Parando proxys HLS web1-web16..."

pkill -f ffmpeg_web1_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web2_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web3_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web4_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web5_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web6_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web7_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web8_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web9_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web10_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web11_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web12_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web13_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web14_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web15_proxy.sh 2>/dev/null || true
pkill -f ffmpeg_web16_proxy.sh 2>/dev/null || true

pkill -f 'ffmpeg .*hls/web1' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web2' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web3' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web4' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web5' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web6' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web7' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web8' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web9' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web10' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web11' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web12' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web13' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web14' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web15' 2>/dev/null || true
pkill -f 'ffmpeg .*hls/web16' 2>/dev/null || true

pkill -f monitor_web_proxies.sh 2>/dev/null || true
pkill -f web12_guardian.sh 2>/dev/null || true
pkill -f web14_guardian.sh 2>/dev/null || true

echo "[stop_all_services] Todo parado (proxys HLS, monitor y guardian web12/web14)."
