-- Run at every startup by app/run.R. IF NOT EXISTS makes it idempotent, and
-- safe when several replicas start at the same time (busy_timeout makes each
-- one wait for the write lock instead of failing).
--
-- Keep this file to a single statement with nothing after its semicolon:
-- DBI runs one statement per call and warns about anything left over.
CREATE TABLE IF NOT EXISTS submissions (
    id                   INTEGER PRIMARY KEY,
    created_at           TEXT    NOT NULL,  -- UTC, ISO 8601, for example 2026-10-19T15:09:12Z
    name                 TEXT,              -- NULL means anonymous
    language             TEXT    NOT NULL,
    container_experience INTEGER NOT NULL CHECK (container_experience BETWEEN 1 AND 5),
    environments         TEXT    NOT NULL,  -- JSON array, for example ["Laptop","AWS"]
    comments             TEXT
);
