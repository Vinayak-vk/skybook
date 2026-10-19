"""HTTP handlers. Routes are registered in app.main.create_app."""

import logging
import secrets
from decimal import ROUND_HALF_UP, Decimal
from typing import Annotated, Any

from fastapi import Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import check_database, get_session
from app.flights import FlightSearchClient, FlightServiceUnavailable, get_flight_client
from app.metrics import BOOKINGS_CREATED, UPSTREAM_ERRORS
from app.models import Booking, utcnow
from app.schemas import BookingCreate, BookingOut

logger = logging.getLogger(__name__)

SessionDep = Annotated[Session, Depends(get_session)]
SettingsDep = Annotated[Settings, Depends(get_settings)]
FlightClientDep = Annotated[FlightSearchClient, Depends(get_flight_client)]

# No 0/O or 1/I so references survive being read out over the phone.
REFERENCE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
REFERENCE_LENGTH = 6
REFERENCE_ATTEMPTS = 5
LIST_LIMIT = 20
CENTS = Decimal("0.01")


def generate_reference() -> str:
    return "".join(secrets.choice(REFERENCE_ALPHABET) for _ in range(REFERENCE_LENGTH))


def _fetch_flight(
    flights: FlightSearchClient, flight_id: str, request: Request
) -> dict[str, Any] | None:
    """Look a flight up, counting and logging upstream failures before re-raising."""
    try:
        return flights.get_flight(flight_id, request_id=request.headers.get("x-request-id"))
    except FlightServiceUnavailable as exc:
        UPSTREAM_ERRORS.labels(upstream="flight-search").inc()
        logger.warning(
            "flight-search lookup failed", extra={"flight_id": flight_id, "error": str(exc)}
        )
        raise


def _to_out(booking: Booking, flight: dict[str, Any] | None) -> BookingOut:
    out = BookingOut.model_validate(booking)
    out.flight = flight
    return out


# --- probes, metrics, version ------------------------------------------------


async def healthz() -> dict[str, str]:
    # Liveness only: the process is up and serving. Dependencies are checked
    # by /readyz so a database outage never gets healthy pods restarted.
    return {"status": "ok"}


def readyz(request: Request) -> JSONResponse:
    try:
        check_database(request.app.state.engine)
    except SQLAlchemyError as exc:
        error = str(getattr(exc, "orig", None) or exc)
        logger.warning("readiness check failed", extra={"error": error})
        return JSONResponse(
            {"status": "unavailable", "detail": "database unreachable"}, status_code=503
        )
    return JSONResponse({"status": "ready"})


async def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


async def get_version(settings: SettingsDep) -> dict[str, str]:
    return {"service": "booking-api", "version": settings.app_version}


# --- bookings ----------------------------------------------------------------


def create_booking(
    payload: BookingCreate,
    request: Request,
    session: SessionDep,
    flights: FlightClientDep,
) -> BookingOut:
    try:
        flight = _fetch_flight(flights, payload.flight_id, request)
    except FlightServiceUnavailable as exc:
        raise HTTPException(
            status_code=503, detail="Flight search is unavailable, please try again shortly"
        ) from exc
    if flight is None:
        raise HTTPException(status_code=422, detail="Unknown flight")

    seats_available = flight["seatsAvailable"]
    if payload.seats > seats_available:
        raise HTTPException(
            status_code=409,
            detail=f"Only {seats_available} seat(s) left on this flight",
        )

    # str() first: Decimal(float) would carry the float's binary error along.
    unit_price = Decimal(str(flight["price"]))
    total_price = (unit_price * payload.seats).quantize(CENTS, rounding=ROUND_HALF_UP)

    for _ in range(REFERENCE_ATTEMPTS):
        booking = Booking(
            reference=generate_reference(),
            flight_id=payload.flight_id,
            passenger_name=payload.passenger_name,
            email=payload.email,
            seats=payload.seats,
            total_price=total_price,
            currency=str(flight.get("currency") or "USD"),
            status="CONFIRMED",
            created_at=utcnow(),
        )
        session.add(booking)
        try:
            session.commit()
        except IntegrityError:
            # Reference collision on the unique index (1 in ~10^9 per pair):
            # roll back and try a fresh one.
            session.rollback()
            continue
        break
    else:
        raise HTTPException(status_code=500, detail="Could not allocate a booking reference")

    BOOKINGS_CREATED.inc()
    logger.info(
        "booking created",
        extra={
            "reference": booking.reference,
            "flight_id": booking.flight_id,
            "seats": booking.seats,
        },
    )
    return _to_out(booking, flight)


def list_bookings(
    session: SessionDep,
    email: Annotated[str, Query(min_length=3, max_length=254)],
) -> list[BookingOut]:
    statement = (
        select(Booking)
        .where(Booking.email == email.strip().lower())
        .order_by(Booking.created_at.desc(), Booking.id.desc())
        .limit(LIST_LIMIT)
    )
    return [BookingOut.model_validate(booking) for booking in session.scalars(statement)]


def get_booking(
    reference: str,
    request: Request,
    session: SessionDep,
    flights: FlightClientDep,
) -> BookingOut:
    booking = session.scalar(select(Booking).where(Booking.reference == reference.strip().upper()))
    if booking is None:
        raise HTTPException(status_code=404, detail="Booking not found")

    # Enrich with live flight details, but a flight-search outage must not
    # make an existing booking unreadable: degrade to flight=null instead.
    try:
        flight = _fetch_flight(flights, booking.flight_id, request)
    except FlightServiceUnavailable:
        flight = None
    return _to_out(booking, flight)
