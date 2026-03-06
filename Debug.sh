#!/usr/bin/env bash
set -euo pipefail

MODE=""
TARGET_USER="krishadmin"
TARGET_PASSWORD=""
PUBLIC_KEY_FILE=""
SSH_KEY_FILE=""
HOSTS_FILE="conf/hosts.txt"
SSH_PORT="22"
SSH_TIMEOUT="5"

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/ssh_recovery_bundle.sh recover-local --user krishadmin [--password 'NewPassword']
  ./scripts/ssh_recovery_bundle.sh install-key --user krishadmin --public-key-file ~/.ssh/id_ed25519.pub --hosts-file conf/hosts.txt
  ./scripts/ssh_recovery_bundle.sh verify --user krishadmin --ssh-key-file ~/.ssh/id_ed25519 --hosts-file conf/hosts.txt
  ./scripts/ssh_recovery_bundle.sh show-effective-config

Modes:
  recover-local
    Run this on a VM through the Proxmox console to restore SSH password login and prepare ~/.ssh permissions.

  install-key
    Run this from a machine that can already SSH using password auth to install the given public key on all hosts.

  verify
    Run this from a management machine or Pi to test key-based SSH to all hosts.

  show-effective-config
    Show the active sshd authentication settings on the current machine.

Examples:
  sudo ./scripts/ssh_recovery_bundle.sh recover-local --user krishadmin --password 'KrishAdmin@2003'
  ./scripts/ssh_recovery_bundle.sh install-key --user krishadmin --public-key-file ~/.ssh/id_ed25519.pub --hosts-file conf/hosts.txt
  ./scripts/ssh_recovery_bundle.sh verify --user krishadmin --ssh-key-file ~/.ssh/id_ed25519 --hosts-file conf/hosts.txt
EOF
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

as_root_if_needed() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this mode as root or with sudo." >&2
    exit 1
  fi
}

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
  fi

  MODE="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        TARGET_USER="${2:-}"
        shift 2
        ;;
      --password)
        TARGET_PASSWORD="${2:-}"
        shift 2
        ;;
      --public-key-file)
        PUBLIC_KEY_FILE="${2:-}"
        shift 2
        ;;
      --ssh-key-file)
        SSH_KEY_FILE="${2:-}"
        shift 2
        ;;
      --hosts-file)
        HOSTS_FILE="${2:-}"
        shift 2
        ;;
      --port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      --timeout)
        SSH_TIMEOUT="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Unknown arg: $1" >&2
        usage
        ;;
    esac
  done
}

recover_local() {
  as_root_if_needed
  need_cmd sshd
  need_cmd systemctl
  need_cmd passwd
  need_cmd getent

  log "Recovering SSH on local machine for user ${TARGET_USER}"

  if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
    echo "User does not exist: ${TARGET_USER}" >&2
    exit 1
  fi

  install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "/home/${TARGET_USER}/.ssh"
  touch "/home/${TARGET_USER}/.ssh/authorized_keys"
  chown "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${TARGET_USER}/.ssh/authorized_keys"

  cat > /etc/ssh/sshd_config.d/99-krishadmin-recovery.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin prohibit-password
EOF

  sshd -t

  systemctl restart ssh 2>/dev/null || true
  systemctl restart sshd 2>/dev/null || true

  sleep 0.4

  if systemctl is-active --quiet ssh 2>/dev/null; then
    log "ssh service is active"
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    log "sshd service is active"
  else
    echo "SSH service did not come up cleanly" >&2
    exit 1
  fi

  if [[ -n "${TARGET_PASSWORD}" ]]; then
    echo "${TARGET_USER}:${TARGET_PASSWORD}" | chpasswd
    log "Password updated for ${TARGET_USER}"
  else
    log "No password passed in. Run: passwd ${TARGET_USER}"
  fi

  log "Effective SSH authentication settings:"
  sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|authorizedkeysfile|usepam' || true

  log "Recovery complete"
}

install_key() {
  need_cmd ssh
  need_cmd ssh-copy-id
  need_cmd grep

  if [[ ! -f "${PUBLIC_KEY_FILE}" ]]; then
    echo "Missing public key file: ${PUBLIC_KEY_FILE}" >&2
    exit 1
  fi

  if [[ ! -f "${HOSTS_FILE}" ]]; then
    echo "Missing hosts file: ${HOSTS_FILE}" >&2
    exit 1
  fi

  mapfile -t HOSTS < <(grep -vE '^\s*#' "${HOSTS_FILE}" | sed '/^\s*$/d')
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    echo "No hosts found in ${HOSTS_FILE}" >&2
    exit 1
  fi

  log "Installing public key from ${PUBLIC_KEY_FILE}"

  for host in "${HOSTS[@]}"; do
    log "Installing key on ${host}"
    ssh-copy-id -i "${PUBLIC_KEY_FILE}" -p "${SSH_PORT}" -o ConnectTimeout="${SSH_TIMEOUT}" "${TARGET_USER}@${host}"
    sleep 0.4
  done

  log "Key install complete"
}

verify_key_access() {
  need_cmd ssh
  need_cmd grep

  if [[ ! -f "${SSH_KEY_FILE}" ]]; then
    echo "Missing SSH private key file: ${SSH_KEY_FILE}" >&2
    exit 1
  fi

  if [[ ! -f "${HOSTS_FILE}" ]]; then
    echo "Missing hosts file: ${HOSTS_FILE}" >&2
    exit 1
  fi

  mapfile -t HOSTS < <(grep -vE '^\s*#' "${HOSTS_FILE}" | sed '/^\s*$/d')
  if [[ "${#HOSTS[@]}" -eq 0 ]]; then
    echo "No hosts found in ${HOSTS_FILE}" >&2
    exit 1
  fi

  fail=0

  for host in "${HOSTS[@]}"; do
    echo "== ${host} =="
    if ssh -i "${SSH_KEY_FILE}" \
      -p "${SSH_PORT}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout="${SSH_TIMEOUT}" \
      "${TARGET_USER}@${host}" 'hostname && whoami' 2>/dev/null; then
      echo "result: ok"
    else
      echo "result: fail"
      fail=1
    fi
    echo
    sleep 0.3
  done

  if [[ "${fail}" -eq 0 ]]; then
    log "All SSH key checks passed"
  else
    echo "One or more SSH key checks failed" >&2
    exit 2
  fi
}

show_effective_config() {
  need_cmd sshd
  sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|authorizedkeysfile|usepam|permitrootlogin'
}

main() {
  parse_args "$@"

  case "${MODE}" in
    recover-local)
      recover_local
      ;;
    install-key)
      install_key
      ;;
    verify)
      verify_key_access
      ;;
    show-effective-config)
      show_effective_config
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
