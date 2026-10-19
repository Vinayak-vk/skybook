"""Probes, version and metrics endpoints."""

from pathlib import Path

from fastapi.testclient import TestClient
from prometheus_client import REGISTRY

from app.config import Settings
from app.main import create_app
from tests.fakes import VALID_BOOKING


def test_healthz(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_reports_unreachable_database(tmp_path: Path) -> None:
    # SQLite cannot create a file in a directory that does not exist.
    missing = (tmp_path / "missing" / "bookings.db").as_posix()
    app = create_app(Settings(database_url=f"sqlite:///{missing}", log_level="WARNING"))

    # No `with`: the lifespan (which would retry for a while) is not run.
    response = TestClient(app).get("/readyz")

    assert response.status_code == 503
    assert response.json()["status"] == "unavailable"


def test_version_is_not_shadowed_by_reference_route(client: TestClient) -> None:
    response = client.get("/api/bookings/version")
    assert response.status_code == 200
    assert response.json() == {"service": "booking-api", "version": "1.2.3-test"}


def test_metrics_expose_route_templates(client: TestClient) -> None:
    reference = client.post("/api/bookings", json=VALID_BOOKING).json()["reference"]
    client.get(f"/api/bookings/{reference}")
    client.get("/no-such-path")
    client.get("/metrics")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text
    assert "# TYPE http_request_duration_seconds histogram" in text
    assert 'route="/api/bookings/{reference}"' in text
    assert 'route="unmatched"' in text
    assert 'route="/metrics"' not in text
    assert "skybook_bookings_created_total" in text
    assert "skybook_upstream_errors_total" in text

    count = REGISTRY.get_sample_value(
        "http_request_duration_seconds_count",
        {"method": "GET", "route": "/api/bookings/{reference}", "status": "200"},
    )
    assert count is not None
    assert count >= 1
