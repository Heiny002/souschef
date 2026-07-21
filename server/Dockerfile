# SousChef extraction backend. Railway (and most container hosts) build this automatically.
FROM python:3.12-slim

# ffmpeg is used by yt-dlp for any audio/subtitle post-processing; ca-certificates for TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Railway provides $PORT; default to 8000 for local runs.
ENV PORT=8000
EXPOSE 8000
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
