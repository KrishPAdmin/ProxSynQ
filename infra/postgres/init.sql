CREATE TABLE IF NOT EXISTS jobs (
  job_id UUID PRIMARY KEY,
  job_type TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  submitted_by TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued',
  claimed_by TEXT,
  claimed_at TIMESTAMPTZ,
  lease_expires_at TIMESTAMPTZ,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_idempotency_key
ON jobs (idempotency_key);

CREATE TABLE IF NOT EXISTS job_results (
  job_id UUID PRIMARY KEY REFERENCES jobs(job_id) ON DELETE CASCADE,
  finished_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  result JSONB NOT NULL DEFAULT '{}'::jsonb
);
