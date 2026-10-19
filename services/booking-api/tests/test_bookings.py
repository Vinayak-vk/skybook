"""Booking endpoints, end to end through the HTTP layer."""

import re
from typing import Any

import pytest
from fastapi.testclient import TestClient
from httpx import Response
from prometheus_client import REGISTRY

from tests.fakes import FLIGHT_ID, VALID_BOOKING, FakeFlightClient, make_flight

REFERENCE_PATTERN = re.compile(r"[A-HJ-NP-Z2-9]{6}")


def book(client: TestClient, **overrides: Any) -> Response:
    return client.post("/api/bookings", json={**VALID_BOOKING, **overrides})


def counter(name: str, labels: dict[str, str] | None = None) -> float:
    return REGISTRY.get_sample_value(name, labels or {}) or 0.0


# --- create -------------------------------------------------------------------


def test_create_booking(client: TestClient) -> None:
    response = book(client)

    assert response.status_code == 201
    body = response.json()
    assert REFERENCE_PATTERN.fullmatch(body["reference"])
    assert body["flight_id"] == FLIGHT_ID
    assert body["passenger_name"] == "Ada Lovelace"
    assert body["email"] == "ada@example.com"
    assert body["seats"] == 2
    assert body["total_price"] == 399.98
    assert body["currency"] == "USD"
    assert body["status"] == "CONFIRMED"
    assert body["created_at"]
    assert body["flight"] == make_flight()


def test_total_price_uses_decimal_arithmetic(client: TestClient, flights: FakeFlightClient) -> None:
    # 33.335 * 3 is 100.00499999... in binary floating point.
    flights.add(make_flight("SB2000-BOS-SFO-20261101", price=33.335))

    response = book(client, flight_id="SB2000-BOS-SFO-20261101", seats=3)

    assert response.status_code == 201
    assert response.json()["total_price"] == 100.01


def test_create_increments_counter(client: TestClient) -> None:
    before = counter("skybook_bookings_created_total")
    assert book(client).status_code == 201
    assert counter("skybook_bookings_created_total") == before + 1


def test_request_id_is_forwarded_upstream(client: TestClient, flights: FakeFlightClient) -> None:
    client.post("/api/bookings", json=VALID_BOOKING, headers={"X-Request-ID": "req-42"})
    assert flights.calls[-1] == (FLIGHT_ID, "req-42")


@pytest.mark.parametrize(
    "overrides",
    [
        {"seats": 0},
        {"seats": 10},
        {"passenger_name": "A"},
        {"passenger_name": "x" * 81},
        {"email": "not-an-email"},
        {"email": "two@@example.com"},
        {"flight_id": "../../healthz"},
        {"flight_id": ""},
    ],
)
def test_create_rejects_invalid_input(client: TestClient, overrides: dict[str, Any]) -> None:
    response = book(client, **overrides)
    assert response.status_code == 422
    assert isinstance(response.json()["detail"], list)


def test_create_rejects_missing_fields(client: TestClient) -> None:
    response = client.post("/api/bookings", json={"flight_id": FLIGHT_ID})
    assert response.status_code == 422


def test_unknown_flight(client: TestClient) -> None:
    response = book(client, flight_id="SB9999-JFK-LAX-20261020")
    assert response.status_code == 422
    assert response.json() == {"detail": "Unknown flight"}


def test_not_enough_seats(client: TestClient, flights: FakeFlightClient) -> None:
    flights.add(make_flight("SB3000-ORD-DEN-20261105", seats=3))

    response = book(client, flight_id="SB3000-ORD-DEN-20261105", seats=4)

    assert response.status_code == 409
    assert "3" in response.json()["detail"]


def test_flight_search_down(client: TestClient, flights: FakeFlightClient) -> None:
    labels = {"upstream": "flight-search"}
    before = counter("skybook_upstream_errors_total", labels)
    flights.available = False

    response = book(client)

    assert response.status_code == 503
    assert counter("skybook_upstream_errors_total", labels) == before + 1


# --- read ---------------------------------------------------------------------


def test_get_booking_by_reference(client: TestClient) -> None:
    created = book(client).json()

    response = client.get(f"/api/bookings/{created['reference']}")

    assert response.status_code == 200
    assert response.json() == created


def test_get_booking_is_case_insensitive(client: TestClient) -> None:
    reference = book(client).json()["reference"]
    response = client.get(f"/api/bookings/{reference.lower()}")
    assert response.status_code == 200
    assert response.json()["reference"] == reference


def test_get_booking_survives_flight_search_outage(
    client: TestClient, flights: FakeFlightClient
) -> None:
    reference = book(client).json()["reference"]
    flights.available = False

    response = client.get(f"/api/bookings/{reference}")

    assert response.status_code == 200
    assert response.json()["flight"] is None


def test_get_unknown_booking(client: TestClient) -> None:
    response = client.get("/api/bookings/ZZZZZZ")
    assert response.status_code == 404
    assert response.json() == {"detail": "Booking not found"}


def test_list_bookings_by_email_newest_first(client: TestClient) -> None:
    references = [book(client, email="Grace@Example.com").json()["reference"] for _ in range(3)]
    book(client, email="someone-else@example.com")

    response = client.get("/api/bookings", params={"email": "GRACE@example.com"})

    assert response.status_code == 200
    assert [item["reference"] for item in response.json()] == list(reversed(references))


def test_list_bookings_is_capped(client: TestClient) -> None:
    for _ in range(21):
        assert book(client, email="frequent@example.com", seats=1).status_code == 201

    response = client.get("/api/bookings", params={"email": "frequent@example.com"})

    assert response.status_code == 200
    assert len(response.json()) == 20


def test_list_bookings_unknown_email(client: TestClient) -> None:
    response = client.get("/api/bookings", params={"email": "nobody@example.com"})
    assert response.status_code == 200
    assert response.json() == []


def test_list_bookings_requires_email(client: TestClient) -> None:
    assert client.get("/api/bookings").status_code == 422
