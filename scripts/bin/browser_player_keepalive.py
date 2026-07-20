#!/usr/bin/env python3
"""
Mantiene un reproductor Chromium abierto (modo headed) sobre una URL de canal.
Se usa junto con x11grab para restream de navegador real.
"""

import os
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



def hide_page_chrome(page) -> None:
    try:
        page.evaluate(
            """
            () => {
                const styleId = "browser-player-clean-page-chrome";
                if (!document.getElementById(styleId)) {
                    const st = document.createElement("style");
                    st.id = styleId;
                    st.textContent = `
                      html, body { top: 0 !important; margin: 0 !important; padding: 0 !important; overflow: hidden !important; background: #000 !important; }
                      .goog-te-banner-frame,
                      .goog-te-balloon-frame,
                      .goog-te-menu-frame,
                      .goog-tooltip,
                      .goog-tooltip-popup,
                      .skiptranslate,
                      iframe[src*="translate.google"],
                      iframe[src*="translate.googleapis"],
                      iframe[src*="translate-pa.googleapis"] {
                        display: none !important;
                        visibility: hidden !important;
                        opacity: 0 !important;
                        width: 0 !important;
                        height: 0 !important;
                        pointer-events: none !important;
                      }
                    `;
                    document.documentElement.appendChild(st);
                }

                for (const selector of [
                    ".goog-te-banner-frame",
                    ".goog-te-balloon-frame",
                    ".goog-te-menu-frame",
                    ".goog-tooltip",
                    ".goog-tooltip-popup",
                    ".skiptranslate",
                    "iframe[src*=\"translate.google\"]",
                    "iframe[src*=\"translate.googleapis\"]",
                    "iframe[src*=\"translate-pa.googleapis\"]"
                ]) {
                    for (const el of document.querySelectorAll(selector)) {
                        try {
                            el.remove();
                        } catch (e) {
                            try {
                                el.style.display = "none";
                                el.style.visibility = "hidden";
                                el.style.opacity = "0";
                            } catch (ignore) {}
                        }
                    }
                }

                try { document.documentElement.style.top = "0px"; } catch (e) {}
                try { document.body.style.top = "0px"; } catch (e) {}
            }
            """
        )
    except Exception:
        pass



def force_video_surface(page) -> bool:
    surface_js = """
    () => {
        const videos = Array.from(document.querySelectorAll("video"));
        if (!videos.length) return false;
        const score = (v) => {
            const r = v.getBoundingClientRect();
            return Math.max(1, r.width * r.height, (v.videoWidth || 0) * (v.videoHeight || 0));
        };
        const video = videos.sort((a, b) => score(b) - score(a))[0];

        try {
            if (video.parentElement !== document.body) {
                document.body.appendChild(video);
            }
        } catch (e) {}

        const styleId = "browser-player-force-video-surface-v2";
        if (!document.getElementById(styleId)) {
            const st = document.createElement("style");
            st.id = styleId;
            st.textContent = `
              html, body {
                width: 100vw !important;
                height: 100vh !important;
                margin: 0 !important;
                padding: 0 !important;
                overflow: hidden !important;
                background: #000 !important;
              }
              body > *:not(video):not(style):not(script) {
                display: none !important;
                visibility: hidden !important;
                opacity: 0 !important;
                pointer-events: none !important;
              }
              header, nav, aside, footer,
              [role="banner"], [role="navigation"], [role="toolbar"], [role="dialog"],
              [class*="guide" i], [data-testid*="guide" i], [aria-label*="guide" i],
              [class*="epg" i], [data-testid*="epg" i],
              [class*="schedule" i], [class*="program" i], [class*="channel" i],
              [class*="overlay" i], [class*="modal" i], [class*="drawer" i],
              [class*="tooltip" i], [class*="control" i], [data-testid*="control" i] {
                display: none !important;
                visibility: hidden !important;
                opacity: 0 !important;
                pointer-events: none !important;
              }
              * { cursor: none !important; }
              video::-webkit-media-controls,
              video::-webkit-media-controls-enclosure,
              video::-webkit-media-controls-panel {
                display: none !important;
                opacity: 0 !important;
                pointer-events: none !important;
              }
              video {
                display: block !important;
                visibility: visible !important;
                opacity: 1 !important;
                position: fixed !important;
                inset: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                min-width: 100vw !important;
                min-height: 100vh !important;
                max-width: 100vw !important;
                max-height: 100vh !important;
                object-fit: contain !important;
                background: #000 !important;
                z-index: 2147483647 !important;
                pointer-events: none !important;
              }
            `;
            document.documentElement.appendChild(st);
        }

        for (const el of Array.from(document.body.children)) {
            if (el === video || el.tagName === "SCRIPT" || el.tagName === "STYLE") continue;
            try {
                el.style.setProperty("display", "none", "important");
                el.style.setProperty("visibility", "hidden", "important");
                el.style.setProperty("opacity", "0", "important");
                el.style.setProperty("pointer-events", "none", "important");
            } catch (e) {}
        }

        try { video.muted = false; } catch (e) {}
        try { video.controls = false; video.removeAttribute("controls"); } catch (e) {}
        try { video.style.setProperty("display", "block", "important"); } catch (e) {}
        try { video.play(); } catch (e) {}
        try { document.documentElement.style.top = "0px"; } catch (e) {}
        try { document.body.style.top = "0px"; } catch (e) {}
        return true;
    }
    """
    frame_js = """
    (iframe) => {
        const styleId = "browser-player-force-frame-surface";
        if (!document.getElementById(styleId)) {
            const st = document.createElement("style");
            st.id = styleId;
            st.textContent = `
              html, body {
                width: 100vw !important;
                height: 100vh !important;
                margin: 0 !important;
                padding: 0 !important;
                overflow: hidden !important;
                background: #000 !important;
              }
              body > *:not(iframe):not(style):not(script) {
                display: none !important;
                visibility: hidden !important;
                opacity: 0 !important;
                pointer-events: none !important;
              }
              iframe {
                display: block !important;
                visibility: visible !important;
                opacity: 1 !important;
                position: fixed !important;
                inset: 0 !important;
                width: 100vw !important;
                height: 100vh !important;
                min-width: 100vw !important;
                min-height: 100vh !important;
                max-width: 100vw !important;
                max-height: 100vh !important;
                border: 0 !important;
                z-index: 2147483646 !important;
                background: #000 !important;
              }
            `;
            document.documentElement.appendChild(st);
        }
        try { document.body.appendChild(iframe); } catch (e) {}
        for (const el of Array.from(document.body.children)) {
            if (el === iframe || el.tagName === "SCRIPT" || el.tagName === "STYLE") continue;
            try {
                el.style.setProperty("display", "none", "important");
                el.style.setProperty("visibility", "hidden", "important");
                el.style.setProperty("opacity", "0", "important");
                el.style.setProperty("pointer-events", "none", "important");
            } catch (e) {}
        }
        try { iframe.setAttribute("allowfullscreen", "true"); } catch (e) {}
        try { iframe.style.setProperty("display", "block", "important"); } catch (e) {}
        try { iframe.style.setProperty("position", "fixed", "important"); } catch (e) {}
        try { iframe.style.setProperty("inset", "0", "important"); } catch (e) {}
        try { iframe.style.setProperty("width", "100vw", "important"); } catch (e) {}
        try { iframe.style.setProperty("height", "100vh", "important"); } catch (e) {}
        try { iframe.style.setProperty("z-index", "2147483646", "important"); } catch (e) {}
    }
    """
    found_video = False
    try:
        page.keyboard.press("Escape")
    except Exception:
        pass

    for frame in page.frames:
        has_video = False
        try:
            has_video = bool(frame.evaluate(surface_js))
        except Exception:
            has_video = False
        if has_video:
            found_video = True
            try:
                frame.frame_element().evaluate(frame_js)
            except Exception:
                pass

    return found_video


def read_video_state(page):
    state_js = """
    () => {
        const videos = Array.from(document.querySelectorAll("video"));
        if (!videos.length) return ["no-video", null, null, 0];
        const score = (v) => {
            const r = v.getBoundingClientRect();
            return Math.max(1, r.width * r.height, (v.videoWidth || 0) * (v.videoHeight || 0));
        };
        const v = videos.sort((a, b) => score(b) - score(a))[0];
        let decodedFrames = null;
        try {
            if (typeof v.getVideoPlaybackQuality === "function") {
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
        if (v.ended) return ["ended", v.currentTime || 0, decodedFrames, v.readyState || 0];
        if (v.paused) return ["paused", v.currentTime || 0, decodedFrames, v.readyState || 0];
        if (v.readyState < 2) return ["buffering", v.currentTime || 0, decodedFrames, v.readyState || 0];
        return ["playing", v.currentTime || 0, decodedFrames, v.readyState || 0];
    }
    """
    for frame in page.frames:
        try:
            state = frame.evaluate(state_js)
            if state and state[0] != "no-video":
                return state
        except Exception:
            continue
    return ["no-video", None, None, 0]


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

    hide_page_chrome(page)
    force_video_surface(page)

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
                      * { cursor: none !important; }
                      [class*="control" i], [class*="Control"], [data-testid*="control" i], [role="toolbar"] { opacity: 0 !important; visibility: hidden !important; pointer-events: none !important; }
                      video::-webkit-media-controls { display: none !important; opacity: 0 !important; pointer-events: none !important; }
                      video::-webkit-media-controls-enclosure { display: none !important; opacity: 0 !important; pointer-events: none !important; }
                      video::-webkit-media-controls-panel { display: none !important; opacity: 0 !important; pointer-events: none !important; }
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
                "--disable-translate",
                "--disable-features=Translate,TranslateUI,OptimizationHints,OptimizationGuideModelDownloading",
                "--lang=es-MX",
                "--hide-scrollbars",
                "--kiosk",
                "--start-fullscreen",
                f"--alsa-output-device={os.environ.get('BROWSER_ALSA_OUTPUT_DEVICE', 'default')}",
                "--window-position=0,0",
                f"--window-size={width},{height}",
            ],
        )
        context = browser.new_context(
            no_viewport=True,
            user_agent=user_agent,
            locale="es-MX",
            timezone_id="America/Mexico_City",
            extra_http_headers={"Accept-Language": "es-MX,es;q=0.9,en-US;q=0.8,en;q=0.7"},
        )
        context.add_init_script(
            """
            Object.defineProperty(navigator, "language", { get: () => "es-MX" });
            Object.defineProperty(navigator, "languages", { get: () => ["es-MX", "es", "en-US", "en"] });
            """
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
            hide_page_chrome(page)
            force_video_surface(page)
            try:
                state, current_time, frame_count, ready_state = read_video_state(page)
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
