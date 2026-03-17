#!/usr/bin/env bash
set -euo pipefail

USER_NAME="krishadmin"
AGENT_DIR="/home/${USER_NAME}/proxsyncq-node-agent"
SERVICE_FILE="/etc/systemd/system/proxsyncq-node-agent.service"
RABBIT_HOST="10.26.0.171"
RABBIT_PORT="5672"
POSTGRES_HOST="10.26.0.171"
POSTGRES_PORT="5432"
SHARED_PATH="/srv/proxsyncq/shared"

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y python3 python3-venv python3-pip curl ca-certificates procps iproute2 prometheus-node-exporter

sudo mkdir -p "${SHARED_PATH}"
sudo mkdir -p "${SHARED_PATH}/results"
sudo chown -R "${USER_NAME}:${USER_NAME}" "${SHARED_PATH}" || true

sudo systemctl stop proxsyncq-node-agent 2>/dev/null || true
sudo systemctl disable proxsyncq-node-agent 2>/dev/null || true

pid="$(sudo ss -ltnp '( sport = :8000 )' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -n1 || true)"
if [ -n "${pid}" ]; then
  sudo kill "${pid}" >/dev/null 2>&1 || true
  sleep 2
fi

sudo rm -f "${SERVICE_FILE}"
sudo systemctl daemon-reload

rm -rf "${AGENT_DIR}"
mkdir -p "${AGENT_DIR}"

cat > "${AGENT_DIR}/requirements.txt" <<'REQ'
fastapi==0.115.8
uvicorn[standard]==0.34.0
prometheus-client==0.21.1
REQ

cat > "${AGENT_DIR}/worker.py" <<'PY'
import hashlib
import json
import multiprocessing as mp
import os
import socket
import sys
import time
from datetime import datetime, timezone

SHARED_PATH = os.getenv("SHARED_PATH", "/srv/proxsyncq/shared")

def demo_write(payload):
    message = str(payload.get("message", "hello"))
    line = f"{datetime.now(timezone.utc).isoformat()} {socket.gethostname()} {message}\n"
    with open("/tmp/proxsyncq_demo_write.log", "a", encoding="utf-8") as fh:
        fh.write(line)
    if os.path.exists(SHARED_PATH):
        try:
            with open(os.path.join(SHARED_PATH, f"demo_{socket.gethostname()}.log"), "a", encoding="utf-8") as fh:
                fh.write(line)
        except Exception:
            pass

def sleep_job(payload):
    seconds = max(1, min(int(payload.get("seconds", 3)), 300))
    time.sleep(seconds)

def burn_loop(seconds: int):
    deadline = time.time() + seconds
    salt = os.urandom(16)
    block = os.urandom(64)
    while time.time() < deadline:
        hashlib.pbkdf2_hmac("sha256", block, salt, 200000, 64)

def crypto_burn(payload):
    seconds = max(1, min(int(payload.get("seconds", 30)), 300))
    workers = max(1, min(int(payload.get("workers", 2)), 8))
    procs = []
    for _ in range(workers):
        p = mp.Process(target=burn_loop, args=(seconds,))
        p.start()
        procs.append(p)
    for p in procs:
        p.join()

def main():
    job_type = sys.argv[1]
    payload = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    if job_type == "demo_write":
        demo_write(payload)
    elif job_type == "sleep":
        sleep_job(payload)
    elif job_type == "crypto_burn":
        crypto_burn(payload)
    else:
        sleep_job({"seconds": 1})

if __name__ == "__main__":
    main()
PY

cat > "${AGENT_DIR}/app.py" <<'PY'
import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CollectorRegistry, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI(title="proxsyncq-node-agent")
BASE_DIR = Path(__file__).resolve().parent
RABBIT_HOST = os.getenv("RABBIT_HOST", "10.26.0.171")
RABBIT_PORT = int(os.getenv("RABBIT_PORT", "5672"))
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
SHARED_PATH = os.getenv("SHARED_PATH", "/srv/proxsyncq/shared")
RESULTS_DIR = os.path.join(SHARED_PATH, "results")

def tcp_ok(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False

def state():
    return {
        "node": socket.gethostname(),
        "shared_path": SHARED_PATH,
        "shared_path_exists": os.path.exists(SHARED_PATH),
        "shared_path_mounted": os.path.ismount(SHARED_PATH),
        "results_dir": RESULTS_DIR,
        "results_dir_exists": os.path.isdir(RESULTS_DIR),
        "rabbitmq": tcp_ok(RABBIT_HOST, RABBIT_PORT),
        "postgres": tcp_ok(POSTGRES_HOST, POSTGRES_PORT),
        "time": datetime.now(timezone.utc).isoformat(),
    }

@app.get("/health")
def health():
    return JSONResponse(state())

@app.get("/metrics")
def metrics():
    data = state()
    registry = CollectorRegistry()
    Gauge("node_agent_up", "Node agent up", registry=registry).set(1)
    Gauge("node_agent_rabbitmq_ok", "RabbitMQ reachability", registry=registry).set(1 if data["rabbitmq"] else 0)
    Gauge("node_agent_postgres_ok", "Postgres reachability", registry=registry).set(1 if data["postgres"] else 0)
    Gauge("node_agent_shared_path_exists", "Shared path exists", registry=registry).set(1 if data["shared_path_exists"] else 0)
    Gauge("node_agent_shared_path_mounted", "Shared path mounted", registry=registry).set(1 if data["shared_path_mounted"] else 0)
    Gauge("node_agent_results_dir_exists", "Results dir exists", registry=registry).set(1 if data["results_dir_exists"] else 0)
    return PlainTextResponse(generate_latest(registry).decode(), media_type=CONTENT_TYPE_LATEST)

@app.post("/jobs")
def submit_job(body: dict):
    job_type = str(body.get("job_type", "sleep"))
    payload_obj = body.get("payload", {})
    cmd = [sys.executable, str(BASE_DIR / "worker.py"), job_type, json.dumps(payload_obj)]
    proc = subprocess.Popen(
        cmd,
        cwd=str(BASE_DIR),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return JSONResponse({
        "accepted": True,
        "job_type": job_type,
        "pid": proc.pid,
        "payload": payload_obj,
    })
PY

python3 -m venv "${AGENT_DIR}/.venv"
"${AGENT_DIR}/.venv/bin/pip" install --upgrade pip
"${AGENT_DIR}/.venv/bin/pip" install -r "${AGENT_DIR}/requirements.txt"

cat > /tmp/proxsyncq-node-agent.service <<UNIT
[Unit]
Description=ProxSyncQ Node Agent
After=network.target

[Service]
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=${AGENT_DIR}
Environment=RABBIT_HOST=${RABBIT_HOST}
Environment=RABBIT_PORT=${RABBIT_PORT}
Environment=POSTGRES_HOST=${POSTGRES_HOST}
Environment=POSTGRES_PORT=${POSTGRES_PORT}
Environment=SHARED_PATH=${SHARED_PATH}
ExecStart=${AGENT_DIR}/.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=2
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo install -m 0644 /tmp/proxsyncq-node-agent.service "${SERVICE_FILE}"
sudo systemctl daemon-reload
sudo systemctl reset-failed proxsyncq-node-agent || true
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter
sudo systemctl enable --now proxsyncq-node-agent
sudo systemctl restart proxsyncq-node-agent
sleep 4

echo
echo "== host =="
hostname
echo
echo "== services =="
sudo systemctl is-active proxsyncq-node-agent || true
sudo systemctl is-active prometheus-node-exporter || true
echo
echo "== ports =="
sudo ss -ltnp | grep ':8000' || true
sudo ss -ltnp | grep ':9100' || true
echo
echo "== local health =="
curl -fsS http://127.0.0.1:8000/health || true
echo
echo
echo "== local metrics heads =="
curl -fsS http://127.0.0.1:9100/metrics | sed -n '1,3p' || true
echo
echo "== upstream reachability =="
timeout 3 bash -c "</dev/tcp/${RABBIT_HOST}/${RABBIT_PORT}" && echo "RabbitMQ OK" || echo "RabbitMQ FAIL"
timeout 3 bash -c "</dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT}" && echo "Postgres OK" || echo "Postgres FAIL"
echo
echo "== shared path =="
findmnt "${SHARED_PATH}" || true
ls -ld "${SHARED_PATH}" || true
