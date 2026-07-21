# SousChef Extraction Backend

A tiny FastAPI service that wraps [yt-dlp](https://github.com/yt-dlp/yt-dlp) so the iOS app
can pull recipe **captions** (and, when available, subtitles) from Instagram / TikTok /
YouTube. The app already knows how to call this — it just needs a URL.

It speaks the exact contract the app expects:

| Endpoint | Body | Returns |
| --- | --- | --- |
| `POST /extract-transcript` | `{ "url": "..." }` | `{ caption, transcript, onScreenText[], blogURL, duration, thumbnail }` |
| `POST /search-recipe` | `{ "query": "..." }` | `{ results: [ { url, title } ] }` (best-effort) |
| `GET /health` | — | `{ status, yt_dlp }` |

The important one is **`/extract-transcript`**: it returns the post's caption, which is where
Instagram/TikTok creators write the recipe. That's the piece the app can't reliably get on its
own.

---

## Deploy to Railway (≈5 minutes)

1. **New project → Deploy from GitHub repo →** pick `Heiny002/souschef`.
2. In the service's **Settings → Build**, set **Root Directory** to `server`. Railway will
   detect the `Dockerfile` and build it. (Everything for the service lives under `server/`.)
3. Wait for the build to go green, then open **Settings → Networking → Generate Domain**.
   You'll get a URL like `https://souschef-production.up.railway.app`.
4. Test it:
   ```bash
   curl https://YOUR-APP.up.railway.app/health
   # {"status":"ok","yt_dlp":"..."}

   curl -X POST https://YOUR-APP.up.railway.app/extract-transcript \
     -H 'Content-Type: application/json' \
     -d '{"url":"https://www.instagram.com/reel/XXXXXXXXX/"}'
   ```
   You should get the caption back in the `caption` field.

## Point the app at it

Set the URL in the app's build config (same place as the API key):

```
# Config.xcconfig  (or your local Signing/Secrets xcconfig)
RECIPE_BACKEND_URL = https://YOUR-APP.up.railway.app
```

Rebuild. Release builds will now call your backend; without it, the app just falls back to its
on-device caption fetch. (In debug builds with no URL set, it still tries `localhost:8000`.)

---

## Instagram & the data-center IP problem

Instagram aggressively blocks **data-center IPs** — and Railway is one. For many *public*
reels yt-dlp still works, but if you see `login required` / `rate-limited` errors, give yt-dlp
your session cookies so it authenticates as you:

1. Log into instagram.com in a browser.
2. Export cookies with a "Get cookies.txt" browser extension (Netscape format).
3. In Railway **Settings → Variables**, add `IG_COOKIES` and paste the **entire** cookies.txt
   contents as the value. On boot the service writes them to a file and hands them to yt-dlp.

⚠️ Treat those cookies like a password — anyone with them can act as your Instagram login.
Use a throwaway/secondary account if you'd rather not risk your main one. `IG_COOKIES` is an
environment variable, never committed to the repo.

## Run locally (optional)

```bash
cd server
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
# app debug builds auto-target http://localhost:8000
```

## Notes & limits

- **`transcript`** is best-effort: it flattens English (auto-)subtitles when a video has them
  (great for YouTube, sometimes TikTok). Instagram reels rarely have subtitles, so `transcript`
  is often `null` there — the **caption** carries the recipe, which is the point.
- Full audio→text via Whisper and on-screen-text OCR are deliberately **not** included yet
  (they need a GPU/paid API and heavier infra). The caption path covers the common case.
- **`/search-recipe`** scrapes DuckDuckGo's HTML endpoint and is genuinely best-effort; the app
  handles an empty result set gracefully, so it never blocks an import.
- yt-dlp is unpinned on purpose — **redeploy periodically** so it stays current with platform
  changes (that's the whole reason yt-dlp lives on a server instead of inside the app).
