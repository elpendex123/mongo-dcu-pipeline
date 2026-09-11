"""Structured logging in the pipe-delimited key=value format Splunk expects.

Every line looks like this::

    2026-09-10T14:20:20.298Z level=INFO env=qa component=executor run_id=8f3a1c2e line=1 msg="execution succeeded" result_count=14 duration_ms=91

Splunk extracts ``key=value`` pairs with no configuration at all, which is why
this format rather than JSON: the same line stays readable to a person tailing
the file, and searchable in Splunk, without a parser in between.

Four fields are on every line - the timestamp, ``level``, ``env`` and
``component`` - plus ``run_id`` once a file is being processed. Correlating
everything a single run did is then one search.

Logging here is deliberately verbose. Splunk is a first-class part of this
project, and it is more useful given a complete narrative of a run than a
curated subset of it.
"""

from __future__ import annotations

import contextvars
import logging
import logging.handlers
import os
import sys
import traceback
from datetime import datetime, timezone
from typing import Any

# Set for the duration of one file's processing, so every line emitted by any
# component while that file is in flight carries its run_id without each call
# site having to pass it along.
_current_run_id: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "current_run_id", default=None
)

_environment = "dev"

# Keys the formatter renders itself, in this order, before any extra fields.
_RESERVED = frozenset({"msg", "level", "env", "component", "run_id", "timestamp"})


def set_run_id(run_id: str | None) -> None:
    """Attach a run_id to every subsequent log line, or clear it with None."""
    _current_run_id.set(run_id)


def current_run_id() -> str | None:
    return _current_run_id.get()


def _format_value(value: Any) -> str:
    """Render one value for a key=value pair.

    Quoted when it contains anything that would otherwise break the pair apart:
    whitespace, a quote, an equals sign, or nothing at all. Newlines are
    escaped rather than emitted, because a log event that spans several lines
    is several events as far as Splunk is concerned.
    """
    if value is None:
        return '""'
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)

    text = str(value)
    needs_quotes = (
        text == ""
        or any(character.isspace() for character in text)
        or '"' in text
        or "=" in text
    )
    if not needs_quotes:
        return text

    escaped = (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


class KeyValueFormatter(logging.Formatter):
    """Renders a record as a timestamp followed by key=value pairs."""

    def format(self, record: logging.LogRecord) -> str:
        timestamp = datetime.fromtimestamp(record.created, tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.%f"
        )[:-3] + "Z"

        parts = [
            timestamp,
            f"level={record.levelname}",
            f"env={_environment}",
            f"component={getattr(record, 'component', record.name)}",
        ]

        run_id = getattr(record, "run_id", None) or current_run_id()
        if run_id:
            parts.append(f"run_id={run_id}")

        parts.append(f"msg={_format_value(record.getMessage())}")

        for key, value in getattr(record, "fields", {}).items():
            if key not in _RESERVED:
                parts.append(f"{key}={_format_value(value)}")

        # An exception becomes one more field on this same line rather than a
        # block of its own. Splunk treats each line as an event, so a traceback
        # spread over twenty lines would arrive as twenty unrelated events with
        # the error message in only the first.
        if record.exc_info:
            formatted = "".join(traceback.format_exception(*record.exc_info))
            parts.append(f"traceback={_format_value(formatted.strip())}")

        return " ".join(parts)


class ComponentLogger:
    """A logger bound to one component, taking fields as keyword arguments.

        log.info("execution succeeded", line=1, result_count=14, duration_ms=91)
    """

    def __init__(self, component: str) -> None:
        self._component = component
        self._logger = logging.getLogger(component)

    def _log(self, level: int, message: str, exc_info: Any = None, **fields: Any) -> None:
        self._logger.log(
            level,
            message,
            exc_info=exc_info,
            extra={"component": self._component, "fields": fields},
        )

    def debug(self, message: str, **fields: Any) -> None:
        self._log(logging.DEBUG, message, **fields)

    def info(self, message: str, **fields: Any) -> None:
        self._log(logging.INFO, message, **fields)

    def warning(self, message: str, **fields: Any) -> None:
        self._log(logging.WARNING, message, **fields)

    def error(self, message: str, exc_info: Any = None, **fields: Any) -> None:
        self._log(logging.ERROR, message, exc_info=exc_info, **fields)

    def exception(self, message: str, **fields: Any) -> None:
        """An ERROR line carrying the current exception's traceback field."""
        self._log(logging.ERROR, message, exc_info=sys.exc_info(), **fields)


def configure_logging(
    environment: str,
    level: str = "INFO",
    log_dir: str | None = None,
    log_file: str = "app.log",
    max_bytes: int = 10 * 1024 * 1024,
    backup_count: int = 5,
) -> None:
    """Set up stdout and rotating-file logging.

    Two destinations, for two different readers. Stdout is what ``kubectl
    logs`` and ``docker compose logs`` show. The file is what Splunk monitors -
    a directory the sidecar also mounts in QA and production, and a bind mount
    locally. Splunk here reads files from a directory rather than receiving
    events over HTTP, so the file is not a convenience, it is the input.

    Rotation is bounded because in QA and production that directory is an
    emptyDir sharing the node's disk with everything else on it.
    """
    global _environment
    _environment = environment

    root = logging.getLogger()
    root.setLevel(getattr(logging, level, logging.INFO))

    for handler in list(root.handlers):
        root.removeHandler(handler)

    formatter = KeyValueFormatter()

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    root.addHandler(stream_handler)

    if log_dir:
        try:
            os.makedirs(log_dir, exist_ok=True)
            file_handler = logging.handlers.RotatingFileHandler(
                os.path.join(log_dir, log_file),
                maxBytes=max_bytes,
                backupCount=backup_count,
                encoding="utf-8",
            )
            file_handler.setFormatter(formatter)
            root.addHandler(file_handler)
        except OSError as error:
            # Losing the Splunk feed is bad; refusing to start because of it
            # would be worse. Say so loudly on stdout and carry on.
            logging.getLogger("logger").error(
                "could not open the log directory",
                extra={
                    "component": "logger",
                    "fields": {"log_dir": log_dir, "error": str(error)},
                },
            )

    # boto3 at INFO narrates every HTTP call it makes, which would bury the
    # pipeline's own narrative in the file Splunk reads.
    for noisy in ("boto3", "botocore", "urllib3", "s3transfer"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def get_logger(component: str) -> ComponentLogger:
    """A logger for one component: main, s3, executor, reporter, db, notifier."""
    return ComponentLogger(component)
