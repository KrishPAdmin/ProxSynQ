#!/usr/bin/env bash
set -euo pipefail

ROLE=""
USER_NAME="krishadmin"
SHARED_MNT="/srv/proxsyncq/shared"
BRICK_DIR="/gluster/brick1/proxsyncq"
VOLUME_NAME="proxsyncqvol"
DO_VERIFY="0"
DO_SET_HOSTNAME="1"

usage() {
  echo "Usage: sudo $0 --role {vm1|vm2|vm3|rpi} [--user krishadmin] [--no-hostname] [--verify]"
  exit 1
}

log() {
  printf "[%s] %s\n" "$(date -Iseconds)" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

as_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0 ..."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        ROLE="${2:-}"
        shift 2
        ;;
      --user)
        USER_NAME="${2:-}"
        shift 2
        ;;
      --verify)
        DO_VERIFY="1"
        shift 1
        ;;
      --no-hostname)
        DO_SET_HOSTNAME="0"
        shift 1
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Unknown arg: $1"
        usage
        ;;
    esac
  done
  if [[ -z "${ROLE}" ]]; then
    usage
  fi
}

role_config() {
  case "${ROLE}" in
    vm1)
      NODE_IP="10.26.0.171"
      NODE_HOSTNAME="COE892-VM-1"
      PRIMARY_VOLFILE="10.26.0.171"
      BACKUP_VOLFILE="10.26.0.172"
      ;;
    vm2)
      NODE_IP="10.26.0.172"
      NODE_HOSTNAME="COE892-VM-2"
      PRIMARY_VOLFILE="10.26.0.172"
      BACKUP_VOLFILE="10.26.0.173"
      ;;
    vm3)
      NODE_IP="10.26.0.173"
      NODE_HOSTNAME="COE892-VM-3"
      PRIMARY_VOLFILE="10.26.0.173"
      BACKUP_VOLFILE="10.26.0.171"
      ;;
    rpi)
      NODE_IP="10.26.0.170"
      NODE_HOSTNAME="COE892-RPi"
      PRIMARY_VOLFILE="10.26.0.172"
      BACKUP_VOLFILE="10.26.0.173"
      ;;
    *)
      echo "Invalid role: ${ROLE}"
      usage
      ;;
  esac
  PEERS=("10.26.0.171" "10.26.0.172" "10.26.0.173")
}

ensure_hosts_entries() {
  local hosts_file="/etc/hosts"
  local lines=(
    "10.26.0.170 coe892-rpi COE892-RPi"
    "10.26.0.171 coe892-vm1 COE892-VM-1"
    "10.26.0.172 coe892-vm2 COE892-VM-2"
    "10.26.0.173 coe892-vm3 COE892-VM-3"
  )
  for l in "${lines[@]}"; do
    local ip="${l%% *}"
    if ! grep -qE "^${ip}[[:space:]]" "${hosts_file}"; then
      echo "${l}" >> "${hosts_file}"
    fi
  done
}

set_hostname_if_needed() {
  if [[ "${DO_SET_HOSTNAME}" != "1" ]]; then
    return
  fi
  local cur
  cur="$(hostname)"
  if [[ "${cur}" != "${NODE_HOSTNAME}" ]]; then
    log "Setting hostname to ${NODE_HOSTNAME}"
    hostnamectl set-hostname "${NODE_HOSTNAME}"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

install_gluster() {
  if [[ "${ROLE}" == "rpi" ]]; then
    log "Installing gluster client"
    apt_install glusterfs-client
  else
    log "Installing gluster server"
    apt_install glusterfs-server
    systemctl enable --now glusterd
  fi
}

gluster_try_probe_peers() {
  if [[ "${ROLE}" == "rpi" ]]; then
    return
  fi
  local ok_any="0"
  for ip in "${PEERS[@]}"; do
    if [[ "${ip}" == "${NODE_IP}" ]]; then
      continue
    fi
    for attempt in 1 2 3 4 5; do
      if gluster peer probe "${ip}" >/dev/null 2>&1; then
        ok_any="1"
        break
      fi
      sleep 0.3
    done
  done
  if [[ "${ok_any}" == "1" ]]; then
    gluster peer status || true
  fi
}

ensure_brick_dir() {
  if [[ "${ROLE}" == "rpi" ]]; then
    return
  fi
  mkdir -p "${BRICK_DIR}"
  chown -R "${USER_NAME}:${USER_NAME}" "/gluster/brick1" || true
}

volume_exists() {
  gluster volume info "${VOLUME_NAME}" >/dev/null 2>&1
}

create_or_start_volume_vm1() {
  if [[ "${ROLE}" != "vm1" ]]; then
    return
  fi
  if volume_exists; then
    log "Gluster volume ${VOLUME_NAME} already exists"
    gluster volume start "${VOLUME_NAME}" >/dev/null 2>&1 || true
    return
  fi
  log "Creating gluster volume ${VOLUME_NAME} (replica 3)"
  gluster volume create "${VOLUME_NAME}" replica 3 transport tcp \
    10.26.0.171:"${BRICK_DIR}" \
    10.26.0.172:"${BRICK_DIR}" \
    10.26.0.173:"${BRICK_DIR}" force
  gluster volume start "${VOLUME_NAME}"
}

ensure_mountpoint() {
  mkdir -p "${SHARED_MNT}"
}

is_gluster_mounted() {
  local fstype
  fstype="$(findmnt -n -o FSTYPE --target "${SHARED_MNT}" 2>/dev/null || true)"
  [[ "${fstype}" == "glusterfs" ]]
}

mount_shared() {
  ensure_mountpoint
  if is_gluster_mounted; then
    return
  fi
  if findmnt -n --target "${SHARED_MNT}" >/dev/null 2>&1; then
    umount "${SHARED_MNT}" || true
    sleep 0.2
  fi
  log "Mounting ${VOLUME_NAME} at ${SHARED_MNT} using ${PRIMARY_VOLFILE} with backup ${BACKUP_VOLFILE}"
  mount -t glusterfs -o "backupvolfile-server=${BACKUP_VOLFILE}" "${PRIMARY_VOLFILE}:/${VOLUME_NAME}" "${SHARED_MNT}"
}

ensure_fstab_entry() {
  local fstab="/etc/fstab"
  local desired="${PRIMARY_VOLFILE}:/${VOLUME_NAME} ${SHARED_MNT} glusterfs defaults,_netdev,backupvolfile-server=${BACKUP_VOLFILE} 0 0"
  if grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/${VOLUME_NAME}[[:space:]]+${SHARED_MNT}[[:space:]]+glusterfs" "${fstab}"; then
    sed -i -E "s|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/${VOLUME_NAME}[[:space:]]+${SHARED_MNT}[[:space:]]+glusterfs.*$|${desired}|" "${fstab}"
  else
    echo "${desired}" >> "${fstab}"
  fi
}

ensure_shared_permissions() {
  groupadd -f proxsyncq
  if id -u "${USER_NAME}" >/dev/null 2>&1; then
    usermod -aG proxsyncq "${USER_NAME}" || true
  fi
  if is_gluster_mounted; then
    chown "${USER_NAME}:proxsyncq" "${SHARED_MNT}" || true
    chmod 2775 "${SHARED_MNT}" || true
  fi
}

verify_shared_sync() {
  if [[ "${DO_VERIFY}" != "1" ]]; then
    return
  fi
  if ! is_gluster_mounted; then
    log "Verify skipped because ${SHARED_MNT} is not mounted as glusterfs"
    return
  fi
  local ts fn
  ts="$(date +%s)"
  fn="${SHARED_MNT}/proof_${ROLE}_$(hostname)_${ts}.txt"
  echo "proof from ${ROLE} $(hostname) at ${ts}" > "${fn}"
  sync
  log "Created ${fn}"
  ls -l "${fn}" || true
  ls -l "${SHARED_MNT}" | tail -n 10 || true
}

main() {
  as_root
  need_cmd apt-get
  need_cmd findmnt
  parse_args "$@"
  role_config
  log "Role=${ROLE} User=${USER_NAME} NodeIP=${NODE_IP} Primary=${PRIMARY_VOLFILE} Backup=${BACKUP_VOLFILE}"
  ensure_hosts_entries
  set_hostname_if_needed
  install_gluster
  if [[ "${ROLE}" != "rpi" ]]; then
    gluster_try_probe_peers
    ensure_brick_dir
    create_or_start_volume_vm1
  fi
  mount_shared
  ensure_fstab_entry
  ensure_shared_permissions
  verify_shared_sync
  log "Done"
  if [[ "${ROLE}" != "rpi" ]]; then
    gluster volume status "${VOLUME_NAME}" >/dev/null 2>&1 || true
  fi
  findmnt "${SHARED_MNT}" || true
}

main "$@"
