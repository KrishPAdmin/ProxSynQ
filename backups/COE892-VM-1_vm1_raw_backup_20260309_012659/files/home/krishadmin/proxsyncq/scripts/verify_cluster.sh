#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SHARED_PATH="${SHARED_PATH:-/srv/proxsyncq/shared}"
HOSTS_FILE="${HOSTS_FILE:-${REPO_DIR}/conf/hosts.txt}"
SSH_USER="${SSH_USER:-krishadmin}"

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=3
)

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "missing hosts file: $HOSTS_FILE" >&2
  exit 1
fi

mapfile -t HOSTS < <(grep -vE '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d')
if [[ "${#HOSTS[@]}" -eq 0 ]]; then
  echo "no hosts found in $HOSTS_FILE" >&2
  exit 1
fi

echo "shared_path=$SHARED_PATH"
echo "hosts=${HOSTS[*]}"
echo

fail=0

for h in "${HOSTS[@]}"; do
  echo "== $h =="

  if ping -c 1 -W 1 "$h" >/dev/null 2>&1; then
    echo "ping: ok"
  else
    echo "ping: fail"
    fail=1
  fi

  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" "findmnt -rn '${SHARED_PATH}' >/dev/null"; then
    echo "mount: ok"
  else
    echo "mount: fail"
    fail=1
  fi

  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" "node=\$(hostname -s); ts=\$(date -Is); echo \"\$ts \$node\" > '${SHARED_PATH}/proof_'\${node}'.txt'"; then
    echo "write: ok"
  else
    echo "write: fail"
    fail=1
  fi

  count_remote="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" "ls -1 '${SHARED_PATH}'/proof_*.txt 2>/dev/null | wc -l | tr -d ' '" || echo 0)"
  echo "remote_proof_files: ${count_remote}"
  echo
done

echo "== shared view check from local =="

if findmnt -rn "$SHARED_PATH" >/dev/null 2>&1; then
  echo "local_mount: ok"
else
  echo "local_mount: fail"
  fail=1
fi

count_local="$(ls -1 "$SHARED_PATH"/proof_*.txt 2>/dev/null | wc -l | tr -d ' ')"
echo "local_proof_files: $count_local"
ls -1 "$SHARED_PATH"/proof_*.txt 2>/dev/null || true

echo
if [[ "$fail" -eq 0 ]]; then
  echo "RESULT: OK"
else
  echo "RESULT: FAIL"
  exit 2
fi
