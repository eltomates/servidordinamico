#!/usr/bin/env python3
"""
Mantiene un reproductor Chromium abierto (modo headed) sobre una URL de canal.
Se usa junto con x11grab para restream de navegador real.
"""

import sys
import time
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
        page.keyboard.press("F11")
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
                      video::-webkit-media-controls { display: none !important; }
                      video::-webkit-media-controls-enclosure { display: none !important; }
                      video { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: contain !important; background: #000 !important; z-index: 2147483647 !important; }
                    `;
                    document.documentElement.appendChild(st);
                }

                const video = document.querySelector('video');
                if (!video) return;
                try { video.muted = false; } catch (e) {}
                try { video.play(); } catch (e) {}
                try { video.controls = false; video.removeAttribute('controls'); } catch (e) {}
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

    try:
        page.mouse.move(width - 5, 5)
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

        last_video_time = None
        last_video_progress_at = time.monotonic()
        last_frame_count = None
        last_frame_progress_at = time.monotonic()

        while True:
            page.wait_for_timeout(2500)
            try:
                state, current_time, frame_count, ready_state = page.evaluate(
                    """
                    () => {
                        const v = document.querySelector('video');
                        if (!v) return ['no-video', null, null, 0];

                        let decodedFrames = null;
                        try {
                            if (typeof v.getVideoPlaybackQuality === 'function') {
                                const quality = v.getVideoPlaybackQuality();
                                if (quality && Number.isFinite(quality.totalVideoFrames)) {
                                    decodedFrames = quality.totalVideoFrames;
                                }
                            }
                        } catch (e) {}

                        if (decodedFrames == null) {
                            const webkitFrames = v.webkitDecodedFrameCount;
                            if (Number.isFinite(webkitFrames)) {
                                decodedFrames = webkitFrames;
                            }
                        }

                        if (v.ended) return ['ended', v.currentTime || 0, decodedFrames, v.readyState || 0];
                        if (v.paused) return ['paused', v.currentTime || 0, decodedFrames, v.readyState || 0];
                        if (v.readyState < 2) return ['buffering', v.currentTime || 0, decodedFrames, v.readyState || 0];
                        return ['playing', v.currentTime || 0, decodedFrames, v.readyState || 0];
                    }
                    """
                )
            except Exception:
                state = "unknown"
                current_time = None
                frame_count = None
                ready_state = 0

            if isinstance(current_time, (int, float)):
                if last_video_time is None or current_time > (last_video_time + 0.4):
                    last_video_time = current_time
                    last_video_progress_at = time.monotonic()

            if isinstance(frame_count, (int, float)):
                if last_frame_count is None or frame_count > last_frame_count:
                    last_frame_count = frame_count
                    last_frame_progress_at = time.monotonic()

            stalled_for = time.monotonic() - last_video_progress_at
            frame_stalled_for = time.monotonic() - last_frame_progress_at

            if state in ("paused", "buffering", "ended", "no-video", "unknown"):
                poke_player(page, width, height)

            decode_stalled = isinstance(frame_count, (int, float)) and ready_state >= 2 and frame_stalled_for >= 10
            time_stalled = stalled_for >= 12

            if state == "playing" and (time_stalled or decode_stalled):
                reason = []
                if time_stalled:
                    reason.append(f"tiempo {stalled_for:.1f}s")
                if decode_stalled:
                    reason.append(f"frames {frame_stalled_for:.1f}s")
                print(
                    f"[browser_keepalive] Video atascado ({', '.join(reason)}; readyState={ready_state}; currentTime={current_time}; frames={frame_count}), recargando",
                    file=sys.stderr,
                )
                try:
                    page.reload(wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(1500)
                except Exception:
                    pass
                poke_player(page, width, height)
                last_video_time = None
                last_video_progress_at = time.monotonic()
                last_frame_count = None
                last_frame_progress_at = time.monotonic()

            # Si la pagina se queda sin video por largo tiempo, recarga.
            if state == "no-video":
                try:
                    page.reload(wait_until="domcontentloaded", timeout=30000)
                    page.wait_for_timeout(1500)
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
