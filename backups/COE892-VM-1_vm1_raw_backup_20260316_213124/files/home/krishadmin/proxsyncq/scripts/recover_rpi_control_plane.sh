#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"
RPI_USER="${RPI_USER:-krishadmin}"
HOSTS=(
  10.26.0.170
  10.26.0.171
  10.26.0.172
  10.26.0.173
)

cd "$HOME/proxsyncq"

mkdir -p rpi-control

cat > rpi-control/bootstrap_rpi_stack.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

shopt -s nullglob
for f in /etc/apt/sources.list.d/*; do
  if [[ -f "$f" ]] && grep -q 'download.docker.com/linux/ubuntu' "$f"; then
    sudo mv "$f" "${f}.disabled_by_proxsyncq"
  fi
done

if [[ -f /etc/apt/sources.list ]]; then
  sudo sed -i '/download\.docker\.com\/linux\/ubuntu/s/^/# disabled_by_proxsyncq /' /etc/apt/sources.list || true
fi

sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose curl ca-certificates
sudo systemctl enable --now docker

cd "$HOME/proxsyncq-rpi"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD="docker-compose"
fi

sudo $COMPOSE_CMD up -d --build
sudo $COMPOSE_CMD ps
SCRIPT
chmod +x rpi-control/bootstrap_rpi_stack.sh

repair_and_install_exporter() {
  local host="$1"
  echo "== repairing and installing node exporter on ${host} =="

  ssh -tt "${RPI_USER}@${host}" 'sudo bash -s' <<'REMOTE'
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
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 5 "http://${host}:9100/metrics" | head -n 3; then
      echo
      return 0
    fi
    sleep 1
  done
  echo "node_exporter check failed for ${host}"
  return 1
}

for host in "${HOSTS[@]}"; do
  repair_and_install_exporter "$host"
done

for host in "${HOSTS[@]}"; do
  check_exporter "$host"
done

echo "== pushing rpi control-plane stack =="
rsync -av rpi-control/ "${RPI_USER}@${RPI_HOST}:/home/${RPI_USER}/proxsyncq-rpi/"

echo "== bootstrapping rpi stack =="
ssh -tt "${RPI_USER}@${RPI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd "$HOME/proxsyncq-rpi"
bash ./bootstrap_rpi_stack.sh
REMOTE

echo "== checking rpi services =="
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  OK=0
  curl -fsS --max-time 5 "http://${RPI_HOST}:8080" >/dev/null && OK=$((OK+1)) || true
  curl -fsS --max-time 5 "http://${RPI_HOST}:9090/-/healthy" >/dev/null && OK=$((OK+1)) || true
  curl -fsS --max-time 5 "http://${RPI_HOST}:3000/api/health" >/dev/null && OK=$((OK+1)) || true
  if [[ "$OK" -eq 3 ]]; then
    break
  fi
  sleep 2
done

echo
echo "== final endpoint checks =="
curl -fsS --max-time 5 "http://${RPI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${RPI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${RPI_HOST}:3000/api/health" && echo || true

echo
echo "== rpi docker compose status =="
ssh -tt "${RPI_USER}@${RPI_HOST}" 'cd ~/proxsyncq-rpi && sudo docker compose ps || sudo docker-compose ps'

echo
echo "recovery run complete"
