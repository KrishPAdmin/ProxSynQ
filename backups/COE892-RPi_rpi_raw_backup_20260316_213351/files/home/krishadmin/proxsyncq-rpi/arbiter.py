#!/usr/bin/env python3
"""
arbiter.py  —  ProxSyncQ out-of-band quorum coordinator
Deploy to: /home/krishadmin/proxsyncq-rpi/arbiter.py

What it does:
  - Polls /health on all 3 VMs every POLL_INTERVAL seconds
  - Marks a node as failed after FAIL_THRESHOLD consecutive missed checks
  - Reboots the VM via ProxMox API, records action in arbiter_actions table
  - Enforces a COOLDOWN_SECONDS window per VM to avoid reboot loops
  - Exposes GET /status on port 8090 so the dashboard can query arbiter state
  - Logs everything to stdout (journald captures it)

Run standalone:  python3 arbiter.py
Service:         sudo systemctl start proxsyncq-arbiter
"""

import http.server
import json
import logging
import os
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ── install guard ─────────────────────────────────────────────────────────────
try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("ERROR: psycopg2 not found. Run: pip3 install psycopg2-binary requests")
    sys.exit(1)

try:
    import requests as _req
except ImportError:
    print("ERROR: requests not found. Run: pip3 install psycopg2-binary requests")
    sys.exit(1)

# ── CONFIG ────────────────────────────────────────────────────────────────────
POLL_INTERVAL    = int(os.getenv("POLL_INTERVAL",    "30"))   # seconds between health checks
FAIL_THRESHOLD   = int(os.getenv("FAIL_THRESHOLD",   "3"))    # consecutive failures before action
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "300"))  # 5 min between reboots per VM
STATUS_PORT      = int(os.getenv("STATUS_PORT",      "8090"))
HEALTH_TIMEOUT   = float(os.getenv("HEALTH_TIMEOUT", "4.0"))

PG_HOST = os.getenv("POSTGRES_HOST", "10.26.0.171")
PG_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
PG_DB   = os.getenv("POSTGRES_DB",   "proxsyncq")
PG_USER = os.getenv("POSTGRES_USER", "proxsyncq")
PG_PASS = os.getenv("POSTGRES_PASS", "proxsyncqpass")

PROXMOX_HOST  = os.getenv("PROXMOX_HOST",  "10.26.0.50")
PROXMOX_PORT  = int(os.getenv("PROXMOX_PORT", "8006"))
PROXMOX_TOKEN = os.getenv(
    "PROXMOX_TOKEN",
    "root@pam!proxsyncq=91e9c388-f1f5-41e4-80bc-1bda8ff96999"
)
PROXMOX_NODE  = os.getenv("PROXMOX_NODE", "prox")

NODES = [
    {"name": "COE892-VM-1", "ip": "10.26.0.171", "agent_port": 8000, "vmid": 171},
    {"name": "COE892-VM-2", "ip": "10.26.0.172", "agent_port": 8000, "vmid": 172},
    {"name": "COE892-VM-3", "ip": "10.26.0.173", "agent_port": 8000, "vmid": 173},
]
# ─────────────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [arbiter] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("arbiter")

# ── shared state (read by status endpoint, written by poll loop) ──────────────
_state_lock = threading.RLock()
_node_state: dict[str, dict] = {
    n["name"]: {
        "name":         n["name"],
        "ip":           n["ip"],
        "vmid":         n["vmid"],
        "healthy":      None,       # True / False / None (unknown)
        "fail_count":   0,
        "last_check":   None,
        "last_healthy": None,
        "last_action":  None,
        "last_reboot":  None,       # timestamp of last triggered reboot
        "health_data":  None,
    }
    for n in NODES
}
_arbiter_started = datetime.now(timezone.utc).isoformat()


# ── DB helpers ────────────────────────────────────────────────────────────────

def _db():
    return psycopg2.connect(
        host=PG_HOST, port=PG_PORT,
        dbname=PG_DB, user=PG_USER, password=PG_PASS,
        connect_timeout=5,
    )


def _record_action(action: str, target: str, reason: str,
                   proxmox_task: str | None, outcome: str):
    try:
        conn = _db()
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO arbiter_actions
                    (action, target, reason, proxmox_task, triggered_at, outcome)
                VALUES (%s, %s, %s, %s, NOW(), %s)
            """, (action, target, reason, proxmox_task, outcome))
            conn.commit()
        conn.close()
        log.info("DB: recorded action=%s target=%s outcome=%s", action, target, outcome)
    except Exception as e:
        log.error("DB: failed to record action: %s", e)


# ── ProxMox API ───────────────────────────────────────────────────────────────

def _px_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _px_post(path: str, data: dict | None = None) -> dict:
    url     = f"https://{PROXMOX_HOST}:{PROXMOX_PORT}/api2/json{path}"
    headers = {
        "Authorization": f"PVEAPIToken={PROXMOX_TOKEN}",
        "Content-Type":  "application/json",
    }
    body = json.dumps(data or {}).encode()
    req  = urllib.request.Request(url, data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, context=_px_ctx(), timeout=10) as resp:
        return json.loads(resp.read().decode())


def start_vm(vmid: int) -> tuple[bool, str]:
    """Start a stopped VM."""
    try:
        resp = _px_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/start")
        task = resp.get("data", "")
        log.info("ProxMox: start vmid=%d task=%s", vmid, task)
        return True, str(task)
    except urllib.error.HTTPError as e:
        msg = e.read().decode()
        log.error("ProxMox: start vmid=%d HTTP %d: %s", vmid, e.code, msg)
        return False, msg
    except Exception as e:
        log.error("ProxMox: start vmid=%d error: %s", vmid, e)
        return False, str(e)


def reboot_vm(vmid: int) -> tuple[bool, str]:
    """Graceful ACPI reboot. Returns (success, task_id_or_error)."""
    try:
        resp = _px_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/reboot")
        task = resp.get("data", "")
        log.info("ProxMox: reboot vmid=%d task=%s", vmid, task)
        return True, str(task)
    except urllib.error.HTTPError as e:
        msg = e.read().decode()
        log.error("ProxMox: reboot vmid=%d HTTP %d: %s", vmid, e.code, msg)
        return False, msg
    except Exception as e:
        log.error("ProxMox: reboot vmid=%d error: %s", vmid, e)
        return False, str(e)


# ── health check ──────────────────────────────────────────────────────────────

def check_node(node: dict) -> tuple[bool, dict | None]:
    url = f"http://{node['ip']}:{node['agent_port']}/health"
    try:
        resp = _req.get(url, timeout=HEALTH_TIMEOUT)
        if resp.status_code == 200:
            return True, resp.json()
        return False, None
    except Exception:
        return False, None


# ── quorum decision ───────────────────────────────────────────────────────────

def quorum_allows_reboot(target_name: str) -> bool:
    """
    Only reboot if at least one OTHER node is healthy.
    Prevents rebooting when the whole cluster is down (network issue on Pi side).
    """
    healthy_others = 0
    with _state_lock:
        for name, st in _node_state.items():
            if name != target_name and st["healthy"] is True:
                healthy_others += 1
    if healthy_others == 0:
        log.warning("QUORUM: no healthy peers — skipping reboot of %s", target_name)
        return False
    return True


def in_cooldown(node_name: str) -> bool:
    with _state_lock:
        last = _node_state[node_name].get("last_reboot")
    if last is None:
        return False
    elapsed = time.time() - last
    if elapsed < COOLDOWN_SECONDS:
        log.info("COOLDOWN: %s rebooted %.0fs ago, skipping (cooldown=%ds)",
                 node_name, elapsed, COOLDOWN_SECONDS)
        return True
    return False


# ── main poll loop ────────────────────────────────────────────────────────────

def poll_once():
    for node in NODES:
        name   = node["name"]
        vmid   = node["vmid"]
        ok, data = check_node(node)
        now    = time.time()
        now_ts = datetime.now(timezone.utc).isoformat(timespec="seconds")

        with _state_lock:
            st = _node_state[name]
            st["last_check"] = now_ts

            if ok:
                st["healthy"]      = True
                st["fail_count"]   = 0
                st["last_healthy"] = now_ts
                st["health_data"]  = data
                log.debug("OK   %s", name)
            else:
                st["healthy"]    = False
                st["fail_count"] = st["fail_count"] + 1
                st["health_data"] = None
                fc = st["fail_count"]
                log.warning("FAIL %s  consecutive=%d", name, fc)

                if fc >= FAIL_THRESHOLD:
                    if not in_cooldown(name) and quorum_allows_reboot(name):
                        log.warning("ACTION: rebooting %s (vmid=%d) after %d failures",
                                    name, vmid, fc)
                        st["last_reboot"] = now
                        st["fail_count"]  = 0
                        st["last_action"] = f"reboot triggered @ {now_ts}"
                        should_reboot = True
                    else:
                        should_reboot = False
                else:
                    should_reboot = False

                if should_reboot:
                    # check actual ProxMox power state — start if stopped, reboot if running
                    try:
                        url = f"https://{PROXMOX_HOST}:{PROXMOX_PORT}/api2/json/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/current"
                        req = urllib.request.Request(
                            url,
                            headers={"Authorization": f"PVEAPIToken={PROXMOX_TOKEN}"},
                            method="GET"
                        )
                        resp = urllib.request.urlopen(req, context=_px_ctx(), timeout=5)
                        vm_status = json.loads(resp.read())["data"]["status"]
                    except Exception as e:
                        log.error("Could not get VM status for vmid=%d: %s", vmid, e)
                        vm_status = "unknown"

                    if vm_status == "stopped":
                        log.warning("VM %d is stopped — sending START", vmid)
                        success, task = start_vm(vmid)
                        action_name = "start_vm"
                    else:
                        log.warning("VM %d is %s — sending REBOOT", vmid, vm_status)
                        success, task = reboot_vm(vmid)
                        action_name = "reboot_vm"

                    outcome = "success" if success else "failed"
                    reason  = f"node failed {FAIL_THRESHOLD} consecutive health checks (vm_status={vm_status})"
                    _record_action(action_name, name, reason, task if success else None, outcome)
                    with _state_lock:
                        _node_state[name]["last_action"] = (
                            f"{action_name} {'ok' if success else 'FAILED'} @ {now_ts}"
                        )


def poll_loop():
    log.info("Poll loop started — interval=%ds fail_threshold=%d cooldown=%ds",
             POLL_INTERVAL, FAIL_THRESHOLD, COOLDOWN_SECONDS)
    while True:
        try:
            poll_once()
        except Exception as e:
            log.error("poll_once error: %s", e)
        time.sleep(POLL_INTERVAL)


# ── status HTTP server ────────────────────────────────────────────────────────

class StatusHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request logs

    def do_GET(self):
        if self.path not in ("/status", "/health"):
            self.send_response(404)
            self.end_headers()
            return

        with _state_lock:
            snapshot = {k: dict(v) for k, v in _node_state.items()}

        healthy_count = sum(1 for s in snapshot.values() if s["healthy"] is True)
        total         = len(snapshot)

        payload = {
            "arbiter":       "COE892-RPi",
            "started_at":    _arbiter_started,
            "checked_at":    datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "quorum":        f"{healthy_count}/{total}",
            "quorum_ok":     healthy_count >= (total // 2 + 1),
            "nodes":         list(snapshot.values()),
            "poll_interval": POLL_INTERVAL,
            "fail_threshold": FAIL_THRESHOLD,
            "cooldown":      COOLDOWN_SECONDS,
        }

        body = json.dumps(payload, default=str).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def status_server():
    server = http.server.HTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    log.info("Status endpoint: http://0.0.0.0:%d/status", STATUS_PORT)
    server.serve_forever()


# ── entrypoint ────────────────────────────────────────────────────────────────

def main():
    log.info("ProxSyncQ arbiter starting")
    log.info("  nodes        : %s", [n["name"] for n in NODES])
    log.info("  poll interval: %ds", POLL_INTERVAL)
    log.info("  fail threshold: %d", FAIL_THRESHOLD)
    log.info("  cooldown     : %ds", COOLDOWN_SECONDS)
    log.info("  proxmox      : %s:%d  node=%s", PROXMOX_HOST, PROXMOX_PORT, PROXMOX_NODE)
    log.info("  postgres     : %s:%d/%s", PG_HOST, PG_PORT, PG_DB)

    # test DB
    try:
        conn = _db()
        conn.close()
        log.info("DB connection OK")
    except Exception as e:
        log.error("DB connection FAILED: %s — arbiter will retry each cycle", e)

    # test ProxMox connectivity
    try:
        url = f"https://{PROXMOX_HOST}:{PROXMOX_PORT}/api2/json/nodes"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"PVEAPIToken={PROXMOX_TOKEN}"},
            method="GET"
        )
        urllib.request.urlopen(req, context=_px_ctx(), timeout=5)
        log.info("ProxMox API connection OK")
    except Exception as e:
        log.error("ProxMox API connection FAILED: %s — reboot actions will fail", e)

    # run initial poll immediately
    try:
        poll_once()
    except Exception as e:
        log.error("Initial poll error: %s", e)

    # start status server in background thread
    t = threading.Thread(target=status_server, daemon=True, name="status-server")
    t.start()

    # start poll loop (blocks forever)
    poll_loop()


if __name__ == "__main__":
    main()
