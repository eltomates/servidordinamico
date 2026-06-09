#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/var/www/html"

cd "$REPO_DIR"

if [[ -n "${1:-}" ]]; then
  COMMIT_MSG="$*"
else
  COMMIT_MSG="actualizacion $(date '+%Y-%m-%d %H:%M:%S')"
fi

git add -A

if git diff --cached --quiet; then
  echo "No hay cambios para subir."
  exit 0
fi

git commit -m "$COMMIT_MSG"
git push

echo "Respaldo enviado a GitHub en origin/main."
