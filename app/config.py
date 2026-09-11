"""Configuration, read once from the environment at startup.

Every deployment target sets the same variables by a different route: Docker
Compose from an env file locally, a ConfigMap and Kubernetes Secrets in QA and
production. The application does not know or care which - it reads environment
variables and nothing else.

Configuration is validated up front rather than where it is used. A missing
bucket name should stop the process immediately with a message naming every
variable that is absent, not surface twenty minutes later when the first file
arrives.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


class ConfigError(Exception):
    """Configuration is missing or unusable. Raised before any work starts."""


@dataclass(frozen=True)
class S3Buckets:
    """The five buckets one environment's pipeline moves files between."""

    input: str
    successful: str
    failed: str
    reports_json: str
    reports_log: str


@dataclass(frozen=True)
class MongoSettings:
    uri: str
    database: str
    collection: str
    timeout_ms: int


@dataclass(frozen=True)
class MySQLSettings:
    enabled: bool
    host: str
    port: int
    user: str
    password: str
    database: str
    connect_timeout_seconds: int


@dataclass(frozen=True)
class NotifierSettings:
    """SES. Disabled in local development, where a log line is enough."""

    enabled: bool
    sender: str
    recipients: tuple[str, ...]


@dataclass(frozen=True)
class Config:
    environment: str
    aws_region: str
    poll_interval_seconds: int
    work_dir: str
    log_dir: str
    log_file: str
    log_level: str
    metrics_enabled: bool
    metrics_port: int
    promotion_token_ttl_hours: int
    buckets: S3Buckets
    mongo: MongoSettings
    mysql: MySQLSettings
    notifier: NotifierSettings
    s3_endpoint_url: str | None = None
    missing: tuple[str, ...] = field(default=(), repr=False)


VALID_ENVIRONMENTS = ("dev", "qa", "prod")


def load_config() -> Config:
    """Build the configuration from environment variables.

    Raises:
        ConfigError: if anything required is absent or malformed. The message
            names every problem found, not just the first, so a misconfigured
            deployment can be fixed in one pass rather than one restart at a
            time.
    """
    problems: list[str] = []

    environment = os.getenv("APP_ENV", "dev").strip().lower()
    if environment not in VALID_ENVIRONMENTS:
        problems.append(
            f"APP_ENV must be one of {', '.join(VALID_ENVIRONMENTS)} (got {environment!r})"
        )

    def required(name: str) -> str:
        value = os.getenv(name, "").strip()
        if not value:
            problems.append(f"{name} is required")
        return value

    def integer(name: str, default: int, minimum: int = 1) -> int:
        raw = os.getenv(name, "").strip()
        if not raw:
            return default
        try:
            value = int(raw)
        except ValueError:
            problems.append(f"{name} must be a whole number (got {raw!r})")
            return default
        if value < minimum:
            problems.append(f"{name} must be at least {minimum} (got {value})")
            return default
        return value

    def boolean(name: str, default: bool) -> bool:
        raw = os.getenv(name, "").strip().lower()
        if not raw:
            return default
        if raw in ("1", "true", "yes", "on"):
            return True
        if raw in ("0", "false", "no", "off"):
            return False
        problems.append(f"{name} must be true or false (got {raw!r})")
        return default

    buckets = S3Buckets(
        input=required("S3_INPUT_BUCKET"),
        successful=required("S3_SUCCESSFUL_BUCKET"),
        failed=required("S3_FAILED_BUCKET"),
        reports_json=required("S3_REPORTS_JSON_BUCKET"),
        reports_log=required("S3_REPORTS_LOG_BUCKET"),
    )

    mongo = MongoSettings(
        uri=required("MONGO_URI"),
        database=os.getenv("MONGO_DATABASE", "mongo_dcu").strip(),
        collection=os.getenv("MONGO_COLLECTION", "properties").strip(),
        timeout_ms=integer("MONGO_TIMEOUT_MS", 5000, minimum=100),
    )

    mysql_enabled = boolean("MYSQL_ENABLED", True)
    mysql = MySQLSettings(
        enabled=mysql_enabled,
        host=required("MYSQL_HOST") if mysql_enabled else "",
        port=integer("MYSQL_PORT", 3306),
        user=required("MYSQL_USER") if mysql_enabled else "",
        password=os.getenv("MYSQL_PASSWORD", ""),
        database=os.getenv("MYSQL_DATABASE", "mongo_dcu").strip(),
        connect_timeout_seconds=integer("MYSQL_CONNECT_TIMEOUT_SECONDS", 10),
    )

    notifier_enabled = boolean("SES_ENABLED", False)
    recipients = tuple(
        address.strip()
        for address in os.getenv("SES_RECIPIENTS", "").split(",")
        if address.strip()
    )
    if notifier_enabled and not recipients:
        problems.append("SES_RECIPIENTS is required when SES_ENABLED is true")

    notifier = NotifierSettings(
        enabled=notifier_enabled,
        sender=required("SES_SENDER") if notifier_enabled else "",
        recipients=recipients,
    )

    config = Config(
        environment=environment,
        aws_region=os.getenv("AWS_REGION", "us-east-1").strip(),
        poll_interval_seconds=integer("POLL_INTERVAL_SECONDS", 20),
        work_dir=os.getenv("WORK_DIR", "/tmp/mongo-dcu").strip(),
        log_dir=os.getenv("LOG_DIR", "/var/log/mongo-dcu").strip(),
        log_file=os.getenv("LOG_FILE", "app.log").strip(),
        log_level=os.getenv("LOG_LEVEL", "INFO").strip().upper(),
        metrics_enabled=boolean("METRICS_ENABLED", True),
        metrics_port=integer("METRICS_PORT", 9090),
        promotion_token_ttl_hours=integer("PROMOTION_TOKEN_TTL_HOURS", 24),
        buckets=buckets,
        mongo=mongo,
        mysql=mysql,
        notifier=notifier,
        # Set only when pointing at a local S3 stand-in. Empty everywhere in
        # this project, which uses real S3 even in local development.
        s3_endpoint_url=os.getenv("S3_ENDPOINT_URL", "").strip() or None,
    )

    if problems:
        raise ConfigError(
            "configuration is invalid:\n  - " + "\n  - ".join(problems)
        )

    return config
