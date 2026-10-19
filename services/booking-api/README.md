# booking-api

Python service (FastAPI, SQLAlchemy 2, PostgreSQL) that creates and looks up
SkyBook bookings.

Before it stores a booking, the service fetches the flight from
[flight-search](../flight-search). That call confirms the flight exists, checks
seat availability and gets the price. Prices are multiplied with `Decimal` and
rounded to cents, so totals are exact.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| POST | `/api/bookings` | Create a booking. See the request and responses below |
| GET | `/api/bookings/{reference}` | Get one booking (the reference is case-insensitive), or 404 |
| GET | `/api/bookings?email=...` | Bookings for an email address, newest first, up to 20 |
| GET | `/api/bookings/version` | `{"service":"booking-api","version":"<APP_VERSION>"}` |
| GET | `/healthz` | Liveness. Returns 200 whenever the process is serving |
| GET | `/readyz` | Readiness. Runs `SELECT 1` and returns 503 if the database is unreachable |
| GET | `/metrics` | Prometheus metrics |
| GET | `/docs` | OpenAPI UI. It is not routed through the frontend proxy |

### `POST /api/bookings`

```json
{ "flight_id": "SB6162-JFK-LAX-20261020", "passenger_name": "Ada Lovelace",
  "email": "ada@example.com", "seats": 2 }
```

Validation rules: `passenger_name` must be 2-80 characters, `email` must
match a simple `x@y.z` shape (it is stored lowercased), and `seats` must be
between 1 and 9.

| Status | When |
| --- | --- |
| 201 | Booking created. The body is shown below |
| 409 | `seats` is greater than the flight's `seatsAvailable` |
| 422 | Validation error, or `{"detail":"Unknown flight"}` when flight-search returns 404 |
| 503 | flight-search is unreachable, timed out (2 s), returned 5xx, or the database is down |

```json
{
  "reference": "K7Q2ZP",
  "flight_id": "SB6162-JFK-LAX-20261020",
  "passenger_name": "Ada Lovelace",
  "email": "ada@example.com",
  "seats": 2,
  "total_price": 760.76,
  "currency": "USD",
  "status": "CONFIRMED",
  "created_at": "2026-10-19T09:30:12.345678Z",
  "flight": { "id": "SB6162-JFK-LAX-20261020", "departureTime": "05:55", "...": "..." }
}
```

References are 6 characters drawn from an alphabet with no look-alike
characters (`0/O`, `1/I`). A unique index backs them, and a collision is
retried with a new reference.

`GET /api/bookings/{reference}` also fetches the live flight details. If
flight-search is down, the booking is still returned with `"flight": null`.

## Observability

- **Metrics:** `http_request_duration_seconds{method, route, status}` uses
  the same buckets as flight-search. `route` is the route template (for
  example `/api/bookings/{reference}`), or `unmatched` when no route matched,
  and `/metrics` itself is not recorded. The service also exports
  `skybook_bookings_created_total` and
  `skybook_upstream_errors_total{upstream="flight-search"}`, plus the
  standard Python process metrics.
- **Logs:** JSON lines on stdout. Each request gets one line with `method`,
  `route`, `path`, `status`, `duration_ms` and `request_id`. Query strings are
  not logged because they can contain an email address. Uvicorn's own logs
  use the same JSON format, and its access log is disabled.
- **Request IDs:** an incoming `X-Request-ID` is forwarded to flight-search,
  so one ID follows a booking across services.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `DATABASE_URL` | `sqlite:///./skybook.db` | `postgresql://`, `postgres://` and `postgresql+psycopg://` URLs are accepted and run on psycopg 3. `sqlite:///` is meant for tests and local hacking |
| `FLIGHT_SEARCH_URL` | `http://flight-search:3000` | Base URL of flight-search |
| `APP_VERSION` | `dev` | Reported by `/api/bookings/version`. The image sets it from the `VERSION` build arg |
| `LOG_LEVEL` | `INFO` | Python log level |

On startup the service creates its tables. While the database is still coming
up, it retries for about 60 s before it gives up and exits.

## Run and test

```sh
python -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt

pytest --cov                   # SQLite + a fake flight-search, no services needed
ruff check .

FLIGHT_SEARCH_URL=http://localhost:3000 uvicorn app.main:app --reload
```

With Docker:

```sh
docker build --build-arg VERSION=local -t skybook-booking-api .
docker run --rm -p 8000:8000 --read-only --tmpfs /tmp \
  -e DATABASE_URL=postgresql://skybook:skybook@host.docker.internal:5432/skybook \
  skybook-booking-api
```

The image runs as UID 10001 and writes nothing outside `/tmp`, so it works
with `readOnlyRootFilesystem: true`.
