"""Tests for the configuration rules that depend on the environment."""

from __future__ import annotations

import pytest

from app.config import ConfigError, load_config

REQUIRED = {
    "S3_INPUT_BUCKET": "input",
    "S3_SUCCESSFUL_BUCKET": "successful",
    "S3_FAILED_BUCKET": "failed",
    "S3_REPORTS_JSON_BUCKET": "reports-json",
    "S3_REPORTS_LOG_BUCKET": "reports-log",
    "MONGO_URI": "mongodb://localhost:27017",
    "MYSQL_HOST": "localhost",
    "MYSQL_USER": "mongo_dcu",
}


@pytest.fixture
def environment(monkeypatch):
    for name, value in REQUIRED.items():
        monkeypatch.setenv(name, value)
    return monkeypatch


def test_prod_refuses_to_start_without_run_history(environment):
    environment.setenv("APP_ENV", "prod")
    environment.setenv("MYSQL_ENABLED", "false")
    with pytest.raises(ConfigError, match="MYSQL_ENABLED must be true in prod"):
        load_config()


@pytest.mark.parametrize("app_env", ["dev", "qa"])
def test_other_environments_may_run_without_run_history(environment, app_env):
    environment.setenv("APP_ENV", app_env)
    environment.setenv("MYSQL_ENABLED", "false")
    assert load_config().mysql.enabled is False


def test_prod_starts_with_run_history(environment):
    environment.setenv("APP_ENV", "prod")
    assert load_config().environment == "prod"
