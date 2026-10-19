"""Runtime configuration, read from environment variables."""

import os
from dataclasses import dataclass
from typing import Self

from fastapi import Request

# A local SQLite file keeps `uvicorn app.main:app` usable without Postgres.
# Containers always set DATABASE_URL.
DEFAULT_DATABASE_URL = "sqlite:///./skybook.db"
DEFAULT_FLIGHT_SEARCH_URL = "http://flight-search:3000"


@dataclass(frozen=True)
class Settings:
    database_url: str = DEFAULT_DATABASE_URL
    flight_search_url: str = DEFAULT_FLIGHT_SEARCH_URL
    app_version: str = "dev"
    log_level: str = "INFO"
    # Upstream calls sit on the booking request path, so fail fast.
    flight_search_timeout: float = 2.0
    # How long startup waits for the database before giving up.
    db_startup_timeout: float = 60.0

    @classmethod
    def from_env(cls) -> Self:
        return cls(
            database_url=os.getenv("DATABASE_URL") or DEFAULT_DATABASE_URL,
            flight_search_url=(
                os.getenv("FLIGHT_SEARCH_URL") or DEFAULT_FLIGHT_SEARCH_URL
            ).rstrip("/"),
            app_version=os.getenv("APP_VERSION") or "dev",
            log_level=(os.getenv("LOG_LEVEL") or "INFO").upper(),
        )


def get_settings(request: Request) -> Settings:
    """FastAPI dependency returning the settings the app was created with."""
    return request.app.state.settings
