-- Run history for the mongo-dcu-pipeline application.
--
-- One MySQL instance is shared by qa and prod rather than one per environment.
-- This is pipeline metadata, not business data, and sharing it means a single
-- query can compare a production run against the QA run it was promoted from.
-- Every table therefore carries an environment column.
--
-- Applied to the local MySQL container automatically by Docker Compose, and to
-- RDS by the Ansible schema bootstrap play.

CREATE DATABASE IF NOT EXISTS mongo_dcu
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE mongo_dcu;

-- One row per file processed.
CREATE TABLE IF NOT EXISTS runs (
    run_id                CHAR(36)     NOT NULL,
    environment           VARCHAR(10)  NOT NULL,
    file_name             VARCHAR(512) NOT NULL,

    -- SHA-256 of the file's bytes, computed from what the application actually
    -- read. The promotion gate compares this against the file submitted for
    -- production, which is what makes "byte-identical to what QA validated" a
    -- verifiable claim.
    file_hash             CHAR(64)     NOT NULL,

    total_lines           INT          NOT NULL DEFAULT 0,
    success_count         INT          NOT NULL DEFAULT 0,
    syntax_fail_count     INT          NOT NULL DEFAULT 0,
    execution_fail_count  INT          NOT NULL DEFAULT 0,
    skipped_lines         INT          NOT NULL DEFAULT 0,

    -- running while the file is in flight, then success or failed.
    status                VARCHAR(16)  NOT NULL,

    -- Promotion gate. Issued only on a fully successful qa run, usable once,
    -- and only before it expires.
    promotion_token       CHAR(64)     NULL,
    token_expires_at      DATETIME     NULL,
    token_used            BOOLEAN      NOT NULL DEFAULT FALSE,

    -- On a production run, the qa run whose token authorised it.
    promoted_from_run_id  CHAR(36)     NULL,

    started_at            DATETIME(3)  NOT NULL,
    completed_at          DATETIME(3)  NULL,
    duration_ms           INT          NULL,

    PRIMARY KEY (run_id),

    -- The promotion gate looks a run up by hash and by token, and both lookups
    -- happen while a person waits on a Jenkins job.
    KEY idx_runs_file_hash (file_hash),
    UNIQUE KEY uq_runs_promotion_token (promotion_token),
    KEY idx_runs_environment_started (environment, started_at),
    KEY idx_runs_status (status),

    CONSTRAINT fk_runs_promoted_from
        FOREIGN KEY (promoted_from_run_id) REFERENCES runs (run_id)
        ON DELETE SET NULL
) ENGINE = InnoDB;

-- One row per query line, so a failure can be traced to the exact line without
-- fetching the report object.
CREATE TABLE IF NOT EXISTS run_lines (
    line_id        CHAR(36)     NOT NULL,
    run_id         CHAR(36)     NOT NULL,
    environment    VARCHAR(10)  NOT NULL,
    line_number    INT          NOT NULL,
    raw_query      TEXT         NOT NULL,

    -- success, fail_syntax, fail_execution, or not_run for a valid line in a
    -- file that failed validation before anything was executed.
    status         VARCHAR(20)  NOT NULL,

    error_message  TEXT         NULL,

    -- Which of the five checks rejected the line, and where. Not in the
    -- original design, added because "how often does a missing brace get as
    -- far as QA" is a question worth being able to answer in SQL.
    error_stage    VARCHAR(16)  NULL,
    error_column   INT          NULL,

    duration_ms    INT          NOT NULL DEFAULT 0,

    PRIMARY KEY (line_id),
    KEY idx_run_lines_run (run_id),
    KEY idx_run_lines_status (status),
    UNIQUE KEY uq_run_lines_run_line (run_id, line_number),

    CONSTRAINT fk_run_lines_run
        FOREIGN KEY (run_id) REFERENCES runs (run_id)
        ON DELETE CASCADE
) ENGINE = InnoDB;

-- What was emailed about a run, so a missing notification can be told apart
-- from one that was sent and not noticed.
CREATE TABLE IF NOT EXISTS email_notifications (
    notification_id  CHAR(36)     NOT NULL,
    run_id           CHAR(36)     NOT NULL,
    environment      VARCHAR(10)  NOT NULL,

    -- start, success or failure.
    type             VARCHAR(16)  NOT NULL,

    recipients       VARCHAR(512) NULL,
    sent_at          DATETIME(3)  NOT NULL,

    PRIMARY KEY (notification_id),
    KEY idx_email_notifications_run (run_id),

    CONSTRAINT fk_email_notifications_run
        FOREIGN KEY (run_id) REFERENCES runs (run_id)
        ON DELETE CASCADE
) ENGINE = InnoDB;
