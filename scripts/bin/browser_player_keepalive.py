#!/usr/bin/env python3
"""
Mantiene un reproductor Chromium abierto (modo headed) sobre una URL de canal.
Se usa junto con x11grab para restream de navegador real.
"""

import sys
from typing import Iterable

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    sys.exit("ERROR: playwright no instalado. Ejecuta: python3 -m playwright install chromium")


def click_first(scope, selectors: Iterable[str], timeout: int = 1200) -> bool:
    for selector in selectors:
        try:
            locator = scope.locator(selector).first
            if locator.count() > 0:
                locator.click(timeout=timeout)
                return True
        except Exception:
            continue
    return False


def poke_player(page, width: int, height: int) -> None:
    click_first(
        page,
        [
            "button:has-text('Aceptar')",
            "button:has-text('Acepto')",
            "button:has-text('Allow all')",
            "button:has-text('Accept all')",
            "button:has-text('Reproducir')",
            "button:has-text('Ver ahora')",
            ".vjs-big-play-button",
            "button[aria-label*='play' i]",
            "button[title*='play' i]",
        ],
    )

    try:
        page.mouse.click(max(1, width // 2), max(1, height // 2))
    except Exception:
        pass

    try:
        page.evaluate(
            """
            () => {
                const styleId = 'web4-video-only-style';
                if (!document.getElementById(styleId)) {
                    const st = document.createElement('style');
                    st.id = styleId;
                    st.textContent = `
                      html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; background: #000 !important; }
                      header, nav, [role="banner"], .goog-te-banner-frame, .skiptranslate, .vjs-control-bar { display: none !important; }
                      video { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: contain !important; background: #000 !important; z-index: 2147483647 !important; }
                    `;
                    document.documentElement.appendChild(st);
                }

                const video = document.querySelector('video');
                if (!video) return;
                try { video.muted = false; } catch (e) {}
                try { video.play(); } catch (e) {}
                try { video.setAttribute('controls', ''); video.removeAttribute('controls'); } catch (e) {}
                try {
                    if (document.fullscreenElement !== video) {
                        video.requestFullscreen().catch(() => {});
                    }
                } catch (e) {}
            }
            """
        )
    except Exception:
        pass


def main() -> int:
    page_url = sys.argv[1] if len(sys.argv) > 1 else "https://www.canela.tv/player/channel/canela-clasicos"
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
    height = int(sys.argv[3]) if len(sys.argv) > 3 else 720
    user_agent = (
        sys.argv[4]
        if len(sys.argv) > 4
        else "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    )

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=False,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--autoplay-policy=no-user-gesture-required",
                "--disable-infobars",
                "--disable-features=Translate,TranslateUI",
                "--hide-scrollbars",
                "--kiosk",
                "--start-fullscreen",
                "--window-position=0,0",
                f"--window-size={width},{height}",
            ],
        )
        context = browser.new_context(
            no_viewport=True,
            user_agent=user_agent,
            locale="es-MX",
            timezone_id="America/Mexico_City",
        )
        page = context.new_page()

        print(f"[browser_keepalive] Abriendo {page_url}", file=sys.stderr)
        try:
            page.goto(page_url, wait_until="domcontentloaded", timeout=45000)
        except PlaywrightTimeout:
            print("[browser_keepalive] Timeout en goto, continuando", file=sys.stderr)
        except Exception as exc:
            print(f"[browser_keepalive] goto error: {exc}", file=sys.stderr)

        page.wait_for_timeout(2500)
        poke_player(page, width, height)

        while True:
            page.wait_for_timeout(2500)
            try:
                state = page.evaluate(
                    """
                    () => {
                        const v = document.querySelector('video');
                        if (!v) return 'no-video';
                        if (v.ended) return 'ended';
                        if (v.paused) return 'paused';
                        if (v.readyState < 2) return 'buffering';
                        return 'playing';
                    }
                    """
                )
            except Exception:
                state = "unknown"

            if state in ("paused", "buffering", "ended", "no-video", "unknown"):
                poke_player(page, width, height)

            # Si la pagina se queda sin video por largo tiempo, recarga.
            if state == "no-video":
                try:
                    page.reload(wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(1500)
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
