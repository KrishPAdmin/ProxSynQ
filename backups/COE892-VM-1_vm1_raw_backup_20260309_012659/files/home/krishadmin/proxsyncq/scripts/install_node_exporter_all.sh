#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-krishadmin}"
HOSTS=(
  10.26.0.170
  10.26.0.171
  10.26.0.172
  10.26.0.173
)

for host in "${HOSTS[@]}"; do
  echo "== ${host} =="
  scp -q scripts/repair_bad_docker_repo.sh "${TARGET_USER}@${host}:/tmp/repair_bad_docker_repo.sh"
  scp -q scripts/install_node_exporter.sh "${TARGET_USER}@${host}:/tmp/install_node_exporter.sh"
  ssh -q "${TARGET_USER}@${host}" 'bash /tmp/install_node_exporter.sh'
  echo
done
