```bash
#!/bin/bash
set -e

echo "🚀 Starting FastChannels..."

# Start Redis.
# FastChannels disables Redis persistence, so Redis does not need to write
# anything under /data. Use /tmp, which is writable by the runtime user.
REDIS_DIR="/tmp/redis"
mkdir -p "$REDIS_DIR"

redis-server \
    --daemonize yes \
    --logfile "" \
    --dir "$REDIS_DIR" \
    --dbfilename "dump.rdb" \
    --pidfile "$REDIS_DIR/redis.pid" \
    --save "" \
    --appendonly no

echo "✅ Redis started"

# Wait for Redis to be ready before proceeding.
echo "⏳ Waiting for Redis..."

for i in $(seq 1 30); do
    if redis-cli ping > /dev/null 2>&1; then
        echo "✅ Redis ready"
        break
    fi

    if [ "$i" = "30" ]; then
        echo "❌ Redis did not become ready in time"
        exit 1
    fi

    sleep 0.5
done

# /data is created and made writable by the Dockerfile.
# Do not mkdir /data here because Blitz runs the container as a non-root user.

if [ ! -d /data ]; then
    echo "❌ /data does not exist"
    exit 1
fi

if [ ! -w /data ]; then
    echo "❌ /data exists but is not writable"
    ls -ld /data || true
    exit 1
fi

echo "✅ /data is writable"

# One-time cleanup: the legacy watch-M3U output was replaced by the PrismCast
# hybrid feed, so its artifacts are no longer generated.
rm -f /data/cache/xml/*watch-m3u.m3u 2>/dev/null || true

# Create DB tables and run schema migrations before worker/gunicorn start.
cd /app

python -c "from app import create_app; app = create_app()"

python /app/run_migrations.py

export FC_SCHEMA_READY=1

echo "✅ DB ready"

# Seed sources.
python -c "from app.worker import seed_sources; seed_sources()" || true

echo "✅ Sources seeded"

# Force-purge any source whose scraper class has been missing from the registry
# for longer than its grace period.
python -c "from app.worker import purge_orphaned_sources; purge_orphaned_sources()" || true

echo "✅ Orphaned sources checked"

# Sweep up channels/programs left behind by a disable whose purge job never ran.
python -c "from app.worker import purge_disabled_source_leftovers; purge_disabled_source_leftovers()" || true

echo "✅ Disabled-source leftovers checked"

wait_for_network() {
    echo "⏳ Waiting for outbound network and DNS..."

    for i in $(seq 1 30); do
        if python - <<'PY'
import socket
import sys

targets = [
    ("therokuchannel.roku.com", 443),
    ("watch.sling.com", 443),
    ("tubitv.com", 443),
    ("valencia-app-mds.xumo.com", 443),
]

try:
    for host, port in targets:
        infos = socket.getaddrinfo(
            host,
            port,
            type=socket.SOCK_STREAM
        )

        last_error = None
        connected = False

        for family, socktype, proto, _, sockaddr in infos:
            try:
                with socket.socket(
                    family,
                    socktype,
                    proto
                ) as sock:
                    sock.settimeout(3)
                    sock.connect(sockaddr)

                connected = True
                break

            except OSError as exc:
                last_error = exc

        if not connected:
            raise last_error or OSError(
                f"could not connect to {host}:{port}"
            )

except Exception as exc:
    print(
        f"network check failed: {exc}",
        file=sys.stderr
    )
    sys.exit(1)
PY
        then
            echo "✅ Network ready"
            return 0
        fi

        sleep 2
    done

    echo "⚠ Network was not ready after 60s; starting anyway"
    return 0
}

wait_for_network

# Start isolated worker roles with watchdogs.
#
# scheduler    = periodic scheduling and maintenance
# scraper      = scraping and stream audits
# fast         = immediate short-lived jobs
# maintenance  = heavier non-urgent background work

(
    while true; do
        FC_WORKER_ROLE=scheduler python -m app.worker
        echo "⚠ Scheduler worker exited (code $?) — restarting in 5s"
        sleep 5
    done
) &

(
    while true; do
        FC_WORKER_ROLE=scraper python -m app.worker
        echo "⚠ Scraper worker exited (code $?) — restarting in 5s"
        sleep 5
    done
) &

(
    while true; do
        FC_WORKER_ROLE=fast python -m app.worker
        echo "⚠ Fast worker exited (code $?) — restarting in 5s"
        sleep 5
    done
) &

(
    while true; do
        FC_WORKER_ROLE=maintenance python -m app.worker
        echo "⚠ Maintenance worker exited (code $?) — restarting in 5s"
        sleep 5
    done
) &

echo "✅ Worker roles started (scheduler, scraper, fast, maintenance)"

GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
GUNICORN_MAX_REQUESTS="${GUNICORN_MAX_REQUESTS:-250}"
GUNICORN_MAX_REQUESTS_JITTER="${GUNICORN_MAX_REQUESTS_JITTER:-50}"
GUNICORN_PRELOAD="${GUNICORN_PRELOAD:-1}"

echo "✅ Starting gunicorn on port 5523"

exec gunicorn \
    --config /app/gunicorn.conf.py \
    --bind 0.0.0.0:5523 \
    --worker-class gevent \
    --worker-connections 1000 \
    --workers "$GUNICORN_WORKERS" \
    --timeout 300 \
    --keep-alive 0 \
    --max-requests "$GUNICORN_MAX_REQUESTS" \
    --max-requests-jitter "$GUNICORN_MAX_REQUESTS_JITTER" \
    --pid /tmp/gunicorn.pid \
    --worker-tmp-dir /dev/shm \
    --access-logfile - \
    --access-logformat '%(h)s "%(r)s" %(s)s %(b)s %(T)ss' \
    $(
        [ "$GUNICORN_PRELOAD" = "1" ] && printf '%s' "--preload"
    ) \
    "wsgi:app"
```
