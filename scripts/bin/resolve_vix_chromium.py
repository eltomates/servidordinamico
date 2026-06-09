#!/usr/bin/env python3
"""
Resuelve una URL de stream para ViX usando Chromium/Playwright.

Uso: python3 resolve_vix_chromium.py <page_url> [timeout_seconds]
Salida: URL de manifest (preferente .m3u8) en stdout, diagnostico en stderr.
"""

import os
import sys
import urllib.request

page_url = sys.argv[1] if len(sys.argv) > 1 else "https://vix.com/es-es/canales/premium/channel-callsign-NU9VE"
timeout_sec = int(sys.argv[2]) if len(sys.argv) > 2 else 30
headless_mode = os.environ.get("PW_HEADLESS", "1") != "0"
email = os.environ.get("VIX_USER") or os.environ.get("VIX_EMAIL") or ""
password = os.environ.get("VIX_PASSWORD") or ""

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout
except ImportError:
    sys.exit("ERROR: playwright no instalado. Ejecuta: python3 -m playwright install chromium")


def is_hls_candidate(url: str) -> bool:
    lowered = url.lower()
    return lowered.startswith("https://") and ".m3u8" in lowered


def is_dash_candidate(url: str) -> bool:
    lowered = url.lower()
    return lowered.startswith("https://") and ".mpd" in lowered


def is_drm_signal(url: str) -> bool:
    lowered = url.lower()
    needles = ("widevine", "playready", "fairplay", "license", "drm")
    return any(needle in lowered for needle in needles)


def score_hls(url: str) -> int:
    score = 0
    lowered = url.lower()
    if "content.m3u8" in lowered:
        score += 120
    if "default_video" in lowered:
        score += 90
    if "default_audio" in lowered:
        score -= 160
    if "/media.m3u8" in lowered:
        score -= 40
    if "master.m3u8" in lowered:
        score += 20
    if "playlist.m3u8" in lowered:
        score += 15
    if "token=" in lowered or "jwt=" in lowered:
        score += 20
    if "chunk" in lowered or "segment" in lowered:
        score -= 30
    return score


def try_verify_hls(url: str, timeout: int = 8) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        text = response.read().decode("utf-8", "ignore")

    if "#EXTM3U" not in text:
        return False
    return any(marker in text for marker in ("#EXT-X-STREAM-INF", ".ts", ".m4s", ".mp4"))


def click_if_present(page, selector: str, wait_ms: int = 500) -> bool:
    try:
        locator = page.locator(selector).first
        if locator.count() > 0:
            locator.click(timeout=1200)
            page.wait_for_timeout(wait_ms)
            return True
    except Exception:
        return False
    return False


def fill_first_on_page_or_frames(page, selectors, value: str) -> bool:
    scopes = [page] + list(page.frames)
    for scope in scopes:
        for selector in selectors:
            try:
                locator = scope.locator(selector).first
                if locator.count() == 0:
                    continue
                locator.click(timeout=1200)
                locator.fill(value, timeout=2000)
                return True
            except Exception:
                continue
    return False


def has_bot_challenge(page) -> bool:
    checks = [
        "text=Press & Hold to confirm you are a human",
        "text=Before we continue",
        "iframe",
    ]
    for selector in checks:
        try:
            if page.locator(selector).count() > 0:
                if selector != "iframe":
                    return True
        except Exception:
            continue

    for frame in page.frames:
        try:
            if frame.locator("text=Press & Hold to confirm you are a human").count() > 0:
                return True
            if frame.locator("text=Before we continue").count() > 0:
                return True
        except Exception:
            continue

    return False


def has_premium_wall(page) -> bool:
    wall_markers = [
        "text=Con Premium tienes más",
        "text=Mejorar plan",
        "text=Ahora no, tal vez luego.",
        "text=Ya tengo plan Premium",
    ]
    for marker in wall_markers:
        try:
            if page.locator(marker).count() > 0:
                return True
        except Exception:
            continue
    return False


def wait_for_password_or_challenge(page, timeout_ms: int = 12000) -> None:
    pass_selectors = [
        "input[type='password']",
        "input[name='password']",
        "input[aria-label='Contrasena']",
        "input[aria-label='Contraseña']",
        "input[id*='pass' i]",
        "input[autocomplete='current-password']",
    ]

    elapsed = 0
    step = 400
    while elapsed < timeout_ms:
        if has_bot_challenge(page):
            return
        scopes = [page] + list(page.frames)
        for scope in scopes:
            for selector in pass_selectors:
                try:
                    if scope.locator(selector).count() > 0:
                        return
                except Exception:
                    continue
        page.wait_for_timeout(step)
        elapsed += step


def maybe_login(page) -> None:
    if not email or not password:
        print("[vix] Sin credenciales en entorno, se omite login automatizado", file=sys.stderr)
        return

    # Intentar abrir modal/formulario de login.
    login_selectors = [
        "button:has-text('Iniciar sesion')",
        "button:has-text('Inicia sesion')",
        "button:has-text('Ya tengo plan Premium, iniciar sesion')",
        "button:has-text('Ya tengo plan Premium, iniciar sesión.')",
        "button:has-text('Entrar')",
        "button:has-text('Sign in')",
        "a:has-text('Iniciar sesion')",
        "a:has-text('Entrar')",
    ]
    for selector in login_selectors:
        if click_if_present(page, selector, 700):
            break

    email_ok = fill_first_on_page_or_frames(page, [
        "input[aria-label='Correo electronico']",
        "input[aria-label='Correo electrónico']",
        "input[type='email']",
        "input[name='email']",
        "input[id*='email' i]",
        "input[autocomplete='email']",
    ], email)

    click_if_present(page, "button:has-text('Ingresar con mi correo')", 1000)
    wait_for_password_or_challenge(page, 12000)

    pass_ok = fill_first_on_page_or_frames(page, [
        "input[type='password']",
        "input[name='password']",
        "input[aria-label='Contrasena']",
        "input[aria-label='Contraseña']",
        "input[id*='pass' i]",
        "input[autocomplete='current-password']",
    ], password)

    if not email_ok:
        print("[vix] No se detecto formulario de correo", file=sys.stderr)
        return

    if has_bot_challenge(page):
        print("[vix] Challenge anti-bot detectado antes de capturar contrasena", file=sys.stderr)
        return

    if not pass_ok:
        print("[vix] No se detecto formulario de contrasena", file=sys.stderr)
        return

    submit_selectors = [
        "button[type='submit']",
        "button:has-text('Continuar')",
        "button:has-text('Entrar')",
        "button:has-text('Iniciar sesion')",
        "button:has-text('Sign in')",
    ]
    submitted = False
    for selector in submit_selectors:
        if click_if_present(page, selector, 1200):
            submitted = True
            break

    if not submitted:
        try:
            page.keyboard.press("Enter")
            page.wait_for_timeout(1200)
        except Exception:
            pass

    print("[vix] Intento de login enviado", file=sys.stderr)


def poke_player(page) -> None:
    try:
        page.mouse.click(640, 300)
        page.wait_for_timeout(700)
    except Exception:
        pass

    selectors = [
        "button[aria-label*='play' i]",
        "button[title*='play' i]",
        ".vjs-big-play-button",
        "[class*='play']",
        "button:has-text('Ver ahora')",
        "button:has-text('Reproducir')",
    ]
    for selector in selectors:
        click_if_present(page, selector, 600)

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


def main() -> int:
    hls_seen = []
    dash_seen = []
    drm_seen = []

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
            if is_hls_candidate(url):
                hls_seen.append(url)
                print(f"[resp-hls] {url[:240]}", file=sys.stderr)
            elif is_dash_candidate(url):
                dash_seen.append(url)
                print(f"[resp-dash] {url[:240]}", file=sys.stderr)
            elif is_drm_signal(url):
                drm_seen.append(url)
                print(f"[resp-drm] {url[:240]}", file=sys.stderr)

        context.on("response", on_response)

        page = context.new_page()
        print(f"[vix] Abriendo: {page_url}", file=sys.stderr)
        try:
            page.goto(page_url, wait_until="domcontentloaded", timeout=45000)
        except PlaywrightTimeout:
            print("[vix] Timeout en goto, continuando", file=sys.stderr)
        except Exception as exc:
            print(f"[vix] goto error: {exc}", file=sys.stderr)

        page.wait_for_timeout(2500)

        if has_premium_wall(page):
            sys.exit("ERROR: ViX muestra paywall premium para este canal en la sesion actual")

        # Consentimiento/cookies comunes.
        for selector in [
            "button:has-text('Aceptar')",
            "button:has-text('Acepto')",
            "button:has-text('Allow all')",
            "button:has-text('Accept all')",
        ]:
            if click_if_present(page, selector, 600):
                break

        maybe_login(page)

        if has_premium_wall(page):
            sys.exit("ERROR: ViX mantiene paywall premium despues del intento de login")

        if has_bot_challenge(page):
            sys.exit("ERROR: ViX activo challenge anti-bot (Press & Hold); no automatizable en este flujo")

        poke_player(page)

        # Espera incremental: salir temprano cuando ya exista HLS candidata,
        # en lugar de dormir todo el timeout y bloquear el wrapper.
        waited_ms = 0
        step_ms = 500
        max_wait_ms = timeout_sec * 1000
        while waited_ms < max_wait_ms:
            page.wait_for_timeout(step_ms)
            waited_ms += step_ms
            if hls_seen:
                break

        browser.close()

    # Mantener orden de captura y hacer desempate estable por score.
    hls_unique = list(dict.fromkeys(hls_seen))
    hls_unique.sort(key=score_hls, reverse=True)
    for candidate in hls_unique[:8]:
        try:
            if try_verify_hls(candidate):
                print(candidate)
                return 0
        except Exception as exc:
            print(f"[vix] Validacion fallo: {exc}", file=sys.stderr)

    if hls_unique:
        print("[vix] Aviso: devolviendo candidata HLS no verificada", file=sys.stderr)
        print(hls_unique[0])
        return 0

    if dash_seen or drm_seen:
        sys.exit("ERROR: ViX expuso solo DASH/DRM (sin HLS util para ffmpeg)")

    sys.exit("ERROR: No se capturo URL de stream util en ViX")


if __name__ == "__main__":
    raise SystemExit(main())
