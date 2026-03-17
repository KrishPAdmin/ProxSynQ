#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

bash /tmp/repair_bad_docker_repo.sh 2>/dev/null || true
sudo apt-get update -y
sudo apt-get install -y prometheus-node-exporter curl ca-certificates
sudo systemctl enable --now prometheus-node-exporter
sleep 1
sudo systemctl status prometheus-node-exporter --no-pager || true
curl -fsS http://127.0.0.1:9100/metrics | head -n 5 || true
