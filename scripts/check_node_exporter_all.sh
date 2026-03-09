#!/usr/bin/env bash
set -euo pipefail

HOSTS=(
  10.26.0.170
  10.26.0.171
  10.26.0.172
  10.26.0.173
)

for host in "${HOSTS[@]}"; do
  echo "== ${host} =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | head -n 5 || true
  echo
done
