#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/proxsyncq"

cat > scripts/repair_bad_docker_repo.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

shopt -s nullglob

for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
  [[ -f "$f" ]] || continue
  if grep -q 'download\.docker\.com/linux/ubuntu' "$f"; then
    cp "$f" "${f}.bak_proxsyncq" || true
    sed -i 's|^\(.*download\.docker\.com/linux/ubuntu.*\)$|# disabled_by_proxsyncq \1|g' "$f"
  fi
done
SCRIPT
chmod +x scripts/repair_bad_docker_repo.sh

cat > scripts/install_node_exporter.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

bash /tmp/repair_bad_docker_repo.sh 2>/dev/null || true
sudo apt-get update -y
sudo apt-get install -y prometheus-node-exporter curl ca-certificates
sudo systemctl enable --now prometheus-node-exporter
sleep 1
sudo systemctl status prometheus-node-exporter --no-pager || true
curl -fsS http://127.0.0.1:9100/metrics | head -n 5 || true
SCRIPT
chmod +x scripts/install_node_exporter.sh

cat > scripts/install_node_exporter_all.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-krishadmin}"
HOSTS=(
  10.26.0.170
  10.26.0.171
  10.26.0.172
  10.26.0.173
)

for host in "${HOSTS[@]}"; do
  echo "== ${host} =="
  scp -q scripts/repair_bad_docker_repo.sh "${TARGET_USER}@${host}:/tmp/repair_bad_docker_repo.sh"
  scp -q scripts/install_node_exporter.sh "${TARGET_USER}@${host}:/tmp/install_node_exporter.sh"
  ssh -q "${TARGET_USER}@${host}" 'bash /tmp/install_node_exporter.sh'
  echo
done
SCRIPT
chmod +x scripts/install_node_exporter_all.sh

cat > scripts/check_node_exporter_all.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

HOSTS=(
  10.26.0.170
  10.26.0.171
  10.26.0.172
  10.26.0.173
)

for host in "${HOSTS[@]}"; do
  echo "== ${host} =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | head -n 5 || true
  echo
done
SCRIPT
chmod +x scripts/check_node_exporter_all.sh

cat > rpi-control/bootstrap_rpi_stack.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

bash /tmp/repair_bad_docker_repo.sh 2>/dev/null || true
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose curl ca-certificates
sudo systemctl enable --now docker
sleep 1
sudo docker version
sudo docker compose up -d --build
sudo docker compose ps
SCRIPT
chmod +x rpi-control/bootstrap_rpi_stack.sh

cat > scripts/push_rpi_stack.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"
RPI_USER="${RPI_USER:-krishadmin}"
REMOTE_DIR="${REMOTE_DIR:-/home/${RPI_USER}/proxsyncq-rpi}"

rsync -av rpi-control/ "${RPI_USER}@${RPI_HOST}:${REMOTE_DIR}/"
scp -q scripts/repair_bad_docker_repo.sh "${RPI_USER}@${RPI_HOST}:/tmp/repair_bad_docker_repo.sh"
ssh "${RPI_USER}@${RPI_HOST}" "cd ${REMOTE_DIR} && bash bootstrap_rpi_stack.sh"
SCRIPT
chmod +x scripts/push_rpi_stack.sh

cat > scripts/check_rpi_control_plane.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"

curl -fsS --max-time 5 "http://${RPI_HOST}:8080" > /dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${RPI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${RPI_HOST}:3000/api/health" && echo || true
SCRIPT
chmod +x scripts/check_rpi_control_plane.sh

echo "repair scripts written"
