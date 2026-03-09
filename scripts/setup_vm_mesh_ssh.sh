#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
TARGET_USER="${TARGET_USER:-krishadmin}"
HOSTS_FILE="${HOSTS_FILE:-conf/hosts.txt}"
KEY_NAME="${KEY_NAME:-id_ed25519}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/setup_vm_mesh_ssh.sh generate-local-key
  bash scripts/setup_vm_mesh_ssh.sh show-local-pubkey
  bash scripts/setup_vm_mesh_ssh.sh install-authorized-keys --keys-file /path/to/all_vm_keys.txt
  bash scripts/setup_vm_mesh_ssh.sh verify-mesh --hosts-file conf/hosts.txt
EOF
  exit 1
}

generate_local_key() {
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  if [[ ! -f ~/.ssh/${KEY_NAME} ]]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/${KEY_NAME}
  fi
  echo "Local key ready: ~/.ssh/${KEY_NAME}"
}

show_local_pubkey() {
  if [[ ! -f ~/.ssh/${KEY_NAME}.pub ]]; then
    echo "Missing ~/.ssh/${KEY_NAME}.pub" >&2
    exit 1
  fi
  cat ~/.ssh/${KEY_NAME}.pub
}

install_authorized_keys() {
  local keys_file=""

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keys-file)
        keys_file="${2:-}"
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  if [[ -z "${keys_file}" || ! -f "${keys_file}" ]]; then
    echo "Missing keys file" >&2
    exit 1
  fi

  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak_$(date +%s) 2>/dev/null || true
  cp "${keys_file}" ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  chown -R "${TARGET_USER}:${TARGET_USER}" ~/.ssh
  chmod go-w ~ || true

  echo "Installed authorized_keys from ${keys_file}"
}

verify_mesh() {
  if [[ ! -f "${HOSTS_FILE}" ]]; then
    echo "Missing hosts file: ${HOSTS_FILE}" >&2
    exit 1
  fi

  mapfile -t HOSTS < <(grep -vE '^\s*#' "${HOSTS_FILE}" | sed '/^\s*$/d')
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    echo "No hosts found in ${HOSTS_FILE}" >&2
    exit 1
  fi

  for host in "${HOSTS[@]}"; do
    echo "== ${host} =="
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${TARGET_USER}@${host}" 'hostname && whoami' || true
    echo
  done
}

case "${MODE}" in
  generate-local-key)
    generate_local_key
    ;;
  show-local-pubkey)
    show_local_pubkey
    ;;
  install-authorized-keys)
    install_authorized_keys "$@"
    ;;
  verify-mesh)
    verify_mesh
    ;;
  *)
    usage
    ;;
esac
