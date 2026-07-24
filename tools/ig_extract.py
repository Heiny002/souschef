#!/usr/bin/env python3
"""
ig_extract.py — desktop debugger for SousChef's Instagram recipe extraction.

Runs the SAME fetch + parse steps the app uses, but on your Mac (a residential IP, like
your phone) with instant iteration — no Xcode rebuild. It shows exactly what caption each
route retrieves and how the recipe parser turns it into a recipe, so we can see where
extraction breaks.

USAGE
    python3 tools/ig_extract.py "https://www.instagram.com/reel/XXXXXXX/"
    python3 tools/ig_extract.py "<url>" --cookies cookies.txt   # authenticated (full caption)
    python3 tools/ig_extract.py --caption-file some.txt         # parse a caption you paste in

Getting cookies.txt (for the authenticated route): log into instagram.com in a browser,
export cookies with a "Get cookies.txt" extension (Netscape format). This is the desktop
equivalent of the app's "Connect Instagram" — it gets past the login wall the same way.

Requires `requests`:  pip3 install requests
"""
from __future__ import annotations

import argparse
import json
import re
import sys

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
DOC_ID = "25531498899829322"   # Instagram's PolarisPostActionLoadPostQuery; rotates over time


# --------------------------------------------------------------------------- fetch
def shortcode(url: str):
    m = re.search(r"instagram\.com/(?:reels?|p|tv)/([A-Za-z0-9_-]+)", url)
    return m.group(1) if m else None


def load_cookies(path):
    """Netscape cookies.txt -> {name: value} for instagram.com."""
    jar = {}
    if not path:
        return jar
    try:
        for line in open(path, encoding="utf-8", errors="ignore"):
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 7 and "instagram" in parts[0].lower():
                jar[parts[5]] = parts[6]
    except OSError as e:
        print(f"  ! couldn't read cookies file: {e}")
    return jar


def _gql_caption_from_embed(html: str):
    """Pull the caption out of the embed page's escaped gql_data blob."""
    marker = '\\"gql_data\\":'
    pos = html.find(marker)
    if pos == -1:
        return None
    start = pos + len(marker)
    cands, depth, i = [], 0, start
    while i < len(html) and len(cands) < 8:
        c = html[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth <= 0:
                cands.append(html[start:i + 1])
        elif c == "<":
            break
        i += 1
    hp = html.find(',\\"hostname\\"', start)
    if hp != -1:
        cands.append(html[start:hp])
    for frag in cands:
        try:
            gql = json.loads(json.loads('"' + frag + '"'))
            media = gql.get("shortcode_media", {})
            edges = (media.get("edge_media_to_caption") or {}).get("edges") or []
            if edges:
                return edges[0]["node"]["text"]
        except Exception:
            continue
    return None


def fetch_embed(requests, code, cookies):
    url = f"https://www.instagram.com/p/{code}/embed/captioned/"
    try:
        r = requests.get(url, headers={"User-Agent": UA, "Referer": "https://www.instagram.com/"},
                         cookies=cookies, timeout=20)
    except Exception as e:
        return None, f"request error: {e}"
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}"
    html = r.text
    cap = _gql_caption_from_embed(html)
    if cap:
        return cap, "ok (gql_data)"
    m = re.search(r'class="Caption"[^>]*>(.*?)<div class="CaptionComments"', html, re.DOTALL)
    if m:
        t = re.sub(r"<br\s*/?>", "\n", m.group(1))
        t = re.sub(r"<a[^>]*>.*?</a>", "", t, count=1, flags=re.DOTALL)
        t = re.sub(r"<[^>]+>", "", t).strip()
        if t:
            return t, "ok (rendered .Caption)"
    low = html.lower()
    if "login" in low and "password" in low:
        return None, "login wall"
    return None, "no caption in page"


def fetch_graphql(requests, code, cookies):
    variables = json.dumps({
        "shortcode": code, "fetch_comment_count": 0, "parent_comment_count": 0,
        "child_comment_count": 0, "fetch_like_count": 0, "fetch_tagged_user_count": None,
        "fetch_preview_comment_count": 0, "has_threaded_comments": True,
        "hoisted_comment_id": None, "hoisted_reply_id": None,
    })
    headers = {
        "User-Agent": UA, "X-IG-App-ID": "936619743392459",
        "Referer": "https://www.instagram.com/",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    if "csrftoken" in cookies:
        headers["X-CSRFToken"] = cookies["csrftoken"]
    try:
        r = requests.post("https://www.instagram.com/graphql/query/",
                          data={"doc_id": DOC_ID, "variables": variables},
                          headers=headers, cookies=cookies, timeout=20)
    except Exception as e:
        return None, f"request error: {e}"
    if r.status_code != 200:
        return None, f"HTTP {r.status_code}"
    try:
        data = r.json().get("data") or {}
        media = data.get("xdt_shortcode_media") or data.get("shortcode_media")
        if not media:
            return None, "no shortcode_media (needs login, or doc_id is stale)"
        edges = (media.get("edge_media_to_caption") or {}).get("edges") or []
        if edges:
            return edges[0]["node"]["text"], "ok"
        return None, "empty caption field"
    except Exception as e:
        return None, f"parse error: {e}"


# ------------------------------------------------------- recipe parser (port of Swift)
ING_HEADERS = {"ingredients", "ingredient", "what you need", "you'll need", "you will need", "shopping list"}
STEP_HEADERS = {"instructions", "instruction", "directions", "direction", "method", "steps",
                "step", "preparation", "how to make it", "how to make", "to make it", "to make"}
FRAC = "½¼¾⅓⅔⅛⅜⅝⅞"
QTY = {"a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
       "half", "quarter", "dozen"}
UNITS = {"cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons", "oz",
         "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams", "kg", "ml", "l",
         "liter", "liters", "can", "cans", "clove", "cloves", "pinch", "dash", "slice", "slices",
         "stick", "sticks", "bunch", "handful", "package", "packages", "pkg", "sprig", "sprigs",
         "head", "stalk", "stalks"}
VERBS = {"preheat", "mix", "stir", "cook", "heat", "bake", "roast", "fry", "saute", "sauté", "boil",
         "simmer", "blend", "chop", "dice", "slice", "peel", "season", "combine", "pour", "place",
         "put", "remove", "transfer", "drain", "fold", "whisk", "beat", "cream", "knead", "roll",
         "cut", "serve", "let", "allow", "rest", "cool", "refrigerate", "freeze", "marinate", "coat",
         "brush", "sprinkle", "garnish", "squeeze", "grate", "mince", "crush", "press", "add",
         "bring", "reduce", "cover", "toss", "spread", "top", "arrange", "warm", "melt", "sear"}
MARKER = re.compile(r"^\s*(?:[-*•·▢□◦‣⁃]\s+|\[\s?\]\s*|\d+\s*[.)]\s+|step\s*\d+\s*[:.)-]?\s*)", re.I)


def strip_marker(l):
    return MARKER.sub("", l).strip()


def norm_header(l):
    s = re.sub(r"^[#>*_`\s]+", "", l.strip())
    s = re.sub(r"[#*_`:：\s]+$", "", s)
    s = re.sub(r"^\d+[.)]\s*", "", s)
    return s.strip().lower()


def is_ing_h(l):
    n = norm_header(l); return n in ING_HEADERS or n.startswith("ingredient")


def is_step_h(l):
    n = norm_header(l)
    return n in STEP_HEADERS or n.startswith("instruction") or n.startswith("direction") or n.startswith("method")


def is_sub(l):
    n = norm_header(l); return (n.startswith("for the ") or n.startswith("for ")) and len(n) < 40


def looks_ing(l):
    s = strip_marker(l).lower(); w = s.split()
    if not w:
        return False
    if w[0][0].isdigit() or w[0][0] in FRAC:
        return True
    if w[0] in QTY and len(w) <= 6:
        return True
    return bool(set(re.findall(r"[a-z]+", s)) & UNITS)


def looks_step(l):
    s = strip_marker(l).lower(); w = s.split()
    if w and w[0].strip(".,") in VERBS:
        return True
    return len(s) > 60


def sentence_split(p):
    return [x.strip() for x in re.split(r"(?<=[.!?])\s+(?=[A-Z0-9])", p.strip()) if x.strip()]


def split_inline_numbered(line):
    parts = [strip_marker(p) for p in re.split(r"(?<=\s)(?=\d+\s*[.)]\s+)", line.strip()) if strip_marker(p)]
    return parts if len(parts) > 1 else [strip_marker(line)]


def clean_caption(cap):
    out = []
    for line in cap.split("\n"):
        t = line.strip()
        if not t:
            out.append(line); continue
        toks = t.split()
        if sum(1 for x in toks if x.startswith("#") or x.startswith("@")) == len(toks):
            continue
        out.append(line)
    return "\n".join(out)


def parse_recipe(text):
    text = clean_caption(text)
    lines = [l.rstrip() for l in text.split("\n")]
    ne = [(i, l) for i, l in enumerate(lines) if l.strip()]
    ing_i = step_i = sub_i = title_i = None
    for i, l in enumerate(lines):
        if not l.strip():
            continue
        if ing_i is None and is_ing_h(l):
            ing_i = i
        elif step_i is None and is_step_h(l):
            step_i = i
        if sub_i is None and is_sub(l):
            sub_i = i
    title, ings, steps = None, [], []
    if ing_i is not None or step_i is not None:
        earliest = min(x for x in [ing_i, step_i, sub_i] if x is not None)
        for i in range(earliest):
            if lines[i].strip() and not is_ing_h(lines[i]) and not is_step_h(lines[i]) and not is_sub(lines[i]):
                title, title_i = strip_marker(lines[i]), i
                break
        if ing_i is not None:
            start = ing_i + 1
        elif step_i is not None:
            start = (title_i + 1) if title_i is not None else 0
        else:
            start = None
        if start is not None:
            end = step_i if (step_i is not None and step_i > start) else len(lines)
            cur = None
            for i in range(start, end):
                l = lines[i]
                if not l.strip() or is_step_h(l) or is_ing_h(l):
                    continue
                if is_sub(l):
                    cur = strip_marker(l).rstrip(":"); continue
                ings.append((strip_marker(l), cur))
        if step_i is not None:
            block = [l.strip() for i in range(step_i + 1, len(lines)) for l in [lines[i]]
                     if l.strip() and not is_ing_h(l)]
            if len(block) == 1:
                block = split_inline_numbered(block[0])
                if len(block) == 1 and len(sentence_split(block[0])) > 1:
                    block = sentence_split(block[0])
            else:
                block = [strip_marker(b) for b in block]
            steps = [b for b in block if b]
    else:
        if ne:
            title = strip_marker(ne[0][1]); phase = "ing"
            for _, l in ne[1:]:
                if phase == "ing" and looks_step(l) and not looks_ing(l):
                    phase = "step"
                if phase == "ing":
                    ings.append((strip_marker(l), None))
                elif len(strip_marker(l)) > 15:
                    steps.append(strip_marker(l))
            if len(steps) == 1 and len(sentence_split(steps[0])) > 1:
                steps = sentence_split(steps[0])
    return {"title": title or "(none)", "ingredients": ings, "steps": steps}


# --------------------------------------------------------------------------- main
def show_recipe(cap):
    print("\n----- RAW CAPTION -----")
    print(cap if cap else "(empty)")
    r = parse_recipe(cap or "")
    print("\n----- PARSED RECIPE -----")
    print("Title:", r["title"])
    print(f"Ingredients ({len(r['ingredients'])}):")
    for ing, sec in r["ingredients"]:
        print("   -", (f"[{sec}] " if sec else "") + ing)
    print(f"Steps ({len(r['steps'])}):")
    for s in r["steps"]:
        print("   *", s)
    viable = bool(r["title"] != "(none)" and r["ingredients"] and r["steps"])
    print("\nVIABLE RECIPE:", "YES ✅" if viable else "NO ❌ (needs title + ≥1 ingredient + ≥1 step)")


def main():
    ap = argparse.ArgumentParser(description="Debug SousChef Instagram extraction on the desktop.")
    ap.add_argument("url", nargs="?", help="Instagram reel/post URL")
    ap.add_argument("--cookies", help="Netscape cookies.txt for authenticated fetch")
    ap.add_argument("--caption-file", help="Skip fetching; parse a caption from this file")
    args = ap.parse_args()

    if args.caption_file:
        show_recipe(open(args.caption_file, encoding="utf-8").read())
        return

    if not args.url:
        ap.error("provide a URL, or --caption-file")

    try:
        import requests
    except ImportError:
        sys.exit("Missing 'requests'. Install with:  pip3 install requests")

    code = shortcode(args.url)
    if not code:
        sys.exit("Could not find a shortcode in that URL.")
    cookies = load_cookies(args.cookies)
    print(f"Shortcode: {code}   Cookies loaded: {len(cookies)}"
          + ("  (has sessionid ✅)" if "sessionid" in cookies else "  (no sessionid — logged out)"))

    print("\n=== ROUTES ===")
    caption = None
    for name, fn in [("embed/captioned", fetch_embed), ("graphql", fetch_graphql)]:
        cap, status = fn(requests, code, cookies)
        got = f"{len(cap)} chars" if cap else "—"
        print(f"  {name:18} {status:40} {got}")
        if cap and not caption:
            caption = cap

    if caption:
        show_recipe(caption)
    else:
        print("\nNo caption retrieved by any route.")
        print("If you're logged out, pass --cookies cookies.txt. If you ARE logged in and it")
        print("still fails, the doc_id may have rotated — tell Claude and we'll refresh it.")


if __name__ == "__main__":
    main()
