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
