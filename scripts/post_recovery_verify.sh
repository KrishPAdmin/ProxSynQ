#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${USER_NAME:-krishadmin}"
HOSTS_FILE="${HOSTS_FILE:-$HOME/proxsyncq/conf/hosts.txt}"
SHARED_PATH="${SHARED_PATH:-/srv/proxsyncq/shared}"
PI_HOST="${PI_HOST:-10.26.0.170}"
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=4
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

check_local_vm1_stack() {
  echo "== VM1 control services =="
  if [[ -d "$HOME/proxsyncq/infra" ]]; then
    (
      cd "$HOME/proxsyncq/infra"
      docker compose ps || true
    )
  else
    echo "infra directory not found"
  fi
  echo
}

check_pi_stack() {
  echo "== Pi control plane =="
  curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
  curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" >/dev/null && echo "prometheus: ok" || echo "prometheus: fail"
  curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" >/dev/null && echo "grafana: ok" || echo "grafana: fail"
  curl -fsS --max-time 5 "http://${PI_HOST}:9100/metrics" >/dev/null && echo "pi_node_exporter: ok" || echo "pi_node_exporter: fail"
  echo
}

check_remote_node() {
  local host="$1"

  echo "== ${host} =="

  if ping -c 1 -W 1 "$host" >/dev/null 2>&1; then
    echo "ping: ok"
  else
    echo "ping: fail"
    return 1
  fi

  if ssh "${SSH_OPTS[@]}" "${USER_NAME}@${host}" 'hostname && whoami' >/tmp/proxsyncq_verify_${host}.txt 2>/dev/null; then
    echo "ssh: ok"
    cat /tmp/proxsyncq_verify_${host}.txt
  else
    echo "ssh: fail"
    return 1
  fi

  if ssh "${SSH_OPTS[@]}" "${USER_NAME}@${host}" "findmnt -rn '${SHARED_PATH}' >/dev/null"; then
    echo "shared_mount: ok"
  else
    echo "shared_mount: fail"
  fi

  if ssh "${SSH_OPTS[@]}" "${USER_NAME}@${host}" "test -d '${SHARED_PATH}'"; then
    echo "shared_path_exists: ok"
  else
    echo "shared_path_exists: fail"
  fi

  if ssh "${SSH_OPTS[@]}" "${USER_NAME}@${host}" "echo '${host} $(date -Iseconds)' > '${SHARED_PATH}/proof_${host//./_}.txt'"; then
    echo "shared_write: ok"
  else
    echo "shared_write: fail"
  fi

  if curl -fsS --max-time 5 "http://${host}:8000/health" >/tmp/proxsyncq_health_${host}.json 2>/dev/null; then
    echo "node_agent: ok"
    cat /tmp/proxsyncq_health_${host}.json
    echo
  else
    echo "node_agent: fail"
  fi

  if curl -fsS --max-time 5 "http://${host}:9100/metrics" >/dev/null 2>&1; then
    echo "node_exporter: ok"
  else
    echo "node_exporter: fail"
  fi

  if ssh "${SSH_OPTS[@]}" "${USER_NAME}@${host}" "systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1"; then
    echo "ssh_service: ok"
  else
    echo "ssh_service: fail"
  fi

  echo
}

show_shared_results() {
  echo "== Shared results =="
  if [[ -d "${SHARED_PATH}/results" ]]; then
    ls -l "${SHARED_PATH}/results" | tail -n 20 || true
  else
    echo "results directory missing"
  fi
  echo
}

show_recent_jobs() {
  echo "== Recent jobs in Postgres =="
  if [[ -d "$HOME/proxsyncq/infra" ]]; then
    (
      cd "$HOME/proxsyncq/infra"
      docker exec -i proxsyncq-postgres psql -U proxsyncq -d proxsyncq -c "
SELECT
  job_id,
  job_type,
  state,
  claimed_by,
  attempt_count,
  submitted_by,
  submitted_at
FROM jobs
ORDER BY submitted_at DESC
LIMIT 15;
" || true
    )
  else
    echo "infra directory not found"
  fi
  echo
}

main() {
  need_cmd ssh
  need_cmd curl
  need_cmd ping

  if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "Missing hosts file: $HOSTS_FILE" >&2
    exit 1
  fi

  mapfile -t HOSTS < <(grep -vE '^\s*#' "$HOSTS_FILE" | sed '/^\s*$/d')
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    echo "No hosts found in $HOSTS_FILE" >&2
    exit 1
  fi

  echo "Starting post-recovery verification"
  echo

  check_local_vm1_stack
  sleep 0.3

  check_pi_stack
  sleep 0.3

  for host in "${HOSTS[@]}"; do
    check_remote_node "$host"
    sleep 0.4
  done

  show_shared_results
  sleep 0.3

  show_recent_jobs

  echo "Verification complete"
}

main "$@"
