"""Shared runtime for Product A's Python services (the Python peer of the .NET common library).

Only the log-field contract lives here: every service, .NET, Python or nginx, writes one JSON
object per line to stdout with the same field names (timestamp, level, message, logger, service),
so one log query works across all of them.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from datetime import datetime, timezone

_LEVELS = {
    "DEBUG": "debug",
    "INFO": "information",
    "WARNING": "warning",
    "ERROR": "error",
    "CRITICAL": "critical",
}

# Attributes every LogRecord has; anything else on a record came from `extra=` and is a field.
_RESERVED = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime", "taskName"}


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str) -> None:
        super().__init__()
        self._service = service

    def format(self, record: logging.LogRecord) -> str:
        doc = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": _LEVELS.get(record.levelname, record.levelname.lower()),
            "message": record.getMessage(),
            "logger": record.name,
            "service": self._service,
        }
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                doc[key] = value
        if record.exc_info:
            doc["exception"] = self.formatException(record.exc_info)
        return json.dumps(doc, default=str, ensure_ascii=False)


def configure_logging(service: str, level: str | None = None) -> None:
    """Route the root logger (and uvicorn's) to one JSON stream on stdout."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel((level or os.environ.get("LOG_LEVEL") or "INFO").upper())
    # uvicorn installs its own plain-text handlers; hand its loggers to the root handler instead.
    # Its access log is off: the app's own request log (without the query string) replaces it.
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers[:] = []
        logging.getLogger(name).propagate = True
    logging.getLogger("uvicorn.access").disabled = True
