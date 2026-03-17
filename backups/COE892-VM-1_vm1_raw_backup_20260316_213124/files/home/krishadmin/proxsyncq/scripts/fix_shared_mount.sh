#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT="/srv/proxsyncq/shared"
VOLUME_NAME="proxsyncqvol"
PRIMARY_PEER="10.26.0.172"
BACKUP1="10.26.0.171"
BACKUP2="10.26.0.173"
FSTAB_LINE="${PRIMARY_PEER}:/${VOLUME_NAME} ${MOUNT_POINT} glusterfs defaults,_netdev,backupvolfile-server=${BACKUP1}:backupvolfile-server=${BACKUP2} 0 0"

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y glusterfs-client

sudo mkdir -p "${MOUNT_POINT}"

if mountpoint -q "${MOUNT_POINT}"; then
  echo "Already mounted at ${MOUNT_POINT}"
else
  sudo umount -lf "${MOUNT_POINT}" 2>/dev/null || true
  sudo mount -t glusterfs "${PRIMARY_PEER}:/${VOLUME_NAME}" "${MOUNT_POINT}"
fi

sudo mkdir -p "${MOUNT_POINT}/results"

if ! grep -Fq "${PRIMARY_PEER}:/${VOLUME_NAME} ${MOUNT_POINT} glusterfs" /etc/fstab; then
  echo "${FSTAB_LINE}" | sudo tee -a /etc/fstab >/dev/null
fi

sudo systemctl daemon-reload
sleep 2

echo
echo "== mount check =="
findmnt "${MOUNT_POINT}" || true
echo
echo "== test write =="
touch "${MOUNT_POINT}/results/mount_test_$(hostname).txt"
ls -l "${MOUNT_POINT}/results/" | tail -n 5 || true
echo
echo "== agent health =="
curl -fsS http://127.0.0.1:8000/health || true
