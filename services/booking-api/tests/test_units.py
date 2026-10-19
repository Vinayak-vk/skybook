"""Unit tests for configuration, the flight-search client and logging."""

import json
import logging
from typing import Any

import httpx
import pytest

from app.config import DEFAULT_DATABASE_URL, Settings
from app.db import create_db_engine, normalize_database_url
from app.flights import FlightSearchClient, FlightServiceUnavailable
from app.logging_config import JsonFormatter
from app.routes import REFERENCE_ALPHABET, generate_reference
from tests.fakes import FLIGHT_ID, make_flight

# --- configuration ------------------------------------------------------------


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("postgresql://u:p@db:5432/app", "postgresql+psycopg://u:p@db:5432/app"),
        ("postgres://u:p@db/app", "postgresql+psycopg://u:p@db/app"),
        ("postgresql+psycopg://u:p@db/app", "postgresql+psycopg://u:p@db/app"),
        ("sqlite:///./local.db", "sqlite:///./local.db"),
    ],
)
def test_normalize_database_url(url: str, expected: str) -> None:
    assert normalize_database_url(url) == expected


def test_postgres_engine_uses_psycopg3() -> None:
    engine = create_db_engine("postgresql://u:p@localhost:5432/app")
    try:
        assert engine.url.drivername == "postgresql+psycopg"
    finally:
        engine.dispose()


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("FLIGHT_SEARCH_URL", "http://flights.internal:3000/")
    monkeypatch.setenv("APP_VERSION", "abc123")

    settings = Settings.from_env()

    assert settings.database_url == DEFAULT_DATABASE_URL
    assert settings.flight_search_url == "http://flights.internal:3000"
    assert settings.app_version == "abc123"


def test_generate_reference() -> None:
    reference = generate_reference()
    assert len(reference) == 6
    assert set(reference) <= set(REFERENCE_ALPHABET)


# --- flight-search client -----------------------------------------------------


def client_for(handler: Any) -> FlightSearchClient:
    return FlightSearchClient("http://flight-search:3000", transport=httpx.MockTransport(handler))


def test_client_returns_flight_and_forwards_request_id() -> None:
    seen: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["request_id"] = request.headers.get("x-request-id")
        return httpx.Response(200, json=make_flight())

    assert client_for(handler).get_flight(FLIGHT_ID, request_id="req-1") == make_flight()
    assert seen == {
        "url": f"http://flight-search:3000/api/flights/{FLIGHT_ID}",
        "request_id": "req-1",
    }


def test_client_returns_none_for_unknown_flight() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"error": "Flight not found"})

    assert client_for(handler).get_flight(FLIGHT_ID) is None


@pytest.mark.parametrize(
    ("status", "kwargs"),
    [
        (500, {"json": {"error": "boom"}}),
        (503, {"text": "Service Unavailable"}),
        (200, {"text": "not json"}),
        (200, {"json": {"id": FLIGHT_ID}}),
    ],
)
def test_client_rejects_bad_responses(status: int, kwargs: dict[str, Any]) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, **kwargs)

    with pytest.raises(FlightServiceUnavailable):
        client_for(handler).get_flight(FLIGHT_ID)


def test_client_wraps_network_errors() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    with pytest.raises(FlightServiceUnavailable):
        client_for(handler).get_flight(FLIGHT_ID)


# --- logging ------------------------------------------------------------------


def test_json_formatter_emits_extra_fields() -> None:
    record = logging.makeLogRecord(
        {
            "name": "test",
            "levelname": "INFO",
            "msg": "hello %s",
            "args": ("world",),
            "route": "/api/bookings/{reference}",
        }
    )

    line = json.loads(JsonFormatter(version="9.9.9").format(record))

    assert line["msg"] == "hello world"
    assert line["level"] == "info"
    assert line["service"] == "booking-api"
    assert line["version"] == "9.9.9"
    assert line["route"] == "/api/bookings/{reference}"
