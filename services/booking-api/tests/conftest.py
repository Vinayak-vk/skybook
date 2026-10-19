"""Shared fixtures: the real app on a throwaway SQLite database, with flight-search faked."""

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.flights import get_flight_client
from app.main import create_app
from tests.fakes import FakeFlightClient


@pytest.fixture
def flights() -> FakeFlightClient:
    return FakeFlightClient()


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_url=f"sqlite:///{(tmp_path / 'bookings.db').as_posix()}",
        flight_search_url="http://flight-search.invalid",
        app_version="1.2.3-test",
        log_level="WARNING",
        db_startup_timeout=5.0,
    )


@pytest.fixture
def client(settings: Settings, flights: FakeFlightClient) -> Iterator[TestClient]:
    app = create_app(settings)
    app.dependency_overrides[get_flight_client] = lambda: flights
    # Entering the context runs the lifespan, which creates the tables.
    with TestClient(app) as test_client:
        yield test_client
