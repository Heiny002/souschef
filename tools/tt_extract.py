#!/usr/bin/env python3
"""Debug SousChef TikTok extraction on the desktop.

Mirrors VideoMetadataFetcher's TikTok ladder exactly:
  1. fetch the post page; try the __UNIVERSAL_DATA_FOR_REHYDRATION__ itemStruct
  2. shell page? resolve the JS-escaped canonical /@handle/(photo|video)/ID
  3. fetch embed/v2/<id>; parse imagePostInfo.displayImages + stickerTextList
so a broken import can be dissected without rebuilding the app.

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
        body = resp.read().decode("utf-8", errors="replace")
        print(f"GET {url[:80]} → HTTP {resp.status}, {len(body)} bytes")
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
    except json.JSONDecodeError:
        return None


def find_item_struct(scope):
    """Known key first, then every scope entry (mirrors the Swift scan)."""
    ordered = [scope.get("webapp.video-detail")] + list(scope.values())
    for value in ordered:
        if isinstance(value, dict):
            item = value.get("itemInfo", {}).get("itemStruct")
            if isinstance(item, dict):
                return item
    return None


def canonical_post(html):
    """Mirrors tiktokCanonicalPost: unescape \\u002F, find /@handle/(photo|video)/ID."""
    unescaped = html.replace("\\u002F", "/")
    m = re.search(r'https://www\.tiktok\.com/@[^"/\\\s]+/(?:photo|video)/(\d+)', unescaped)
    return (m.group(0), m.group(1)) if m else (None, None)


def balanced(text, marker, open_ch, close_ch):
    """Mirrors balancedJSON: quote/escape-aware bracket matching after marker."""
    i = text.find(marker)
    if i < 0:
        return None
    j = i + len(marker)
    while j < len(text) and text[j] != open_ch:
        if text[j] not in "=: \t\r\n":
            return None
        j += 1
    depth, in_str, esc = 0, False, False
    out = []
    while j < len(text):
        c = text[j]
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = not in_str
        elif not in_str:
            if c == open_ch:
                depth += 1
            elif c == close_ch:
                depth -= 1
                if depth == 0:
                    return "".join(out)
        j += 1
    return None


def embed_details(html):
    """Mirrors tiktokEmbedDetails: imagePostInfo.displayImages + stickerTextList."""
    images, stickers = [], []
    obj_text = balanced(html, '"imagePostInfo"', "{", "}")
    if obj_text:
        try:
            for d in json.loads(obj_text).get("displayImages") or []:
                urls = d.get("urlList") or []
                if urls:
                    images.append(urls[0])
        except json.JSONDecodeError:
            print("!! imagePostInfo present but failed to parse")
    arr_text = balanced(html, '"stickerTextList"', "[", "]")
    if arr_text:
        try:
            for entry in json.loads(arr_text):
                if isinstance(entry, str):
                    stickers.append(entry)
                elif isinstance(entry, dict):
                    s = entry.get("text") or entry.get("Text")
                    if s:
                        stickers.append(s)
        except json.JSONDecodeError:
            pass
    return images, stickers


def report_item(item):
    print(f"\n----- CAPTION (desc) -----\n{item.get('desc') or '(empty)'}")
    stickers = []
    for s in item.get("stickersOnItem") or []:
        stickers.extend(s.get("stickerText") or [])
    print(f"\n----- STICKER TEXT ({len(stickers)}) -----")
    print("\n".join(stickers) if stickers else "(none)")
    images = []
    for img in (item.get("imagePost") or {}).get("images") or []:
        urls = (img.get("imageURL") or {}).get("urlList") or []
        if urls:
            images.append(urls[0])
    print(f"\n----- PHOTO-MODE SLIDES ({len(images)}) -----")
    for u in images:
        print("  ", u[:110])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("url", nargs="?", help="TikTok post URL (short links fine)")
    ap.add_argument("--html", help="parse a saved page instead of fetching")
    args = ap.parse_args()

    if args.html:
        html = open(args.html, encoding="utf-8", errors="replace").read()
        post_id = None
    elif args.url:
        html = fetch(args.url)
        m = re.search(r"/(?:photo|video)/(\d+)", args.url)
        post_id = m.group(1) if m else None
    else:
        ap.error("give a URL or --html FILE")

    # Rung 1: rehydration itemStruct.
    root = rehydration_json(html)
    scope = (root or {}).get("__DEFAULT_SCOPE__", {})
    item = find_item_struct(scope)
    if item:
        print("\nRUNG 1 HIT: itemStruct in rehydration blob")
        report_item(item)
        return

    print(f"\nrung 1 miss — scope keys: {sorted(scope.keys()) if scope else 'NO BLOB'}")

    # Rung 2: canonical/id from the shell → embed page.
    canon_url, canon_id = canonical_post(html)
    post_id = post_id or canon_id
    print(f"canonical: {canon_url or '(not found)'}  id: {post_id or '(none)'}")
    if not post_id:
        print("\nVERDICT: no post id recoverable — paste this output into the chat.")
        sys.exit(1)

    embed_html = fetch(f"https://www.tiktok.com/embed/v2/{post_id}")
    images, stickers = embed_details(embed_html)
    print(f"\nRUNG 2 (embed): {len(images)} slides, {len(stickers)} sticker texts")
    for u in images:
        print("  ", u[:110])
    if stickers:
        print("\n----- STICKER TEXT -----")
        print("\n".join(stickers))

    if images or stickers:
        print("\nVERDICT: the app should extract from this post (slides → on-device OCR).")
    else:
        print("\nVERDICT: embed page had no slides or stickers — paste this output.")


if __name__ == "__main__":
    main()
