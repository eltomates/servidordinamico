#!/usr/bin/env python3
"""Refresh a local ffmpeg-friendly Plex media playlist.

Usage: refresh_plex_direct_playlist.py <master_url> <output_path> [target_bandwidth]
"""

import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", "ignore")


def pick_variant(master_url: str, target_bandwidth: int) -> str:
    master_lines = fetch_text(master_url).splitlines()
    variants = []

    for index, line in enumerate(master_lines[:-1]):
        if not line.startswith("#EXT-X-STREAM-INF:"):
            continue

        match = re.search(r"BANDWIDTH=(\d+)", line)
        bandwidth = int(match.group(1)) if match else 0
        variant_url = urllib.parse.urljoin(master_url, master_lines[index + 1].strip())
        variants.append((bandwidth, variant_url))

    if not variants:
        raise RuntimeError("No se encontraron variantes en el master playlist Plex")

    under_target = [item for item in variants if item[0] <= target_bandwidth]
    if under_target:
        return max(under_target, key=lambda item: item[0])[1]

    return min(variants, key=lambda item: item[0])[1]


def rewrite_playlist(variant_url: str) -> str:
    out_lines = []

    for raw_line in fetch_text(variant_url).splitlines():
        line = raw_line.strip()
        if line.startswith("http"):
            parsed = urllib.parse.urlparse(line)
            query = urllib.parse.parse_qs(parsed.query)
            redirect_url = query.get("redirect_url", [""])[0]
            out_lines.append(urllib.parse.unquote(redirect_url) if redirect_url else line)
        else:
            out_lines.append(raw_line)

    return "\n".join(out_lines) + "\n"


def atomic_write(output_path: str, content: str) -> None:
    directory = os.path.dirname(output_path) or "."
    os.makedirs(directory, exist_ok=True)

    with tempfile.NamedTemporaryFile("w", dir=directory, delete=False, encoding="utf-8") as handle:
        handle.write(content)
        temp_path = handle.name

    os.replace(temp_path, output_path)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(
            "Uso: refresh_plex_direct_playlist.py <master_url> <output_path> [target_bandwidth]\n"
        )
        return 1

    master_url = sys.argv[1]
    output_path = sys.argv[2]
    target_bandwidth = int(sys.argv[3]) if len(sys.argv) > 3 else 1500000

    variant_url = pick_variant(master_url, target_bandwidth)
    playlist_text = rewrite_playlist(variant_url)
    atomic_write(output_path, playlist_text)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())