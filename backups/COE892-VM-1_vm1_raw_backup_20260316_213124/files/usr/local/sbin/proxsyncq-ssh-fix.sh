#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="krishadmin"
USER_HOME="/home/${TARGET_USER}"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${SSH_DIR}"
touch "${AUTH_KEYS}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chmod go-w "${USER_HOME}" || true
