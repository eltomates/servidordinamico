#!/usr/bin/env python3
import re
import sys
import time

try:
    from playwright.sync_api import sync_playwright
except Exception:
    raise SystemExit(1)


def score_url(url: str) -> int:
    score = 0
    if "osm.sr.roku.com/osm/v1/hls/master/" in url:
        score += 100
    if "/osm/v1/hls/use2/variant/" in url:
        score += 90
    if "jwt=" in url:
        score += 20
    if "cdn=" in url:
        score += 5
    return score


def is_candidate(url: str) -> bool:
    if not url or not url.startswith(("http://", "https://")):
        return False
    if ".m3u8" not in url:
        return False
    if "roku.com" not in url and "roku" not in url:
        return False
    patterns = [
        r"osm\.sr\.roku\.com/osm/v1/hls/master/",
        r"osm-use2\.sr\.roku\.com/osm/v1/hls/use2/variant/",
        r"/osm/v1/hls/",
    ]
    return any(re.search(p, url) for p in patterns)


def main() -> int:
    if len(sys.argv) < 2:
        return 1

    watch_url = sys.argv[1].strip()
    timeout_seconds = 20
    if len(sys.argv) >= 3:
        try:
            timeout_seconds = max(8, min(60, int(sys.argv[2])))
        except Exception:
            timeout_seconds = 20

    deadline = time.time() + timeout_seconds
    seen = {}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/124.0.0.0 Safari/537.36"
            ),
            locale="es-MX",
            viewport={"width": 1366, "height": 768},
        )
        page = context.new_page()

        def record_url(url: str):
            if is_candidate(url):
                seen[url] = max(score_url(url), seen.get(url, 0))

        page.on("request", lambda req: record_url(req.url))
        page.on("response", lambda resp: record_url(resp.url))

        try:
            page.goto(watch_url, wait_until="domcontentloaded", timeout=30000)
        except Exception:
            pass

        while time.time() < deadline:
            if seen:
                top_url = max(seen.items(), key=lambda item: item[1])[0]
                if "master" in top_url and "jwt=" in top_url:
                    break
            page.wait_for_timeout(500)

        browser.close()

    if not seen:
        return 1

    best_url = max(seen.items(), key=lambda item: item[1])[0]
    print(best_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
