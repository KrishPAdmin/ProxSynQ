#!/usr/bin/env bash
set -euo pipefail

PI_HOST="10.26.0.170"
PI_USER="krishadmin"
NODES=("10.26.0.171" "10.26.0.172" "10.26.0.173")

cd "$HOME/proxsyncq"

mkdir -p rpi-control/control_ui/templates
mkdir -p rpi-control/control_ui/static

cat > rpi-control/control_ui/requirements.txt <<'REQ'
fastapi==0.115.8
uvicorn[standard]==0.34.0
requests==2.32.3
psycopg2-binary==2.9.10
jinja2==3.1.5
python-multipart==0.0.20
itsdangerous==2.2.0
REQ

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
      UI_USERNAME: krishadmin
      UI_PASSWORD: KrishAdmin@2003
      SESSION_SECRET: proxsyncq-session-secret-2026
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
from starlette.middleware.sessions import SessionMiddleware

PROM_URL = os.getenv("PROM_URL", "http://prometheus:9090").rstrip("/")
RABBIT_URL = os.getenv("RABBIT_URL", "http://10.26.0.171:15672/api").rstrip("/")
RABBIT_USER = os.getenv("RABBIT_USER", "proxsyncq")
RABBIT_PASS = os.getenv("RABBIT_PASS", "proxsyncqpass")
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_DB = os.getenv("POSTGRES_DB", "proxsyncq")
POSTGRES_USER = os.getenv("POSTGRES_USER", "proxsyncq")
POSTGRES_PASS = os.getenv("POSTGRES_PASS", "proxsyncqpass")
UI_USERNAME = os.getenv("UI_USERNAME", "krishadmin")
UI_PASSWORD = os.getenv("UI_PASSWORD", "KrishAdmin@2003")
SESSION_SECRET = os.getenv("SESSION_SECRET", "proxsyncq-session-secret-2026")
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

app = FastAPI(title="ProxSyncQ Control UI")
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET, max_age=60 * 60 * 10, same_site="lax")
templates = Jinja2Templates(directory="templates")


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


def prom_query(expr):
    try:
        response = requests.get(f"{PROM_URL}/api/v1/query", params={"query": expr}, timeout=4.0)
        response.raise_for_status()
        return response.json().get("data", {}).get("result", [])
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


def prom_up(job, instance):
    results = prom_query(f'up{{job="{job}"}}')
    for item in results:
        if item.get("metric", {}).get("instance") == instance:
            try:
                return int(float(item["value"][1])) == 1
            except Exception:
                return False
    return False


def rabbit_queue_summary():
    vhost = quote("/", safe="")
    queue_name = quote("proxsyncq_jobs", safe="")
    url = f"{RABBIT_URL}/queues/{vhost}/{queue_name}"
    try:
        response = requests.get(url, auth=(RABBIT_USER, RABBIT_PASS), timeout=4.0)
        response.raise_for_status()
        data = response.json()
        return {
            "name": data.get("name"),
            "state": data.get("state"),
            "messages": data.get("messages"),
            "ready": data.get("messages_ready"),
            "unacked": data.get("messages_unacknowledged"),
            "consumers": data.get("consumers"),
            "error": "",
        }
    except Exception as exc:
        return {
            "name": "proxsyncq_jobs",
            "state": "unknown",
            "messages": None,
            "ready": None,
            "unacked": None,
            "consumers": None,
            "error": str(exc),
        }


def recent_jobs(limit=30):
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


def get_health(node):
    if not node.get("agent_port"):
        return {
            "reachable": True,
            "status_code": 200,
            "data": {
                "node": node["name"],
                "rabbitmq": None,
                "postgres": None,
                "shared_path_exists": None,
            },
            "error": "",
        }
    try:
        response = requests.get(f"http://{node['ip']}:{node['agent_port']}/health", timeout=3.0)
        return {
            "reachable": response.status_code == 200,
            "status_code": response.status_code,
            "data": response.json(),
            "error": "",
        }
    except Exception as exc:
        return {
            "reachable": False,
            "status_code": 0,
            "data": None,
            "error": str(exc),
        }


def get_metrics(node):
    exporter_instance = f"{node['ip']}:{node['node_exporter_port']}"
    agent_instance = f"{node['ip']}:{node['agent_port']}" if node.get("agent_port") else None

    exporter_up = prom_up("node_exporter", exporter_instance)
    agent_up = prom_up("node_agent", agent_instance) if agent_instance else None

    if not exporter_up:
        return {
            "exporter_up": False,
            "agent_up": agent_up,
            "cpu": None,
            "mem": None,
            "root_used": None,
            "shared_used": None,
            "load1": None,
        }

    return {
        "exporter_up": True,
        "agent_up": agent_up,
        "cpu": prom_value('100 - (avg by (instance) (rate(node_cpu_seconds_total{job="node_exporter",mode="idle"}[5m])) * 100)', exporter_instance),
        "mem": prom_value('100 * (1 - (node_memory_MemAvailable_bytes{job="node_exporter"} / node_memory_MemTotal_bytes{job="node_exporter"}))', exporter_instance),
        "root_used": prom_value('100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"}))', exporter_instance),
        "shared_used": prom_value('100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"}))', exporter_instance),
        "load1": prom_value('node_load1{job="node_exporter"}', exporter_instance),
    }


def is_authed(request: Request):
    return request.session.get("auth_user") == UI_USERNAME


def need_auth(request: Request):
    if not is_authed(request):
        return RedirectResponse(url="/login", status_code=303)
    return None


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    if is_authed(request):
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse("login.html", {"request": request, "error": ""})


@app.post("/login", response_class=HTMLResponse)
def login_submit(request: Request, username: str = Form(...), password: str = Form(...)):
    if username == UI_USERNAME and password == UI_PASSWORD:
        request.session["auth_user"] = UI_USERNAME
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse("login.html", {"request": request, "error": "Invalid username or password"})


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    redirect = need_auth(request)
    if redirect:
        return redirect

    nodes = get_nodes()
    rows = []
    for node in nodes:
        rows.append({
            "node": node,
            "health": get_health(node),
            "metrics": get_metrics(node),
        })
        time.sleep(0.04)

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "username": request.session.get("auth_user", ""),
            "queue": rabbit_queue_summary(),
            "rows": rows,
            "jobs": recent_jobs(),
            "failover_ring": FAILOVER_RING,
            "message": request.query_params.get("message", ""),
            "status": request.query_params.get("status", ""),
        },
    )


@app.post("/submit")
def submit_job(
    request: Request,
    target_ip: str = Form(...),
    job_type: str = Form(...),
    count: int = Form(1),
    message_text: str = Form("hello from rpi control"),
    sleep_seconds: int = Form(3),
):
    redirect = need_auth(request)
    if redirect:
        return redirect

    count = max(1, min(int(count), 50))
    payload = {"message": message_text} if job_type == "demo_write" else {"seconds": max(1, min(int(sleep_seconds), 30))}
    sent = 0
    errors = 0

    for _ in range(count):
        try:
            response = requests.post(
                f"http://{target_ip}:8000/jobs",
                json={"job_type": job_type, "payload": payload},
                timeout=4.0,
            )
            response.raise_for_status()
            sent += 1
        except Exception:
            errors += 1
        time.sleep(0.08)

    if errors:
        return RedirectResponse(url=f"/?status=partial&message=sent:{sent},errors:{errors}", status_code=303)
    return RedirectResponse(url=f"/?status=ok&message=submitted:{sent}", status_code=303)
PY

cat > rpi-control/control_ui/templates/login.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ProxSyncQ Login</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;600;700;900&display=swap" rel="stylesheet" />
  <style>
    :root {
      --accent: #20fd14;
      --bg: #000;
      --glassBg: rgba(12, 14, 16, 0.80);
      --glassBorder: rgba(255, 255, 255, 0.10);
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
      --textSoft: rgb(190, 190, 190);
      --titleShadow: 0 12px 30px rgba(0, 0, 0, 0.55);
    }
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    html { font-size: 62.5%; font-family: "Source Sans 3", system-ui, sans-serif; }
    body {
      min-height: 100vh;
      color: #fff;
      background-color: var(--bg);
      overflow-x: hidden;
      position: relative;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -2;
      background:
        linear-gradient(to right, rgba(0, 0, 0, 0.80), rgba(37, 44, 49, 0.80)),
        url("https://krishadmin.com/svg/common-bg.svg");
      background-position: center;
      background-size: cover;
    }
    body::after {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -1;
      background-image: url("https://krishadmin.com/pics/LimeK.png");
      background-repeat: no-repeat;
      background-position: right 4% bottom 6%;
      background-size: clamp(180px, 22vw, 360px);
      opacity: 0.08;
    }
    .wrap {
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2.4rem;
    }
    .card {
      width: min(92vw, 52rem);
      background: var(--glassBg);
      border: 1px solid var(--glassBorder);
      border-radius: 18px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      padding: 3.2rem;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 1.4rem;
      margin-bottom: 2.2rem;
    }
    .brand img {
      width: 6rem;
      height: 6rem;
      border-radius: 999px;
      object-fit: cover;
      background: var(--accent);
    }
    h1 {
      font-size: 3.2rem;
      font-weight: 900;
      letter-spacing: 2px;
      text-transform: uppercase;
      text-shadow: var(--titleShadow);
    }
    .sub {
      margin-top: 0.8rem;
      color: var(--textSoft);
      font-size: 1.7rem;
      line-height: 1.6;
    }
    .field {
      margin-top: 1.6rem;
    }
    label {
      display: block;
      font-size: 1.4rem;
      letter-spacing: 1px;
      text-transform: uppercase;
      font-weight: 900;
      color: var(--accent);
      margin-bottom: 0.8rem;
    }
    input {
      width: 100%;
      padding: 1.3rem 1.4rem;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.12);
      background: rgba(255,255,255,0.06);
      color: #fff;
      font-size: 1.6rem;
    }
    button {
      width: 100%;
      margin-top: 2rem;
      padding: 1.4rem 1.6rem;
      border: 0;
      border-radius: 10px;
      background: var(--accent);
      color: #000;
      font-size: 1.6rem;
      font-weight: 900;
      text-transform: uppercase;
      letter-spacing: 1px;
      cursor: pointer;
      box-shadow: var(--shadow);
    }
    .error {
      margin-top: 1.2rem;
      color: #ff9494;
      font-size: 1.5rem;
      font-weight: 700;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="brand">
        <img src="https://krishadmin.com/pics/Krish_Patel_Face.jpg" alt="Krish Patel" />
        <div>
          <h1>ProxSyncQ Login</h1>
          <div class="sub">Raspberry Pi control plane access for the COE892 cluster</div>
        </div>
      </div>
      <form method="post" action="/login">
        <div class="field">
          <label for="username">Username</label>
          <input id="username" name="username" type="text" autocomplete="username" required />
        </div>
        <div class="field">
          <label for="password">Password</label>
          <input id="password" name="password" type="password" autocomplete="current-password" required />
        </div>
        <button type="submit">Sign In</button>
        {% if error %}
        <div class="error">{{ error }}</div>
        {% endif %}
      </form>
    </div>
  </div>
</body>
</html>
HTML

cat > rpi-control/control_ui/templates/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ProxSyncQ Control Plane</title>
  <link rel="icon" href="https://krishadmin.com/pics/LimeK.png" type="image/png" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;600;700;900&display=swap" rel="stylesheet" />
  <style>
    :root {
      --accent: #20fd14;
      --bg: #000;
      --glassBg: rgba(12, 14, 16, 0.78);
      --glassBorder: rgba(255, 255, 255, 0.10);
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
      --textSoft: rgb(190, 190, 190);
      --textSub: rgb(149, 149, 149);
      --textOnGlass: #eee;
      --titleShadow: 0 12px 30px rgba(0, 0, 0, 0.55);
      --headerH: 9rem;
      --max: 120rem;
    }
    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
    html {
      font-size: 62.5%;
      scroll-behavior: smooth;
      font-family: "Source Sans 3", system-ui, sans-serif;
    }
    body {
      background-color: var(--bg);
      color: #fff;
      line-height: 1.5;
      overflow-x: hidden;
      position: relative;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -2;
      background:
        linear-gradient(to right, rgba(0, 0, 0, 0.80), rgba(37, 44, 49, 0.80)),
        url("https://krishadmin.com/svg/common-bg.svg");
      background-position: center;
      background-size: cover;
    }
    body::after {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -1;
      background-image: url("https://krishadmin.com/pics/LimeK.png");
      background-repeat: no-repeat;
      background-position: right 4% bottom 6%;
      background-size: clamp(180px, 22vw, 360px);
      opacity: 0.08;
    }
    a { text-decoration: none; color: inherit; }
    img { display: block; max-width: 100%; }
    button, input, select { font: inherit; }
    .main-container { max-width: var(--max); margin: auto; width: 92%; }
    .glass-panel {
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border: 1px solid var(--glassBorder);
      border-radius: 18px;
      box-shadow: var(--shadow);
    }
    .header {
      position: fixed;
      width: 100%;
      z-index: 1000;
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border-bottom: 1px solid var(--glassBorder);
    }
    .header__content {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1rem 5rem;
      min-height: var(--headerH);
    }
    .header__logo-container {
      display: flex;
      align-items: center;
      color: var(--accent);
      gap: 1.4rem;
    }
    .header__logo-img-cont {
      width: 7rem;
      height: 7rem;
      border-radius: 50px;
      overflow: hidden;
      background: var(--accent);
    }
    .header__logo-img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }
    .header__logo-sub {
      font-size: 1.8rem;
      text-transform: uppercase;
      font-weight: 900;
      letter-spacing: 1px;
    }
    .header__links {
      display: flex;
      gap: 0.8rem;
      align-items: center;
    }
    .header__link {
      padding: 1.4rem 1.6rem;
      display: inline-block;
      font-size: 1.4rem;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      border-radius: 10px;
      transition: background 0.2s ease, filter 0.2s ease;
    }
    .header__link:hover {
      filter: brightness(1.10);
      background: rgba(32, 253, 20, 0.10);
    }
    .site-socials {
      position: fixed;
      left: 0;
      top: 50%;
      transform: translateY(-50%);
      z-index: 900;
      border: 2px solid rgba(238, 238, 238, 0.85);
      border-left: 0;
      background: rgba(0, 0, 0, 0.30);
      backdrop-filter: blur(6px);
      -webkit-backdrop-filter: blur(6px);
    }
    .site-socials__link {
      width: 5.2rem;
      height: 5.2rem;
      display: flex;
      align-items: center;
      justify-content: center;
      border-bottom: 2px solid rgba(238, 238, 238, 0.85);
      transition: background 0.2s ease;
    }
    .site-socials__link:hover { background: rgba(255, 255, 255, 0.10); }
    .site-socials__link--last { border-bottom: 0; }
    .site-socials__icon, .main-footer__icon {
      width: 2.8rem;
      height: 2.8rem;
      object-fit: contain;
    }
    .home-hero {
      min-height: 68vh;
      padding-top: var(--headerH);
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .home-hero__content {
      max-width: 96rem;
      width: 92%;
      text-align: center;
      padding: 8rem 0 6rem 0;
    }
    .heading-primary {
      color: #fff;
      font-size: clamp(3.6rem, 5vw, 6.3rem);
      text-transform: uppercase;
      letter-spacing: 3px;
      text-align: center;
      text-shadow: var(--titleShadow);
    }
    .text-primary {
      color: #fff;
      font-size: clamp(1.9rem, 2.2vw, 2.5rem);
      text-align: center;
      width: 100%;
      line-height: 1.6;
      text-shadow: 0 10px 24px rgba(0, 0, 0, 0.45);
      margin-top: 2.4rem;
    }
    .btn {
      background: #000;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 2px;
      display: inline-block;
      font-weight: 900;
      border-radius: 8px;
      box-shadow: var(--shadow);
      transition: transform 0.2s ease, filter 0.2s ease, color 0.2s ease;
      border: 0;
      cursor: pointer;
    }
    .btn:hover { transform: translateY(-2px); filter: brightness(1.04); color: #fff; }
    .btn--bg { padding: 1.5rem 4rem; font-size: 1.7rem; }
    .btn--med { padding: 1.2rem 2.4rem; font-size: 1.4rem; }
    .btn--theme { background: var(--accent); color: #000; }
    .section {
      padding: 4rem 0 8rem 0;
    }
    .section__panel {
      max-width: 118rem;
      margin: 0 auto 2.4rem auto;
      padding: 2.6rem;
    }
    .heading-sec__main {
      display: block;
      font-size: clamp(2.6rem, 3vw, 4rem);
      text-transform: uppercase;
      letter-spacing: 3px;
      text-align: center;
      margin-bottom: 3.5rem;
      position: relative;
      text-shadow: var(--titleShadow);
      color: #fff;
    }
    .heading-sec__main::after {
      content: "";
      position: absolute;
      top: calc(100% + 1.5rem);
      height: 5px;
      width: 3rem;
      background: var(--accent);
      left: 50%;
      transform: translateX(-50%);
      border-radius: 999px;
    }
    .grid-2 {
      display: grid;
      grid-template-columns: 1.1fr 0.9fr;
      gap: 2rem;
    }
    .grid-3 {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 2rem;
    }
    .node-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 2rem;
    }
    .card {
      background: rgba(255,255,255,0.04);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 16px;
      padding: 1.8rem;
      box-shadow: var(--shadow);
    }
    .card h3 {
      font-size: 2rem;
      font-weight: 900;
      margin-bottom: 0.4rem;
      color: #fff;
      text-shadow: var(--titleShadow);
    }
    .muted { color: var(--textSub); }
    .mono { font-family: Consolas, monospace; }
    .pill {
      display: inline-block;
      padding: 0.5rem 1rem;
      border-radius: 999px;
      font-size: 1.2rem;
      font-weight: 900;
      letter-spacing: 1px;
      text-transform: uppercase;
      margin-right: 0.8rem;
      margin-top: 0.8rem;
    }
    .good { background: rgba(32,253,20,0.18); color: #9aff8f; }
    .warn { background: rgba(251,191,36,0.18); color: #ffd86f; }
    .bad { background: rgba(248,113,113,0.18); color: #ff9a9a; }
    .stat-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 1rem;
      margin-top: 1.6rem;
    }
    .stat {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 1.2rem;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .stat__label {
      font-size: 1.2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--textSub);
      font-weight: 900;
    }
    .stat__value {
      margin-top: 0.5rem;
      font-size: 2.1rem;
      font-weight: 900;
      color: #fff;
    }
    .form-grid {
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      gap: 1rem;
      margin-top: 1.6rem;
    }
    label {
      display: block;
      font-size: 1.2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--accent);
      font-weight: 900;
      margin-bottom: 0.6rem;
    }
    input, select {
      width: 100%;
      padding: 1.1rem 1.2rem;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.12);
      background: rgba(255,255,255,0.06);
      color: #fff;
      font-size: 1.5rem;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 1.2rem;
    }
    th, td {
      padding: 1rem;
      border-bottom: 1px solid rgba(255,255,255,0.08);
      text-align: left;
      font-size: 1.4rem;
      vertical-align: top;
    }
    th {
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      font-size: 1.2rem;
    }
    .ring-item {
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 14px;
      padding: 1.4rem;
      margin-top: 1.2rem;
    }
    .ring-item:first-child { margin-top: 0; }
    .main-footer {
      padding: 0 0 6rem 0;
    }
    .footer__panel {
      max-width: 118rem;
      margin: 0 auto;
      padding: 2.6rem;
    }
    .main-footer__upper {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 4rem;
      margin-bottom: 2.2rem;
    }
    .heading-sm {
      color: #fff;
      font-size: 2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      text-shadow: 0 10px 24px rgba(0, 0, 0, 0.45);
    }
    .main-footer__social-cont {
      display: flex;
      gap: 1.2rem;
      margin-top: 1.4rem;
      flex-wrap: wrap;
    }
    .main-footer__short-desc, .footer-emails {
      margin-top: 1.4rem;
      font-size: 1.7rem;
      color: var(--textSoft);
      line-height: 1.7;
    }
    .main-footer__lower {
      padding-top: 2.2rem;
      border-top: 1px solid rgba(255, 255, 255, 0.12);
      font-size: 1.5rem;
      color: var(--textSub);
      text-align: center;
      font-weight: 700;
      letter-spacing: 1px;
    }
    @media (max-width: 1100px) {
      .grid-2, .grid-3, .node-grid, .main-footer__upper { grid-template-columns: 1fr; }
      .form-grid { grid-template-columns: 1fr 1fr; }
    }
    @media (max-width: 700px) {
      .header__content { padding: 1rem 2rem; }
      .header__links { display: none; }
      .site-socials { display: none; }
      .form-grid { grid-template-columns: 1fr; }
      .stat-grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header class="header">
    <div class="header__content">
      <a class="header__logo-container" href="https://krishadmin.com" aria-label="Home">
        <div class="header__logo-img-cont">
          <img src="https://krishadmin.com/pics/Krish_Patel_Face.jpg" alt="Krish Patel" class="header__logo-img" />
        </div>
        <span class="header__logo-sub">Krish Patel</span>
      </a>
      <div class="header__links">
        <a href="https://krishadmin.com" class="header__link">Home</a>
        <a href="https://co-op.krishadmin.com" class="header__link">Co-op</a>
        <a href="https://notes.krishadmin.com" class="header__link">Notes</a>
        <a href="https://server.krishadmin.com" class="header__link">Servers</a>
        <a href="https://contact.krishadmin.com" class="header__link">Contact</a>
        <a href="/logout" class="header__link">Logout</a>
      </div>
    </div>
  </header>

  <aside class="site-socials" aria-label="Social links">
    <a href="https://www.linkedin.com/in/krishadmin" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="LinkedIn">
      <img src="https://krishadmin.com/pics/Icon-LinkedIn.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://discord.com/users/290130274010923010" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="Discord">
      <img src="https://krishadmin.com/pics/Icon-Discord.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://github.com/KrishPAdmin" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
      <img src="https://krishadmin.com/pics/Icon-Github.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://www.youtube.com/channel/UCPOpecefAO1ub4KB50wDmjg" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="YouTube">
      <img src="https://krishadmin.com/pics/Icon-Youtube.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://www.instagram.com/krish_admin/" class="site-socials__link site-socials__link--last" target="_blank" rel="noopener noreferrer" aria-label="Instagram">
      <img src="https://krishadmin.com/pics/Icon-Instagram.png" alt="" class="site-socials__icon" />
    </a>
  </aside>

  <section class="home-hero">
    <div class="home-hero__content">
      <h1 class="heading-primary">ProxSyncQ Control Plane</h1>
      <div class="text-primary">
        Raspberry Pi hosted cluster operations dashboard for VM1, VM2, VM3, queue orchestration, Gluster failover visibility, and shared-storage monitoring.
      </div>
      <div style="margin-top:3rem;">
        <a href="http://10.26.0.170:3000" class="btn btn--bg btn--theme" target="_blank" rel="noopener noreferrer">Open Grafana</a>
      </div>
      {% if message %}
      <div style="margin-top:2rem;">
        <span class="pill {% if status == 'ok' %}good{% elif status == 'partial' %}warn{% else %}bad{% endif %}">{{ status }} {{ message }}</span>
      </div>
      {% endif %}
    </div>
  </section>

  <section class="section">
    <div class="main-container">
      <div class="glass-panel section__panel">
        <span class="heading-sec__main">Cluster Operations</span>
        <div class="grid-2">
          <div class="card">
            <h3>Submit Jobs</h3>
            <div class="muted" style="font-size:1.6rem;">Authenticated as <span class="mono">{{ username }}</span></div>
            <form method="post" action="/submit">
              <div class="form-grid">
                <div>
                  <label for="target_ip">Target node</label>
                  <select name="target_ip" id="target_ip">
                    <option value="10.26.0.171">COE892-VM-1</option>
                    <option value="10.26.0.172">COE892-VM-2</option>
                    <option value="10.26.0.173">COE892-VM-3</option>
                  </select>
                </div>
                <div>
                  <label for="job_type">Job type</label>
                  <select name="job_type" id="job_type">
                    <option value="demo_write">demo_write</option>
                    <option value="sleep">sleep</option>
                  </select>
                </div>
                <div>
                  <label for="count">Count</label>
                  <input type="number" id="count" name="count" value="5" min="1" max="50" />
                </div>
                <div>
                  <label for="message_text">Message</label>
                  <input type="text" id="message_text" name="message_text" value="hello from rpi control" />
                </div>
                <div>
                  <label for="sleep_seconds">Sleep seconds</label>
                  <input type="number" id="sleep_seconds" name="sleep_seconds" value="3" min="1" max="30" />
                </div>
              </div>
              <div style="margin-top:1.6rem;">
                <button type="submit" class="btn btn--med btn--theme">Submit Jobs</button>
              </div>
            </form>
          </div>

          <div class="card">
            <h3>Queue Summary</h3>
            <table>
              <tr><th>Name</th><td class="mono">{{ queue.name }}</td></tr>
              <tr><th>State</th><td>{{ queue.state }}</td></tr>
              <tr><th>Total messages</th><td>{{ queue.messages }}</td></tr>
              <tr><th>Ready</th><td>{{ queue.ready }}</td></tr>
              <tr><th>Unacked</th><td>{{ queue.unacked }}</td></tr>
              <tr><th>Consumers</th><td>{{ queue.consumers }}</td></tr>
              <tr><th>Error</th><td class="mono">{{ queue.error }}</td></tr>
            </table>
          </div>
        </div>
      </div>

      <div class="glass-panel section__panel">
        <span class="heading-sec__main">Node Status</span>
        <div class="node-grid">
          {% for row in rows %}
          <div class="card">
            <h3>{{ row.node.name }}</h3>
            <div class="muted mono">{{ row.node.ip }}</div>

            {% if row.health.reachable %}
            <span class="pill good">health ok</span>
            {% else %}
            <span class="pill bad">health down</span>
            {% endif %}

            {% if row.metrics.exporter_up %}
            <span class="pill good">metrics online</span>
            {% else %}
            <span class="pill warn">metrics unavailable</span>
            {% endif %}

            {% if row.metrics.agent_up == true %}
            <span class="pill good">agent online</span>
            {% elif row.metrics.agent_up == false %}
            <span class="pill warn">agent scrape down</span>
            {% endif %}

            <div class="stat-grid">
              <div class="stat">
                <div class="stat__label">CPU Utilization</div>
                <div class="stat__value">{{ row.metrics.cpu if row.metrics.cpu is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Memory Used</div>
                <div class="stat__value">{{ row.metrics.mem if row.metrics.mem is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Root Storage Used</div>
                <div class="stat__value">{{ row.metrics.root_used if row.metrics.root_used is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Shared Mount Used</div>
                <div class="stat__value">{{ row.metrics.shared_used if row.metrics.shared_used is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Load 1m</div>
                <div class="stat__value">{{ row.metrics.load1 if row.metrics.load1 is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Shared Path</div>
                <div class="stat__value">
                  {% if row.health.data and row.health.data.shared_path_exists is sameas true %}yes{% elif row.health.data and row.health.data.shared_path_exists is sameas false %}no{% else %}n/a{% endif %}
                </div>
              </div>
            </div>

            {% if row.node.name != 'COE892-RPi' %}
            <table>
              <tr><th>RabbitMQ</th><td>{{ row.health.data.rabbitmq if row.health.data else 'n/a' }}</td></tr>
              <tr><th>Postgres</th><td>{{ row.health.data.postgres if row.health.data else 'n/a' }}</td></tr>
              <tr><th>Health error</th><td class="mono">{{ row.health.error }}</td></tr>
            </table>
            {% endif %}
          </div>
          {% endfor %}
        </div>
      </div>

      <div class="glass-panel section__panel">
        <span class="heading-sec__main">Gluster Failover Ring</span>
        <div class="grid-3">
          {% for item in failover_ring %}
          <div class="ring-item">
            <div style="font-size:2rem;font-weight:900;color:#fff;">{{ item.client }}</div>
            <div style="margin-top:0.8rem;font-size:1.6rem;color:var(--textSoft);">primary: <span class="mono">{{ item.primary }}</span></div>
            <div style="margin-top:0.4rem;font-size:1.6rem;color:var(--textSoft);">backup: <span class="mono">{{ item.backup }}</span></div>
          </div>
          {% endfor %}
        </div>
      </div>

      <div class="glass-panel section__panel">
        <span class="heading-sec__main">Recent Jobs</span>
        <table>
          <thead>
            <tr>
              <th>Submitted At</th>
              <th>Job Type</th>
              <th>State</th>
              <th>Claimed By</th>
              <th>Attempts</th>
              <th>Submitted By</th>
            </tr>
          </thead>
          <tbody>
            {% for job in jobs %}
            <tr>
              <td class="mono">{{ job.submitted_at }}</td>
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
  </section>

  <footer class="main-footer" aria-label="Footer">
    <div class="glass-panel footer__panel">
      <div class="main-footer__upper">
        <div>
          <div class="heading-sm">Social</div>
          <div class="main-footer__social-cont">
            <a href="https://www.linkedin.com/in/krishadmin" target="_blank" rel="noopener noreferrer" aria-label="LinkedIn">
              <img src="https://krishadmin.com/pics/Icon-LinkedIn.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://github.com/KrishPAdmin" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
              <img src="https://krishadmin.com/pics/Icon-Github.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://www.youtube.com/channel/UCPOpecefAO1ub4KB50wDmjg" target="_blank" rel="noopener noreferrer" aria-label="YouTube">
              <img src="https://krishadmin.com/pics/Icon-Youtube.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://www.instagram.com/krish_admin/" target="_blank" rel="noopener noreferrer" aria-label="Instagram">
              <img src="https://krishadmin.com/pics/Icon-Instagram.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://discord.com/users/290130274010923010" target="_blank" rel="noopener noreferrer" aria-label="Discord">
              <img src="https://krishadmin.com/pics/Icon-Discord.png" alt="" class="main-footer__icon" />
            </a>
          </div>
          <div class="footer-emails">
            Discord: <a href="https://discord.com/users/290130274010923010" target="_blank" rel="noopener noreferrer" style="color:var(--accent);text-decoration:underline;">DM me here</a><br />
            Email: <a href="mailto:krish@krishadmin.com" style="color:var(--accent);text-decoration:underline;">krish@krishadmin.com</a>
          </div>
        </div>
        <div>
          <div class="heading-sm">About</div>
          <div class="main-footer__short-desc">
            ProxSyncQ Raspberry Pi control plane for cluster health, queue orchestration, shared storage visibility, and Gluster failover mapping.
          </div>
        </div>
      </div>
      <div class="main-footer__lower">
        © <span id="yearNow"></span> Krish Patel. Built for <a href="https://krishadmin.com" style="color:var(--accent);text-decoration:underline;">www.krishadmin.com</a>
      </div>
    </div>
  </footer>

  <script>
    (function () {
      var yearNow = document.getElementById("yearNow");
      if (yearNow) yearNow.textContent = String(new Date().getFullYear());
      setInterval(function () {
        if (!document.hidden) window.location.reload();
      }, 20000);
    })();
  </script>
</body>
</html>
HTML

echo "== syncing new UI to Pi =="
rsync -av rpi-control/ "${PI_USER}@${PI_HOST}:/home/${PI_USER}/proxsyncq-rpi/"

echo
echo "== rebuilding Pi UI stack =="
ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd ~/proxsyncq-rpi
sudo docker compose up -d --build control_ui
sleep 4
sudo docker compose ps
echo
sudo docker compose logs --tail=120 control_ui
REMOTE

echo
echo "== ensuring node exporter on VM1 VM2 VM3 =="
for host in "${NODES[@]}"; do
  echo "== ${host} =="
  ssh -tt "${PI_USER}@${host}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y prometheus-node-exporter curl ca-certificates
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl status prometheus-node-exporter --no-pager || true
REMOTE
  echo
done

echo "== waiting for Prometheus scrape refresh =="
sleep 20

echo
echo "== endpoint checks =="
curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" && echo || true
echo

for host in 10.26.0.170 10.26.0.171 10.26.0.172 10.26.0.173; do
  echo "== ${host}:9100 =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | sed -n '1,3p' || true
  echo
done

echo "done"
