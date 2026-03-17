#!/usr/bin/env bash
# Usage: sudo ./set_static_ip_and_hostname.sh NEW_HOSTNAME NEW_STATIC_IP [INTERFACE]

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:  sudo $0 NEW_HOSTNAME NEW_STATIC_IP [INTERFACE]" >&2
    exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: sudo $0 NEW_HOSTNAME NEW_STATIC_IP [INTERFACE]" >&2
    exit 1
fi

NEW_HOSTNAME=$1
STATIC_IP=$2
IFACE=${3:-$(ip route get 8.8.8.8 | awk '{print $5;exit}')}   # auto‑detect if not given

# ── Network constants ────────────────────────────────────────────────────────────
GATEWAY="$(echo "$STATIC_IP" | awk -F. '{print $1"."$2"."$3".1"}')"  #  x.y.z.1
DNS="$GATEWAY"

echo "Using interface: $IFACE"
echo "Static address : $STATIC_IP/24 (GW $GATEWAY, DNS $DNS)"
echo

# ── Hostname ─────────────────────────────────────────────────────────────────────
echo "[*] Setting hostname to $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# Remove any existing 127.0.1.1 lines, then add one clean line
grep -vE '^127\.0\.1\.1\b' /etc/hosts > /etc/hosts.new
echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts.new
mv /etc/hosts.new /etc/hosts

# ── Disable conflicting netplan files (cloud‑init / installer) ───────────────────
for f in /etc/netplan/*.yaml; do
    if grep -q "$IFACE" "$f"; then
        echo "[*] Disabling $f"
        mv "$f" "${f%.yaml}.yaml.bak"
    fi
done

# ── Write our own static file ────────────────────────────────────────────────────
NP_FILE="/etc/netplan/01-${IFACE}-static.yaml"
echo "[*] Creating $NP_FILE"

cat > "$NP_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [$STATIC_IP/24]
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS,8.8.8.8]
EOF

# ── Apply and verify ─────────────────────────────────────────────────────────────
echo "[*] Applying netplan…"
netplan generate          # validates syntax
netplan apply             # activates config

echo
ip -4 addr show "$IFACE" | grep inet
echo "[√] Hostname and static IP configured."
echo "   (If you use cloud-init, disable it with:"
echo "    sudo touch /etc/cloud/cloud-init.disabled)"
