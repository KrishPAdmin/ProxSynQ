#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-krishadmin}"
USER_HOME="/home/${TARGET_USER}"
REPO_DIR="${USER_HOME}/proxsyncq"
PI_STACK_DIR="${USER_HOME}/proxsyncq-rpi"
INFRA_DIR="${REPO_DIR}/infra"
NODE_AGENT_ENV="${REPO_DIR}/services/node_agent/.env"
NODE_AGENT_APP="services.node_agent.app:app"
SHARED_PATH="/srv/proxsyncq/shared"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

detect_role() {
  local host
  host="$(hostname)"
  case "$host" in
    COE892-RPi|coe892-rpi)
      echo "rpi"
      ;;
    COE892-VM-1|coe892-vm1)
      echo "vm1"
      ;;
    COE892-VM-2|coe892-vm2)
      echo "vm2"
      ;;
    COE892-VM-3|coe892-vm3)
      echo "vm3"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

enable_ssh_unit() {
  if systemctl cat ssh >/dev/null 2>&1; then
    systemctl enable ssh
    return 0
  fi
  if systemctl cat sshd >/dev/null 2>&1; then
    systemctl enable sshd
    return 0
  fi
  echo "No usable ssh service unit found" >&2
  return 1
}

restart_ssh_unit() {
  systemctl restart ssh 2>/dev/null \
    || systemctl restart ssh.service 2>/dev/null \
    || systemctl restart sshd 2>/dev/null \
    || systemctl restart sshd.service 2>/dev/null
}

status_ssh_unit() {
  systemctl status ssh --no-pager 2>/dev/null \
    || systemctl status ssh.service --no-pager 2>/dev/null \
    || systemctl status sshd --no-pager 2>/dev/null \
    || systemctl status sshd.service --no-pager 2>/dev/null \
    || true
}

write_ssh_fix_script() {
  sudo tee /usr/local/sbin/proxsyncq-ssh-fix.sh > /dev/null <<EOF
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
  sudo chmod 755 /usr/local/sbin/proxsyncq-ssh-fix.sh
}

write_ssh_fix_service() {
  local before_unit="ssh.service"
  if systemctl cat sshd >/dev/null 2>&1 && ! systemctl cat ssh >/dev/null 2>&1; then
    before_unit="sshd.service"
  fi

  sudo tee /etc/systemd/system/proxsyncq-ssh-fix.service > /dev/null <<EOF
[Unit]
Description=ProxSyncQ SSH permission self-heal
After=local-fs.target
Before=${before_unit}

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxsyncq-ssh-fix.sh

[Install]
WantedBy=multi-user.target
EOF
}

write_shared_check_script() {
  sudo tee /usr/local/sbin/proxsyncq-shared-check.sh > /dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

SHARED_PATH="${SHARED_PATH}"

mkdir -p "\${SHARED_PATH}"

if ! findmnt -rn "\${SHARED_PATH}" >/dev/null 2>&1; then
  mount "\${SHARED_PATH}" || true
fi

findmnt -rn "\${SHARED_PATH}" >/dev/null 2>&1
EOF
  sudo chmod 755 /usr/local/sbin/proxsyncq-shared-check.sh
}

write_shared_check_service() {
  sudo tee /etc/systemd/system/proxsyncq-shared-check.service > /dev/null <<EOF
[Unit]
Description=ProxSyncQ shared mount check
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxsyncq-shared-check.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_node_agent_service() {
  sudo tee /etc/systemd/system/proxsyncq-node-agent.service > /dev/null <<EOF
[Unit]
Description=ProxSyncQ Node Agent
After=network-online.target proxsyncq-shared-check.service
Wants=network-online.target
Requires=proxsyncq-shared-check.service

[Service]
Type=simple
User=${TARGET_USER}
WorkingDirectory=${REPO_DIR}
EnvironmentFile=${NODE_AGENT_ENV}
ExecStart=${REPO_DIR}/.venv/bin/uvicorn ${NODE_AGENT_APP} --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_vm1_infra_service() {
  sudo tee /etc/systemd/system/proxsyncq-infra.service > /dev/null <<EOF
[Unit]
Description=ProxSyncQ VM1 infra stack
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
User=${TARGET_USER}
WorkingDirectory=${INFRA_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_rpi_stack_service() {
  sudo tee /etc/systemd/system/proxsyncq-rpi-stack.service > /dev/null <<EOF
[Unit]
Description=ProxSyncQ Raspberry Pi control plane
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
User=${TARGET_USER}
WorkingDirectory=${PI_STACK_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
  fi

  need_cmd systemctl
  need_cmd sshd
  need_cmd docker

  local role
  role="$(detect_role)"

  if [[ "${role}" == "unknown" ]]; then
    echo "Unknown hostname: $(hostname)" >&2
    exit 1
  fi

  write_ssh_fix_script
  write_ssh_fix_service

  sudo mkdir -p /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/99-proxsyncq-auth.conf > /dev/null <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin prohibit-password
EOF

  sudo sshd -t

  sudo systemctl daemon-reload
  enable_ssh_unit
  sudo systemctl enable proxsyncq-ssh-fix.service
  sudo systemctl start proxsyncq-ssh-fix.service
  restart_ssh_unit

  sudo systemctl enable docker
  sudo systemctl restart docker

  if systemctl list-unit-files | grep -q '^prometheus-node-exporter\.service'; then
    sudo systemctl enable prometheus-node-exporter
    sudo systemctl restart prometheus-node-exporter
  fi

  case "${role}" in
    vm1|vm2|vm3)
      write_shared_check_script
      write_shared_check_service
      write_node_agent_service

      sudo systemctl daemon-reload
      sudo systemctl enable proxsyncq-shared-check.service
      sudo systemctl start proxsyncq-shared-check.service

      if [[ -f "${NODE_AGENT_ENV}" && -x "${REPO_DIR}/.venv/bin/uvicorn" ]]; then
        sudo systemctl enable proxsyncq-node-agent.service
        sudo systemctl restart proxsyncq-node-agent.service
      else
        echo "Skipping node agent enable because .venv or .env is missing"
      fi
      ;;
  esac

  case "${role}" in
    vm1)
      if [[ -d "${INFRA_DIR}" && -f "${INFRA_DIR}/docker-compose.yml" ]]; then
        write_vm1_infra_service
        sudo systemctl daemon-reload
        sudo systemctl enable proxsyncq-infra.service
        sudo systemctl restart proxsyncq-infra.service
      fi
      ;;
    rpi)
      if [[ -d "${PI_STACK_DIR}" && -f "${PI_STACK_DIR}/docker-compose.yml" ]]; then
        write_rpi_stack_service
        sudo systemctl daemon-reload
        sudo systemctl enable proxsyncq-rpi-stack.service
        sudo systemctl restart proxsyncq-rpi-stack.service
      fi
      ;;
  esac

  echo
  echo "Role: ${role}"
  echo
  echo "SSH status:"
  status_ssh_unit
  echo
  echo "Docker status:"
  systemctl status docker --no-pager || true
  echo
  echo "Node exporter status:"
  systemctl status prometheus-node-exporter --no-pager || true
  echo
  echo "Shared check status:"
  systemctl status proxsyncq-shared-check.service --no-pager || true
  echo
  echo "Node agent status:"
  systemctl status proxsyncq-node-agent.service --no-pager || true
  echo
  echo "VM1 infra status:"
  systemctl status proxsyncq-infra.service --no-pager || true
  echo
  echo "RPi stack status:"
  systemctl status proxsyncq-rpi-stack.service --no-pager || true
}

main "$@"
