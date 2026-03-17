#!/usr/bin/env bash
set -euo pipefail

API_URL="${1:-http://10.26.0.171:8000/jobs}"
COUNT="${2:-20}"

for i in $(seq 1 "$COUNT"); do
  curl -s -X POST "$API_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"job_type\":\"demo_write\",\"payload\":{\"message\":\"batch-$i\"}}"
  echo
  sleep 0.2
done
