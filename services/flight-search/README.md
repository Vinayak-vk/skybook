# flight-search

Node.js (Express 5) service that serves SkyBook's airport list and flight
search results.

Flights are not stored anywhere. Each search seeds a small PRNG with
`from + to + date`, so the same query always returns the same 3-6 flights, and
`GET /api/flights/:id` rebuilds a flight from its id alone. The service is
stateless and can be scaled horizontally without coordination.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/flights/airports` | The 16 supported airports: `{code, city, country, lat, lon}` |
| GET | `/api/flights/search?from=JFK&to=LAX&date=2026-10-20` | `{from, to, date, flights: [...]}`. Returns 400 `{error}` for an unknown airport, `from == to`, or an invalid date |
| GET | `/api/flights/version` | `{"service":"flight-search","version":"<APP_VERSION>"}` |
| GET | `/api/flights/:id` | A single flight, or 404 `{error}`. Ids look like `SB1234-JFK-LAX-20261020` |
| GET | `/healthz` | Liveness: `{"status":"ok"}` |
| GET | `/readyz` | Readiness: `{"status":"ready"}` |
| GET | `/metrics` | Prometheus metrics |

A flight looks like this:

```json
{
  "id": "SB6162-JFK-LAX-20261020",
  "flightNumber": "SB6162",
  "from": "JFK",
  "to": "LAX",
  "date": "2026-10-20",
  "departureTime": "05:55",
  "arrivalTime": "11:25",
  "durationMinutes": 330,
  "price": 380.38,
  "currency": "USD",
  "seatsAvailable": 22,
  "aircraft": "Airbus A321neo"
}
```

Duration comes from the great-circle distance at about 800 km/h plus 30
minutes for taxi and climb. Times are plain clock times with no time zones, and
an `arrivalTime` earlier than `departureTime` means the flight lands the next
day.

## Observability

- **Metrics:** default Node.js process metrics, plus the histogram
  `http_request_duration_seconds{method, route, status}`. `route` is the
  matched Express route template (for example `/api/flights/:id`), or
  `unmatched` when no route matched. Requests to `/metrics` are not recorded.
- **Logs:** pino writes JSON lines to stdout, one per request, with `method`,
  `route`, `path`, `status`, `duration_ms` and `request_id` (taken from the
  `X-Request-ID` header). Probe and scrape requests are logged at `debug`
  level.
- **Shutdown:** on SIGTERM the server stops accepting new connections, lets
  in-flight requests finish (for up to 10 s), then exits.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `3000` | HTTP port |
| `APP_VERSION` | `dev` | Reported by `/api/flights/version`. The image sets it from the `VERSION` build arg |
| `LOG_LEVEL` | `info` | pino log level (`debug`, `info`, `warn`, `error`, `silent`) |

## Run and test

Requires Node.js 22 or later. The image uses Node 24.

```sh
npm install
npm test          # node --test, no extra test dependencies
npm start         # http://localhost:3000/api/flights/airports
```

With Docker:

```sh
docker build --build-arg VERSION=local -t skybook-flight-search .
docker run --rm -p 3000:3000 --read-only skybook-flight-search
```

The image runs as UID 1000 and does not write to its filesystem, so it works
with `readOnlyRootFilesystem: true`.
