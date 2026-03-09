#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/proxsyncq}"
RPI_HOST="${RPI_HOST:-10.26.0.170}"
RPI_USER="${RPI_USER:-krishadmin}"

cd "$REPO_DIR"

mkdir -p docs scripts
mkdir -p rpi-control/prometheus
mkdir -p rpi-control/grafana/provisioning/datasources
mkdir -p rpi-control/grafana/provisioning/dashboards
mkdir -p rpi-control/grafana/dashboards
mkdir -p rpi-control/control_ui/templates
mkdir -p rpi-control/control_ui/static

touch docs/storage-options.md docs/networking.md docs/demo.md docs/failure-tests.md docs/architecture.md

if ! grep -q 'PROXSYNCQ_GLUSTER_FAILOVER_RING' docs/storage-options.md 2>/dev/null; then
cat >> docs/storage-options.md <<'DOC'

<!-- PROXSYNCQ_GLUSTER_FAILOVER_RING -->
## Current shared storage failover behavior

ProxSyncQ currently uses a Gluster-backed shared mount at:

/srv/proxsyncq/shared

Each VM mounts the same volume using a primary Gluster server and a backup Gluster server, forming a cyclic failover chain:

- VM1: primary 10.26.0.171, backup 10.26.0.172
- VM2: primary 10.26.0.172, backup 10.26.0.173
- VM3: primary 10.26.0.173, backup 10.26.0.171

This failover pattern is configured in `scripts/setup_node.sh` through `backupvolfile-server` and persisted into `/etc/fstab`.

This means the current storage access path is cyclic from a client perspective:

- VM1 -> VM2
- VM2 -> VM3
- VM3 -> VM1

If a client loses its current Gluster endpoint, it can reconnect through the next server in the ring.

## Current storage visibility goals

The Raspberry Pi control plane will show:

- shared mount presence on each VM
- shared mount usage on each VM
- the cyclic Gluster failover mapping
- failure-test evidence showing the next-hop backup path
DOC
fi

if ! grep -q 'PROXSYNCQ_NETWORKING_CONTROL_PLANE' docs/networking.md 2>/dev/null; then
cat >> docs/networking.md <<'DOC'

<!-- PROXSYNCQ_NETWORKING_CONTROL_PLANE -->
## Raspberry Pi control plane ports

The Raspberry Pi at `10.26.0.170` hosts the monitoring and control plane.

Expected services:

- Prometheus: `9090`
- Grafana: `3000`
- ProxSyncQ Control UI: `8080`
- Node Exporter: `9100`

Application metrics targets:

- VM1 node agent: `10.26.0.171:8000`
- VM2 node agent: `10.26.0.172:8000`
- VM3 node agent: `10.26.0.173:8000`

Host metrics targets:

- Pi node exporter: `10.26.0.170:9100`
- VM1 node exporter: `10.26.0.171:9100`
- VM2 node exporter: `10.26.0.172:9100`
- VM3 node exporter: `10.26.0.173:9100`

## Shared storage failover map

- VM1 mount path `/srv/proxsyncq/shared`: primary `10.26.0.171`, backup `10.26.0.172`
- VM2 mount path `/srv/proxsyncq/shared`: primary `10.26.0.172`, backup `10.26.0.173`
- VM3 mount path `/srv/proxsyncq/shared`: primary `10.26.0.173`, backup `10.26.0.171`
DOC
fi

if ! grep -q 'PROXSYNCQ_DEMO_CONTROL_PLANE' docs/demo.md 2>/dev/null; then
cat >> docs/demo.md <<'DOC'

<!-- PROXSYNCQ_DEMO_CONTROL_PLANE -->
## Raspberry Pi control plane demo

Open the Raspberry Pi control plane UI.

Expected proof:

- cluster health is visible for VM1, VM2, VM3, and Pi
- queue summary is visible
- recent jobs are visible
- CPU, memory, root filesystem, and shared mount usage are visible
- the Gluster failover ring is shown as VM1 -> VM2 -> VM3 -> VM1

## Cyclic storage failover proof

Demonstrate the configured client failover mapping:

- VM1 uses backup server VM2
- VM2 uses backup server VM3
- VM3 uses backup server VM1

Expected proof:

- the shared mount remains visible from a client after the current Gluster endpoint is unavailable
- the cyclic next-hop mapping is documented and visible in the control plane
DOC
fi

if ! grep -q 'PROXSYNCQ_FAILURE_TESTS_RING' docs/failure-tests.md 2>/dev/null; then
cat >> docs/failure-tests.md <<'DOC'

<!-- PROXSYNCQ_FAILURE_TESTS_RING -->
## Gluster client failover ring test

Goal: show that each VM client mount has a next-hop backup Gluster server.

Configuration under test:

- VM1: primary `10.26.0.171`, backup `10.26.0.172`
- VM2: primary `10.26.0.172`, backup `10.26.0.173`
- VM3: primary `10.26.0.173`, backup `10.26.0.171`

Test pattern:

1. confirm `/srv/proxsyncq/shared` is mounted
2. perform a shared read or write
3. make the current Gluster endpoint unavailable
4. verify the client continues through the configured backup server
5. capture evidence in logs, screenshots, and control-plane metrics

Expected outcome:

- shared storage remains reachable from the client
- the cyclic next-hop path matches the configured backup server
DOC
fi

if ! grep -q 'PROXSYNCQ_ARCH_RPI_CONTROL_PLANE' docs/architecture.md 2>/dev/null; then
cat >> docs/architecture.md <<'DOC'

<!-- PROXSYNCQ_ARCH_RPI_CONTROL_PLANE -->
## Raspberry Pi control plane

The Raspberry Pi acts as the ProxSyncQ control and visibility plane.

It hosts:

- Prometheus for metrics collection
- Grafana for dashboards
- a ProxSyncQ Control UI for job submission, queue visibility, cluster health, and Gluster failover visibility

The VM nodes continue to host the distributed worker logic, while the Pi provides a single operational surface for observing and driving the system.
DOC
fi

cat > scripts/install_node_exporter.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
sleep 0.3
sudo systemctl status prometheus-node-exporter --no-pager || true
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
  scp -q scripts/install_node_exporter.sh "${TARGET_USER}@${host}:/tmp/install_node_exporter.sh"
  ssh -q "${TARGET_USER}@${host}" 'bash /tmp/install_node_exporter.sh'
  sleep 0.5
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
  curl -fsS "http://${host}:9100/metrics" | head -n 5 || true
  sleep 0.3
  echo
done
SCRIPT
chmod +x scripts/check_node_exporter_all.sh

cat > rpi-control/docker-compose.yml <<'YAML'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: proxsyncq-prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
  grafana:
    image: grafana/grafana:latest
    container_name: proxsyncq-grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: proxsyncqadmin
      GF_USERS_ALLOW_SIGN_UP: "false"
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
  control_ui:
    build:
      context: ./control_ui
    container_name: proxsyncq-control-ui
    restart: unless-stopped
    environment:
      PROM_URL: http://prometheus:9090
      RABBIT_URL: http://10.26.0.171:15672/api
      RABBIT_USER: proxsyncq
      RABBIT_PASS: proxsyncqpass
      POSTGRES_HOST: 10.26.0.171
      POSTGRES_PORT: "5432"
      POSTGRES_DB: proxsyncq
      POSTGRES_USER: proxsyncq
      POSTGRES_PASS: proxsyncqpass
      NODE_MAP_JSON: |
        [
          {"name":"COE892-RPi","ip":"10.26.0.170","agent_port":null,"node_exporter_port":9100},
          {"name":"COE892-VM-1","ip":"10.26.0.171","agent_port":8000,"node_exporter_port":9100},
          {"name":"COE892-VM-2","ip":"10.26.0.172","agent_port":8000,"node_exporter_port":9100},
          {"name":"COE892-VM-3","ip":"10.26.0.173","agent_port":8000,"node_exporter_port":9100}
        ]
    ports:
      - "8080:8080"
    depends_on:
      - prometheus
volumes:
  prometheus_data:
  grafana_data:
YAML

cat > rpi-control/prometheus/prometheus.yml <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
  - job_name: node_agent
    metrics_path: /metrics
    static_configs:
      - targets:
          - 10.26.0.171:8000
          - 10.26.0.172:8000
          - 10.26.0.173:8000
  - job_name: node_exporter
    static_configs:
      - targets:
          - 10.26.0.170:9100
          - 10.26.0.171:9100
          - 10.26.0.172:9100
          - 10.26.0.173:9100
YAML

cat > rpi-control/grafana/provisioning/datasources/datasource.yml <<'YAML'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
YAML

cat > rpi-control/grafana/provisioning/dashboards/dashboard.yml <<'YAML'
apiVersion: 1

providers:
  - name: proxsyncq
    orgId: 1
    folder: ProxSyncQ
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
YAML

cat > rpi-control/grafana/dashboards/proxsyncq-overview.json <<'JSON'
{
  "annotations": {
    "list": []
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{job=\"node_exporter\",mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "CPU Busy %",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "id": 2,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "100 * (1 - (node_memory_MemAvailable_bytes{job=\"node_exporter\"} / node_memory_MemTotal_bytes{job=\"node_exporter\"}))",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "Memory Used %",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "id": 3,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "100 * (1 - (node_filesystem_avail_bytes{job=\"node_exporter\",mountpoint=\"/\",fstype!~\"rootfs|tmpfs|overlay\"} / node_filesystem_size_bytes{job=\"node_exporter\",mountpoint=\"/\",fstype!~\"rootfs|tmpfs|overlay\"}))",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "Root Filesystem Used %",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "id": 4,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "100 * (1 - (node_filesystem_avail_bytes{job=\"node_exporter\",mountpoint=\"/srv/proxsyncq/shared\"} / node_filesystem_size_bytes{job=\"node_exporter\",mountpoint=\"/srv/proxsyncq/shared\"}))",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "Shared Mount Used %",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 16
      },
      "id": 5,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "sum by (node) (proxsyncq_jobs_completed_total)",
          "legendFormat": "{{node}}",
          "refId": "A"
        }
      ],
      "title": "Jobs Completed Total",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 16
      },
      "id": 6,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "sum by (node) (proxsyncq_jobs_failed_total)",
          "legendFormat": "{{node}}",
          "refId": "A"
        }
      ],
      "title": "Jobs Failed Total",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 24
      },
      "id": 7,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "up{job=\"node_agent\"}",
          "legendFormat": "{{instance}}",
          "refId": "A"
        }
      ],
      "title": "Node Agent Up",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "grafana"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 24
      },
      "id": 8,
      "options": {
        "legend": {
          "displayMode": "list",
          "placement": "bottom"
        }
      },
      "targets": [
        {
          "expr": "sum(proxsyncq_jobs_submitted_total)",
          "legendFormat": "submitted",
          "refId": "A"
        }
      ],
      "title": "Jobs Submitted Total",
      "type": "timeseries"
    }
  ],
  "refresh": "15s",
  "schemaVersion": 39,
  "style": "dark",
  "tags": [
    "proxsyncq"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-3h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "ProxSyncQ Overview",
  "uid": "proxsyncq-overview",
  "version": 1,
  "weekStart": ""
}
JSON

cat > rpi-control/control_ui/requirements.txt <<'REQ'
fastapi==0.115.8
uvicorn[standard]==0.34.0
requests==2.32.3
psycopg2-binary==2.9.10
jinja2==3.1.5
REQ

cat > rpi-control/control_ui/Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
COPY static ./static
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
DOCKER

cat > rpi-control/control_ui/app.py <<'PY'
import json
import os
import time
from datetime import datetime, timezone
from urllib.parse import quote

import psycopg2
import psycopg2.extras
import requests
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

app = FastAPI(title="ProxSyncQ Control UI")
templates = Jinja2Templates(directory="templates")

PROM_URL = os.getenv("PROM_URL", "http://prometheus:9090").rstrip("/")
RABBIT_URL = os.getenv("RABBIT_URL", "http://10.26.0.171:15672/api").rstrip("/")
RABBIT_USER = os.getenv("RABBIT_USER", "proxsyncq")
RABBIT_PASS = os.getenv("RABBIT_PASS", "proxsyncqpass")
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_DB = os.getenv("POSTGRES_DB", "proxsyncq")
POSTGRES_USER = os.getenv("POSTGRES_USER", "proxsyncq")
POSTGRES_PASS = os.getenv("POSTGRES_PASS", "proxsyncqpass")
NODE_MAP_JSON = os.getenv("NODE_MAP_JSON", "")

DEFAULT_NODES = [
    {"name": "COE892-RPi", "ip": "10.26.0.170", "agent_port": None, "node_exporter_port": 9100},
    {"name": "COE892-VM-1", "ip": "10.26.0.171", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-2", "ip": "10.26.0.172", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-3", "ip": "10.26.0.173", "agent_port": 8000, "node_exporter_port": 9100},
]

FAILOVER_RING = [
    {"client": "COE892-VM-1", "primary": "10.26.0.171", "backup": "10.26.0.172"},
    {"client": "COE892-VM-2", "primary": "10.26.0.172", "backup": "10.26.0.173"},
    {"client": "COE892-VM-3", "primary": "10.26.0.173", "backup": "10.26.0.171"},
]

def utc_now():
    return datetime.now(timezone.utc).isoformat()

def get_nodes():
    if not NODE_MAP_JSON.strip():
        return DEFAULT_NODES
    try:
        return json.loads(NODE_MAP_JSON)
    except Exception:
        return DEFAULT_NODES

def db_conn():
    return psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASS,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )

def safe_get_json(url, auth=None, timeout=2.0):
    try:
        response = requests.get(url, auth=auth, timeout=timeout)
        response.raise_for_status()
        return response.json(), None
    except Exception as exc:
        return None, str(exc)

def prom_query(expr):
    try:
        response = requests.get(
            f"{PROM_URL}/api/v1/query",
            params={"query": expr},
            timeout=3.0,
        )
        response.raise_for_status()
        payload = response.json()
        return payload.get("data", {}).get("result", [])
    except Exception:
        return []

def prom_value(expr, instance):
    results = prom_query(expr)
    for item in results:
        if item.get("metric", {}).get("instance") == instance:
            try:
                return round(float(item["value"][1]), 2)
            except Exception:
                return None
    return None

def get_node_health(node):
    if not node.get("agent_port"):
        return {
            "reachable": True,
            "status_code": 200,
            "data": {
                "node": node["name"],
                "rabbitmq": None,
                "postgres": None,
                "shared_path_exists": None,
                "time": utc_now(),
            },
            "error": None,
        }
    url = f"http://{node['ip']}:{node['agent_port']}/health"
    try:
        response = requests.get(url, timeout=2.0)
        data = response.json()
        return {
            "reachable": response.status_code == 200,
            "status_code": response.status_code,
            "data": data,
            "error": None,
        }
    except Exception as exc:
        return {
            "reachable": False,
            "status_code": 0,
            "data": None,
            "error": str(exc),
        }

def get_queue_summary():
    vhost = quote("/", safe="")
    queue_name = quote("proxsyncq_jobs", safe="")
    url = f"{RABBIT_URL}/queues/{vhost}/{queue_name}"
    data, error = safe_get_json(url, auth=(RABBIT_USER, RABBIT_PASS), timeout=3.0)
    if error or not data:
        return {
            "name": "proxsyncq_jobs",
            "state": "unknown",
            "messages": None,
            "ready": None,
            "unacked": None,
            "consumers": None,
            "error": error,
        }
    return {
        "name": data.get("name"),
        "state": data.get("state"),
        "messages": data.get("messages"),
        "ready": data.get("messages_ready"),
        "unacked": data.get("messages_unacknowledged"),
        "consumers": data.get("consumers"),
        "error": None,
    }

def get_recent_jobs(limit=25):
    try:
        with db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                      job_id,
                      job_type,
                      state,
                      claimed_by,
                      attempt_count,
                      submitted_by,
                      submitted_at
                    FROM jobs
                    ORDER BY submitted_at DESC
                    LIMIT %s
                    """,
                    (limit,),
                )
                return cur.fetchall()
    except Exception:
        return []

def get_node_metrics(node):
    instance = f"{node['ip']}:{node['node_exporter_port']}"
    cpu = prom_value('100 - (avg by (instance) (rate(node_cpu_seconds_total{job="node_exporter",mode="idle"}[5m])) * 100)', instance)
    mem = prom_value('100 * (1 - (node_memory_MemAvailable_bytes{job="node_exporter"} / node_memory_MemTotal_bytes{job="node_exporter"}))', instance)
    root_used = prom_value('100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"}))', instance)
    shared_used = prom_value('100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"}))', instance)
    load1 = prom_value('node_load1{job="node_exporter"}', instance)
    return {
        "cpu": cpu,
        "mem": mem,
        "root_used": root_used,
        "shared_used": shared_used,
        "load1": load1,
    }

@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    nodes = get_nodes()
    health_rows = []
    for node in nodes:
        health_rows.append({
            "node": node,
            "health": get_node_health(node),
            "metrics": get_node_metrics(node),
        })
        time.sleep(0.05)
    queue_summary = get_queue_summary()
    recent_jobs = get_recent_jobs()
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "generated_at": utc_now(),
            "nodes": nodes,
            "health_rows": health_rows,
            "queue_summary": queue_summary,
            "recent_jobs": recent_jobs,
            "failover_ring": FAILOVER_RING,
            "message": request.query_params.get("message", ""),
            "status": request.query_params.get("status", ""),
        },
    )

@app.post("/submit")
def submit(
    target_ip: str = Form(...),
    job_type: str = Form(...),
    count: int = Form(1),
    message_text: str = Form("hello from rpi control"),
    sleep_seconds: int = Form(3),
):
    count = max(1, min(int(count), 50))
    sent = 0
    errors = []
    payload = {"message": message_text} if job_type == "demo_write" else {"seconds": sleep_seconds}
    for _ in range(count):
        try:
            response = requests.post(
                f"http://{target_ip}:8000/jobs",
                json={"job_type": job_type, "payload": payload},
                timeout=3.0,
            )
            response.raise_for_status()
            sent += 1
        except Exception as exc:
            errors.append(str(exc))
        time.sleep(0.1)
    if errors:
        return RedirectResponse(
            url=f"/?status=partial&message=sent:{sent},errors:{len(errors)}",
            status_code=303,
        )
    return RedirectResponse(
        url=f"/?status=ok&message=submitted:{sent}",
        status_code=303,
    )
PY

cat > rpi-control/control_ui/templates/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>ProxSyncQ Control Plane</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: Arial, sans-serif; margin: 0; background: #0b1220; color: #e5e7eb; }
    .wrap { max-width: 1400px; margin: 0 auto; padding: 20px; }
    h1, h2, h3 { margin: 0 0 12px 0; }
    .grid { display: grid; gap: 16px; }
    .cards-4 { grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
    .cards-2 { grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); }
    .card { background: #111827; border: 1px solid #1f2937; border-radius: 12px; padding: 16px; }
    .good { color: #34d399; }
    .warn { color: #fbbf24; }
    .bad { color: #f87171; }
    .muted { color: #9ca3af; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 8px 10px; border-bottom: 1px solid #1f2937; text-align: left; font-size: 14px; }
    .pill { display: inline-block; padding: 4px 10px; border-radius: 999px; font-size: 12px; background: #1f2937; }
    input, select, button { width: 100%; padding: 10px; border-radius: 8px; border: 1px solid #374151; background: #0f172a; color: #e5e7eb; }
    button { background: #2563eb; cursor: pointer; }
    .small { font-size: 13px; }
    .mono { font-family: Consolas, monospace; }
    .row { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
    .ring { display: grid; gap: 10px; }
    .ring-item { background: #0f172a; border: 1px solid #243041; padding: 10px; border-radius: 10px; }
    a { color: #93c5fd; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>ProxSyncQ Raspberry Pi Control Plane</h1>
      <div class="small muted">Generated at {{ generated_at }}</div>
      {% if message %}
      <div style="margin-top:10px" class="pill">{{ status }} {{ message }}</div>
      {% endif %}
      <div style="margin-top:12px" class="small">
        <a href="http://10.26.0.170:3000" target="_blank">Grafana</a> |
        <a href="http://10.26.0.170:9090" target="_blank">Prometheus</a> |
        <a href="http://10.26.0.171:15672" target="_blank">RabbitMQ UI</a>
      </div>
    </div>

    <div class="grid cards-2" style="margin-top:16px;">
      <div class="card">
        <h2>Submit Jobs</h2>
        <form method="post" action="/submit">
          <div class="row">
            <div>
              <label class="small">Target node</label>
              <select name="target_ip">
                <option value="10.26.0.171">COE892-VM-1</option>
                <option value="10.26.0.172">COE892-VM-2</option>
                <option value="10.26.0.173">COE892-VM-3</option>
              </select>
            </div>
            <div>
              <label class="small">Job type</label>
              <select name="job_type">
                <option value="demo_write">demo_write</option>
                <option value="sleep">sleep</option>
              </select>
            </div>
            <div>
              <label class="small">Count</label>
              <input type="number" name="count" value="5" min="1" max="50">
            </div>
            <div>
              <label class="small">Message</label>
              <input type="text" name="message_text" value="hello from rpi control">
            </div>
            <div>
              <label class="small">Sleep seconds</label>
              <input type="number" name="sleep_seconds" value="3" min="1" max="30">
            </div>
          </div>
          <div style="margin-top:12px;">
            <button type="submit">Submit</button>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Queue Summary</h2>
        <table>
          <tr><th>Name</th><td class="mono">{{ queue_summary.name }}</td></tr>
          <tr><th>State</th><td>{{ queue_summary.state }}</td></tr>
          <tr><th>Total messages</th><td>{{ queue_summary.messages }}</td></tr>
          <tr><th>Ready</th><td>{{ queue_summary.ready }}</td></tr>
          <tr><th>Unacked</th><td>{{ queue_summary.unacked }}</td></tr>
          <tr><th>Consumers</th><td>{{ queue_summary.consumers }}</td></tr>
          <tr><th>Error</th><td class="bad">{{ queue_summary.error }}</td></tr>
        </table>
      </div>
    </div>

    <div class="grid cards-4" style="margin-top:16px;">
      {% for row in health_rows %}
      <div class="card">
        <h3>{{ row.node.name }}</h3>
        <div class="small muted mono">{{ row.node.ip }}</div>
        <div style="margin-top:8px;" class="{% if row.health.reachable %}good{% else %}bad{% endif %}">
          {% if row.health.reachable %}reachable{% else %}unreachable{% endif %}
        </div>
        <table style="margin-top:8px;">
          <tr><th>CPU %</th><td>{{ row.metrics.cpu }}</td></tr>
          <tr><th>Memory %</th><td>{{ row.metrics.mem }}</td></tr>
          <tr><th>Load 1m</th><td>{{ row.metrics.load1 }}</td></tr>
          <tr><th>Root used %</th><td>{{ row.metrics.root_used }}</td></tr>
          <tr><th>Shared used %</th><td>{{ row.metrics.shared_used }}</td></tr>
          <tr><th>RabbitMQ</th><td>{{ row.health.data.rabbitmq if row.health.data else 'n/a' }}</td></tr>
          <tr><th>Postgres</th><td>{{ row.health.data.postgres if row.health.data else 'n/a' }}</td></tr>
          <tr><th>Shared path</th><td>{{ row.health.data.shared_path_exists if row.health.data else 'n/a' }}</td></tr>
        </table>
      </div>
      {% endfor %}
    </div>

    <div class="grid cards-2" style="margin-top:16px;">
      <div class="card">
        <h2>Gluster Failover Ring</h2>
        <div class="ring">
          {% for item in failover_ring %}
          <div class="ring-item">
            <div><strong>{{ item.client }}</strong></div>
            <div class="small">primary: <span class="mono">{{ item.primary }}</span></div>
            <div class="small">backup: <span class="mono">{{ item.backup }}</span></div>
          </div>
          {% endfor %}
        </div>
      </div>

      <div class="card">
        <h2>Recent Jobs</h2>
        <table>
          <thead>
            <tr>
              <th>Job type</th>
              <th>State</th>
              <th>Claimed by</th>
              <th>Attempts</th>
              <th>Submitted by</th>
            </tr>
          </thead>
          <tbody>
            {% for job in recent_jobs %}
            <tr>
              <td class="mono">{{ job.job_type }}</td>
              <td>{{ job.state }}</td>
              <td>{{ job.claimed_by }}</td>
              <td>{{ job.attempt_count }}</td>
              <td>{{ job.submitted_by }}</td>
            </tr>
            {% endfor %}
          </tbody>
        </table>
      </div>
    </div>
  </div>
</body>
</html>
HTML

cat > rpi-control/bootstrap_rpi_stack.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose-v2 ca-certificates curl
sudo systemctl enable --now docker
sleep 0.5
sudo docker compose up -d --build
SCRIPT
chmod +x rpi-control/bootstrap_rpi_stack.sh

cat > scripts/push_rpi_stack.sh <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-$RPI_HOST}"
RPI_USER="${RPI_USER:-$RPI_USER}"
REMOTE_DIR="\${REMOTE_DIR:-/home/\${RPI_USER}/proxsyncq-rpi}"

rsync -av rpi-control/ "\${RPI_USER}@\${RPI_HOST}:\${REMOTE_DIR}/"
sleep 0.5
ssh "\${RPI_USER}@\${RPI_HOST}" "cd \${REMOTE_DIR} && bash bootstrap_rpi_stack.sh"
SCRIPT
chmod +x scripts/push_rpi_stack.sh

cat > scripts/check_rpi_control_plane.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RPI_HOST="${RPI_HOST:-10.26.0.170}"

curl -fsS "http://${RPI_HOST}:8080" > /dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS "http://${RPI_HOST}:9090/-/healthy" && echo || true
curl -fsS "http://${RPI_HOST}:3000/api/health" && echo || true
SCRIPT
chmod +x scripts/check_rpi_control_plane.sh

echo "stage complete"
echo "generated:"
echo "  scripts/install_node_exporter.sh"
echo "  scripts/install_node_exporter_all.sh"
echo "  scripts/check_node_exporter_all.sh"
echo "  scripts/push_rpi_stack.sh"
echo "  scripts/check_rpi_control_plane.sh"
echo "  rpi-control/"
