#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-krishadmin}"
USER_HOME="/home/${TARGET_USER}"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SSH_CFG="${SSH_DIR}/config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-proxsyncq-auth.conf"
BOOT_FIX_SCRIPT="/usr/local/sbin/proxsyncq-ssh-fix.sh"
BOOT_FIX_SERVICE="/etc/systemd/system/proxsyncq-ssh-fix.service"

AUTHORIZED_KEYS_BLOCK='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID5atibQbhK+tWquRvc1or3leFnUs2eLNLRrXaaGo+Pr krishadmin@COE892-VM-1
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQ1elNR2Ha10XIO6bPBLppmIzdNIVQwLrc2kVQKOhO6 krishadmin@COE892-VM-2
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCF5IDXWPieguh7RezNyDDYKDpienBdZOgPSw9J0P2n krishadmin@COE892-VM-3
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUX5mIUdhibMDDjF7Fj63EUWfgvu/yvhYkBIWjWk5Vc krishadmin@COE892-RPi'

SSH_CONFIG_BLOCK='Host 10.26.0.*
  User krishadmin
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ConnectTimeout 5'

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

as_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
  fi
}

detect_ssh_service_name() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    echo "ssh"
    return
  fi
  if systemctl list-unit-files | grep -q '^sshd\.service'; then
    echo "sshd"
    return
  fi
  echo "ssh"
}

main() {
  as_root
  need_cmd systemctl
  need_cmd sshd
  need_cmd install
  need_cmd getent

  if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
    echo "User does not exist: ${TARGET_USER}" >&2
    exit 1
  fi

  local SSH_SERVICE
  SSH_SERVICE="$(detect_ssh_service_name)"

  log "Preparing ${SSH_DIR}"
  install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${SSH_DIR}"

  if [[ -f "${AUTH_KEYS}" ]]; then
    cp "${AUTH_KEYS}" "${AUTH_KEYS}.bak_$(date +%s)"
  fi

  printf '%s\n' "${AUTHORIZED_KEYS_BLOCK}" > "${AUTH_KEYS}"
  chown "${TARGET_USER}:${TARGET_USER}" "${AUTH_KEYS}"
  chmod 600 "${AUTH_KEYS}"

  if [[ -f "${SSH_CFG}" ]]; then
    cp "${SSH_CFG}" "${SSH_CFG}.bak_$(date +%s)"
  fi

  printf '%s\n' "${SSH_CONFIG_BLOCK}" > "${SSH_CFG}"
  chown "${TARGET_USER}:${TARGET_USER}" "${SSH_CFG}"
  chmod 600 "${SSH_CFG}"

  if [[ ! -f "${SSH_DIR}/id_ed25519" ]]; then
    log "Generating missing local id_ed25519 keypair for ${TARGET_USER}"
    sudo -u "${TARGET_USER}" ssh-keygen -t ed25519 -N "" -f "${SSH_DIR}/id_ed25519"
  else
    log "Existing local id_ed25519 keypair found, leaving it unchanged"
  fi

  chown -R "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"
  chmod 600 "${SSH_DIR}/id_ed25519" 2>/dev/null || true
  chmod 644 "${SSH_DIR}/id_ed25519.pub" 2>/dev/null || true
  chmod go-w "${USER_HOME}" || true

  log "Writing persistent sshd config"
  mkdir -p "$(dirname "${SSHD_DROPIN}")"
  cat > "${SSHD_DROPIN}" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin prohibit-password
EOF

  log "Installing boot-time self-heal script"
  cat > "${BOOT_FIX_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TARGET_USER="${TARGET_USER}"
USER_HOME="/home/\${TARGET_USER}"
SSH_DIR="\${USER_HOME}/.ssh"
AUTH_KEYS="\${SSH_DIR}/authorized_keys"

install -d -m 700 -o "\${TARGET_USER}" -g "\${TARGET_USER}" "\${SSH_DIR}"
touch "\${AUTH_KEYS}"
chown -R "\${TARGET_USER}:\${TARGET_USER}" "\${SSH_DIR}"
chmod 700 "\${SSH_DIR}"
chmod 600 "\${AUTH_KEYS}"
chmod go-w "\${USER_HOME}" || true
EOF
  chmod 755 "${BOOT_FIX_SCRIPT}"

  log "Installing boot-time self-heal service"
  cat > "${BOOT_FIX_SERVICE}" <<EOF
[Unit]
Description=ProxSyncQ SSH permission self-heal
After=local-fs.target
Before=${SSH_SERVICE}.service

[Service]
Type=oneshot
ExecStart=${BOOT_FIX_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

  log "Validating sshd config"
  sshd -t

  log "Enabling services"
  systemctl daemon-reload
  systemctl enable "${SSH_SERVICE}"
  systemctl enable proxsyncq-ssh-fix.service
  systemctl start proxsyncq-ssh-fix.service
  systemctl restart "${SSH_SERVICE}"

  log "Active SSH auth settings"
  sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|authorizedkeysfile|usepam|permitrootlogin' || true

  log "Local public key on this machine"
  sudo -u "${TARGET_USER}" cat "${SSH_DIR}/id_ed25519.pub" || true

  log "Done"
  echo
  echo "Now test from this machine:"
  echo "  ssh 10.26.0.170 hostname"
  echo "  ssh 10.26.0.171 hostname"
  echo "  ssh 10.26.0.172 hostname"
  echo "  ssh 10.26.0.173 hostname"
  echo
  echo "After all 4 machines succeed without password prompts, you can switch to public-key-only safely."
}

main "$@"
