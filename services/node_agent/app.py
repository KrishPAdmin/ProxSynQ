import json
import os
import socket
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pika
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

load_dotenv(Path(__file__).resolve().with_name(".env"))

NODE_NAME = os.getenv("NODE_NAME", socket.gethostname())
SHARED_PATH = os.getenv("SHARED_PATH", "/srv/proxsyncq/shared")
RABBITMQ_HOST = os.getenv("RABBITMQ_HOST", "10.26.0.171")
RABBITMQ_PORT = int(os.getenv("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = os.getenv("RABBITMQ_USER", "proxsyncq")
RABBITMQ_PASS = os.getenv("RABBITMQ_PASS", "proxsyncqpass")
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_DB = os.getenv("POSTGRES_DB", "proxsyncq")
POSTGRES_USER = os.getenv("POSTGRES_USER", "proxsyncq")
POSTGRES_PASS = os.getenv("POSTGRES_PASS", "proxsyncqpass")
QUEUE_NAME = os.getenv("QUEUE_NAME", "proxsyncq_jobs")
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", "3"))
RETRY_DELAY_S = float(os.getenv("RETRY_DELAY_S", "2"))
LEASE_SECONDS = int(os.getenv("LEASE_SECONDS", "30"))

RESULTS_DIR = os.path.join(SHARED_PATH, "results")
SUPPORTED_JOB_TYPES = {"demo_write", "sleep"}

REQUEST_COUNT = Counter("proxsyncq_http_requests_total", "HTTP request count", ["method", "path", "status"])
JOB_SUBMITTED = Counter("proxsyncq_jobs_submitted_total", "Submitted jobs", ["job_type"])
JOB_COMPLETED = Counter("proxsyncq_jobs_completed_total", "Completed jobs", ["job_type", "node"])
JOB_FAILED = Counter("proxsyncq_jobs_failed_total", "Failed jobs", ["job_type", "node"])
JOB_DURATION = Histogram("proxsyncq_job_duration_seconds", "Job runtime", ["job_type", "node"])

app = FastAPI(title="ProxSyncQ Node Agent")


class JobRequest(BaseModel):
    job_type: str
    payload: dict = Field(default_factory=dict)
    idempotency_key: str | None = None
    priority: int = 0


def utc_now():
    return datetime.now(timezone.utc)


def ensure_dirs():
    os.makedirs(RESULTS_DIR, exist_ok=True)


def rabbit_credentials():
    return pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASS)


def rabbit_params():
    return pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        port=RABBITMQ_PORT,
        credentials=rabbit_credentials(),
        heartbeat=30,
        blocked_connection_timeout=30,
    )


def db_conn():
    return psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASS,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def queue_declare():
    conn = pika.BlockingConnection(rabbit_params())
    ch = conn.channel()
    ch.queue_declare(queue=QUEUE_NAME, durable=True)
    ch.close()
    conn.close()


def rabbit_ok():
    conn = pika.BlockingConnection(rabbit_params())
    conn.close()
    return True


def db_ok():
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
    return True


def publish_job(message: dict):
    conn = pika.BlockingConnection(rabbit_params())
    ch = conn.channel()
    ch.queue_declare(queue=QUEUE_NAME, durable=True)
    ch.basic_publish(
        exchange="",
        routing_key=QUEUE_NAME,
        body=json.dumps(message).encode(),
        properties=pika.BasicProperties(delivery_mode=2),
    )
    ch.close()
    conn.close()


def fetch_existing_job_by_key(idempotency_key: str):
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT job_id, job_type, state, submitted_at, submitted_by
                FROM jobs
                WHERE idempotency_key = %s
                """,
                (idempotency_key,),
            )
            return cur.fetchone()


def insert_job(job_id: str, req: JobRequest):
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO jobs (
                    job_id, job_type, payload, idempotency_key, priority,
                    submitted_at, submitted_by, state, attempt_count
                ) VALUES (
                    %s, %s, %s::jsonb, %s, %s, NOW(), %s, 'queued', 0
                )
                """,
                (
                    job_id,
                    req.job_type,
                    json.dumps(req.payload),
                    req.idempotency_key,
                    req.priority,
                    NODE_NAME,
                ),
            )


def claim_job(job_id: str):
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT job_id, job_type, payload, state, attempt_count, submitted_by, idempotency_key
                FROM jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (job_id,),
            )
            row = cur.fetchone()
            if not row:
                return None
            if row["state"] == "succeeded":
                return row
            cur.execute(
                """
                UPDATE jobs
                SET state = 'running',
                    claimed_by = %s,
                    claimed_at = NOW(),
                    lease_expires_at = NOW() + (%s || ' seconds')::interval
                WHERE job_id = %s
                """,
                (NODE_NAME, LEASE_SECONDS, job_id),
            )
            return row


def mark_success(job_id: str, result: dict):
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE jobs
                SET state = 'succeeded',
                    lease_expires_at = NULL,
                    last_error = NULL
                WHERE job_id = %s
                """,
                (job_id,),
            )
            cur.execute(
                """
                INSERT INTO job_results (job_id, finished_at, result)
                VALUES (%s, NOW(), %s::jsonb)
                ON CONFLICT (job_id)
                DO UPDATE SET
                    finished_at = EXCLUDED.finished_at,
                    result = EXCLUDED.result
                """,
                (job_id, json.dumps(result)),
            )


def mark_failure(job_id: str, error_text: str):
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT attempt_count, job_type
                FROM jobs
                WHERE job_id = %s
                FOR UPDATE
                """,
                (job_id,),
            )
            row = cur.fetchone()
            if not row:
                return None
            next_attempt = int(row["attempt_count"]) + 1
            if next_attempt < MAX_ATTEMPTS:
                cur.execute(
                    """
                    UPDATE jobs
                    SET attempt_count = %s,
                        state = 'retry_wait',
                        lease_expires_at = NULL,
                        last_error = %s
                    WHERE job_id = %s
                    """,
                    (next_attempt, error_text[:1000], job_id),
                )
                return {"job_type": row["job_type"], "retry": True, "attempt_count": next_attempt}
            cur.execute(
                """
                UPDATE jobs
                SET attempt_count = %s,
                    state = 'dead_lettered',
                    lease_expires_at = NULL,
                    last_error = %s
                WHERE job_id = %s
                """,
                (next_attempt, error_text[:1000], job_id),
            )
            return {"job_type": row["job_type"], "retry": False, "attempt_count": next_attempt}


def execute_demo_write(job_id: str, payload: dict):
    ensure_dirs()
    result_path = os.path.join(RESULTS_DIR, f"{job_id}.json")
    tmp_path = f"{result_path}.tmp"
    body = {
        "job_id": job_id,
        "job_type": "demo_write",
        "claimed_by": NODE_NAME,
        "message": payload.get("message", "hello from ProxSyncQ"),
        "payload": payload,
        "finished_at": utc_now().isoformat(),
    }
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(body, f, indent=2)
    os.replace(tmp_path, result_path)
    return {
        "result_path": result_path,
        "claimed_by": NODE_NAME,
        "finished_at": body["finished_at"],
    }


def execute_sleep(payload: dict):
    seconds = int(payload.get("seconds", 5))
    seconds = max(1, min(seconds, 30))
    elapsed = 0.0
    while elapsed < seconds:
        time.sleep(0.2)
        elapsed += 0.2
    return {
        "slept_seconds": seconds,
        "claimed_by": NODE_NAME,
        "finished_at": utc_now().isoformat(),
    }


def execute_job(job_id: str, job_type: str, payload: dict):
    if job_type == "demo_write":
        return execute_demo_write(job_id, payload)
    if job_type == "sleep":
        return execute_sleep(payload)
    raise RuntimeError(f"unsupported job_type={job_type}")


def process_message(ch, method, properties, body):
    started = time.time()
    message = json.loads(body.decode())
    job_id = message["job_id"]

    try:
        row = claim_job(job_id)
        if row is None:
            ch.basic_ack(delivery_tag=method.delivery_tag)
            return
        if row["state"] == "succeeded":
            ch.basic_ack(delivery_tag=method.delivery_tag)
            return

        job_type = row["job_type"]
        payload = row["payload"] or {}

        result = execute_job(job_id, job_type, payload)
        mark_success(job_id, result)
        JOB_COMPLETED.labels(job_type=job_type, node=NODE_NAME).inc()
        JOB_DURATION.labels(job_type=job_type, node=NODE_NAME).observe(time.time() - started)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as exc:
        failure = mark_failure(job_id, str(exc))
        if failure is not None:
            JOB_FAILED.labels(job_type=failure["job_type"], node=NODE_NAME).inc()
            if failure["retry"]:
                time.sleep(RETRY_DELAY_S)
                try:
                    publish_job(message)
                    with db_conn() as conn:
                        with conn.cursor() as cur:
                            cur.execute(
                                """
                                UPDATE jobs
                                SET state = 'queued'
                                WHERE job_id = %s
                                """,
                                (job_id,),
                            )
                except Exception:
                    pass
        ch.basic_ack(delivery_tag=method.delivery_tag)


def worker_loop():
    while True:
        try:
            ensure_dirs()
            queue_declare()
            conn = pika.BlockingConnection(rabbit_params())
            ch = conn.channel()
            ch.queue_declare(queue=QUEUE_NAME, durable=True)
            ch.basic_qos(prefetch_count=1)
            ch.basic_consume(queue=QUEUE_NAME, on_message_callback=process_message)
            ch.start_consuming()
        except Exception as exc:
            print(f"[worker] reconnect after error: {exc}", flush=True)
            time.sleep(2)


@app.on_event("startup")
def startup_event():
    ensure_dirs()
    queue_declare()
    t = threading.Thread(target=worker_loop, daemon=True)
    t.start()


@app.get("/health")
def health():
    ensure_dirs()
    status = {
        "node": NODE_NAME,
        "shared_path": SHARED_PATH,
        "shared_path_exists": os.path.isdir(SHARED_PATH),
        "results_dir": RESULTS_DIR,
        "rabbitmq": False,
        "postgres": False,
        "time": utc_now().isoformat(),
    }
    try:
        status["rabbitmq"] = rabbit_ok()
    except Exception:
        status["rabbitmq"] = False
    try:
        status["postgres"] = db_ok()
    except Exception:
        status["postgres"] = False
    code = 200 if status["rabbitmq"] and status["postgres"] and status["shared_path_exists"] else 503
    REQUEST_COUNT.labels(method="GET", path="/health", status=str(code)).inc()
    return JSONResponse(status_code=code, content=status)


@app.get("/metrics")
def metrics():
    REQUEST_COUNT.labels(method="GET", path="/metrics", status="200").inc()
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/jobs")
def submit_job(req: JobRequest):
    if req.job_type not in SUPPORTED_JOB_TYPES:
        REQUEST_COUNT.labels(method="POST", path="/jobs", status="400").inc()
        raise HTTPException(status_code=400, detail=f"unsupported job_type={req.job_type}")

    job_id = str(uuid.uuid4())
    if not req.idempotency_key:
        req.idempotency_key = job_id

    try:
        insert_job(job_id, req)
    except psycopg2.Error as exc:
        if exc.pgcode == "23505":
            existing = fetch_existing_job_by_key(req.idempotency_key)
            REQUEST_COUNT.labels(method="POST", path="/jobs", status="200").inc()
            return {
                "job_id": str(existing["job_id"]),
                "job_type": existing["job_type"],
                "state": existing["state"],
                "submitted_by": existing["submitted_by"],
                "duplicate": True,
            }
        REQUEST_COUNT.labels(method="POST", path="/jobs", status="500").inc()
        raise HTTPException(status_code=500, detail="database insert failed") from exc

    message = {
        "job_id": job_id,
        "job_type": req.job_type,
        "payload": req.payload,
        "idempotency_key": req.idempotency_key,
        "priority": req.priority,
        "submitted_by": NODE_NAME,
        "submitted_at": utc_now().isoformat(),
    }

    try:
        publish_job(message)
    except Exception as exc:
        with db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE jobs
                    SET state = 'failed', last_error = %s
                    WHERE job_id = %s
                    """,
                    (str(exc)[:1000], job_id),
                )
        REQUEST_COUNT.labels(method="POST", path="/jobs", status="500").inc()
        raise HTTPException(status_code=500, detail="broker publish failed") from exc

    JOB_SUBMITTED.labels(job_type=req.job_type).inc()
    REQUEST_COUNT.labels(method="POST", path="/jobs", status="200").inc()
    return {
        "job_id": job_id,
        "job_type": req.job_type,
        "state": "queued",
        "submitted_by": NODE_NAME,
        "duplicate": False,
    }
