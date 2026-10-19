# --- deps: install production dependencies from the lockfile only -----------
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# --- runtime -----------------------------------------------------------------
FROM node:24-alpine AS runtime

LABEL org.opencontainers.image.source="https://github.com/vinayak-vk/skybook" \
      org.opencontainers.image.title="skybook-flight-search" \
      org.opencontainers.image.description="SkyBook flight search API" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app

# Files stay owned by root, so the app user can read but not modify its own
# code. Nothing is written at runtime, which is what lets the container run
# with a read-only root filesystem.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Declared late so a version bump does not invalidate the layers above.
ARG VERSION=dev
ENV APP_VERSION=$VERSION \
    NODE_ENV=production \
    PORT=3000
LABEL org.opencontainers.image.version=$VERSION

# Numeric UID (the image's "node" user) so Kubernetes can verify runAsNonRoot.
USER 1000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${PORT}/healthz" || exit 1

# Run node directly (no npm) so it is PID 1 and receives SIGTERM itself.
CMD ["node", "src/server.js"]
