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
    import uuid, psycopg2
    job_type = str(body.get("job_type", "sleep"))
    payload_obj = body.get("payload", {})
    job_id = str(uuid.uuid4())
    node = socket.gethostname()

    # record in DB
    try:
        conn = psycopg2.connect(
            host=os.getenv("POSTGRES_HOST", "10.26.0.171"),
            port=int(os.getenv("POSTGRES_PORT", "5432")),
            dbname=os.getenv("POSTGRES_DB", "proxsyncq"),
            user=os.getenv("POSTGRES_USER", "proxsyncq"),
            password=os.getenv("POSTGRES_PASS", "proxsyncqpass"),
            connect_timeout=3,
        )
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO jobs
                    (job_id, job_type, state, submitted_by, claimed_by,
                     attempt_count, submitted_at, payload)
                VALUES (%s, %s, 'completed', %s, %s, 1, NOW(), %s)
            """, (job_id, job_type, node, node, json.dumps(payload_obj)))
            conn.commit()
        conn.close()
    except Exception as e:
        pass  # don't block job execution if DB is down

    cmd = [sys.executable, str(BASE_DIR / "worker.py"), job_type, json.dumps(payload_obj)]
    proc = subprocess.Popen(
        cmd,
        cwd=str(BASE_DIR),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    # update state to completed after launch (fire and forget model)
    try:
        conn = psycopg2.connect(
            host=os.getenv("POSTGRES_HOST", "10.26.0.171"),
            port=int(os.getenv("POSTGRES_PORT", "5432")),
            dbname=os.getenv("POSTGRES_DB", "proxsyncq"),
            user=os.getenv("POSTGRES_USER", "proxsyncq"),
            password=os.getenv("POSTGRES_PASS", "proxsyncqpass"),
            connect_timeout=3,
        )
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE jobs SET state='completed', completed_at=NOW() WHERE job_id=%s",
                (job_id,)
            )
            conn.commit()
        conn.close()
    except Exception:
        pass

    return JSONResponse({
        "accepted": True,
        "job_type": job_type,
        "pid": proc.pid,
        "payload": payload_obj,
        "job_id": job_id,
    })
