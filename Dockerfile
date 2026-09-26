FROM node:24-bookworm-slim AS node_runtime

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    curl \
    redis-server \
    ca-certificates \
    sqlite3 \
    libxml2-utils \
    xvfb \
    libgtk-3-0 \
    libstdc++6 \
    android-tools-adb \
    && rm -rf /var/lib/apt/lists/*

# Create FastChannels persistent directories while building as root.
# Blitz runs the container as a non-root user at runtime.
RUN mkdir -p /data /root/.android \
    && chmod 0777 /data \
    && chmod 0777 /root/.android

# Node.js 24 from the official Node image.
COPY --from=node_runtime /usr/local/bin/node /usr/local/bin/node-real

# yt-dlp may invoke node with --permission.
# Add the required permissions only when --permission is requested.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'case " $* " in' \
    '  *" --permission "*|*" --experimental-permission "*)' \
    '    exec /usr/local/bin/node-real --no-warnings --allow-fs-read=* --allow-child-process "$@" ;;' \
    'esac' \
    'exec /usr/local/bin/node-real "$@"' \
    > /usr/local/bin/node \
    && chmod +x /usr/local/bin/node

COPY requirements.txt /app/

RUN pip install --upgrade pip \
    && pip install -r requirements.txt

# Keep yt-dlp at GitHub master.
ARG YTDLP_REFRESH=unset

RUN echo "yt-dlp refresh token: ${YTDLP_REFRESH}" \
    && pip install --force-reinstall \
        "yt-dlp[default] @ https://github.com/yt-dlp/yt-dlp/archive/master.tar.gz"

RUN playwright install-deps chromium \
    && playwright install chromium

# Real Google Chrome is amd64-only.
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        playwright install-deps chrome \
        && playwright install chrome; \
    else \
        echo "Skipping unsupported Playwright Chrome download on $TARGETARCH"; \
    fi

# Camoufox for interactive Sling sign-in.
RUN python -m camoufox fetch

# Disable Redis file logging in the system configuration.
# entrypoint.sh explicitly passes --logfile "" too.
RUN sed -i 's/^logfile .*/logfile ""/' /etc/redis/redis.conf

# Copy the FastChannels application.
COPY . /app/

RUN chmod +x /app/entrypoint.sh

# Bundle the latest FastChannels Player release APK.
ARG FC_PLAYER_APK_REFRESH=unset

RUN echo "fc-player APK refresh token: ${FC_PLAYER_APK_REFRESH}" \
    && (curl -fsSL \
        -o /app/fc_player_release.apk.tmp \
        "https://github.com/kineticman/FastChannels/releases/latest/download/FastChannelsPlayer.apk" \
        && mv /app/fc_player_release.apk.tmp /app/fc_player_release.apk \
        && echo "Bundled FastChannels Player release APK." \
        || (rm -f /app/fc_player_release.apk.tmp \
            && echo "FastChannels Player APK was not available — install button will report unavailable."))

# Use the system CA bundle for Python requests.
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

EXPOSE 5523

ENTRYPOINT ["/app/entrypoint.sh"]
