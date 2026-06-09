#!/usr/bin/env python3
"""
Resuelve la URL del stream HLS de TV Azteca usando Chromium headless (Playwright).
Abre la página, espera a que el player inicie y captura la petición al CDN MDSTRM.

Uso: python3 resolve_tvazteca_chromium.py <page_url> [timeout_seconds]
Salida: URL de la playlist HLS de MDSTRM en stdout, diagnóstico en stderr
"""

import re
import sys
import time
import os

page_url = sys.argv[1] if len(sys.argv) > 1 else "https://www.tvazteca.com/aztecauno/envivo"
timeout_sec = int(sys.argv[2]) if len(sys.argv) > 2 else 40
headless_mode = os.environ.get("PW_HEADLESS", "1") != "0"
debug_all_requests = os.environ.get("PW_DEBUG_ALL", "0") == "1"

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    sys.exit("ERROR: playwright no instalado. Ejecuta: python3 -m playwright install chromium")

# Patrones de URL HLS del CDN MDSTRM
MDSTRM_PATTERNS = [
    re.compile(r'https://[^\s"\'<>]+\.cdn\.mdstrm\.com/live-stream[^\s"\'<>]*\.m3u8'),
    re.compile(r'https://[^\s"\'<>]+\.mdstrm\.com/live-stream[^\s"\'<>]*\.m3u8'),
    re.compile(r'https://[^\s"\'<>]+/live-stream[^\s"\'<>]*/hls/[^\s"\'<>]*\.m3u8'),
]

captured_url = None


def check_url(url):
    global captured_url
    if captured_url:
        return
    for pat in MDSTRM_PATTERNS:
        m = pat.search(url)
        if m:
            captured_url = m.group(0)
            print(f"[CAPTURED] {captured_url}", file=sys.stderr)
            return


def on_request(request):
    url = request.url
    if debug_all_requests or "mdstrm" in url or "m3u8" in url:
        print(f"[req] {url[:200]}", file=sys.stderr)
    check_url(url)


def on_response(response):
    url = response.url
    if "mdstrm" in url or "m3u8" in url:
        print(f"[resp] {url[:200]}", file=sys.stderr)
    check_url(url)


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=headless_mode,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
                "--mute-audio",
                "--autoplay-policy=no-user-gesture-required",
            ],
        )
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1280, "height": 720},
        )

        # Atenuar señales comunes de automatización para sitios con anti-bot.
        context.add_init_script(
            """
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64' });
            Object.defineProperty(navigator, 'language', { get: () => 'es-MX' });
            Object.defineProperty(navigator, 'languages', { get: () => ['es-MX', 'es', 'en-US', 'en'] });
            window.chrome = window.chrome || { runtime: {} };
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
            """
        )

        context.on("request", on_request)
        context.on("response", on_response)

        page = context.new_page()

        print(f"[chromium] Abriendo: {page_url}", file=sys.stderr)
        try:
            page.goto(page_url, wait_until="domcontentloaded", timeout=timeout_sec * 1000)
            print("[chromium] Página cargada", file=sys.stderr)
        except PlaywrightTimeout:
            print("[chromium] Timeout en goto, continuando...", file=sys.stderr)
        except Exception as e:
            print(f"[chromium] goto error: {e}", file=sys.stderr)

        # Intento primario: leer src de iframe MDSTRM en el DOM.
        try:
            page.wait_for_timeout(1500)
            iframe_src = page.evaluate(
                """
                () => {
                    const frames = Array.from(document.querySelectorAll('iframe'));
                    const found = frames.find(f => f.src && f.src.includes('mdstrm.com/live-stream/'));
                    return found ? found.src : null;
                }
                """
            )
            if iframe_src:
                print(f"[chromium] iframe mdstrm detectado", file=sys.stderr)
                print(iframe_src)
                context.close()
                browser.close()
                return
        except Exception:
            pass

        # Dar tiempo al JS para cargar el player y hacer click para activarlo
        try:
            page.wait_for_timeout(2000)
            page.mouse.click(640, 360)
            print("[chromium] Click enviado al player", file=sys.stderr)
        except Exception:
            pass

        # Intentar botones típicos de play para sitios con overlay
        play_selectors = [
            "button[aria-label*='Play']",
            "button[aria-label*='play']",
            ".vjs-big-play-button",
            "[class*='play']",
        ]
        for selector in play_selectors:
            try:
                page.locator(selector).first.click(timeout=1500)
                print(f"[chromium] Click selector: {selector}", file=sys.stderr)
                page.wait_for_timeout(500)
            except Exception:
                continue

        # Forzar play en cualquier tag <video> encontrado.
        try:
            page.evaluate(
                """
                () => {
                    const videos = Array.from(document.querySelectorAll('video'));
                    for (const v of videos) {
                        try { v.muted = true; v.play(); } catch (e) {}
                    }
                }
                """
            )
            print("[chromium] Intento de play() en elementos video", file=sys.stderr)
        except Exception:
            pass

        # Esperar hasta capturar la URL o timeout
        deadline = time.time() + timeout_sec
        while not captured_url and time.time() < deadline:
            try:
                page.wait_for_timeout(500)
            except Exception:
                break

        context.close()
        browser.close()

    if not captured_url:
        sys.exit("ERROR: No se capturó URL de MDSTRM en la página")

    print(captured_url)


if __name__ == "__main__":
    main()
