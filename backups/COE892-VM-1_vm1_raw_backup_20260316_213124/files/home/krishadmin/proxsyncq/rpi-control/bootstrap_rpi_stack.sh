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
