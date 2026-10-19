"""Request and response models."""

import re
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_serializer, field_validator

# Deliberately simple: one "@", no whitespace, a dot in the domain. Real
# validation happens when the confirmation email bounces, not in a regex.
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def normalize_email(value: str) -> str:
    value = value.strip().lower()
    if not EMAIL_PATTERN.fullmatch(value):
        raise ValueError("invalid email address")
    return value


class BookingCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    # Only characters that can appear in a flight id; the id is put into the
    # upstream URL, so anything path-like is rejected here.
    flight_id: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9-]+$")
    passenger_name: str = Field(min_length=2, max_length=80)
    email: str = Field(max_length=254)
    seats: int = Field(ge=1, le=9)

    @field_validator("email")
    @classmethod
    def check_email(cls, value: str) -> str:
        return normalize_email(value)


class BookingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    reference: str
    flight_id: str
    passenger_name: str
    email: str
    seats: int
    total_price: Decimal
    currency: str
    status: str
    created_at: datetime
    # Snapshot of the flight from flight-search; null if it could not be fetched.
    flight: dict[str, Any] | None = None

    @field_validator("created_at")
    @classmethod
    def assume_utc(cls, value: datetime) -> datetime:
        # SQLite (tests, local runs) drops the offset; values are always UTC.
        return value if value.tzinfo is not None else value.replace(tzinfo=UTC)

    @field_serializer("total_price", when_used="json")
    def total_price_as_number(self, value: Decimal) -> float:
        # Pydantic emits Decimal as a JSON string by default; clients get a
        # number, consistent with the flight's `price`. Exact arithmetic
        # happens server-side and the value is already rounded to cents.
        return float(value)
