"""Prometheus metrics and the request observability middleware."""

import logging
import time

from prometheus_client import Counter, Histogram, disable_created_metrics
from starlette.types import ASGIApp, Message, Receive, Scope, Send

# The *_created timestamp series double the series count and nothing here
# uses them.
disable_created_metrics()

# Same name, labels and buckets as flight-search so dashboards and SLO rules
# can aggregate across services.
REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    labelnames=("method", "route", "status"),
    buckets=(0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
BOOKINGS_CREATED = Counter(
    "skybook_bookings_created_total",
    "Bookings successfully created.",
)
UPSTREAM_ERRORS = Counter(
    "skybook_upstream_errors_total",
    "Failed calls to upstream services (network errors, timeouts, 5xx, bad payloads).",
    labelnames=("upstream",),
)

UNMATCHED_ROUTE = "unmatched"
# Probes and scrapes arrive every few seconds; keep them out of the info-level log.
_QUIET_PATHS = frozenset({"/healthz", "/readyz", "/metrics"})

access_logger = logging.getLogger("booking_api.access")


def route_template(scope: Scope) -> str:
    """The matched route's path template, e.g. /api/bookings/{reference}.

    Using the template rather than the raw path keeps label cardinality bounded.
    The router stores the matched route in the (shared, mutable) scope, so it is
    available here once the downstream app has run.
    """
    path = getattr(scope.get("route"), "path", None)
    return path if isinstance(path, str) else UNMATCHED_ROUTE


def _header(scope: Scope, name: bytes) -> str | None:
    for key, value in scope.get("headers", ()):
        if key == name:
            return value.decode("latin-1")
    return None


class ObservabilityMiddleware:
    """Records request latency and writes one structured log line per request.

    A plain ASGI middleware rather than BaseHTTPMiddleware: it never buffers
    the response body and sees the real status code, including the 500 that
    ServerErrorMiddleware sends when a handler raises.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.perf_counter()
        status_code = 500  # what the client gets if the app raises before responding

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            self._record(scope, status_code, time.perf_counter() - start)

    @staticmethod
    def _record(scope: Scope, status_code: int, duration: float) -> None:
        method = scope["method"]
        path = scope["path"]
        route = route_template(scope)

        if path != "/metrics":
            REQUEST_DURATION.labels(method=method, route=route, status=str(status_code)).observe(
                duration
            )

        if status_code >= 500:
            level = logging.ERROR
        elif path in _QUIET_PATHS:
            level = logging.DEBUG
        else:
            level = logging.INFO
        # The query string is deliberately not logged: it can carry an email.
        fields = {
            "method": method,
            "route": route,
            "path": path,
            "status": status_code,
            "duration_ms": round(duration * 1000, 3),
        }
        request_id = _header(scope, b"x-request-id")
        if request_id:
            fields["request_id"] = request_id
        access_logger.log(level, "request completed", extra=fields)
