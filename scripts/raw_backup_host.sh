#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
TARGET_USER="${SUDO_USER:-$(whoami)}"
USER_HOME="/home/${TARGET_USER}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${USER_HOME}/host-backups/raw}"
TS="$(date +%Y%m%d_%H%M%S)"
HOSTNAME_NOW="$(hostname -s)"
STAGE="/tmp/proxsyncq_backup_${ROLE}_${TS}"
FILES_STAGE="${STAGE}/files"
STATE_STAGE="${STAGE}/state"
MANIFEST="${STAGE}/MANIFEST.txt"

usage() {
  echo "Usage: sudo bash $0 {vm1|rpi}"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

copy_path() {
  local src="$1"
  local dst="${FILES_STAGE}${src}"

  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync -aAXH "$src"/ "$dst"/
    echo "$src/" >> "$MANIFEST"
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    echo "$src" >> "$MANIFEST"
  fi
}

dump_cmd() {
  local name="$1"
  shift
  {
    echo "### $name"
    echo
    "$@" || true
  } > "${STATE_STAGE}/${name}.txt" 2>&1
}

dump_shell() {
  local name="$1"
  local cmd="$2"
  {
    echo "### $name"
    echo
    bash -lc "$cmd" || true
  } > "${STATE_STAGE}/${name}.txt" 2>&1
}

collect_common() {
  copy_path /etc/hostname
  copy_path /etc/hosts
  copy_path /etc/fstab
  copy_path /etc/ssh/sshd_config
  copy_path /etc/ssh/sshd_config.d
  copy_path /etc/systemd/system
  copy_path /usr/local/sbin
  copy_path "${USER_HOME}/.ssh"
  copy_path "${USER_HOME}/.bashrc"
  copy_path "${USER_HOME}/.profile"

  dump_cmd hostname hostnamectl
  dump_cmd uname uname -a
  dump_shell ip_a "ip a"
  dump_shell ip_r "ip r"
  dump_shell ss_tulpn "ss -tulpn"
  dump_shell mount "mount"
  dump_shell findmnt "findmnt -R"
  dump_shell df_h "df -h"
  dump_shell lsblk "lsblk"
  dump_shell systemd_enabled "systemctl list-unit-files --state=enabled"
  dump_shell systemd_services "systemctl list-units --type=service --all"
  dump_shell crontab "crontab -l"
  dump_shell dpkg_l "dpkg -l"
  dump_shell docker_ps_a "docker ps -a"
  dump_shell docker_images "docker images"
  dump_shell docker_volume_ls "docker volume ls"
  dump_shell docker_network_ls "docker network ls"
}

collect_vm1() {
  copy_path "${USER_HOME}/proxsyncq"
  copy_path /etc/docker
  copy_path /var/lib/docker/volumes

  dump_shell docker_compose_ps_vm1 "cd ${USER_HOME}/proxsyncq/infra && docker compose ps"
  dump_shell postgres_jobs "cd ${USER_HOME}/proxsyncq/infra && docker exec -i proxsyncq-postgres psql -U proxsyncq -d proxsyncq -c 'SELECT job_id, job_type, state, claimed_by, attempt_count, submitted_by, submitted_at FROM jobs ORDER BY submitted_at DESC LIMIT 50;'"
}

collect_rpi() {
  copy_path "${USER_HOME}/proxsyncq-rpi"
  copy_path /etc/docker
  copy_path /var/lib/docker/volumes

  dump_shell docker_compose_ps_rpi "cd ${USER_HOME}/proxsyncq-rpi && docker compose ps"
  dump_shell docker_compose_logs_rpi "cd ${USER_HOME}/proxsyncq-rpi && docker compose logs --tail=200"
}

main() {
  [[ -n "$ROLE" ]] || usage
  [[ "$ROLE" == "vm1" || "$ROLE" == "rpi" ]] || usage

  need_cmd rsync
  need_cmd zip

  mkdir -p "$FILES_STAGE" "$STATE_STAGE" "$OUTPUT_ROOT"
  : > "$MANIFEST"

  echo "Role: $ROLE" > "${STAGE}/README.txt"
  echo "Hostname: $HOSTNAME_NOW" >> "${STAGE}/README.txt"
  echo "Timestamp: $TS" >> "${STAGE}/README.txt"
  echo >> "${STAGE}/README.txt"
  echo "This is a raw host backup ZIP with live configs and state dumps." >> "${STAGE}/README.txt"

  collect_common

  case "$ROLE" in
    vm1)
      collect_vm1
      ;;
    rpi)
      collect_rpi
      ;;
  esac

  local zip_name="${HOSTNAME_NOW}_${ROLE}_raw_backup_${TS}.zip"
  local zip_path="${OUTPUT_ROOT}/${zip_name}"

  (
    cd "$STAGE"
    zip -r "$zip_path" .
  )

  chown "${TARGET_USER}:${TARGET_USER}" "$zip_path" || true
  rm -rf "$STAGE"

  echo "Backup complete:"
  echo "$zip_path"
}

main "$@"
