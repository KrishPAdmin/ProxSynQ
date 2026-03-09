#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"

curl -fsS --max-time 5 "http://${RPI_HOST}:8080" > /dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${RPI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${RPI_HOST}:3000/api/health" && echo || true
