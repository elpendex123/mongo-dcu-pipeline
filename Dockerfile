# Pinned to 3.12 rather than following latest. The local virtual environment
# runs 3.14, and the point of pinning here is that what runs in QA and
# production is the same interpreter every time, regardless of what the
# developer machine happens to have.
FROM python:3.12-slim

# Dependencies first, in their own layer. Application code changes on every
# commit; the dependency set changes rarely, so this ordering means a code
# change reuses the cached install.
WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --requirement requirements.txt

# The Amazon RDS certificate bundle, required to connect to DocumentDB.
#
# DocumentDB enforces TLS and the driver has to verify the server against this
# bundle - so the connection URI sets tlsCAFile to this path. Fetched with
# Python rather than curl because the slim image has no curl, and adding one
# purely for a build step would mean carrying it in production forever.
#
# Nothing in local dev needs it: the MongoDB container speaks plain TCP. It is
# here because the image that runs in qa and prod is the same image.
RUN python -c "import urllib.request; urllib.request.urlretrieve('https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem', '/etc/ssl/certs/global-bundle.pem')" \
 && test -s /etc/ssl/certs/global-bundle.pem

COPY app/ ./app/

# Runs as a non-root user. The application needs to read query files, write
# logs and talk to three services over the network - none of which needs root,
# and a container process running as root is one container escape away from
# being root on the node.
#
# The id is a build argument because local development bind-mounts two host
# directories into this container: the developer's ~/.aws, which is mode 0600
# and readable only by its owner, and ./logs, which the container has to write
# to. A uid that does not match the host user can read neither. Compose builds
# with the host's uid; CI builds take the default.
ARG APP_UID=1001
ARG APP_GID=1001

RUN groupadd --gid ${APP_GID} appuser \
 && useradd --uid ${APP_UID} --gid ${APP_GID} --home-dir /app appuser \
 && mkdir -p /var/log/mongo-dcu /tmp/mongo-dcu \
 && chown -R ${APP_UID}:${APP_GID} /app /var/log/mongo-dcu /tmp/mongo-dcu

USER appuser

# HOME is set explicitly rather than left to the passwd entry, so the AWS SDK
# resolves ~/.aws to the same path whether or not the runtime overrides the
# user.
ENV HOME=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LOG_DIR=/var/log/mongo-dcu \
    WORK_DIR=/tmp/mongo-dcu \
    METRICS_PORT=9090

EXPOSE 9090

# The metrics endpoint doubles as the liveness signal. It is served by the same
# process that runs the polling loop, so a process that has stopped responding
# here has stopped polling too. Written in Python rather than curl because the
# slim image has no curl, and adding one purely for a healthcheck would mean
# carrying it in production for the rest of the image's life.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:9090/metrics', timeout=4)" || exit 1

CMD ["python", "-m", "app.main"]
