# Multi-arch by default: the official python image publishes arm64 + arm/v7
# manifests, so this same Dockerfile builds on a 64-bit or 32-bit Raspberry Pi.
# slim (glibc) avoids Alpine/musl DNS + thread-stack surprises; this app has
# zero pip dependencies so the size win from Alpine isn't worth those gotchas.
FROM python:3.12-slim

# Run as a non-root user inside the container.
RUN useradd --create-home --uid 10001 florence

WORKDIR /app
COPY server.py ./server.py
COPY public ./public

ENV FLORENCE_HOST=0.0.0.0 \
    FLORENCE_PORT=8080 \
    FLORENCE_STATIC_DIR=/app/public \
    FLORENCE_CACHE_DIR=/cache \
    PYTHONUNBUFFERED=1

# Persisted, writable feed cache (mount a named volume here in compose).
RUN mkdir -p /cache && chown florence:florence /cache
VOLUME ["/cache"]

USER florence
EXPOSE 8080

# slim has no curl/wget — probe with stdlib urllib so we add no packages.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=4).status==200 else 1)"

CMD ["python", "-u", "server.py"]
