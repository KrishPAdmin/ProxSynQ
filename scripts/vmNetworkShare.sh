#!/usr/bin/env bash
set -euo pipefail

ROLE=""
USER_NAME="krishadmin"
IFACE=""
SHARED_MNT="/srv/proxsyncq/shared"
BRICK_DIR="/gluster/brick1/proxsyncq"
VOLUME_NAME="proxsyncqvol"
DO_VERIFY="0"
DO_SET_HOSTNAME="1"
DO_NET="1"

usage() {
  echo "Usage: sudo $0 --role {vm1|vm2|vm3|rpi} [--user krishadmin] [--iface IFACE] [--no-hostname] [--no-net] [--verify]"
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
      --iface)
        IFACE="${2:-}"
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
      --no-net)
        DO_NET="0"
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
  GATEWAY="10.26.0.1"
  DNS_PRIMARY="10.26.0.1"
}

detect_iface() {
  if [[ -n "${IFACE}" ]]; then
    return
  fi
  IFACE="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -z "${IFACE}" ]]; then
    IFACE="$(ip -br link | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}')"
  fi
  if [[ -z "${IFACE}" ]]; then
    IFACE="eth0"
  fi
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
    log "Hostname set to ${NODE_HOSTNAME}"
    hostnamectl set-hostname "${NODE_HOSTNAME}"
  fi
  grep -vE '^127\.0\.1\.1\b' /etc/hosts > /etc/hosts.new
  echo "127.0.1.1 ${NODE_HOSTNAME}" >> /etc/hosts.new
  mv /etc/hosts.new /etc/hosts
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

has_netplan() {
  command -v netplan >/dev/null 2>&1
}

ip_already_set() {
  ip -4 addr show "${IFACE}" 2>/dev/null | grep -q "inet ${NODE_IP}/24"
}

netplan_apply_static_vm() {
  if [[ "${DO_NET}" != "1" ]]; then
    return
  fi
  if ! has_netplan; then
    log "Netplan not found, skipping netplan config"
    return
  fi
  if ip_already_set; then
    log "Static IP already present on ${IFACE}: ${NODE_IP}/24"
    return
  fi
  local np_file="/etc/netplan/01-${IFACE}-static.yaml"
  for f in /etc/netplan/*.yaml; do
    [[ -e "$f" ]] || continue
    if grep -q "${IFACE}" "$f"; then
      mv "$f" "${f%.yaml}.yaml.bak" || true
      sleep 0.2
    fi
  done
  cat > "${np_file}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses: [${NODE_IP}/24]
      gateway4: ${GATEWAY}
      nameservers:
        addresses: [${DNS_PRIMARY},8.8.8.8]
EOF
  log "Netplan apply for ${IFACE} to ${NODE_IP}/24"
  netplan generate
  netplan apply
  sleep 1
}

nmcli_config_rpi() {
  if [[ "${DO_NET}" != "1" ]]; then
    return
  fi
  if ! command -v nmcli >/dev/null 2>&1; then
    return
  fi
  if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
    return
  fi
  if ip_already_set; then
    log "Static IP already present on ${IFACE}: ${NODE_IP}/24"
    return
  fi
  local con_name
  con_name="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="${IFACE}" '$2==d{print $1; exit}')"
  if [[ -z "${con_name}" ]]; then
    con_name="coe892-${IFACE}"
    nmcli con add type ethernet ifname "${IFACE}" con-name "${con_name}" >/dev/null 2>&1 || true
    sleep 0.2
  fi
  nmcli con mod "${con_name}" ipv4.addresses "${NODE_IP}/24"
  nmcli con mod "${con_name}" ipv4.gateway "${GATEWAY}"
  nmcli con mod "${con_name}" ipv4.dns "${DNS_PRIMARY} 8.8.8.8"
  nmcli con mod "${con_name}" ipv4.method manual
  nmcli con down "${con_name}" >/dev/null 2>&1 || true
  sleep 0.3
  nmcli con up "${con_name}" >/dev/null 2>&1 || true
  sleep 1
}

dhcpcd_config_rpi() {
  if [[ "${DO_NET}" != "1" ]]; then
    return
  fi
  if [[ ! -f /etc/dhcpcd.conf ]]; then
    return
  fi
  if ! systemctl is-active dhcpcd >/dev/null 2>&1; then
    return
  fi
  if ip_already_set; then
    log "Static IP already present on ${IFACE}: ${NODE_IP}/24"
    return
  fi
  local begin="# coe892-static-begin"
  local end="# coe892-static-end"
  awk -v b="${begin}" -v e="${end}" '
    $0==b{inblk=1; next}
    $0==e{inblk=0; next}
    !inblk{print}
  ' /etc/dhcpcd.conf > /etc/dhcpcd.conf.new
  {
    echo "${begin}"
    echo "interface ${IFACE}"
    echo "static ip_address=${NODE_IP}/24"
    echo "static routers=${GATEWAY}"
    echo "static domain_name_servers=${DNS_PRIMARY} 8.8.8.8"
    echo "${end}"
  } >> /etc/dhcpcd.conf.new
  mv /etc/dhcpcd.conf.new /etc/dhcpcd.conf
  systemctl restart dhcpcd
  sleep 1
}

configure_network_and_hostname() {
  detect_iface
  ensure_hosts_entries
  set_hostname_if_needed
  if [[ "${ROLE}" == "rpi" ]]; then
    nmcli_config_rpi
    dhcpcd_config_rpi
    return
  fi
  netplan_apply_static_vm
}

install_gluster() {
  if [[ "${ROLE}" == "rpi" ]]; then
    log "Gluster client install"
    apt_install glusterfs-client
  else
    log "Gluster server install"
    apt_install glusterfs-server
    systemctl enable --now glusterd
  fi
}

gluster_try_probe_peers() {
  if [[ "${ROLE}" == "rpi" ]]; then
    return
  fi
  for ip in "${PEERS[@]}"; do
    if [[ "${ip}" == "${NODE_IP}" ]]; then
      continue
    fi
    for attempt in 1 2 3 4 5; do
      if gluster peer probe "${ip}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.3
    done
  done
  gluster peer status || true
}

ensure_brick_dir() {
  if [[ "${ROLE}" == "rpi" ]]; then
    return
  fi
  mkdir -p "${BRICK_DIR}"
  chown -R "${USER_NAME}:${USER_NAME}" "/gluster/brick1" >/dev/null 2>&1 || true
}

volume_exists() {
  gluster volume info "${VOLUME_NAME}" >/dev/null 2>&1
}

create_or_start_volume_vm1() {
  if [[ "${ROLE}" != "vm1" ]]; then
    return
  fi
  if volume_exists; then
    gluster volume start "${VOLUME_NAME}" >/dev/null 2>&1 || true
    return
  fi
  log "Gluster volume create ${VOLUME_NAME}"
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
  log "Mount ${PRIMARY_VOLFILE}:/${VOLUME_NAME} with backup ${BACKUP_VOLFILE}"
  mount -t glusterfs -o "backupvolfile-server=${BACKUP_VOLFILE}" "${PRIMARY_VOLFILE}:/${VOLUME_NAME}" "${SHARED_MNT}"
  sleep 0.3
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
    usermod -aG proxsyncq "${USER_NAME}" >/dev/null 2>&1 || true
  fi
  if is_gluster_mounted; then
    chown "${USER_NAME}:proxsyncq" "${SHARED_MNT}" >/dev/null 2>&1 || true
    chmod 2775 "${SHARED_MNT}" >/dev/null 2>&1 || true
  fi
}

verify_shared_sync() {
  if [[ "${DO_VERIFY}" != "1" ]]; then
    return
  fi
  if ! is_gluster_mounted; then
    log "Verify skipped, ${SHARED_MNT} not glusterfs"
    return
  fi
  local ts fn
  ts="$(date +%s)"
  fn="${SHARED_MNT}/proof_${ROLE}_$(hostname)_${ts}.txt"
  echo "proof ${ROLE} $(hostname) ${NODE_IP} ${ts}" > "${fn}"
  sync
  sleep 0.2
  log "Proof file ${fn}"
  ls -l "${fn}" || true
}

main() {
  as_root
  need_cmd apt-get
  need_cmd findmnt
  need_cmd ip
  parse_args "$@"
  role_config
  log "Role=${ROLE} Hostname=${NODE_HOSTNAME} IP=${NODE_IP} IFACE=${IFACE:-auto}"
  configure_network_and_hostname
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
  findmnt "${SHARED_MNT}" || true
  log "Done"
}

main "$@"

# Steps to run:
# sudo ./vmNetworkShare.sh --role vm1 --verify
# sudo ./vmNetworkShare.sh --role vm2 --verify
# sudo ./vmNetworkShare.sh --role vm3 --verify
# sudo ./vmNetworkShare.sh --role rpi --verify
