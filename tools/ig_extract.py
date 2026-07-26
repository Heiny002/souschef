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
    python3 tools/ig_extract.py "<url>" --cookies cookies.txt --llm   # + Claude Haiku structuring

For --llm, set ANTHROPIC_API_KEY in your shell (export ANTHROPIC_API_KEY=sk-ant-...). It
runs the SAME prompt the app's LLMCaptionStructurer uses, so you can compare the
deterministic parse against the LLM structuring on any caption before shipping.

Getting cookies.txt (for the authenticated route): log into instagram.com in a browser,
export cookies with a "Get cookies.txt" extension (Netscape format). This is the desktop
equivalent of the app's "Connect Instagram" — it gets past the login wall the same way.

No dependencies — uses only the Python standard library, so it just runs.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

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


def _cookie_header(cookies):
    return "; ".join(f"{k}={v}" for k, v in cookies.items())


def _read(resp):
    """Read a urllib response, transparently gunzipping if needed."""
    raw = resp.read()
    if resp.headers.get("Content-Encoding") == "gzip":
        raw = gzip.decompress(raw)
    return raw


def _http_get(url, headers, cookies):
    h = dict(headers)
    h.setdefault("Accept-Encoding", "identity")
    if cookies:
        h["Cookie"] = _cookie_header(cookies)
    req = urllib.request.Request(url, headers=h)
    return urllib.request.urlopen(req, timeout=20)


def _http_post(url, form, headers, cookies):
    h = dict(headers)
    h.setdefault("Accept-Encoding", "identity")
    if cookies:
        h["Cookie"] = _cookie_header(cookies)
    body = urllib.parse.urlencode(form).encode()
    req = urllib.request.Request(url, data=body, headers=h, method="POST")
    return urllib.request.urlopen(req, timeout=20)


def fetch_embed(code, cookies):
    url = f"https://www.instagram.com/p/{code}/embed/captioned/"
    try:
        resp = _http_get(url, {"User-Agent": UA, "Referer": "https://www.instagram.com/",
                               "Accept-Language": "en-US,en;q=0.9"}, cookies)
        html = _read(resp).decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, f"request error: {e}"
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


def fetch_graphql(code, cookies):
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
        resp = _http_post("https://www.instagram.com/graphql/query/",
                          {"doc_id": DOC_ID, "variables": variables}, headers, cookies)
        payload = json.loads(_read(resp).decode("utf-8", "ignore"))
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, f"request error: {e}"
    try:
        data = payload.get("data") or {}
        media = data.get("xdt_shortcode_media") or data.get("shortcode_media")
        if not media:
            return None, "no shortcode_media (needs login, or doc_id is stale)"
        edges = (media.get("edge_media_to_caption") or {}).get("edges") or []
        if edges:
            return edges[0]["node"]["text"], "ok"
        return None, "empty caption field"
    except Exception as e:
        return None, f"parse error: {e}"


def _caption_from_page(html):
    """Find the caption in a logged-in reel page's embedded JSON (or og:description)."""
    for pat in (
        r'"edge_media_to_caption":\{"edges":\[\{"node":\{"text":"((?:[^"\\]|\\.)*)"',
        r'"caption":\{[^{}]*?"text":"((?:[^"\\]|\\.)*)"',
        r'\\"edge_media_to_caption\\":\{\\"edges\\":\[\{\\"node\\":\{\\"text\\":\\"((?:[^"\\]|\\.)*?)\\"',
    ):
        m = re.search(pat, html)
        if m:
            try:
                return json.loads('"' + m.group(1) + '"')
            except Exception:
                try:
                    return json.loads('"' + m.group(1).replace('\\\\"', '\\"') + '"')
                except Exception:
                    continue
    m = re.search(r'<meta property="og:description" content="([^"]*)"', html)
    if m:
        return m.group(1)
    return None


def fetch_reel_page(code, cookies):
    """Fetch the full reel page (logged-in) and read the caption from its embedded JSON —
    sidesteps the GraphQL doc_id entirely."""
    url = f"https://www.instagram.com/reel/{code}/"
    headers = {"User-Agent": UA,
               "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
               "Accept-Language": "en-US,en;q=0.9", "Referer": "https://www.instagram.com/"}
    try:
        resp = _http_get(url, headers, cookies)
        html = _read(resp).decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, f"request error: {e}"
    cap = _caption_from_page(html)
    if cap:
        return cap, "ok"
    return None, "no caption pattern found in page"


_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def shortcode_to_media_id(code):
    """Instagram shortcodes are base64 of the numeric media id — decode it back."""
    mid = 0
    for ch in code:
        if ch not in _B64:
            return None
        mid = mid * 64 + _B64.index(ch)
    return mid


def fetch_api_v1(code, cookies):
    """Instagram's internal media-info API. Uses the media id derived from the shortcode,
    so it doesn't depend on a rotating GraphQL doc_id — the more stable authenticated route."""
    mid = shortcode_to_media_id(code)
    if mid is None:
        return None, "bad shortcode"
    url = f"https://www.instagram.com/api/v1/media/{mid}/info/"
    headers = {"User-Agent": UA, "X-IG-App-ID": "936619743392459",
               "Referer": f"https://www.instagram.com/reel/{code}/",
               "Accept": "application/json"}
    if "csrftoken" in cookies:
        headers["X-CSRFToken"] = cookies["csrftoken"]
    try:
        resp = _http_get(url, headers, cookies)
        payload = json.loads(_read(resp).decode("utf-8", "ignore"))
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, f"request error: {e}"
    try:
        items = payload.get("items") or []
        if not items:
            return None, "no items in response"
        cap = (items[0].get("caption") or {}).get("text")
        return (cap, "ok") if cap else (None, "item has no caption")
    except Exception as e:
        return None, f"parse error: {e}"


def dump_raw(code, cookies):
    """Print raw response snippets so we can see what Instagram actually returns and fix
    the parser / doc_id accordingly."""
    print("\n=== RAW DIAGNOSTICS ===")

    # 1. graphql raw body
    variables = json.dumps({"shortcode": code, "fetch_comment_count": 0, "parent_comment_count": 0,
                            "child_comment_count": 0, "fetch_like_count": 0,
                            "fetch_tagged_user_count": None, "fetch_preview_comment_count": 0,
                            "has_threaded_comments": True, "hoisted_comment_id": None,
                            "hoisted_reply_id": None})
    headers = {"User-Agent": UA, "X-IG-App-ID": "936619743392459",
               "Referer": "https://www.instagram.com/",
               "Content-Type": "application/x-www-form-urlencoded"}
    if "csrftoken" in cookies:
        headers["X-CSRFToken"] = cookies["csrftoken"]
    print("\n[1] graphql/query response (first 900 chars):")
    try:
        resp = _http_post("https://www.instagram.com/graphql/query/",
                          {"doc_id": DOC_ID, "variables": variables}, headers, cookies)
        print("   ", _read(resp).decode("utf-8", "ignore")[:900])
    except urllib.error.HTTPError as e:
        print(f"    HTTP {e.code}:", (e.read()[:400].decode("utf-8", "ignore") if e.fp else ""))
    except Exception as e:
        print("    error:", e)

    # 1b. api/v1 media info raw
    mid = shortcode_to_media_id(code)
    print(f"\n[1b] api/v1/media/{mid}/info/ response (first 900 chars):")
    try:
        resp = _http_get(f"https://www.instagram.com/api/v1/media/{mid}/info/",
                         {"User-Agent": UA, "X-IG-App-ID": "936619743392459",
                          "Referer": f"https://www.instagram.com/reel/{code}/",
                          "X-CSRFToken": cookies.get("csrftoken", "")}, cookies)
        print("   ", _read(resp).decode("utf-8", "ignore")[:900])
    except urllib.error.HTTPError as e:
        print(f"    HTTP {e.code}:", (e.read()[:400].decode("utf-8", "ignore") if e.fp else ""))
    except Exception as e:
        print("    error:", e)

    # 1c. embed page raw
    print("\n[1c] embed/captioned page:")
    try:
        resp = _http_get(f"https://www.instagram.com/p/{code}/embed/captioned/",
                         {"User-Agent": UA, "Referer": "https://www.instagram.com/"}, cookies)
        html = _read(resp).decode("utf-8", "ignore")
        print(f"    length={len(html)} chars")
        for needle in ('gql_data', 'class="Caption"', 'edge_media_to_caption', 'caption', 'EmbedIsBroken', 'WatchOnInstagram'):
            i = html.find(needle)
            if i >= 0:
                print(f"    '{needle}' @ {i}:  {html[i:i + 200]}".replace("\n", " "))
            else:
                print(f"    '{needle}': NOT FOUND")
    except urllib.error.HTTPError as e:
        print(f"    HTTP {e.code}")
    except Exception as e:
        print("    error:", e)

    # 2. reel page structure
    print("\n[2] reel page /reel/<code>/ :")
    try:
        resp = _http_get(f"https://www.instagram.com/reel/{code}/",
                         {"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"}, cookies)
        html = _read(resp).decode("utf-8", "ignore")
        print(f"    length={len(html)} chars, 'log in'/'password' present: "
              f"{'log in' in html.lower()}/{'password' in html.lower()}")
        for needle in ('edge_media_to_caption', '"caption"', 'og:description', 'xdt_shortcode_media'):
            i = html.find(needle)
            if i >= 0:
                snip = html[i:i + 220].replace("\n", " ")
                print(f"    '{needle}' @ {i}:  {snip}")
            else:
                print(f"    '{needle}': NOT FOUND")
    except urllib.error.HTTPError as e:
        print(f"    HTTP {e.code}")
    except Exception as e:
        print("    error:", e)


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


def is_step_transition(l):
    """First prose-sentence line after an ingredient list — where steps begin when there's
    no explicit steps header. Ingredient-shaped lines never trigger it."""
    if looks_ing(l):
        return False
    s = strip_marker(l)
    words = s.split()
    if s.rstrip().endswith((".", "!", "?")) and len(words) >= 5:
        return True
    return looks_step(l)


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
            # When there's an ingredients header but NO steps header, the steps often
            # follow the ingredient list as bare prose. Split at the first step-like line.
            in_steps = False
            for i in range(start, end):
                l = lines[i]
                if not l.strip() or is_step_h(l) or is_ing_h(l):
                    continue
                if is_sub(l) and not in_steps:
                    cur = strip_marker(l).rstrip(":"); continue
                if step_i is None and not in_steps and is_step_transition(l):
                    in_steps = True
                if in_steps:
                    steps.append(strip_marker(l))
                else:
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


# ------------------------------------------------- LLM structuring (mirrors Swift)
# Keep this prompt in lockstep with LLMCaptionStructurer.buildPrompt in the app — the
# whole point of the tool is to debug caption→recipe quality without an Xcode rebuild.
def _llm_prompt(caption):
    return (
        "You are extracting a cooking recipe from a social-media video caption "
        "(Instagram / TikTok / YouTube). Captions are messy: they mix the recipe with "
        "marketing narrative, emojis, hashtags, @mentions, calls-to-action "
        '("follow for more", "save this"), and nutrition / serving-size lines. Ingredients '
        'are often grouped under sub-labels like "Steak:" or "For the sauce:", and steps are '
        'often numbered inline ("1.Season the beef…").\n\n'
        "Extract ONLY the actual recipe. Rules:\n"
        "- Exclude hashtags, @mentions, emojis, marketing / call-to-action lines, and "
        "nutrition-fact lines (calories, macros).\n"
        "- Put each ingredient on its own entry, keeping its quantity and unit "
        '("2 tbsp olive oil"). If ingredients are grouped under a sub-label, set "section" to '
        'that label without the trailing colon (e.g. "Steak", "For the sauce"); otherwise '
        '"section" is null.\n'
        "- Steps: one action per entry, in order, with NO leading number or bullet.\n"
        "- Do NOT invent quantities, ingredients, or steps that aren't in the caption.\n"
        '- If the caption is not a recipe, return {"title": null, "ingredients": [], "steps": []}.\n\n'
        "Return ONLY valid JSON (no prose, no code fences) matching this schema:\n"
        "{\n"
        '  "title": "string or null",\n'
        '  "recipeYield": "string or null",\n'
        '  "prepTimeMinutes": number or null,\n'
        '  "cookTimeMinutes": number or null,\n'
        '  "ingredients": [{"text": "string", "section": "string or null"}],\n'
        '  "steps": ["string"]\n'
        "}\n\n"
        "Caption:\n" + caption[:6000]
    )


def _extract_json_object(text):
    start = text.find("{")
    end = text.rfind("}")
    return text[start:end + 1] if 0 <= start < end else text


def structure_with_llm(caption):
    """Send the caption to Claude Haiku and return a parsed recipe dict, or (None, reason)."""
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key:
        return None, "ANTHROPIC_API_KEY not set in environment"
    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 2048,
        "messages": [{"role": "user", "content": _llm_prompt(caption)}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=body, method="POST",
        headers={"content-type": "application/json", "x-api-key": key,
                 "anthropic-version": "2023-06-01"})
    try:
        resp = urllib.request.urlopen(req, timeout=40)
        payload = json.loads(_read(resp).decode("utf-8", "ignore"))
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {(e.read()[:300].decode('utf-8', 'ignore') if e.fp else '')}"
    except Exception as e:
        return None, f"request error: {e}"
    try:
        text = payload["content"][0]["text"]
        return json.loads(_extract_json_object(text)), "ok"
    except Exception as e:
        return None, f"parse error: {e}"


def show_llm_recipe(cap):
    print("\n----- LLM-STRUCTURED RECIPE (Claude Haiku) -----")
    data, status = structure_with_llm(cap or "")
    if not data:
        print("  (skipped:", status + ")")
        return
    ings = data.get("ingredients") or []
    steps = data.get("steps") or []
    print("Title:", data.get("title") or "(none)")
    if data.get("recipeYield"):
        print("Yield:", data["recipeYield"])
    print(f"Ingredients ({len(ings)}):")
    for ing in ings:
        if isinstance(ing, dict):
            sec, txt = ing.get("section"), ing.get("text", "")
        else:
            sec, txt = None, str(ing)
        print("   -", (f"[{sec}] " if sec else "") + txt)
    print(f"Steps ({len(steps)}):")
    for s in steps:
        print("   *", s)
    viable = bool(data.get("title") and ings and steps)
    print("VIABLE:", "YES ✅" if viable else "NO ❌")


# --------------------------------------------------------------------------- main
def show_recipe(cap, use_llm=False):
    print("\n----- RAW CAPTION -----")
    print(cap if cap else "(empty)")
    r = parse_recipe(cap or "")
    print("\n----- PARSED RECIPE (deterministic) -----")
    print("Title:", r["title"])
    print(f"Ingredients ({len(r['ingredients'])}):")
    for ing, sec in r["ingredients"]:
        print("   -", (f"[{sec}] " if sec else "") + ing)
    print(f"Steps ({len(r['steps'])}):")
    for s in r["steps"]:
        print("   *", s)
    viable = bool(r["title"] != "(none)" and r["ingredients"] and r["steps"])
    print("\nVIABLE RECIPE:", "YES ✅" if viable else "NO ❌ (needs title + ≥1 ingredient + ≥1 step)")
    if use_llm:
        show_llm_recipe(cap)


def main():
    ap = argparse.ArgumentParser(description="Debug SousChef Instagram extraction on the desktop.")
    ap.add_argument("url", nargs="?", help="Instagram reel/post URL")
    ap.add_argument("--cookies", help="Netscape cookies.txt for authenticated fetch")
    ap.add_argument("--caption-file", help="Skip fetching; parse a caption from this file")
    ap.add_argument("--raw", action="store_true",
                    help="Dump raw response snippets (to diagnose why routes fail)")
    ap.add_argument("--llm", action="store_true",
                    help="Also structure the caption with Claude Haiku (needs ANTHROPIC_API_KEY "
                         "env var) — mirrors the app's LLMCaptionStructurer")
    args = ap.parse_args()

    if args.caption_file:
        show_recipe(open(args.caption_file, encoding="utf-8").read(), use_llm=args.llm)
        return

    if not args.url:
        ap.error("provide a URL, or --caption-file")

    code = shortcode(args.url)
    if not code:
        sys.exit("Could not find a shortcode in that URL.")
    cookies = load_cookies(args.cookies)
    print(f"Shortcode: {code}   Cookies loaded: {len(cookies)}"
          + ("  (has sessionid ✅)" if "sessionid" in cookies else "  (no sessionid — logged out)"))

    print("\n=== ROUTES ===")
    caption = None
    for name, fn in [("api/v1 media info", fetch_api_v1), ("embed/captioned", fetch_embed),
                     ("graphql", fetch_graphql), ("reel page", fetch_reel_page)]:
        cap, status = fn(code, cookies)
        got = f"{len(cap)} chars" if cap else "—"
        print(f"  {name:18} {status:45} {got}")
        if cap and not caption:
            caption = cap

    if caption:
        show_recipe(caption)
    else:
        print("\nNo caption retrieved by any route.")
        print("If you're logged out, pass --cookies cookies.txt. If you ARE logged in and it")
        print("still fails, re-run with --raw and send Claude the output.")

    if args.raw:
        dump_raw(code, cookies)


if __name__ == "__main__":
    main()
