#!/usr/bin/env bash

# CGI sencillo para reiniciar los contenedores Docker de video (dock_video1 y dock_video2)

echo "Content-Type: text/plain"
echo

DOCKER_DIR="/var/www/html/docker"

if [ ! -d "$DOCKER_DIR" ]; then
  echo "ERROR: Directorio $DOCKER_DIR no existe."
  exit 1
fi

cd "$DOCKER_DIR" || {
  echo "ERROR: No se pudo entrar en $DOCKER_DIR";
  exit 1;
}

if command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker-compose"
elif docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
else
  echo "ERROR: No se encontró docker-compose ni 'docker compose'." >&2
  exit 1
fi

# Intentar reiniciar; si no existen aún, levantarlos
if $DOCKER_COMPOSE restart dock_video1 dock_video2 2>/dev/null; then
  echo "OK: Contenedores dock_video1 y dock_video2 reiniciados."
else
  if $DOCKER_COMPOSE up -d dock_video1 dock_video2; then
    echo "OK: Contenedores dock_video1 y dock_video2 arrancados."
  else
    echo "ERROR: No se pudieron reiniciar/arrancar los contenedores Docker."
  fi
fi
