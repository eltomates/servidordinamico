#!/usr/bin/env bash

# Helper functions shared by the web HLS proxy scripts.

acquire_single_instance_lock() {
  local script_path="${1:-$0}"
  local lock_name
  local lock_dir="${WEB_HLS_LOCK_DIR:-/var/www/html/logs/locks}"
  lock_name="$(basename "$script_path").lock"
  local lock_file="${lock_dir}/${lock_name}"

  mkdir -p "$lock_dir"
  chmod 777 "$lock_dir" 2>/dev/null || true

  if [ ! -e "$lock_file" ]; then
    : >"$lock_file"
  fi
  chmod 666 "$lock_file" 2>/dev/null || true
  exec 9<>"$lock_file"
  if ! flock -n 9; then
    echo "[$(basename "$script_path")] ya tiene una instancia activa; saliendo." >&2
    return 1
  fi

  return 0
}

trim_hls_segments() {
  local target="$1"
  local keep="${2:-20}"

  if [ -z "$target" ]; then
    echo "[lib_web_hls] missing target directory" >&2
    return 1
  fi

  if [ ! -d "$target" ]; then
    return 0
  fi

  # Ordenamos por fecha de modificación (los más nuevos primero) y borramos el resto.
  mapfile -t segments < <(ls -1t "$target"/seg_*.ts 2>/dev/null || true)

  local total="${#segments[@]}"
  if [ "$total" -le "$keep" ]; then
    return 0
  fi

  local i
  for ((i=keep; i<total; i++)); do
    rm -f "${segments[$i]}" 2>/dev/null || true
  done
}
