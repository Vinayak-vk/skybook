"""Client for the flight-search service."""

from typing import Any
from urllib.parse import quote

import httpx
from fastapi import Request


class FlightServiceUnavailable(Exception):
    """flight-search could not be reached or gave an unusable answer."""


def _looks_like_flight(payload: Any) -> bool:
    return (
        isinstance(payload, dict)
        and isinstance(payload.get("price"), int | float)
        and isinstance(payload.get("seatsAvailable"), int)
    )


class FlightSearchClient:
    """Thin synchronous wrapper around GET /api/flights/{id}.

    One pooled ``httpx.Client`` is shared by all requests (it is thread-safe),
    so connections to flight-search are reused instead of opened per booking.
    """

    def __init__(
        self,
        base_url: str,
        timeout: float = 2.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._client = httpx.Client(
            base_url=base_url,
            timeout=timeout,
            transport=transport,
            headers={"Accept": "application/json", "User-Agent": "skybook-booking-api"},
        )

    def get_flight(self, flight_id: str, request_id: str | None = None) -> dict[str, Any] | None:
        """Return the flight, None if flight-search does not know it.

        Raises FlightServiceUnavailable on network errors, timeouts, 5xx and
        malformed responses, which callers translate into a 503.
        """
        path = f"/api/flights/{quote(flight_id, safe='')}"
        headers = {"X-Request-ID": request_id} if request_id else None
        try:
            response = self._client.get(path, headers=headers)
        except httpx.HTTPError as exc:
            raise FlightServiceUnavailable(f"{type(exc).__name__}: {exc}") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise FlightServiceUnavailable(f"unexpected status {response.status_code}")

        try:
            payload = response.json()
        except ValueError as exc:
            raise FlightServiceUnavailable("response is not valid JSON") from exc
        if not _looks_like_flight(payload):
            raise FlightServiceUnavailable("response does not look like a flight")
        return payload

    def close(self) -> None:
        self._client.close()


def get_flight_client(request: Request) -> FlightSearchClient:
    """FastAPI dependency; tests override it with a fake."""
    return request.app.state.flight_client
