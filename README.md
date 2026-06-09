# Proxy HLS web1 / web2 / web3
web 5 no funciona por que estoy metiendo directo el livess
Este directorio `html/` contiene los HLS locales servidos por Apache y los scripts para proxear señales remotas (web1, web2, web3) a playlists HLS propias.

## Estructura

- `index.html` → página web principal (puede reproducir los streams HLS locales).
- `lista.m3u` → lista de canales (puede apuntar a `/hls/.../index.m3u8`).
- `hls/` → salida HLS servida por Apache.
  - `hls/web1/` → segmentos `.ts` y `index.m3u8` para web1.
  - `hls/web2/` → segmentos `.ts` y `index.m3u8` para web2.
  - `hls/web3/` → segmentos `.ts` y `index.m3u8` para web3.
- `scripts/` → scripts de ffmpeg y helpers.
  - `scripts/ffmpeg_web1_proxy.sh`
  - `scripts/ffmpeg_web2_proxy.sh`
  - `scripts/ffmpeg_web3_proxy.sh`
  - `scripts/start_all_proxies.sh`

## Cómo funciona cada webX

Cada `ffmpeg_webX_proxy.sh`:

- Toma una URL HLS remota (`SRC_URL`).
- Recodifica el video a H.264 Baseline + audio AAC.
- Genera un HLS local en `hls/webX/index.m3u8` con segmentos `seg_000000.ts`, `seg_000001.ts`, etc.
- Está envuelto en un bucle infinito `while true` para que, si `ffmpeg` se cae o el origen falla, espere 5 segundos y vuelva a intentar.

## Arrancar todos los proxys web

Desde `/var/www`:

```bash
sudo bash html/scripts/start_all_proxies.sh
```

Este script:

- Mata instancias viejas de `ffmpeg_web1_proxy.sh`, `ffmpeg_web2_proxy.sh`, `ffmpeg_web3_proxy.sh` y procesos `ffmpeg` asociados.
- Lanza cada proxy en segundo plano con `nohup`.
- Deja los logs en:
   - `/var/www/html/logs/ffmpeg_web1.log`
   - `/var/www/html/logs/ffmpeg_web2.log`
   - `/var/www/html/logs/ffmpeg_web3.log`
   - `/var/www/html/logs/ffmpeg_web4.log`

## Cómo agregar una nueva web (web4, web5, etc.)

1. Copiar un script existente en `html/scripts/` (por ejemplo web3) y renombrarlo:

   ```bash
   cd /var/www/html/scripts
   cp ffmpeg_web3_proxy.sh ffmpeg_web4_proxy.sh
   ```

2. Editar el nuevo script y cambiar:

   ```bash
   OUT="/var/www/html/hls/web4"
   SRC_URL="http://IP:PUERTO/play/XXXX/index.m3u8"
   ```

   Por ejemplo, para el servicio `web4` usando la URL remota indicada:

   ```bash
   OUT="/var/www/html/hls/web4"
   SRC_URL="http://45.225.68.1:8532/Live/878e0987f8fffce401028e0283b0b24d/local-ch7.playlist.m3u8"
   ```

3. Crear la carpeta de salida:

   ```bash
   mkdir -p /var/www/html/hls/web4
   ```

4. Editar `html/scripts/start_all_proxies.sh` para añadir web4:

   - En la sección de `pkill`:

     ```bash
     pkill -f ffmpeg_web4_proxy.sh 2>/dev/null || true
     pkill -f 'ffmpeg .*hls/web4' 2>/dev/null || true
     ```

   - En la sección de `nohup`:

     ```bash
     nohup bash "$SCRIPT_DIR/ffmpeg_web4_proxy.sh" > /tmp/ffmpeg_web4.log 2>&1 &
     ```

5. Reiniciar todos los proxys:

   ```bash
   cd /var/www
   sudo bash html/scripts/start_all_proxies.sh
   ```

6. Consumir la nueva señal HLS desde:

   ```text
   http://TU_HOST/hls/web4/index.m3u8
   ```

## Diagnóstico rápido

- Si un canal se queda en una escena fija:
  - Revisa que la playlist `hls/webX/index.m3u8` **no** tenga `#EXT-X-ENDLIST` y que las fechas sigan cambiando.
  - Mira el log en `/tmp/ffmpeg_webX.log` para ver errores.

## Monitor de estado (web_status.json)

El script [scripts/monitor_web_proxies.sh](scripts/monitor_web_proxies.sh) escribe el panel `logs/web_status.json`. Además de revisar que los `.ts` se actualicen cada `STALE_SECONDS` ahora también marca un canal como "no actualizando" en dos escenarios adicionales:

- El log `logs/ffmpeg_webX.log` contiene al menos `MAX_ERROR_HITS` coincidencias con `ERROR_LOG_PATTERNS` en las últimas `ERROR_LOG_LINES` líneas (ej. repeticiones de `HTTP error 404`).
- Aunque los `.ts` tengan marcas de tiempo recientes, el directorio mantiene menos de `MIN_SEGMENTS_HEALTH` segmentos durante más de `LOW_SEGMENTS_GRACE` segundos (típico de orígenes que solo entregan 1-2 fragmentos antes de fallar).

Puedes ajustar estos umbrales exportando variables antes de lanzar el monitor, por ejemplo:

```bash
MIN_SEGMENTS_HEALTH=8 LOW_SEGMENTS_GRACE=120 MAX_ERROR_HITS=2 sudo nohup bash html/scripts/monitor_web_proxies.sh &
```

## Ajuste de buffer para Web1 (aplicable al resto)

Para amortiguar los microcortes detectados en el origen de Web1 se incrementó el búfer local:

- `KEEP_TS` ahora conserva 45 segmentos en [scripts/ffmpeg_web1_proxy.sh](scripts/ffmpeg_web1_proxy.sh), lo que deja ~3.5 minutos de historial antes de purgar archivos.
- Se introdujo la variable `HLS_TIME` (por defecto 5 s) y se ajustó el GOP (`-g`) para que los segmentos nuevos sigan alineados con keyframes.

Si otro proxy (web2, web3, etc.) necesita el mismo comportamiento, se puede:

1. Copiar los valores de `KEEP_TS`, `HLS_TIME` y `GOP_SIZE` dentro del `ffmpeg_webX_proxy.sh` correspondiente, o exportarlos como variables de entorno antes de lanzar el script (`KEEP_TS=45 HLS_TIME=5 sudo bash html/scripts/ffmpeg_web2_proxy.sh`).
2. Reiniciar el proxy afectado mediante `sudo bash html/scripts/start_all_proxies.sh` para que tome la nueva configuración.
