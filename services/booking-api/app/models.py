"""ORM models."""

from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import DateTime, Numeric, String
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


def utcnow() -> datetime:
    return datetime.now(UTC)


class Booking(Base):
    __tablename__ = "bookings"

    id: Mapped[int] = mapped_column(primary_key=True)
    # Customer-facing booking code; the unique index also backs lookups.
    reference: Mapped[str] = mapped_column(String(6), unique=True, index=True)
    flight_id: Mapped[str] = mapped_column(String(64))
    passenger_name: Mapped[str] = mapped_column(String(80))
    email: Mapped[str] = mapped_column(String(254), index=True)
    seats: Mapped[int]
    total_price: Mapped[Decimal] = mapped_column(Numeric(10, 2))
    currency: Mapped[str] = mapped_column(String(3))
    status: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
