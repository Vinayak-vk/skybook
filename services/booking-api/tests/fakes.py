"""Test doubles for flight-search."""

from typing import Any

from app.flights import FlightServiceUnavailable

FLIGHT_ID = "SB1234-JFK-LAX-20261020"

VALID_BOOKING: dict[str, Any] = {
    "flight_id": FLIGHT_ID,
    "passenger_name": "Ada Lovelace",
    "email": "Ada@Example.com",
    "seats": 2,
}


def make_flight(
    flight_id: str = FLIGHT_ID, price: float = 199.99, seats: int = 12
) -> dict[str, Any]:
    """A flight shaped exactly like flight-search's GET /api/flights/{id} response."""
    flight_number, origin, destination, day = flight_id.split("-")
    return {
        "id": flight_id,
        "flightNumber": flight_number,
        "from": origin,
        "to": destination,
        "date": f"{day[:4]}-{day[4:6]}-{day[6:]}",
        "departureTime": "08:15",
        "arrivalTime": "11:20",
        "durationMinutes": 365,
        "price": price,
        "currency": "USD",
        "seatsAvailable": seats,
        "aircraft": "Airbus A321neo",
    }


class FakeFlightClient:
    """In-memory flight-search. Set ``available = False`` to simulate an outage."""

    def __init__(self) -> None:
        self.flights: dict[str, dict[str, Any]] = {FLIGHT_ID: make_flight()}
        self.available = True
        self.calls: list[tuple[str, str | None]] = []

    def add(self, flight: dict[str, Any]) -> None:
        self.flights[flight["id"]] = flight

    def get_flight(self, flight_id: str, request_id: str | None = None) -> dict[str, Any] | None:
        self.calls.append((flight_id, request_id))
        if not self.available:
            raise FlightServiceUnavailable("ConnectError: connection refused")
        return self.flights.get(flight_id)

    def close(self) -> None:
        pass
