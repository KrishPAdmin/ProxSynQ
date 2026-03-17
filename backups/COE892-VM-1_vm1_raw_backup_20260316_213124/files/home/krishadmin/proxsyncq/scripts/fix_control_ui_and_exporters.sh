#!/usr/bin/env bash
set -euo pipefail

PI_HOST="10.26.0.170"
PI_USER="krishadmin"
NODES=("10.26.0.171" "10.26.0.172" "10.26.0.173")

cd "$HOME/proxsyncq"

REQ_FILE="rpi-control/control_ui/requirements.txt"
if ! grep -q '^python-multipart' "$REQ_FILE"; then
  printf '\npython-multipart==0.0.20\n' >> "$REQ_FILE"
fi

echo "== updated requirements.txt =="
cat "$REQ_FILE"
echo

echo "== pushing updated control_ui to Pi =="
rsync -av rpi-control/control_ui/ "${PI_USER}@${PI_HOST}:/home/${PI_USER}/proxsyncq-rpi/control_ui/"

echo
echo "== rebuilding control_ui on Pi =="
ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd ~/proxsyncq-rpi
sudo docker compose up -d --build control_ui
sleep 3
sudo docker compose ps
echo
sudo docker compose logs --tail=120 control_ui
REMOTE

echo
echo "== installing node exporter on VM1, VM2, VM3 =="
for host in "${NODES[@]}"; do
  echo "== ${host} =="
  ssh -tt "${PI_USER}@${host}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

shopt -s nullglob
for f in /etc/apt/sources.list.d/*; do
  if [[ -f "$f" ]] && grep -q 'download.docker.com/linux/ubuntu' "$f"; then
    mv "$f" "${f}.disabled_by_proxsyncq"
  fi
done

if [[ -f /etc/apt/sources.list ]]; then
  sed -i '/download\.docker\.com\/linux\/ubuntu/s/^/# disabled_by_proxsyncq /' /etc/apt/sources.list || true
fi

apt-get update -y
apt-get install -y prometheus-node-exporter curl ca-certificates
systemctl enable --now prometheus-node-exporter
systemctl is-active prometheus-node-exporter
REMOTE
  echo
done

echo "== endpoint checks =="
curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" && echo || true
echo

for host in 10.26.0.170 10.26.0.171 10.26.0.172 10.26.0.173; do
  echo "== ${host}:9100 =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | sed -n '1,3p' || true
  echo
done
