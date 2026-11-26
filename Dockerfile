# The read-only web app: archivectl built from source in the Swift toolchain image, run from the slim runtime image with the
# system SQLite, libvips (thumbnails; libde265 for HEIC) and tzdata (month counts use local time). Builds anywhere with Docker
# (x86_64 or arm64). docker-compose.yml shows how to run it.
FROM swift:6.3-noble AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --product archivectl \
 && mkdir -p /out && cp "$(swift build -c release --product archivectl --show-bin-path)/archivectl" /out/

FROM swift:6.3-noble-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends libsqlite3-0 libvips-tools libheif-plugin-libde265 tzdata ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# COPY keeps the context's modes with root ownership, so set them here (COPY --chmod works where RUN chmod may not).
COPY --from=build --chmod=0755 /out/archivectl /app/archivectl
COPY --chmod=0644 web /app/web
# The thumbnail cache, owned by the user the server runs as (a named volume mounted here inherits it).
RUN mkdir -p /cache && chown 1000:1000 /cache
# The zone month and day counts are shown in; set TZ to yours.
ENV TZ=UTC
# The host name(s) people reach the app by (through your reverse proxy), space-separated. Required.
ENV ARCHIVE_WEB_HOSTS=localhost
# Runs as uid 1000: the archive mount must be readable by it (see README.md, "The web app").
USER 1000:1000
EXPOSE 8452
# Loopback needs no key (the gate exempts it), so the check sees the real answer of the real server.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
  CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/8452 && printf "GET /healthz HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" >&3 && head -1 <&3 | grep -q " 200 "'
ARG REVISION=unknown
LABEL org.opencontainers.image.revision=$REVISION
# The gate: Host must be one of $ARCHIVE_WEB_HOSTS, and every non-loopback request must carry the key your reverse proxy adds
# (X-Archive-Key = $ARCHIVE_WEB_KEY; serve-web refuses to start without it). Any peer is accepted: the port mapping is the boundary.
CMD set -- ; for h in $ARCHIVE_WEB_HOSTS; do set -- "$@" --allow-host "$h"; done; \
    exec /app/archivectl --archive /archive serve-web --bind 0.0.0.0 --port 8452 --any-peer "$@" --web /app/web --cache /cache
