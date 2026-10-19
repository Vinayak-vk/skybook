"""Application factory and ASGI entry point (``uvicorn app.main:app``)."""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from app import routes
from app.config import Settings
from app.db import create_db_engine, init_db
from app.flights import FlightSearchClient
from app.logging_config import configure_logging
from app.metrics import ObservabilityMiddleware

logger = logging.getLogger(__name__)


async def _database_error(request: Request, exc: Exception) -> JSONResponse:
    logger.error("database error", exc_info=exc, extra={"path": request.url.path})
    return JSONResponse(
        {"detail": "Database unavailable, please try again shortly"}, status_code=503
    )


async def _unhandled_error(request: Request, exc: Exception) -> JSONResponse:
    # Uvicorn logs the traceback itself; this only shapes the response body.
    return JSONResponse({"detail": "Internal server error"}, status_code=500)


def _register_routes(app: FastAPI) -> None:
    # Registration order is match order. The literal /api/bookings/version must
    # come before /api/bookings/{reference}, or "version" would be looked up
    # as a booking reference.
    app.add_api_route("/healthz", routes.healthz, methods=["GET"], include_in_schema=False)
    app.add_api_route("/readyz", routes.readyz, methods=["GET"], include_in_schema=False)
    app.add_api_route("/metrics", routes.metrics, methods=["GET"], include_in_schema=False)
    app.add_api_route("/api/bookings/version", routes.get_version, methods=["GET"])
    app.add_api_route("/api/bookings", routes.create_booking, methods=["POST"], status_code=201)
    app.add_api_route("/api/bookings", routes.list_bookings, methods=["GET"])
    app.add_api_route("/api/bookings/{reference}", routes.get_booking, methods=["GET"])


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level, settings.app_version)

    engine = create_db_engine(settings.database_url)
    flight_client = FlightSearchClient(
        settings.flight_search_url, timeout=settings.flight_search_timeout
    )

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        # Startup blocks until the schema exists (or the timeout is hit and the
        # process exits), so the pod only starts serving with a usable database.
        await init_db(engine, timeout=settings.db_startup_timeout)
        logger.info("booking-api ready")
        yield
        flight_client.close()
        engine.dispose()

    app = FastAPI(
        title="SkyBook Booking API",
        version=settings.app_version,
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.engine = engine
    # expire_on_commit=False: handlers return the ORM object right after
    # commit, and reloading every attribute would cost an extra SELECT.
    app.state.session_factory = sessionmaker(bind=engine, expire_on_commit=False)
    app.state.flight_client = flight_client

    app.add_middleware(ObservabilityMiddleware)
    app.add_exception_handler(SQLAlchemyError, _database_error)
    app.add_exception_handler(Exception, _unhandled_error)
    _register_routes(app)
    return app


app = create_app()
