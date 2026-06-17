#!/usr/bin/env python3
"""
Resuelve la URL HLS de Pluto TV usando Chromium/Playwright.

Uso: python3 resolve_pluto_chromium.py <page_url> [timeout_seconds]
Salida: URL de playlist HLS en stdout, diagnóstico en stderr.
"""

import os
import sys
import re
import urllib.request

page_url = sys.argv[1] if len(sys.argv) > 1 else "https://pluto.tv/latam/live-tv/5ddd7cb2cbb9010009b4fe32"
timeout_sec = int(sys.argv[2]) if len(sys.argv) > 2 else 15
headless_mode = os.environ.get("PW_HEADLESS", "1") != "0"
skip_verify = os.environ.get("PLUTO_SKIP_VERIFY", "0") == "1"
target_bandwidth = int(os.environ.get("PLUTO_TARGET_BANDWIDTH", "0") or "0")

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    sys.exit("ERROR: playwright no instalado. Ejecuta: python3 -m playwright install chromium")


def is_candidate(url: str) -> bool:
    return (
        url.startswith("https://")
        and ".m3u8" in url
        and "/v2/stitch/hls/channel/" in url
    )


def score_url(url: str) -> int:
    score = 0
    if "/v2/stitch/hls/channel/" in url:
        score += 40
    if "livestitch/" in url:
        score += 80
    if "/playlist.m3u8" in url:
        score += 20
    if "/master.m3u8" in url:
        score += 10
    if "jwt=" in url:
        score += 20
    if target_bandwidth > 0:
        match = re.search(r"/channel/[a-f0-9]{24}/(\d+)/playlist\.m3u8", url)
        if match:
            bandwidth = int(match.group(1))
            score -= min(abs(bandwidth - target_bandwidth) // 10000, 300)
    return score


def verify_playlist(url: str, timeout: int = 8) -> bool:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        text = response.read().decode("utf-8", "ignore")

    if "ptv_takedownslates" in text or "Device No Longer Available" in text:
        return False

    if "#EXTM3U" not in text:
        return False

    # Pluto puede entregar variantes MPEG-TS o CMAF/fMP4 segun el canal.
    segment_markers = (".ts", ".m4s", ".cmfv", ".cmfa", ".mp4")
    return any(marker in text for marker in segment_markers)


def main() -> int:
    seen = []

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=headless_mode,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
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
            locale="es-MX",
            timezone_id="America/Mexico_City",
        )

        context.add_init_script(
            """
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            window.chrome = window.chrome || { runtime: {} };
            Object.defineProperty(navigator, 'language', { get: () => 'es-MX' });
            Object.defineProperty(navigator, 'languages', { get: () => ['es-MX', 'es', 'en-US', 'en'] });
            """
        )

        def on_response(response):
            url = response.url
            if is_candidate(url):
                seen.append(url)
                print(f"[resp] {url[:240]}", file=sys.stderr)

        context.on("response", on_response)

        page = context.new_page()
        print(f"[chromium] Abriendo: {page_url}", file=sys.stderr)

        try:
            page.goto(page_url, wait_until="domcontentloaded", timeout=45000)
        except PlaywrightTimeout:
            print("[chromium] Timeout en goto, continuando...", file=sys.stderr)
        except Exception as exc:
            print(f"[chromium] goto error: {exc}", file=sys.stderr)

        page.wait_for_timeout(4000)

        try:
            page.mouse.click(640, 260)
            page.wait_for_timeout(1000)
        except Exception:
            pass

        for selector in [
            'button[aria-label*="play"]',
            'button[aria-label*="Play"]',
            '.vjs-big-play-button',
            'button[aria-label*="Silencio"]',
        ]:
            try:
                page.locator(selector).first.click(timeout=1200)
                page.wait_for_timeout(800)
            except Exception:
                continue

        try:
            page.evaluate(
                """
                () => {
                    for (const video of document.querySelectorAll('video')) {
                        try { video.play(); } catch (e) {}
                    }
                }
                """
            )
        except Exception:
            pass

        # Espera en pasos cortos para poder salir apenas se capture una playlist.
        for _ in range(timeout_sec):
            page.wait_for_timeout(1000)
            if skip_verify and seen:
                break

    candidates = sorted({url for url in seen}, key=score_url, reverse=True)
    if not candidates:
        sys.exit("ERROR: No se capturó playlist HLS de Pluto en Chromium")

    top_candidates = candidates[:6]

    if skip_verify:
        # Modo rapido: devolver la mejor candidata capturada por Chromium.
        print(top_candidates[0])
        return 0

    for candidate in top_candidates:
        try:
            if verify_playlist(candidate):
                print(candidate)
                return 0
        except Exception as exc:
            print(f"[chromium] Validación falló para candidata: {exc}", file=sys.stderr)

    # Evita bucles largos: si se capturó una candidata con JWT, usarla como fallback.
    fallback = top_candidates[0]
    if "jwt=" in fallback and "/playlist.m3u8" in fallback:
        print("[chromium] Aviso: usando candidata sin verificar (fallback)", file=sys.stderr)
        print(fallback)
        return 0

    sys.exit("ERROR: Pluto sólo devolvió playlists no reproducibles en Chromium")


if __name__ == "__main__":
    raise SystemExit(main())