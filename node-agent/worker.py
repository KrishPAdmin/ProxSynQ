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
