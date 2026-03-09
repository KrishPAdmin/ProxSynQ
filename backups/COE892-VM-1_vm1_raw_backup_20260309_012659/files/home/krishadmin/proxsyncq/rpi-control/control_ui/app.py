import json
import os
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
    {"name": "COE892-RPi", "ip": "10.26.0.170", "agent_port": None, "node_exporter_port": 9100},
    {"name": "COE892-VM-1", "ip": "10.26.0.171", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-2", "ip": "10.26.0.172", "agent_port": 8000, "node_exporter_port": 9100},
    {"name": "COE892-VM-3", "ip": "10.26.0.173", "agent_port": 8000, "node_exporter_port": 9100},
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
    rows = []
    for node in get_nodes():
        rows.append({
            "node": node,
            "health": get_health(node),
            "metrics": get_metrics(node),
        })
        time.sleep(0.03)

    jobs = [serialize_job(job) for job in recent_jobs()]
    return {
        "queue": rabbit_queue_summary(),
        "rows": rows,
        "jobs": jobs,
        "failover_ring": FAILOVER_RING,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


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
    auth = need_auth_redirect(request)
    if auth:
        return auth

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
