"""Database engine, per-request sessions and schema bootstrap."""

import asyncio
import logging
import time
from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.models import Base

logger = logging.getLogger(__name__)

_POSTGRES_SCHEMES = ("postgres://", "postgresql://")


def normalize_database_url(url: str) -> str:
    """Point plain Postgres URLs at the psycopg 3 driver.

    Platforms such as CloudNativePG hand out ``postgresql://`` (or Heroku-style
    ``postgres://``) URLs, while SQLAlchemy wants the driver named in the scheme.
    """
    for scheme in _POSTGRES_SCHEMES:
        if url.startswith(scheme):
            return "postgresql+psycopg://" + url.removeprefix(scheme)
    return url


def create_db_engine(database_url: str) -> Engine:
    url = normalize_database_url(database_url)
    if url.startswith("sqlite"):
        # FastAPI runs sync endpoints in a thread pool, and SQLite connections
        # refuse to be used outside the thread that created them by default.
        return create_engine(url, connect_args={"check_same_thread": False})
    return create_engine(
        url,
        pool_size=5,
        max_overflow=5,
        # Replace connections that died with a database restart or failover
        # instead of failing the next request that happens to use them.
        pool_pre_ping=True,
        pool_recycle=1800,
        # Fail fast so readiness probes report a dead database promptly.
        connect_args={"connect_timeout": 3, "application_name": "booking-api"},
    )


def check_database(engine: Engine) -> None:
    """Raise SQLAlchemyError if the database cannot answer a trivial query."""
    with engine.connect() as connection:
        connection.execute(text("SELECT 1"))


async def init_db(engine: Engine, timeout: float = 60.0, interval: float = 2.0) -> None:
    """Create missing tables, retrying while the database is still starting up.

    In Kubernetes the API and Postgres start in no particular order, so a
    refused connection at boot is expected and not worth crashing over.
    Concurrent replicas racing on CREATE TABLE are covered by the same retry.
    """
    deadline = time.monotonic() + timeout
    attempt = 0
    while True:
        attempt += 1
        try:
            await asyncio.to_thread(Base.metadata.create_all, engine)
        except SQLAlchemyError as exc:
            if time.monotonic() + interval > deadline:
                logger.error("database unavailable, giving up", extra={"attempts": attempt})
                raise
            logger.warning(
                "database not ready, retrying",
                extra={"attempt": attempt, "error": str(getattr(exc, "orig", None) or exc)},
            )
            await asyncio.sleep(interval)
        else:
            logger.info("database schema ready", extra={"attempts": attempt})
            return


def get_session(request: Request) -> Iterator[Session]:
    """FastAPI dependency: one session per request, closed when the request ends."""
    with request.app.state.session_factory() as session:
        yield session
