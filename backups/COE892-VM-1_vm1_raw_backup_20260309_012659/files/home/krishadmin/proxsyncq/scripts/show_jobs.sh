#!/usr/bin/env bash
set -euo pipefail

cd /home/krishadmin/proxsyncq/infra

docker exec -i proxsyncq-postgres psql -U proxsyncq -d proxsyncq -c "
SELECT
  state,
  job_type,
  claimed_by,
  COUNT(*) AS count
FROM jobs
GROUP BY state, job_type, claimed_by
ORDER BY state, job_type, claimed_by;
"
