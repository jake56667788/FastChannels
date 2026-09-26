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
RUN mkdir -p /data /root/.android \
    && chmod 0777 /data \
    && chmod 0777 /root/.android

# Node.js 24 from the official Node image.
COPY --from=node_runtime /usr/local/bin/node /usr/local/bin/node-real

# yt-dlp may invoke node with --permission.
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

# Keep HOME/USER pinned to root explicitly for the browser install steps
# below. Playwright's own install-deps root check (transformCommandsForRoot
# in its JS driver) is based on process.getuid() === 0, not on HOME/USER —
# verified directly against the installed playwright package — so this does
# not itself change that logic. It's kept here as a defensive, harmless pin.
# No separate user is ever created in this Dockerfile, no
# PLAYWRIGHT_BROWSERS_PATH override points at a non-root directory, and no
# USER directive switches away from root at any point, so root stays root
# end to end and install-deps' direct (non-su, non-sudo) code path is what
# actually runs.
ENV HOME=/root \
    USER=root

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

# Browser dependencies/binaries above were installed while running as root
# during this build. The container also runs as root at runtime (no USER
# directive switches to another user anywhere in this Dockerfile), so no
# additional ownership or permission changes are needed for FastChannels to
# read/execute the installed browsers and their cache directories.

# Disable Redis file logging.
RUN sed -i 's/^logfile .*/logfile ""/' /etc/redis/redis.conf

# Copy FastChannels.
COPY . /app/

# Normalize entrypoint.sh to Unix LF line endings.
# This prevents Windows CRLF files from causing "exec format error".
RUN sed -i 's/\r$//' /app/entrypoint.sh \
    && chmod +x /app/entrypoint.sh

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

ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

EXPOSE 5523

# Explicitly invoke Bash so the entrypoint does not depend on its shebang.
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
