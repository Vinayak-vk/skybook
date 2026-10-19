"""JSON logging to stdout, shared by the app and Uvicorn."""

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

SERVICE_NAME = "booking-api"

# Every attribute a bare LogRecord carries. Anything else on a record was
# passed via `extra=` and becomes a top-level JSON field.
_RECORD_ATTRIBUTES = frozenset(vars(logging.makeLogRecord({}))) | {
    "message",
    "asctime",
    "color_message",  # Uvicorn's ANSI-coloured duplicate of the message
}


class JsonFormatter(logging.Formatter):
    def __init__(self, version: str = "dev") -> None:
        super().__init__()
        self.version = version

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "time": datetime.fromtimestamp(record.created, tz=UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname.lower(),
            "service": SERVICE_NAME,
            "version": self.version,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key, value in vars(record).items():
            if key not in _RECORD_ATTRIBUTES and not key.startswith("_"):
                entry[key] = value
        if record.exc_info:
            entry["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


class _JsonStreamHandler(logging.StreamHandler):
    """Marker type so reconfiguring replaces our handler and nothing else."""


def configure_logging(level: str = "INFO", version: str = "dev") -> None:
    handler = _JsonStreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(version=version))

    root = logging.getLogger()
    for existing in list(root.handlers):
        if isinstance(existing, _JsonStreamHandler):
            root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(level)

    # Uvicorn installs its own plain-text handlers before importing the app.
    # Drop them so its startup/shutdown and error logs go through the JSON
    # handler too. (Access logs are disabled; our middleware logs requests.)
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers.clear()
        uvicorn_logger.propagate = True
