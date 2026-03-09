#!/usr/bin/env bash
set -euo pipefail

PI_USER="krishadmin"
PI_HOST="10.26.0.170"

ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail

echo "== basic identity =="
hostname
whoami
pwd
echo

echo "== proxsyncq-rpi directory =="
ls -la ~
ls -la ~/proxsyncq-rpi || true
echo

echo "== compose file =="
if [[ -f ~/proxsyncq-rpi/docker-compose.yml ]]; then
  ls -l ~/proxsyncq-rpi/docker-compose.yml
  sed -n '1,220p' ~/proxsyncq-rpi/docker-compose.yml
else
  echo "missing ~/proxsyncq-rpi/docker-compose.yml"
fi
echo

echo "== docker binaries =="
command -v docker || true
docker --version || true
docker compose version || true
docker-compose --version || true
echo

echo "== docker service =="
sudo systemctl enable --now docker || true
sudo systemctl status docker --no-pager || true
echo

echo "== docker ps before start =="
sudo docker ps -a || true
echo

echo "== tree under proxsyncq-rpi =="
find ~/proxsyncq-rpi -maxdepth 3 -type f | sort || true
echo

cd ~/proxsyncq-rpi

echo "== compose config check =="
if docker compose version >/dev/null 2>&1; then
  sudo docker compose config
else
  sudo docker-compose config
fi
echo

echo "== compose up =="
if docker compose version >/dev/null 2>&1; then
  sudo docker compose up -d --build
  echo
  echo "== compose ps =="
  sudo docker compose ps
  echo
  echo "== compose logs =="
  sudo docker compose logs --tail=200
else
  sudo docker-compose up -d --build
  echo
  echo "== compose ps =="
  sudo docker-compose ps
  echo
  echo "== compose logs =="
  sudo docker-compose logs --tail=200
fi
REMOTE

echo
echo "== endpoint checks from VM1 =="
curl -fsS --max-time 5 http://10.26.0.170:8080 >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 http://10.26.0.170:9090/-/healthy && echo || true
curl -fsS --max-time 5 http://10.26.0.170:3000/api/health && echo || true
