# frontend

The SkyBook web UI. It is plain HTML, CSS and ES modules served by nginx, with
no framework, no build step and no external CDNs. The same nginx
reverse-proxies the API paths to the backend services, so the browser only
ever talks to one origin, and the image runs unchanged in Docker Compose and
in Kubernetes.

## Features

- Flight search: the airport list comes from `/api/flights/airports` and the
  date defaults to tomorrow. Results show times (with a `+1` marker for
  next-day arrivals), duration, aircraft, seats left and fare.
- Booking: **Book** opens a dialog for name, email and seats with a live
  total. The form posts to `/api/bookings` and shows a confirmation card
  with the booking reference.
- **Find my booking** looks a booking up by its 6-character reference.
- Loading skeletons, inline errors with retry, and an `nginx` JSON fallback
  when a backend is unreachable.
- Footer: an environment badge plus the version of each of the three
  services, read from `/version.json`, `/api/flights/version` and
  `/api/bookings/version`. A version shows as "unavailable" if its request
  fails.
- Responsive layout, dark mode, keyboard accessible, `prefers-reduced-motion`
  aware.

## Layout

```
public/
  index.html     page shell and <template> elements
  styles.css     all styling (system font stack)
  app.js         behaviour (ES module)
  favicon.svg
nginx/
  default.conf.template   rendered by the nginx image's envsubst entrypoint
```

## nginx

| Path | Behaviour |
| --- | --- |
| `/` | Static files. Unknown paths fall back to `index.html` |
| `/api/flights/` | Proxied to `${FLIGHT_SEARCH_URL}` with the full path preserved |
| `/api/bookings` | Proxied to `${BOOKING_API_URL}` with the full path preserved |
| `/healthz` | `200 ok`. Used by the liveness and readiness probes |
| `/version.json` | `{"service":"frontend","version":"${APP_VERSION}","environment":"${APP_ENV}"}` |

Other behaviour:

- Every response carries security headers: CSP (`'self'` only, no inline
  script or style), `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy` and `Permissions-Policy`.
- Responses are gzipped, and `index.html` is served with no-cache.
- Access logs are JSON. They log the path without the query string.
- An `X-Request-ID` is generated, or reused if the caller sent one, and
  forwarded to the APIs.
- If an upstream cannot be reached or times out, nginx returns a JSON `503`
  instead of its HTML error page.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `APP_VERSION` | `dev` | Set from the `VERSION` build arg |
| `APP_ENV` | `local` | Shown as the environment badge (`local`, `dev`, `staging` and `prod` get their own colours) |
| `FLIGHT_SEARCH_URL` | `http://flight-search:3000` | Scheme, host and port only, with no path |
| `BOOKING_API_URL` | `http://booking-api:8000` | Scheme, host and port only, with no path |

## Run

The simplest way to run the frontend is with the whole stack: run
`docker compose up --build` from the repository root, then open
<http://localhost:8080>.

To run the frontend container on its own:

```sh
docker build --build-arg VERSION=local -t skybook-frontend .
docker run --rm -p 8080:8080 --read-only --tmpfs /tmp --tmpfs /etc/nginx/conf.d \
  -e FLIGHT_SEARCH_URL=http://host.docker.internal:3000 \
  -e BOOKING_API_URL=http://host.docker.internal:8000 \
  skybook-frontend
```

nginx resolves the upstream host names when it starts, so they must resolve
by then. Kubernetes Services and Compose service names do.

The image runs as the base image's UID 101 and listens on 8080. With
`readOnlyRootFilesystem`, mount writable volumes at `/tmp` (pid file and temp
files) and `/etc/nginx/conf.d` (the rendered config).
