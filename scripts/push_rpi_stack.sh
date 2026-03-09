#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"
RPI_USER="${RPI_USER:-krishadmin}"
REMOTE_DIR="${REMOTE_DIR:-/home/${RPI_USER}/proxsyncq-rpi}"

rsync -av rpi-control/ "${RPI_USER}@${RPI_HOST}:${REMOTE_DIR}/"
scp -q scripts/repair_bad_docker_repo.sh "${RPI_USER}@${RPI_HOST}:/tmp/repair_bad_docker_repo.sh"
ssh "${RPI_USER}@${RPI_HOST}" "cd ${REMOTE_DIR} && bash bootstrap_rpi_stack.sh"
