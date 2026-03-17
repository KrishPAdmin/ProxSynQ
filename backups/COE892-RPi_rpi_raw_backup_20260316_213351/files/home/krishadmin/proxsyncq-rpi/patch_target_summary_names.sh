#!/usr/bin/env bash
set -euo pipefail

APP_FILE="$HOME/proxsyncq-rpi/control_ui/app.py"
BACKUP_FILE="$HOME/proxsyncq-rpi/control_ui/app.py.bak.$(date +%Y%m%d_%H%M%S)"

cp -a "$APP_FILE" "$BACKUP_FILE"

python3 - <<'PY'
from pathlib import Path

app_file = Path.home() / "proxsyncq-rpi" / "control_ui" / "app.py"
text = app_file.read_text()

helper = '''
def node_name_by_ip(ip: str):
    for node in get_nodes():
        if node.get("ip") == ip:
            return node.get("name", ip)
    return ip
'''

if "def node_name_by_ip(ip: str):" not in text:
    marker = "def resolve_targets(target_mode: str, count: int, job_type: str):"
    if marker not in text:
        raise SystemExit("Could not find resolve_targets marker in app.py")
    text = text.replace(marker, helper + "\n\n" + marker, 1)

old_block = '''    targets = resolve_targets(target_ip, count, job_type)
    sent = 0
    errors = 0
    target_counts = {}

    for ip in targets:
        target_counts[ip] = target_counts.get(ip, 0) + 1
        try:
            response = requests.post(
                f"http://{ip}:8000/jobs",
                json={"job_type": job_type, "payload": payload},
                timeout=6.0,
            )
            response.raise_for_status()
            sent += 1
        except Exception:
            errors += 1
        time.sleep(0.08)

    target_summary = ",".join(f"{ip}x{target_counts[ip]}" for ip in sorted(target_counts))
'''

new_block = '''    targets = resolve_targets(target_ip, count, job_type)
    sent = 0
    errors = 0
    target_counts = {}

    for ip in targets:
        name = node_name_by_ip(ip)
        target_counts[name] = target_counts.get(name, 0) + 1
        try:
            response = requests.post(
                f"http://{ip}:8000/jobs",
                json={"job_type": job_type, "payload": payload},
                timeout=6.0,
            )
            response.raise_for_status()
            sent += 1
        except Exception:
            errors += 1
        time.sleep(0.08)

    target_summary = ",".join(f"{name}x{target_counts[name]}" for name in sorted(target_counts))
'''

if old_block not in text:
    raise SystemExit("Could not find submit_job target summary block in app.py")

text = text.replace(old_block, new_block, 1)
app_file.write_text(text)
print("Patched app.py successfully")
PY

cd ~/proxsyncq-rpi
sudo docker compose build --no-cache control_ui
sudo docker compose up -d control_ui
sleep 8

echo
echo "== backup saved to =="
echo "$BACKUP_FILE"
echo
echo "== quick check =="
sudo docker compose ps
