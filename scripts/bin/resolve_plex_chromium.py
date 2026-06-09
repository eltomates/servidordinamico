#!/usr/bin/env python3
"""
Resuelve la URL HLS de Plex Live TV usando Chromium/Playwright.

Uso: python3 resolve_plex_chromium.py <page_url> [timeout_seconds]
Salida: URL de playlist HLS en stdout, diagnostico en stderr.
"""

import os
import sys
import urllib.request

page_url = sys.argv[1] if len(sys.argv) > 1 else "https://watch.plex.tv/es/live-tv/channel/canela-tv-narco-drama"
timeout_sec = int(sys.argv[2]) if len(sys.argv) > 2 else 12
headless_mode = os.environ.get("PW_HEADLESS", "1") != "0"

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    sys.exit("ERROR: playwright no instalado. Ejecuta: python3 -m playwright install chromium")


def is_candidate(url: str) -> bool:
    return (
        url.startswith("https://")
        and ".m3u8" in url
        and "plex.tv/library/parts/" in url
    )


def score_url(url: str) -> int:
    score = 0
    if "/variant.m3u8" in url:
        score -= 40
    if "/library/parts/" in url:
        score += 60
    if "X-Plex-Token=" in url or "x-plex-token=" in url:
        score += 30
    if "includeAllStreams=1" in url:
        score += 120
    if "url=" in url:
        score -= 30
    if "epg-ipv4.provider.plex.tv" in url:
        score += 50
    return score


def verify_playlist(url: str, timeout: int = 8) -> bool:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        text = response.read().decode("utf-8", "ignore")

    if "#EXTM3U" not in text:
        return False

    markers = (
        "#EXT-X-STREAM-INF",
        ".ts",
        ".m4s",
        ".cmfv",
        ".cmfa",
        ".mp4",
    )
    return any(marker in text for marker in markers)


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

        page.wait_for_timeout(3000)

        for selector in [
            'button[aria-label*="play"]',
            'button[aria-label*="Play"]',
            '.vjs-big-play-button',
            'button:has-text("Ver ahora")',
            'button:has-text("Reproducir")',
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
                        try { video.muted = true; } catch (e) {}
                        try { video.play(); } catch (e) {}
                    }
                }
                """
            )
        except Exception:
            pass

        page.wait_for_timeout(timeout_sec * 1000)
        browser.close()

    candidates = sorted({url for url in seen}, key=score_url, reverse=True)
    if not candidates:
        sys.exit("ERROR: No se capturo playlist HLS de Plex en Chromium")

    for candidate in candidates[:8]:
        try:
            if verify_playlist(candidate):
                print(candidate)
                return 0
        except Exception as exc:
            print(f"[chromium] Validacion fallo para candidata: {exc}", file=sys.stderr)

    print(candidates[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())