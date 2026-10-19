# nginx-unprivileged: runs as UID 101, listens on 8080, and keeps its pid file
# and temp paths in /tmp, so it works with readOnlyRootFilesystem plus
# emptyDirs on /tmp and /etc/nginx/conf.d.
FROM nginxinc/nginx-unprivileged:1.30-alpine

LABEL org.opencontainers.image.source="https://github.com/vinayak-vk/skybook" \
      org.opencontainers.image.title="skybook-frontend" \
      org.opencontainers.image.description="SkyBook web frontend (static site + API proxy)" \
      org.opencontainers.image.licenses="MIT"

# Rendered into /etc/nginx/conf.d/default.conf by the image's envsubst
# entrypoint script on every start, so the same image works in any environment.
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY public/ /usr/share/nginx/html/

# Defaults for every placeholder in the template; Compose and Kubernetes
# override APP_ENV and the upstream URLs per environment.
ARG VERSION=dev
ENV APP_VERSION=$VERSION \
    APP_ENV=local \
    FLIGHT_SEARCH_URL=http://flight-search:3000 \
    BOOKING_API_URL=http://booking-api:8000
LABEL org.opencontainers.image.version=$VERSION

# The base image's numeric non-root user (nginx).
USER 101

EXPOSE 8080
