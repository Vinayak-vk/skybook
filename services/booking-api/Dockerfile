# --- build: resolve dependencies into a self-contained virtualenv ------------
FROM python:3.13-slim AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
# All dependencies ship binary wheels (psycopg[binary] bundles libpq), so no
# compiler or system packages are needed. pip byte-compiles here, at build
# time, because the runtime filesystem is read-only.
RUN pip install -r /tmp/requirements.txt

# --- runtime -----------------------------------------------------------------
FROM python:3.13-slim AS runtime

LABEL org.opencontainers.image.source="https://github.com/vinayak-vk/skybook" \
      org.opencontainers.image.title="skybook-booking-api" \
      org.opencontainers.image.description="SkyBook booking API" \
      org.opencontainers.image.licenses="MIT"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Only the frontend's nginx can reach this service (NetworkPolicy), so trust
# its X-Forwarded-* headers; --proxy-headers alone trusts only 127.0.0.1.
ENV FORWARDED_ALLOW_IPS="*"

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY app ./app

# Declared late so a version bump does not invalidate the layers above.
ARG VERSION=dev
ENV APP_VERSION=$VERSION
LABEL org.opencontainers.image.version=$VERSION

# Numeric UID so Kubernetes can verify runAsNonRoot. Code stays root-owned
# and read-only; nothing but /tmp needs to be writable.
USER 10001

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-access-log"]
