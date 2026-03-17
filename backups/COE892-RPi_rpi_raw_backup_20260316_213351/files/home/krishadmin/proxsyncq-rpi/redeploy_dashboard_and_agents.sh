#!/usr/bin/env bash
set -euo pipefail

USER_NAME="krishadmin"
PI_DIR="/home/${USER_NAME}/proxsyncq-rpi"
VM1="10.26.0.171"
VM2="10.26.0.172"
VM3="10.26.0.173"
VMS=("${VM1}" "${VM2}" "${VM3}")
UI_MARKER="ui-pi-final-v8"

mkdir -p "${PI_DIR}/control_ui/templates"
mkdir -p "${PI_DIR}/prometheus"

cat > "${PI_DIR}/control_ui/app.py" <<'PY'
import json
import os
import random
import time
from datetime import datetime, timezone
from urllib.parse import quote

import psycopg2
import psycopg2.extras
import requests
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
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
    {"name": "COE892-VM-1", "ip": "10.26.0.171", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-2", "ip": "10.26.0.172", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-3", "ip": "10.26.0.173", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-RPi", "ip": "10.26.0.170", "agent_port": None, "node_exporter_port": 9100},
]

DISPLAY_ORDER = {
    "COE892-VM-1": 0,
    "COE892-VM-2": 1,
    "COE892-VM-3": 2,
    "COE892-RPi": 3,
}

FAILOVER_RING = [
    {"client": "COE892-VM-1", "primary": "10.26.0.171", "backup": "10.26.0.172"},
    {"client": "COE892-VM-2", "primary": "10.26.0.172", "backup": "10.26.0.173"},
    {"client": "COE892-VM-3", "primary": "10.26.0.173", "backup": "10.26.0.171"},
]

app = FastAPI(title="ProxSyncQ Control UI")
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET, max_age=60 * 60 * 10, same_site="lax")
templates = Jinja2Templates(directory="templates")


@app.middleware("http")
async def disable_cache(request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


def get_nodes():
    if not NODE_MAP_JSON.strip():
        nodes = DEFAULT_NODES[:]
    else:
        try:
            nodes = json.loads(NODE_MAP_JSON)
        except Exception:
            nodes = DEFAULT_NODES[:]
    return sorted(nodes, key=lambda node: DISPLAY_ORDER.get(node.get("name", ""), 999))


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
            "load_pct": None,
        }

    cpu = prom_value(
        '100 - (avg by (instance) (rate(node_cpu_seconds_total{job="node_exporter",mode="idle"}[5m])) * 100)',
        exporter_instance,
    )
    mem = prom_value(
        '100 * (1 - (node_memory_MemAvailable_bytes{job="node_exporter"} / node_memory_MemTotal_bytes{job="node_exporter"}))',
        exporter_instance,
    )
    root_used = prom_value(
        '100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/",fstype!~"rootfs|tmpfs|overlay"}))',
        exporter_instance,
    )
    shared_used = prom_value(
        '100 * (1 - (node_filesystem_avail_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"} / node_filesystem_size_bytes{job="node_exporter",mountpoint="/srv/proxsyncq/shared"}))',
        exporter_instance,
    )
    load1 = prom_value('node_load1{job="node_exporter"}', exporter_instance)
    cores = prom_value(
        'count by (instance) (count without (cpu,mode) (node_cpu_seconds_total{job="node_exporter",mode="idle"}))',
        exporter_instance,
    )
    load_pct = None
    if load1 is not None and cores is not None and cores > 0:
        load_pct = round((load1 / cores) * 100.0, 2)

    return {
        "exporter_up": True,
        "agent_up": agent_up,
        "cpu": cpu,
        "mem": mem,
        "root_used": root_used,
        "shared_used": shared_used,
        "load_pct": load_pct,
    }


def live_rows():
    rows = []
    for node in get_nodes():
        rows.append({
            "node": node,
            "health": get_health(node),
            "metrics": get_metrics(node),
        })
        time.sleep(0.03)
    return rows


def is_authed(request: Request):
    return request.session.get("auth_user") == UI_USERNAME


def need_auth_redirect(request: Request):
    if not is_authed(request):
        return RedirectResponse(url="/login", status_code=303)
    return None


def need_auth_json(request: Request):
    if not is_authed(request):
        return JSONResponse({"error": "authentication required"}, status_code=403)
    return None


def serialize_job(job):
    out = {}
    for key, value in dict(job).items():
        if hasattr(value, "isoformat"):
            out[key] = value.isoformat(sep=" ")
        else:
            out[key] = value
    return out


def build_dashboard_payload():
    rows = live_rows()
    jobs = [serialize_job(job) for job in recent_jobs()]
    return {
        "queue": rabbit_queue_summary(),
        "rows": rows,
        "jobs": jobs,
        "failover_ring": FAILOVER_RING,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


def candidate_targets(rows):
    candidates = []
    for row in rows:
        node = row["node"]
        if node["name"] == "COE892-RPi":
            continue
        if row["health"]["reachable"] and row["metrics"]["exporter_up"]:
            cpu = row["metrics"]["cpu"] if row["metrics"]["cpu"] is not None else 999
            mem = row["metrics"]["mem"] if row["metrics"]["mem"] is not None else 999
            score = round(cpu + mem, 2)
            candidates.append({
                "name": node["name"],
                "ip": node["ip"],
                "score": score,
            })
    return candidates


def resolve_targets(target_mode: str, count: int):
    rows = live_rows()
    candidates = candidate_targets(rows)

    fixed_ips = {"10.26.0.171", "10.26.0.172", "10.26.0.173"}
    if target_mode in fixed_ips:
        return [target_mode for _ in range(count)]

    if not candidates:
        return ["10.26.0.171" for _ in range(count)]

    if target_mode == "auto_best":
        ordered = sorted(candidates, key=lambda item: item["score"])
        return [ordered[i % len(ordered)]["ip"] for i in range(count)]

    if target_mode == "auto_shuffle":
        ordered = candidates[:]
        random.shuffle(ordered)
        return [ordered[i % len(ordered)]["ip"] for i in range(count)]

    return [candidates[0]["ip"] for _ in range(count)]


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


@app.get("/api/dashboard")
def api_dashboard(request: Request):
    auth = need_auth_json(request)
    if auth:
        return auth
    return JSONResponse(build_dashboard_payload())


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    auth = need_auth_redirect(request)
    if auth:
        return auth

    payload = build_dashboard_payload()
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "username": request.session.get("auth_user", ""),
            "queue": payload["queue"],
            "rows": payload["rows"],
            "jobs": payload["jobs"],
            "failover_ring": payload["failover_ring"],
            "updated_at": payload["updated_at"],
            "message": request.query_params.get("message", ""),
            "status": request.query_params.get("status", ""),
            "ui_marker": "ui-pi-final-v8",
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
    workers: int = Form(2),
):
    auth = need_auth_redirect(request)
    if auth:
        return auth

    count = max(1, min(int(count), 50))
    sleep_seconds = max(1, min(int(sleep_seconds), 300))
    workers = max(1, min(int(workers), 8))

    if job_type == "demo_write":
        payload = {"message": message_text}
    elif job_type == "sleep":
        payload = {"seconds": sleep_seconds}
    elif job_type == "crypto_burn":
        payload = {"seconds": sleep_seconds, "workers": workers}
    else:
        payload = {"seconds": sleep_seconds}

    targets = resolve_targets(target_ip, count)
    sent = 0
    errors = 0

    for ip in targets:
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

    if errors:
        return RedirectResponse(url=f"/?status=partial&message=sent:{sent},errors:{errors}", status_code=303)
    return RedirectResponse(url=f"/?status=ok&message=submitted:{sent}", status_code=303)
PY

cat > "${PI_DIR}/control_ui/templates/index.html" <<'HTML'
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
      --glassBg: rgba(12, 14, 16, 0.82);
      --glassBorder: rgba(255, 255, 255, 0.10);
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
      --textSub: rgb(149, 149, 149);
      --titleShadow: 0 12px 30px rgba(0, 0, 0, 0.55);
      --headerH: 7.2rem;
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
    button, input, select, option { font: inherit; }
    select, option {
      background: #141414;
      color: #fff;
    }
    .header {
      position: fixed;
      inset: 0 0 auto 0;
      width: 100%;
      z-index: 1000;
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border-bottom: 1px solid var(--glassBorder);
    }
    .header__content {
      min-height: var(--headerH);
      width: calc(100vw - 2rem);
      margin: 0 auto;
      padding: 0 0.3rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 2rem;
    }
    .header__logo-container {
      display: flex;
      align-items: center;
      gap: 1.2rem;
      color: var(--accent);
      flex: 0 0 auto;
    }
    .header__logo-img-cont {
      width: 5.2rem;
      height: 5.2rem;
      border-radius: 999px;
      overflow: hidden;
      background: var(--accent);
    }
    .header__logo-img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }
    .header__logo-sub {
      font-size: 1.7rem;
      text-transform: uppercase;
      font-weight: 900;
      letter-spacing: 1px;
      white-space: nowrap;
    }
    .header__links {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      flex-wrap: wrap;
      gap: 0.2rem;
      flex: 1 1 auto;
    }
    .header__link {
      padding: 0.95rem 1.15rem;
      font-size: 1.3rem;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      border-radius: 10px;
      transition: background 0.2s ease, filter 0.2s ease;
      white-space: nowrap;
    }
    .header__link:hover {
      filter: brightness(1.10);
      background: rgba(32, 253, 20, 0.10);
    }
    .page-shell {
      width: min(75vw, 170rem);
      max-width: calc(100vw - 2rem);
      margin: 0 auto;
      padding: calc(var(--headerH) + 1.2rem) 0 3rem 0;
    }
    .glass-panel {
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border: 1px solid var(--glassBorder);
      border-radius: 18px;
      box-shadow: var(--shadow);
    }
    .section {
      margin-bottom: 1.4rem;
    }
    .section__panel {
      width: 100%;
      padding: 1.7rem;
    }
    .intro-strip {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1.4rem;
    }
    .intro-strip__line1 {
      font-size: clamp(4.2rem, 4.8vw, 6.6rem);
      font-weight: 900;
      text-transform: uppercase;
      letter-spacing: 1px;
      text-shadow: var(--titleShadow);
      line-height: 1.02;
    }
    .intro-strip__actions {
      display: flex;
      align-items: center;
      gap: 1rem;
      flex-wrap: wrap;
      flex: 0 0 auto;
    }
    .section-heading {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1.4rem;
      margin-bottom: 1.5rem;
    }
    .section-heading__left {
      display: flex;
      align-items: center;
      gap: 1rem;
      flex-wrap: wrap;
    }
    .heading-sec__main {
      display: inline-block;
      font-size: clamp(2.8rem, 3vw, 4.3rem);
      text-transform: uppercase;
      letter-spacing: 3px;
      position: relative;
      font-weight: 900;
      text-shadow: var(--titleShadow);
      color: #fff;
      line-height: 1.08;
    }
    .heading-sec__main::after {
      content: "";
      position: absolute;
      top: calc(100% + 0.8rem);
      left: 0;
      height: 5px;
      width: 3rem;
      background: var(--accent);
      border-radius: 999px;
    }
    .meta-right {
      display: flex;
      align-items: center;
      gap: 1.6rem;
      flex-wrap: wrap;
      justify-content: flex-end;
    }
    .refresh-meta {
      font-size: 1.35rem;
      color: var(--textSub);
      font-weight: 700;
      white-space: nowrap;
    }
    .btn {
      background: #000;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-weight: 900;
      border-radius: 10px;
      box-shadow: var(--shadow);
      transition: transform 0.2s ease, filter 0.2s ease, color 0.2s ease;
      border: 0;
      cursor: pointer;
      white-space: nowrap;
    }
    .btn:hover {
      transform: translateY(-2px);
      filter: brightness(1.04);
      color: #fff;
    }
    .btn--bg {
      padding: 1.25rem 2.2rem;
      font-size: 1.42rem;
    }
    .btn--med {
      padding: 0.95rem 1.7rem;
      font-size: 1.28rem;
    }
    .btn--theme {
      background: var(--accent);
      color: #000;
    }
    .grid-2 {
      display: grid;
      grid-template-columns: minmax(0, 1.7fr) minmax(38rem, 0.9fr);
      gap: 1.5rem;
      align-items: start;
    }
    .node-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 1.5rem;
    }
    .grid-3 {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 1.5rem;
    }
    .card {
      background: rgba(255,255,255,0.04);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 16px;
      padding: 1.55rem;
      box-shadow: var(--shadow);
      min-width: 0;
    }
    .card h3 {
      font-size: 2rem;
      font-weight: 900;
      margin-bottom: 0.35rem;
      color: #fff;
      text-shadow: var(--titleShadow);
    }
    .muted { color: var(--textSub); }
    .mono {
      font-family: Consolas, monospace;
      word-break: break-word;
      overflow-wrap: anywhere;
    }
    .pill-row {
      display: flex;
      flex-wrap: wrap;
      gap: 0.75rem;
      margin-top: 0.95rem;
    }
    .pill {
      display: inline-block;
      padding: 0.45rem 1rem;
      border-radius: 999px;
      font-size: 1.15rem;
      font-weight: 900;
      letter-spacing: 1px;
      text-transform: uppercase;
    }
    .good { background: rgba(32,253,20,0.18); color: #9aff8f; }
    .warn { background: rgba(251,191,36,0.18); color: #ffd86f; }
    .bad { background: rgba(248,113,113,0.18); color: #ff9a9a; }
    .stat-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 0.95rem;
      margin-top: 1.35rem;
    }
    .stat {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 1.15rem;
      border: 1px solid rgba(255,255,255,0.08);
      min-width: 0;
    }
    .stat__label {
      font-size: 1.12rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--textSub);
      font-weight: 900;
    }
    .stat__value {
      margin-top: 0.42rem;
      font-size: 1.95rem;
      font-weight: 900;
      color: #fff;
      word-break: break-word;
    }
    .form-grid {
      display: grid;
      grid-template-columns: repeat(5, minmax(14rem, 1fr));
      gap: 1rem;
      margin-top: 1.35rem;
      align-items: end;
    }
    .form-actions {
      margin-top: 1.35rem;
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
    }
    label {
      display: block;
      font-size: 1.12rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--accent);
      font-weight: 900;
      margin-bottom: 0.55rem;
    }
    input, select {
      width: 100%;
      min-height: 4.6rem;
      padding: 1rem 1.1rem;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.12);
      background: rgba(255,255,255,0.06);
      color: #fff;
      font-size: 1.45rem;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 0.95rem;
      table-layout: fixed;
    }
    th, td {
      padding: 0.92rem;
      border-bottom: 1px solid rgba(255,255,255,0.08);
      text-align: left;
      font-size: 1.35rem;
      vertical-align: top;
      word-break: break-word;
      overflow-wrap: anywhere;
    }
    th {
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      font-size: 1.12rem;
      width: 13.5rem;
    }
    .ring-item {
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 14px;
      padding: 1.35rem;
      min-width: 0;
    }
    .main-footer {
      padding-top: 0.2rem;
    }
    .footer__panel {
      width: 100%;
      padding: 1.8rem;
    }
    .main-footer__upper {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 3rem;
      margin-bottom: 1.7rem;
    }
    .heading-sm {
      color: #fff;
      font-size: 1.9rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      text-shadow: 0 10px 24px rgba(0, 0, 0, 0.45);
    }
    .main-footer__social-cont {
      display: flex;
      gap: 1rem;
      margin-top: 1.1rem;
      flex-wrap: wrap;
    }
    .main-footer__icon {
      width: 2.6rem;
      height: 2.6rem;
      object-fit: contain;
    }
    .main-footer__short-desc, .footer-emails {
      margin-top: 1.15rem;
      font-size: 1.6rem;
      color: var(--textSub);
      line-height: 1.7;
    }
    .main-footer__lower {
      padding-top: 1.7rem;
      border-top: 1px solid rgba(255, 255, 255, 0.12);
      font-size: 1.45rem;
      color: var(--textSub);
      text-align: center;
      font-weight: 700;
      letter-spacing: 1px;
    }
    @media (max-width: 1700px) {
      .form-grid {
        grid-template-columns: repeat(3, minmax(14rem, 1fr));
      }
    }
    @media (max-width: 1350px) {
      .grid-2 {
        grid-template-columns: 1fr;
      }
      .grid-3 {
        grid-template-columns: 1fr;
      }
      .form-grid {
        grid-template-columns: repeat(2, minmax(14rem, 1fr));
      }
      .page-shell {
        width: min(84vw, 150rem);
      }
    }
    @media (max-width: 1100px) {
      .node-grid {
        grid-template-columns: 1fr;
      }
      .main-footer__upper {
        grid-template-columns: 1fr;
      }
      .page-shell {
        width: calc(100vw - 2rem);
      }
    }
    @media (max-width: 800px) {
      .header__content {
        flex-direction: column;
        justify-content: center;
        padding: 1rem 0.8rem;
        min-height: auto;
      }
      .header__links {
        justify-content: center;
      }
      .page-shell {
        padding-top: 15rem;
        width: calc(100vw - 2rem);
      }
      .intro-strip {
        flex-direction: column;
        align-items: stretch;
      }
      .section-heading {
        flex-direction: column;
        align-items: flex-start;
      }
      .refresh-meta {
        white-space: normal;
      }
      .form-grid {
        grid-template-columns: 1fr;
      }
    }
    @media (max-width: 700px) {
      .stat-grid {
        grid-template-columns: 1fr;
      }
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

  <main class="page-shell">
    <section class="section">
      <div class="glass-panel section__panel intro-strip">
        <div class="intro-strip__line1">Cluster Operations Dashboard</div>
        <div class="intro-strip__actions">
          <a href="http://10.26.0.170:3000" class="btn btn--bg btn--theme" target="_blank" rel="noopener noreferrer">Open Grafana</a>
          <button id="pageRefreshBtn" type="button" class="btn btn--bg">Refresh Data</button>
        </div>
      </div>
      {% if message %}
      <div style="margin-top:1rem;">
        <span class="pill {% if status == 'ok' %}good{% elif status == 'partial' %}warn{% else %}bad{% endif %}">{{ status }} {{ message }}</span>
      </div>
      {% endif %}
    </section>

    <section class="section">
      <div class="glass-panel section__panel">
        <div class="section-heading">
          <div class="section-heading__left">
            <span class="heading-sec__main">Cluster Operations</span>
          </div>
          <div class="meta-right">
            <div class="refresh-meta">Current user: <span class="mono">{{ username }}</span></div>
            <div class="refresh-meta">Last updated: <span id="lastUpdated">{{ updated_at }}</span></div>
          </div>
        </div>

        <div class="grid-2">
          <div class="card">
            <h3>Submit Jobs</h3>
            <form method="post" action="/submit">
              <div class="form-grid">
                <div>
                  <label for="target_ip">Target node</label>
                  <select name="target_ip" id="target_ip">
                    <option value="10.26.0.171">COE892-VM-1</option>
                    <option value="10.26.0.172">COE892-VM-2</option>
                    <option value="10.26.0.173">COE892-VM-3</option>
                    <option value="auto_best">Auto Best</option>
                    <option value="auto_shuffle">Auto Shuffle</option>
                  </select>
                </div>
                <div>
                  <label for="job_type">Job type</label>
                  <select name="job_type" id="job_type">
                    <option value="demo_write">demo_write</option>
                    <option value="sleep">sleep</option>
                    <option value="crypto_burn">crypto_burn</option>
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
                  <label for="sleep_seconds">Duration sec</label>
                  <input type="number" id="sleep_seconds" name="sleep_seconds" value="30" min="1" max="300" />
                </div>
              </div>
              <div class="form-grid" style="margin-top:1rem;">
                <div>
                  <label for="workers">Workers</label>
                  <input type="number" id="workers" name="workers" value="2" min="1" max="8" />
                </div>
              </div>
              <div class="form-actions">
                <button type="submit" class="btn btn--med btn--theme">Submit Jobs</button>
              </div>
            </form>
          </div>

          <div class="card">
            <h3>Queue Summary</h3>
            <table>
              <tbody id="queueSummaryBody">
                <tr><th>Name</th><td class="mono">{{ queue.name }}</td></tr>
                <tr><th>State</th><td>{{ queue.state }}</td></tr>
                <tr><th>Total messages</th><td>{{ queue.messages }}</td></tr>
                <tr><th>Ready</th><td>{{ queue.ready }}</td></tr>
                <tr><th>Unacked</th><td>{{ queue.unacked }}</td></tr>
                <tr><th>Consumers</th><td>{{ queue.consumers }}</td></tr>
                <tr><th>Error</th><td class="mono">{{ queue.error }}</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="glass-panel section__panel">
        <div class="section-heading">
          <div class="section-heading__left">
            <span class="heading-sec__main">Node Status</span>
          </div>
          <button id="nodeRefreshBtn" type="button" class="btn btn--med btn--theme">Refresh Nodes</button>
        </div>

        <div class="node-grid" id="nodeStatusGrid">
          {% for row in rows %}
          <div class="card">
            <h3>{{ row.node.name }}</h3>
            <div class="muted mono">{{ row.node.ip }}</div>

            <div class="pill-row">
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
            </div>

            <div class="stat-grid">
              <div class="stat">
                <div class="stat__label">CPU Utilization %</div>
                <div class="stat__value">{{ ('%.2f%%'|format(row.metrics.cpu)) if row.metrics.cpu is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Memory Used %</div>
                <div class="stat__value">{{ ('%.2f%%'|format(row.metrics.mem)) if row.metrics.mem is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Root Storage %</div>
                <div class="stat__value">{{ ('%.2f%%'|format(row.metrics.root_used)) if row.metrics.root_used is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Shared Mount %</div>
                <div class="stat__value">{{ ('%.2f%%'|format(row.metrics.shared_used)) if row.metrics.shared_used is not none else 'n/a' }}</div>
              </div>
              <div class="stat">
                <div class="stat__label">Load %</div>
                <div class="stat__value">{{ ('%.2f%%'|format(row.metrics.load_pct)) if row.metrics.load_pct is not none else 'n/a' }}</div>
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
              <tr><th>Health Error</th><td class="mono">{{ row.health.error }}</td></tr>
            </table>
            {% endif %}
          </div>
          {% endfor %}
        </div>
      </div>
    </section>

    <section class="section">
      <div class="glass-panel section__panel">
        <div class="section-heading">
          <div class="section-heading__left">
            <span class="heading-sec__main">Gluster Failover Ring</span>
          </div>
        </div>

        <div class="grid-3">
          {% for item in failover_ring %}
          <div class="ring-item">
            <div style="font-size:1.9rem;font-weight:900;color:#fff;">{{ item.client }}</div>
            <div style="margin-top:0.8rem;font-size:1.55rem;color:var(--textSub);">primary: <span class="mono">{{ item.primary }}</span></div>
            <div style="margin-top:0.4rem;font-size:1.55rem;color:var(--textSub);">backup: <span class="mono">{{ item.backup }}</span></div>
          </div>
          {% endfor %}
        </div>
      </div>
    </section>

    <section class="section">
      <div class="glass-panel section__panel">
        <div class="section-heading">
          <div class="section-heading__left">
            <span class="heading-sec__main">Recent Jobs</span>
          </div>
        </div>

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
          <tbody id="recentJobsBody">
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
            <div style="margin-top:1.15rem;font-size:1.6rem;color:var(--textSub);line-height:1.7;">
              Discord: <a href="https://discord.com/users/290130274010923010" target="_blank" rel="noopener noreferrer" style="color:var(--accent);text-decoration:underline;">DM me here</a><br />
              Email: <a href="mailto:krish@krishadmin.com" style="color:var(--accent);text-decoration:underline;">krish@krishadmin.com</a>
            </div>
          </div>
          <div>
            <div class="heading-sm">About</div>
            <div style="margin-top:1.15rem;font-size:1.6rem;color:var(--textSub);line-height:1.7;">
              ProxSyncQ Raspberry Pi control plane for cluster health, queue orchestration, shared storage visibility, and Gluster failover mapping.
            </div>
          </div>
        </div>
        <div class="main-footer__lower">
          © <span id="yearNow"></span> Krish Patel. Built for <a href="https://krishadmin.com" style="color:var(--accent);text-decoration:underline;">www.krishadmin.com</a>
        </div>
      </div>
    </footer>
  </main>

  <script>
    (function () {
      console.log("ui-pi-final-v8");
      var yearNow = document.getElementById("yearNow");
      if (yearNow) yearNow.textContent = String(new Date().getFullYear());

      function esc(value) {
        return String(value)
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;")
          .replace(/"/g, "&quot;")
          .replace(/'/g, "&#39;");
      }

      function fmt(value) {
        if (value === null || value === undefined || value === "") return "n/a";
        return esc(value);
      }

      function fmtPct(value) {
        if (value === null || value === undefined || value === "") return "n/a";
        return esc(Number(value).toFixed(2) + "%");
      }

      function pillClass(ok, warnOnly) {
        if (ok) return "good";
        return warnOnly ? "warn" : "bad";
      }

      function renderQueue(queue) {
        var tbody = document.getElementById("queueSummaryBody");
        tbody.innerHTML = [
          "<tr><th>Name</th><td class='mono'>" + fmt(queue.name) + "</td></tr>",
          "<tr><th>State</th><td>" + fmt(queue.state) + "</td></tr>",
          "<tr><th>Total Messages</th><td>" + fmt(queue.messages) + "</td></tr>",
          "<tr><th>Ready</th><td>" + fmt(queue.ready) + "</td></tr>",
          "<tr><th>Unacked</th><td>" + fmt(queue.unacked) + "</td></tr>",
          "<tr><th>Consumers</th><td>" + fmt(queue.consumers) + "</td></tr>",
          "<tr><th>Error</th><td class='mono'>" + fmt(queue.error) + "</td></tr>"
        ].join("");
      }

      function renderJobs(jobs) {
        var tbody = document.getElementById("recentJobsBody");
        if (!jobs || !jobs.length) {
          tbody.innerHTML = "<tr><td colspan='6' class='mono'>No recent jobs found</td></tr>";
          return;
        }
        tbody.innerHTML = jobs.map(function (job) {
          return [
            "<tr>",
            "<td class='mono'>" + fmt(job.submitted_at) + "</td>",
            "<td class='mono'>" + fmt(job.job_type) + "</td>",
            "<td>" + fmt(job.state) + "</td>",
            "<td>" + fmt(job.claimed_by) + "</td>",
            "<td>" + fmt(job.attempt_count) + "</td>",
            "<td>" + fmt(job.submitted_by) + "</td>",
            "</tr>"
          ].join("");
        }).join("");
      }

      function renderNodeCard(row) {
        var health = row.health || {};
        var metrics = row.metrics || {};
        var data = health.data || {};
        var pills = [];
        pills.push("<span class='pill " + pillClass(!!health.reachable, false) + "'>" + (health.reachable ? "health ok" : "health down") + "</span>");
        pills.push("<span class='pill " + pillClass(!!metrics.exporter_up, true) + "'>" + (metrics.exporter_up ? "metrics online" : "metrics unavailable") + "</span>");
        if (metrics.agent_up === true) pills.push("<span class='pill good'>agent online</span>");
        if (metrics.agent_up === false) pills.push("<span class='pill warn'>agent scrape down</span>");

        var html = [
          "<div class='card'>",
          "<h3>" + fmt(row.node.name) + "</h3>",
          "<div class='muted mono'>" + fmt(row.node.ip) + "</div>",
          "<div class='pill-row'>" + pills.join("") + "</div>",
          "<div class='stat-grid'>",
          "<div class='stat'><div class='stat__label'>CPU Utilization %</div><div class='stat__value'>" + fmtPct(metrics.cpu) + "</div></div>",
          "<div class='stat'><div class='stat__label'>Memory Used %</div><div class='stat__value'>" + fmtPct(metrics.mem) + "</div></div>",
          "<div class='stat'><div class='stat__label'>Root Storage %</div><div class='stat__value'>" + fmtPct(metrics.root_used) + "</div></div>",
          "<div class='stat'><div class='stat__label'>Shared Mount %</div><div class='stat__value'>" + fmtPct(metrics.shared_used) + "</div></div>",
          "<div class='stat'><div class='stat__label'>Load %</div><div class='stat__value'>" + fmtPct(metrics.load_pct) + "</div></div>",
          "<div class='stat'><div class='stat__label'>Shared Path</div><div class='stat__value'>" + (data.shared_path_exists === true ? "yes" : data.shared_path_exists === false ? "no" : "n/a") + "</div></div>",
          "</div>"
        ];

        if (row.node.name !== "COE892-RPi") {
          html.push("<table>");
          html.push("<tr><th>RabbitMQ</th><td>" + fmt(data.rabbitmq) + "</td></tr>");
          html.push("<tr><th>Postgres</th><td>" + fmt(data.postgres) + "</td></tr>");
          html.push("<tr><th>Health Error</th><td class='mono'>" + fmt(health.error) + "</td></tr>");
          html.push("</table>");
        }

        html.push("</div>");
        return html.join("");
      }

      function renderNodes(rows) {
        var grid = document.getElementById("nodeStatusGrid");
        grid.innerHTML = (rows || []).map(renderNodeCard).join("");
      }

      async function refreshDashboard(parts) {
        try {
          var response = await fetch("/api/dashboard", {
            method: "GET",
            credentials: "same-origin",
            headers: {
              "Accept": "application/json",
              "Cache-Control": "no-store"
            }
          });

          if (!response.ok) return;

          var data = await response.json();

          if (parts === "all" || parts === "queue") renderQueue(data.queue || {});
          if (parts === "all" || parts === "nodes") renderNodes(data.rows || []);
          if (parts === "all" || parts === "jobs") renderJobs(data.jobs || []);

          var lastUpdated = document.getElementById("lastUpdated");
          if (lastUpdated) lastUpdated.textContent = data.updated_at || new Date().toISOString();
        } catch (error) {
        }
      }

      var nodeRefreshBtn = document.getElementById("nodeRefreshBtn");
      if (nodeRefreshBtn) {
        nodeRefreshBtn.addEventListener("click", function () {
          refreshDashboard("nodes");
        });
      }

      var pageRefreshBtn = document.getElementById("pageRefreshBtn");
      if (pageRefreshBtn) {
        pageRefreshBtn.addEventListener("click", function () {
          refreshDashboard("all");
        });
      }

      setInterval(function () {
        if (!document.hidden) refreshDashboard("all");
      }, 20000);
    })();
  </script>
  <!-- ui-pi-final-v8 -->
</body>
</html>
HTML

cat > "${PI_DIR}/prometheus/prometheus.yml" <<'YAML'
global:
  scrape_interval: 10s
  evaluation_interval: 10s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: node_exporter
    static_configs:
      - targets:
          - 10.26.0.170:9100
          - 10.26.0.171:9100
          - 10.26.0.172:9100
          - 10.26.0.173:9100

  - job_name: node_agent
    metrics_path: /metrics
    static_configs:
      - targets:
          - 10.26.0.171:8000
          - 10.26.0.172:8000
          - 10.26.0.173:8000
YAML

echo "== rebuilding dashboard on Pi =="
cd "${PI_DIR}"
sudo docker compose build --no-cache control_ui
sudo docker compose up -d control_ui
sudo docker compose restart prometheus
sleep 10
sudo docker compose ps
echo
curl -fsS http://127.0.0.1:8080 | grep -i "${UI_MARKER}"
echo

deploy_agent_service() {
  local host="$1"
  echo "== deploying node agent service on ${host} =="

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -tt "${USER_NAME}@${host}" 'bash -s' <<'REMOTE_VM'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y python3 python3-venv python3-pip curl ca-certificates prometheus-node-exporter procps iproute2 >/dev/null 2>&1 || true

mkdir -p /home/krishadmin/proxsyncq-node-agent

cat > /home/krishadmin/proxsyncq-node-agent/requirements.txt <<'REQ'
fastapi==0.115.8
uvicorn[standard]==0.34.0
prometheus-client==0.21.1
REQ

cat > /home/krishadmin/proxsyncq-node-agent/worker.py <<'PY'
import hashlib
import json
import multiprocessing as mp
import os
import socket
import sys
import time
from datetime import datetime

SHARED_PATH = os.getenv("SHARED_PATH", "/srv/proxsyncq/shared")

def demo_write(payload):
    message = str(payload.get("message", "hello"))
    line = f"{datetime.utcnow().isoformat()}Z {socket.gethostname()} {message}\n"
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

cat > /home/krishadmin/proxsyncq-node-agent/app.py <<'PY'
import json
import os
import socket
import subprocess
import sys
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CollectorRegistry, Gauge, generate_latest, CONTENT_TYPE_LATEST

APP = FastAPI(title="proxsyncq-node-agent")
BASE_DIR = Path(__file__).resolve().parent
RABBIT_HOST = os.getenv("RABBIT_HOST", "10.26.0.171")
RABBIT_PORT = int(os.getenv("RABBIT_PORT", "5672"))
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
SHARED_PATH = os.getenv("SHARED_PATH", "/srv/proxsyncq/shared")

def tcp_ok(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False

def payload():
    return {
        "node": socket.gethostname(),
        "rabbitmq": tcp_ok(RABBIT_HOST, RABBIT_PORT),
        "postgres": tcp_ok(POSTGRES_HOST, POSTGRES_PORT),
        "shared_path_exists": os.path.exists(SHARED_PATH),
    }

@APP.get("/health")
def health():
    return JSONResponse(payload())

@APP.get("/metrics")
def metrics():
    data = payload()
    registry = CollectorRegistry()
    Gauge("node_agent_up", "Node agent up", registry=registry).set(1)
    Gauge("node_agent_rabbitmq_ok", "RabbitMQ reachability", registry=registry).set(1 if data["rabbitmq"] else 0)
    Gauge("node_agent_postgres_ok", "Postgres reachability", registry=registry).set(1 if data["postgres"] else 0)
    Gauge("node_agent_shared_path_exists", "Shared path exists", registry=registry).set(1 if data["shared_path_exists"] else 0)
    body = generate_latest(registry).decode()
    return PlainTextResponse(body, media_type=CONTENT_TYPE_LATEST)

@APP.post("/jobs")
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

python3 -m venv /home/krishadmin/proxsyncq-node-agent/.venv
/home/krishadmin/proxsyncq-node-agent/.venv/bin/pip install --upgrade pip >/dev/null 2>&1
/home/krishadmin/proxsyncq-node-agent/.venv/bin/pip install -r /home/krishadmin/proxsyncq-node-agent/requirements.txt >/dev/null 2>&1

cat > /tmp/proxsyncq-node-agent.service <<'UNIT'
[Unit]
Description=ProxSyncQ Node Agent
After=network-online.target
Wants=network-online.target

[Service]
User=krishadmin
Group=krishadmin
WorkingDirectory=/home/krishadmin/proxsyncq-node-agent
Environment=RABBIT_HOST=10.26.0.171
Environment=RABBIT_PORT=5672
Environment=POSTGRES_HOST=10.26.0.171
Environment=POSTGRES_PORT=5432
Environment=SHARED_PATH=/srv/proxsyncq/shared
ExecStart=/home/krishadmin/proxsyncq-node-agent/.venv/bin/uvicorn app:APP --host 0.0.0.0 --port 8000
Restart=always
RestartSec=2
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo install -m 0644 /tmp/proxsyncq-node-agent.service /etc/systemd/system/proxsyncq-node-agent.service

if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk '/8000->|:8000->|0.0.0.0:8000|:::8000/{print $1}' | while read -r name; do
    [ -n "$name" ] && sudo docker rm -f "$name" >/dev/null 2>&1 || true
  done
fi

pid="$(sudo ss -ltnp '( sport = :8000 )' 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | head -n1 || true)"
if [ -n "${pid}" ]; then
  sudo kill "${pid}" >/dev/null 2>&1 || true
  sleep 2
fi

sudo systemctl daemon-reload
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter
sudo systemctl enable --now proxsyncq-node-agent
sudo systemctl restart proxsyncq-node-agent
sleep 5

echo "host=$(hostname)"
sudo systemctl is-active proxsyncq-node-agent || true
sudo systemctl is-active prometheus-node-exporter || true
sudo ss -ltnp | grep ':8000' || true
sudo ss -ltnp | grep ':9100' || true
curl -fsS http://127.0.0.1:8000/health || true
echo
curl -fsS http://127.0.0.1:9100/metrics | sed -n '1,2p' || true
REMOTE_VM

  echo
}

for host in "${VMS[@]}"; do
  deploy_agent_service "${host}"
done

echo "== waiting for Prometheus refresh =="
sleep 15

echo "== direct endpoint checks from Pi =="
for host in "${VMS[@]}"; do
  echo "== ${host}:8000/health =="
  curl -fsS --max-time 5 "http://${host}:8000/health" || echo "FAILED"
  echo
  echo "== ${host}:9100/metrics =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | sed -n '1,2p' || echo "FAILED"
  echo
done

echo "== Prometheus node_exporter query =="
curl -fsS --get --data-urlencode 'query=up{job="node_exporter"}' http://127.0.0.1:9090/api/v1/query
echo
echo

echo "== Prometheus node_agent query =="
curl -fsS --get --data-urlencode 'query=up{job="node_agent"}' http://127.0.0.1:9090/api/v1/query
echo
echo

echo "== UI API check =="
curl -fsS http://127.0.0.1:8080/api/dashboard | sed -n '1,120p'
echo
