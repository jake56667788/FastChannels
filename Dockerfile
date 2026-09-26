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

# Runtime user this platform requires (uid/gid 1000). Everything up to the
# final USER instruction below still runs as root — Docker images start as
# root by default, so no su/sudo/privilege-escalation is needed to create
# this user or to install anything as root. USER is a native Docker
# instruction that switches the effective user for subsequent layers and
# for the container at runtime; it does not shell out to su or sudo.
RUN groupadd -g 1000 appuser \
    && useradd -u 1000 -g 1000 -m -d /home/appuser -s /bin/bash appuser

# Create FastChannels persistent directories while still root, then hand
# them to the runtime user. /root/.android is not used here: /root itself
# is only accessible to root (mode 0700), so a non-root runtime user could
# never reach anything under it no matter how it's chowned — the ADB
# pairing-key directory has to live under the runtime user's own home
# instead.
RUN mkdir -p /data /home/appuser/.android \
    && chown -R 1000:1000 /data /home/appuser

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

# Point HOME at the runtime user's home BEFORE installing browsers, so
# Playwright and Camoufox write their caches directly under
# /home/appuser/.cache/{ms-playwright,camoufox} instead of /root/.cache —
# the same reasoning as /root/.android above: /root is unreachable for a
# non-root user however it's chowned, so the caches have to be created in
# the right place to begin with rather than moved afterward. This process
# is still root the entire time (no USER switch has happened yet), so
# install-deps' own root check (process.getuid() === 0, verified directly
# against the installed playwright package) takes its direct code path and
# never attempts su or sudo.
ENV HOME=/home/appuser

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

# Hand the browser caches just installed (as root, under HOME=/home/appuser)
# over to the runtime user. This is a plain chown of the exact known path —
# not a filesystem-wide find — since both Playwright's and Camoufox's cache
# locations were confirmed directly against the installed packages:
#   Playwright: $HOME/.cache/ms-playwright
#   Camoufox:   $HOME/.cache/camoufox
RUN chown -R 1000:1000 /home/appuser/.cache

# Disable Redis file logging.
RUN sed -i 's/^logfile .*/logfile ""/' /etc/redis/redis.conf

# Copy FastChannels, owned by the runtime user.
COPY --chown=1000:1000 . /app/

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
        && chown 1000:1000 /app/fc_player_release.apk \
        && echo "Bundled FastChannels Player release APK." \
        || (rm -f /app/fc_player_release.apk.tmp \
            && echo "FastChannels Player APK was not available — install button will report unavailable."))

ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

EXPOSE 5523

# entrypoint.sh runs Redis and Gunicorn under /tmp (world-writable by
# default) and writes application data only under /data, so no further
# ownership work is needed beyond the /data, /home/appuser, and app-code
# chowns already done above.
USER 1000:1000

# Explicitly invoke Bash so the entrypoint does not depend on its shebang.
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
