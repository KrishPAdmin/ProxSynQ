#!/usr/bin/env bash
set -euo pipefail

SHARED_PATH="/srv/proxsyncq/shared"

mkdir -p "${SHARED_PATH}"

if ! findmnt -rn "${SHARED_PATH}" >/dev/null 2>&1; then
  mount "${SHARED_PATH}" || true
fi

findmnt -rn "${SHARED_PATH}" >/dev/null 2>&1
