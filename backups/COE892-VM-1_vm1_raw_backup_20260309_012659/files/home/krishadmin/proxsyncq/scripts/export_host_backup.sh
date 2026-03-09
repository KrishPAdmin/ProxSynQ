#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
BASE_DIR="${2:-$HOME/proxsyncq/backup}"
USER_NAME="${USER_NAME:-krishadmin}"

usage() {
  echo "Usage: $0 {vm1|rpi} [backup_base_dir]"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

sync_dir_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync -a \
      --exclude '.git' \
      --exclude '.venv' \
      --exclude '__pycache__' \
      --exclude '*.pyc' \
      --exclude 'node_modules' \
      --exclude '.env' \
      --exclude 'id_ed25519' \
      --exclude 'id_rsa' \
      --exclude 'known_hosts' \
      "$src"/ "$dst"/
  fi
}

export_state() {
  local out_dir="$1"
  mkdir -p "$out_dir"

  hostname > "$out_dir/hostname.txt"
  whoami > "$out_dir/whoami.txt"
  date -Iseconds > "$out_dir/exported_at.txt"

  ip a > "$out_dir/ip_a.txt" 2>&1 || true
  ip r > "$out_dir/ip_r.txt" 2>&1 || true
  ss -tulpn > "$out_dir/ss_tulpn.txt" 2>&1 || true
  mount > "$out_dir/mount.txt" 2>&1 || true
  findmnt -R > "$out_dir/findmnt.txt" 2>&1 || true
  df -h > "$out_dir/df_h.txt" 2>&1 || true
  lsblk > "$out_dir/lsblk.txt" 2>&1 || true
  systemctl list-unit-files --state=enabled > "$out_dir/systemd_enabled.txt" 2>&1 || true
  systemctl list-units --type=service --all > "$out_dir/systemd_services.txt" 2>&1 || true
  crontab -l > "$out_dir/crontab.txt" 2>&1 || true
  dpkg -l > "$out_dir/dpkg_l.txt" 2>&1 || true
  docker ps -a > "$out_dir/docker_ps_a.txt" 2>&1 || true
  docker images > "$out_dir/docker_images.txt" 2>&1 || true
  docker volume ls > "$out_dir/docker_volume_ls.txt" 2>&1 || true
  docker network ls > "$out_dir/docker_network_ls.txt" 2>&1 || true
}

sanitize_tree() {
  local root="$1"

  find "$root" -type f -name ".env" -delete 2>/dev/null || true
  find "$root" -type f -name "id_ed25519" -delete 2>/dev/null || true
  find "$root" -type f -name "id_rsa" -delete 2>/dev/null || true
  find "$root" -type f -name "known_hosts" -delete 2>/dev/null || true

  while IFS= read -r -d '' file; do
    sed -i -E \
      -e 's/(PASS|PASSWORD|TOKEN|SECRET|KEY)=.*/\1=REDACTED/g' \
      -e 's/(proxsyncqpass|proxsyncqadmin|KrishAdmin@2003)/REDACTED/g' \
      "$file" || true
  done < <(find "$root" -type f \( -name "*.yml" -o -name "*.yaml" -o -name "*.env.example" -o -name "*.conf" -o -name "*.service" -o -name "*.txt" -o -name "*.md" -o -name "*.py" -o -name "*.html" \) -print0)
}

main() {
  need_cmd rsync
  need_cmd ip

  [[ -n "$ROLE" ]] || usage
  [[ "$ROLE" == "vm1" || "$ROLE" == "rpi" ]] || usage

  local OUT="$BASE_DIR/$ROLE"
  rm -rf "$OUT"
  mkdir -p "$OUT/etc" "$OUT/home/$USER_NAME" "$OUT/state"

  copy_if_exists /etc/hostname "$OUT/etc/hostname"
  copy_if_exists /etc/hosts "$OUT/etc/hosts"
  copy_if_exists /etc/fstab "$OUT/etc/fstab"
  copy_if_exists /etc/ssh/sshd_config "$OUT/etc/ssh/sshd_config"

  if [[ -d /etc/ssh/sshd_config.d ]]; then
    mkdir -p "$OUT/etc/ssh/sshd_config.d"
    cp -a /etc/ssh/sshd_config.d/. "$OUT/etc/ssh/sshd_config.d/"
  fi

  if [[ -d /etc/systemd/system ]]; then
    mkdir -p "$OUT/etc/systemd/system"
    cp -a /etc/systemd/system/. "$OUT/etc/systemd/system/"
  fi

  if [[ -d /etc/docker ]]; then
    mkdir -p "$OUT/etc/docker"
    cp -a /etc/docker/. "$OUT/etc/docker/"
  fi

  if [[ -f "$HOME/.ssh/config" ]]; then
    mkdir -p "$OUT/home/$USER_NAME/.ssh"
    cp -a "$HOME/.ssh/config" "$OUT/home/$USER_NAME/.ssh/config"
  fi

  find "$HOME/.ssh" -maxdepth 1 -type f -name "*.pub" -exec cp -a {} "$OUT/home/$USER_NAME/.ssh/" \; 2>/dev/null || true

  if [[ "$ROLE" == "vm1" ]]; then
    sync_dir_if_exists "$HOME/proxsyncq" "$OUT/home/$USER_NAME/proxsyncq"
  fi

  if [[ "$ROLE" == "rpi" ]]; then
    sync_dir_if_exists "$HOME/proxsyncq-rpi" "$OUT/home/$USER_NAME/proxsyncq-rpi"
  fi

  export_state "$OUT/state"
  sanitize_tree "$OUT"

  echo "Export complete: $OUT"
}

main "$@"
