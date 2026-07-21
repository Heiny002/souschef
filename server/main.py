"""
SousChef extraction backend — a thin wrapper around yt-dlp.

Why this exists: the iOS app can't run yt-dlp (it's a Python program that survives by
updating constantly as Instagram/TikTok change). yt-dlp belongs on a server the app calls.
This service implements the exact contract the app already speaks:

    POST /extract-transcript   { "url": "..." }
      -> { caption, transcript, onScreenText[], blogURL, duration, thumbnail }

    POST /search-recipe        { "query": "..." }          (best-effort bonus)
      -> { results: [ { url, title } ] }

The money endpoint is /extract-transcript: yt-dlp pulls the post's caption (where creators
write the recipe) far more reliably than the app's own HTML scrape.

Important reality: Instagram blocks data-center IPs (Railway included). For public posts
yt-dlp often still works, but if you get "login required" errors, set the IG_COOKIES env var
(Netscape cookies.txt contents from a logged-in browser) — yt-dlp will then authenticate and
fetch reliably. See README.md.
"""

from __future__ import annotations

import os
import re
import glob
import tempfile
from typing import Optional
from urllib.parse import unquote, urlparse

import requests
import yt_dlp
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="SousChef Extraction Backend", version="1.0.0")

# --- Cookies -----------------------------------------------------------------
# If IG_COOKIES (raw cookies.txt content) is provided, write it once at startup so
# yt-dlp can authenticate. COOKIES_FILE lets you point at a mounted file instead.
COOKIES_FILE = os.environ.get("COOKIES_FILE", "/tmp/cookies.txt")


def _install_cookies() -> Optional[str]:
    raw = os.environ.get("IG_COOKIES")
    if raw:
        try:
            with open(COOKIES_FILE, "w", encoding="utf-8") as fh:
                fh.write(raw)
            return COOKIES_FILE
        except OSError:
            return None
    return COOKIES_FILE if os.path.exists(COOKIES_FILE) else None


COOKIE_PATH = _install_cookies()


# --- Models ------------------------------------------------------------------
class ExtractRequest(BaseModel):
    url: str


class SearchRequest(BaseModel):
    query: str


# --- yt-dlp helpers ----------------------------------------------------------
def _ydl_opts(extra: Optional[dict] = None) -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        # A real mobile UA helps with some extractors.
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
                "Mobile/15E148 Safari/604.1"
            )
        },
    }
    if COOKIE_PATH:
        opts["cookiefile"] = COOKIE_PATH
    if extra:
        opts.update(extra)
    return opts


def _extract_info(url: str) -> dict:
    with yt_dlp.YoutubeDL(_ydl_opts()) as ydl:
        return ydl.extract_info(url, download=False)


_VTT_TS = re.compile(r"^\d{2}:\d{2}:\d{2}\.\d{3}\s+-->\s+.*$")
_VTT_TAGS = re.compile(r"<[^>]+>")


def _fetch_transcript(url: str) -> Optional[str]:
    """Best-effort: download English (auto-)subtitles and flatten them to plain text.

    Returns None whenever anything goes wrong — the caption is the primary deliverable, so
    a missing transcript must never fail the request.
    """
    try:
        with tempfile.TemporaryDirectory() as tmp:
            opts = _ydl_opts(
                {
                    "writesubtitles": True,
                    "writeautomaticsub": True,
                    "subtitleslangs": ["en", "en-US", "en-GB"],
                    "subtitlesformat": "vtt",
                    "outtmpl": os.path.join(tmp, "%(id)s.%(ext)s"),
                }
            )
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([url])

            lines: list[str] = []
            seen: set[str] = set()
            for path in sorted(glob.glob(os.path.join(tmp, "*.vtt"))):
                with open(path, encoding="utf-8", errors="ignore") as fh:
                    for raw in fh:
                        line = raw.strip()
                        if (
                            not line
                            or line == "WEBVTT"
                            or line.startswith("NOTE")
                            or line.isdigit()
                            or _VTT_TS.match(line)
                        ):
                            continue
                        clean = _VTT_TAGS.sub("", line).strip()
                        # Auto-captions repeat rolling lines; dedupe consecutive/again.
                        if clean and clean not in seen:
                            seen.add(clean)
                            lines.append(clean)
            text = " ".join(lines).strip()
            return text or None
    except Exception:
        return None


# --- Endpoints ---------------------------------------------------------------
@app.get("/")
def root():
    return {
        "service": "souschef-extraction-backend",
        "cookies_loaded": bool(COOKIE_PATH),
        "endpoints": ["/extract-transcript", "/search-recipe", "/health"],
    }


@app.get("/health")
def health():
    return {"status": "ok", "yt_dlp": getattr(yt_dlp.version, "__version__", "unknown")}


@app.post("/extract-transcript")
def extract_transcript(req: ExtractRequest):
    url = (req.url or "").strip()
    if not url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="A valid http(s) URL is required.")

    try:
        info = _extract_info(url)
    except yt_dlp.utils.DownloadError as exc:
        # Most commonly: login required / rate-limited / removed. Surface it so the app
        # can show a useful message rather than a generic failure.
        raise HTTPException(status_code=502, detail=f"Could not fetch media: {exc}") from exc
    except Exception as exc:  # noqa: BLE001 — never leak a 500 stack to the client
        raise HTTPException(status_code=502, detail=f"Extraction failed: {exc}") from exc

    # The caption/description is where the recipe lives on Instagram/TikTok.
    caption = info.get("description") or info.get("title")
    duration = info.get("duration")
    thumbnail = info.get("thumbnail")

    return {
        "caption": caption,
        "transcript": _fetch_transcript(url),
        "onScreenText": [],  # OCR of on-screen text is a future add-on
        "blogURL": None,     # bio-link resolution stays client-side
        "duration": int(duration) if isinstance(duration, (int, float)) else None,
        "thumbnail": thumbnail,  # app ignores unknown keys; handy for debugging
    }


@app.post("/search-recipe")
def search_recipe(req: SearchRequest):
    """Best-effort web search via DuckDuckGo's HTML endpoint. Bonus feature — the app
    treats an empty list gracefully, so flakiness here never breaks an import."""
    query = (req.query or "").strip()
    if not query:
        return {"results": []}
    try:
        resp = requests.post(
            "https://html.duckduckgo.com/html/",
            data={"q": f"{query} recipe"},
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
                )
            },
            timeout=12,
        )
        resp.raise_for_status()
        return {"results": _parse_ddg(resp.text)}
    except Exception:
        return {"results": []}


_DDG_LINK = re.compile(
    r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
    re.IGNORECASE | re.DOTALL,
)
_TAGS = re.compile(r"<[^>]+>")


def _parse_ddg(html: str) -> list[dict]:
    results: list[dict] = []
    for href, title_html in _DDG_LINK.findall(html):
        # DDG wraps the real URL in a redirect: /l/?uddg=<encoded>
        real = href
        m = re.search(r"[?&]uddg=([^&]+)", href)
        if m:
            real = unquote(m.group(1))
        if not real.startswith("http"):
            continue
        host = (urlparse(real).hostname or "").lower()
        if any(s in host for s in ("tiktok.", "instagram.", "youtube.", "youtu.be", "pinterest.")):
            continue
        title = _TAGS.sub("", title_html).strip()
        if title:
            results.append({"url": real, "title": title})
        if len(results) >= 8:
            break
    return results
