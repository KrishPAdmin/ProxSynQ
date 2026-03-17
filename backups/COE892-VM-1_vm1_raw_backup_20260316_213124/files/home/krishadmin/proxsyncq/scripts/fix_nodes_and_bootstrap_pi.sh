#!/usr/bin/env bash
set -euo pipefail

PI_HOST="10.26.0.170"
NODES=("10.26.0.171" "10.26.0.172" "10.26.0.173")
USER_NAME="krishadmin"

install_exporter_remote() {
  local host="$1"
  echo "== installing node exporter on ${host} =="

  ssh -tt "${USER_NAME}@${host}" 'sudo bash -s' <<'REMOTE'
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
}

check_exporter() {
  local host="$1"
  echo "== checking node exporter on ${host} =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | sed -n '1,3p' || true
  echo
}

fix_pi_repo_name_and_bootstrap() {
  echo "== fixing pi repo filename and bootstrapping stack =="
  ssh -tt "${USER_NAME}@${PI_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ -f /etc/apt/sources.list.d/docker.list.disabled_by_proxsyncq ]]; then
  mv /etc/apt/sources.list.d/docker.list.disabled_by_proxsyncq /etc/apt/sources.list.d/docker.disabled_by_proxsyncq
fi

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
apt-get install -y docker.io docker-compose curl ca-certificates
systemctl enable --now docker
REMOTE

  ssh -tt "${USER_NAME}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/proxsyncq-rpi"

if docker compose version >/dev/null 2>&1; then
  sudo docker compose up -d --build
  sudo docker compose ps
else
  sudo docker-compose up -d --build
  sudo docker-compose ps
fi
REMOTE
}

echo "== step 1: vm node exporters =="
for host in "${NODES[@]}"; do
  install_exporter_remote "$host"
done

echo
echo "== step 2: verify vm node exporters =="
for host in "${NODES[@]}"; do
  check_exporter "$host"
done

echo
echo "== step 3: verify pi node exporter =="
check_exporter "$PI_HOST"

echo
echo "== step 4: bootstrap pi stack =="
fix_pi_repo_name_and_bootstrap

echo
echo "== step 5: endpoint checks =="
for i in $(seq 1 15); do
  ok=0
  curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && ok=$((ok+1)) || true
  curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" >/dev/null && ok=$((ok+1)) || true
  curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" >/dev/null && ok=$((ok+1)) || true
  if [[ "$ok" -eq 3 ]]; then
    break
  fi
  sleep 2
done

curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" && echo || true

echo
echo "== pi compose status =="
ssh -tt "${USER_NAME}@${PI_HOST}" 'cd ~/proxsyncq-rpi && (sudo docker compose ps || sudo docker-compose ps)'

echo
echo "done"
