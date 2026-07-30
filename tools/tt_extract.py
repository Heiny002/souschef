#!/usr/bin/env python3
"""Debug SousChef TikTok extraction on the desktop.

Mirrors VideoMetadataFetcher's TikTok path: fetch the post page (following the
/t/ short-link redirect), pull __UNIVERSAL_DATA_FOR_REHYDRATION__, and report
exactly what the app would see — caption, on-screen sticker text, photo-mode
slide URLs — plus diagnostics when any rung is missing, so a broken import can
be dissected without rebuilding the app.

Usage:
    python3 tools/tt_extract.py "https://www.tiktok.com/t/ZP8tWEbKN/"
    python3 tools/tt_extract.py --html saved_page.html
"""

import argparse
import json
import re
import sys
import urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=25) as resp:
        final = resp.geturl()
        body = resp.read().decode("utf-8", errors="replace")
        print(f"HTTP {resp.status}, {len(body)} bytes")
        if final != url:
            print(f"redirected to: {final}")
        return body


def rehydration_json(html):
    """Mirrors VideoMetadataFetcher.tiktokRehydrationJSON."""
    marker = "__UNIVERSAL_DATA_FOR_REHYDRATION__"
    i = html.find(marker)
    if i < 0:
        return None
    tag_end = html.find(">", i)
    close = html.find("</script>", tag_end)
    if tag_end < 0 or close < 0:
        return None
    try:
        return json.loads(html[tag_end + 1:close])
    except json.JSONDecodeError as e:
        print(f"!! blob present but JSON parse failed: {e}")
        return None


def find_item_struct(scope):
    """Mirrors the Swift scope scan: known key first, then every scope entry."""
    detail = scope.get("webapp.video-detail")
    if isinstance(detail, dict):
        item = detail.get("itemInfo", {}).get("itemStruct")
        if isinstance(item, dict):
            return "webapp.video-detail", item
    for key, value in scope.items():
        if isinstance(value, dict):
            item = value.get("itemInfo", {}).get("itemStruct")
            if isinstance(item, dict):
                return key, item
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("url", nargs="?", help="TikTok post URL (short links fine)")
    ap.add_argument("--html", help="parse a saved page instead of fetching")
    args = ap.parse_args()

    if args.html:
        html = open(args.html, encoding="utf-8", errors="replace").read()
    elif args.url:
        html = fetch(args.url)
    else:
        ap.error("give a URL or --html FILE")

    root = rehydration_json(html)
    if root is None:
        print("\nVERDICT: no rehydration blob — TikTok served a bot wall / login page,")
        print("or the page shape changed. First 300 chars of body:")
        print(re.sub(r"\s+", " ", html[:300]))
        sys.exit(1)

    scope = root.get("__DEFAULT_SCOPE__", {})
    print(f"\nscope keys: {sorted(scope.keys())}")

    key, item = find_item_struct(scope)
    if item is None:
        print("\nVERDICT: blob parsed but NO itemInfo.itemStruct under any scope key.")
        print("Paste the scope keys above into the chat — the shape has drifted.")
        sys.exit(1)

    print(f"itemStruct found under: {key}")
    print(f"\n----- CAPTION (desc) -----\n{item.get('desc') or '(empty)'}")

    stickers = []
    for s in item.get("stickersOnItem") or []:
        stickers.extend(s.get("stickerText") or [])
    print(f"\n----- STICKER TEXT ({len(stickers)} entries) -----")
    print("\n".join(stickers) if stickers else "(none)")

    images = []
    for img in (item.get("imagePost") or {}).get("images") or []:
        urls = (img.get("imageURL") or {}).get("urlList") or []
        if urls:
            images.append(urls[0])
    print(f"\n----- PHOTO-MODE SLIDES ({len(images)}) -----")
    for u in images:
        print("  ", u[:120])

    if not stickers and not images and not item.get("desc"):
        print("\nVERDICT: itemStruct present but empty — likely a region/login-gated post.")
    else:
        print("\nVERDICT: the app should extract from this post. If it doesn't, the failure"
              "\nis app-side (routing/gating), not the fetch — report what the app showed.")


if __name__ == "__main__":
    main()
