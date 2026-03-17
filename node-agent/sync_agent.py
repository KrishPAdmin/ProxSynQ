#!/usr/bin/env python3
"""
sync_agent.py  —  ProxSyncQ bidirectional file sync agent
Deploy to: /home/krishadmin/proxsyncq-node-agent/sync_agent.py

How it works:
  - Watches LOCAL_WATCH_DIR  (local to this VM, e.g. /srv/proxsyncq/watch)
  - Publishes changes to    SHARED_SYNC_DIR/<node_name>/  (GlusterFS, seen by all)
  - Pulls changes from other nodes' SHARED_SYNC_DIR slots into LOCAL_WATCH_DIR
  - Records every version hash in Postgres
  - Detects conflicts: file changed locally AND from another node since last sync

Directory layout on GlusterFS:
  /srv/proxsyncq/shared/sync/
    COE892-VM-1/   ← VM1 publishes here
    COE892-VM-2/   ← VM2 publishes here
    COE892-VM-3/   ← VM3 publishes here

Run:
  pip install watchdog psycopg2-binary
  python3 sync_agent.py

Env vars (all optional, defaults shown):
  SHARED_PATH       /srv/proxsyncq/shared
  LOCAL_WATCH_DIR   /srv/proxsyncq/watch
  POSTGRES_HOST     10.26.0.171
  POSTGRES_PORT     5432
  POSTGRES_DB       proxsyncq
  POSTGRES_USER     proxsyncq
  POSTGRES_PASS     proxsyncqpass
  PULL_INTERVAL     10        (seconds between pull scans)
  NODE_NAME         <hostname>
"""

import hashlib
import logging
import os
import shutil
import socket
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
import psycopg2.extras
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

# ── CONFIG ────────────────────────────────────────────────────────────────────
SHARED_PATH     = os.getenv("SHARED_PATH",     "/srv/proxsyncq/shared")
LOCAL_WATCH_DIR = os.getenv("LOCAL_WATCH_DIR", "/srv/proxsyncq/watch")
SHARED_SYNC_DIR = os.path.join(SHARED_PATH, "sync")
CONFLICT_DIR    = os.path.join(SHARED_PATH, "conflicts")

PG_HOST  = os.getenv("POSTGRES_HOST", "10.26.0.171")
PG_PORT  = int(os.getenv("POSTGRES_PORT", "5432"))
PG_DB    = os.getenv("POSTGRES_DB",   "proxsyncq")
PG_USER  = os.getenv("POSTGRES_USER", "proxsyncq")
PG_PASS  = os.getenv("POSTGRES_PASS", "proxsyncqpass")

PULL_INTERVAL = int(os.getenv("PULL_INTERVAL", "10"))
NODE_NAME     = os.getenv("NODE_NAME", socket.gethostname())
# ─────────────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("sync_agent")


# ── DB helpers ────────────────────────────────────────────────────────────────

def _db_connect():
    return psycopg2.connect(
        host=PG_HOST, port=PG_PORT,
        dbname=PG_DB, user=PG_USER, password=PG_PASS,
        connect_timeout=5,
    )


def _upsert_version(conn, node: str, rel_path: str, content_hash: str, size: int):
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO file_versions
                (node_name, file_path, content_hash, logical_clock, size_bytes, updated_at)
            VALUES (%s, %s, %s,
                COALESCE((SELECT logical_clock FROM file_versions
                          WHERE node_name=%s AND file_path=%s), 0) + 1,
                %s, NOW())
            ON CONFLICT (node_name, file_path)
            DO UPDATE SET
                content_hash  = EXCLUDED.content_hash,
                logical_clock = file_versions.logical_clock + 1,
                size_bytes    = EXCLUDED.size_bytes,
                updated_at    = NOW()
        """, (node, rel_path, content_hash, node, rel_path, size))
        conn.commit()


def _get_version(conn, node: str, rel_path: str) -> dict | None:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT content_hash, logical_clock, updated_at
            FROM file_versions
            WHERE node_name=%s AND file_path=%s
        """, (node, rel_path))
        row = cur.fetchone()
        return dict(row) if row else None


def _all_versions_for_path(conn, rel_path: str) -> list[dict]:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT node_name, content_hash, logical_clock, updated_at
            FROM file_versions
            WHERE file_path=%s
        """, (rel_path,))
        return [dict(r) for r in cur.fetchall()]


def _record_conflict(conn, rel_path: str,
                     node_a: str, hash_a: str, clock_a: int, path_a: str,
                     node_b: str, hash_b: str, clock_b: int, path_b: str):
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO conflicts
                (file_path, node_a, node_b, hash_a, hash_b,
                 clock_a, clock_b, saved_path_a, saved_path_b, detected_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,NOW())
        """, (rel_path, node_a, node_b, hash_a, hash_b,
              clock_a, clock_b, path_a, path_b))
        conn.commit()


def _log_event(conn, event_type: str, rel_path: str,
               from_node: str | None = None, detail: str | None = None):
    try:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO sync_events
                    (node_name, event_type, file_path, from_node, detail, occurred_at)
                VALUES (%s,%s,%s,%s,%s,NOW())
            """, (NODE_NAME, event_type, rel_path, from_node, detail))
            conn.commit()
    except Exception as e:
        log.warning("sync_events insert failed: %s", e)


# ── file helpers ──────────────────────────────────────────────────────────────

def _hash_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _rel(abs_path: str) -> str:
    """Return path relative to LOCAL_WATCH_DIR."""
    return os.path.relpath(abs_path, LOCAL_WATCH_DIR)


def _shared_copy(rel_path: str) -> str:
    """Path of this node's published copy on shared storage."""
    return os.path.join(SHARED_SYNC_DIR, NODE_NAME, rel_path)


def _atomic_write(dest: str, src: str):
    """Copy src → dest atomically via a temp file in the same directory."""
    dest_dir = os.path.dirname(dest)
    os.makedirs(dest_dir, exist_ok=True)
    tmp = dest + ".tmp"
    shutil.copy2(src, tmp)
    os.replace(tmp, dest)


# ── push (local → shared) ────────────────────────────────────────────────────

def push_file(rel_path: str, conn):
    """Copy a changed local file to our shared slot and record the new hash."""
    local_abs  = os.path.join(LOCAL_WATCH_DIR, rel_path)
    shared_abs = _shared_copy(rel_path)

    if not os.path.isfile(local_abs):
        return  # deleted — handle separately if needed

    try:
        new_hash = _hash_file(local_abs)
        size     = os.path.getsize(local_abs)

        # skip if shared copy already matches (avoids loops)
        if os.path.isfile(shared_abs) and _hash_file(shared_abs) == new_hash:
            return

        _atomic_write(shared_abs, local_abs)
        _upsert_version(conn, NODE_NAME, rel_path, new_hash, size)
        _log_event(conn, "pushed", rel_path, detail=new_hash[:12])
        log.info("PUSH  %s  (%s)", rel_path, new_hash[:12])

    except Exception as e:
        log.error("push_file error %s: %s", rel_path, e)


# ── pull (shared → local) ────────────────────────────────────────────────────

def pull_all(conn):
    """
    Scan every other node's shared slot.
    For each file:
      - if we have no local copy       → pull it
      - if remote hash ≠ our hash      → check for conflict, then pull or record
      - if hashes match                → nothing to do
    """
    sync_root = Path(SHARED_SYNC_DIR)
    if not sync_root.exists():
        return

    for node_dir in sync_root.iterdir():
        remote_node = node_dir.name
        if remote_node == NODE_NAME or not node_dir.is_dir():
            continue

        for remote_file in node_dir.rglob("*"):
            if not remote_file.is_file() or remote_file.suffix == ".tmp":
                continue

            rel_path  = str(remote_file.relative_to(node_dir))
            local_abs = os.path.join(LOCAL_WATCH_DIR, rel_path)

            try:
                remote_hash = _hash_file(str(remote_file))
                remote_ver  = _get_version(conn, remote_node, rel_path)
                my_ver      = _get_version(conn, NODE_NAME,   rel_path)

                # ── no local copy yet → clean pull ───────────────────────────
                if not os.path.isfile(local_abs):
                    _atomic_write(local_abs, str(remote_file))
                    size = os.path.getsize(local_abs)
                    _upsert_version(conn, NODE_NAME, rel_path, remote_hash, size)
                    _log_event(conn, "pulled", rel_path, from_node=remote_node,
                               detail=remote_hash[:12])
                    log.info("PULL  %s  from %s  (%s)", rel_path, remote_node, remote_hash[:12])
                    continue

                local_hash = _hash_file(local_abs)

                # ── already in sync ───────────────────────────────────────────
                if local_hash == remote_hash:
                    continue

                # ── determine if conflict ─────────────────────────────────────
                # Conflict = both local AND remote changed since the last common
                # synced hash (i.e. my stored hash ≠ remote stored hash AND
                # my local file ≠ my stored hash — local was also modified).
                my_stored_hash = my_ver["content_hash"] if my_ver else None
                local_also_changed = (
                    os.path.isfile(local_abs) and local_hash != remote_hash
                )
                if local_also_changed:
                    _handle_conflict(conn, rel_path, remote_node,
                                     remote_file, remote_hash, remote_ver,
                                     local_abs, local_hash, my_ver)
                else:
                    # remote is newer, local is unchanged — safe pull
                    _atomic_write(local_abs, str(remote_file))
                    size = os.path.getsize(local_abs)
                    _upsert_version(conn, NODE_NAME, rel_path, remote_hash, size)
                    _log_event(conn, "pulled", rel_path, from_node=remote_node,
                               detail=remote_hash[:12])
                    log.info("PULL  %s  from %s  (%s)", rel_path, remote_node, remote_hash[:12])

            except Exception as e:
                log.error("pull error %s from %s: %s", rel_path, remote_node, e)


def _handle_conflict(conn, rel_path: str,
                     remote_node: str, remote_file: Path, remote_hash: str,
                     remote_ver: dict | None,
                     local_abs: str, local_hash: str, my_ver: dict | None):
    """
    Both sides changed. Preserve both versions under CONFLICT_DIR and record
    in Postgres. Does NOT overwrite either side — human or future policy resolves.
    """
    ts    = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    stem  = rel_path.replace("/", "__")

    save_local  = os.path.join(CONFLICT_DIR, f"{stem}.{NODE_NAME}.{ts}")
    save_remote = os.path.join(CONFLICT_DIR, f"{stem}.{remote_node}.{ts}")

    os.makedirs(CONFLICT_DIR, exist_ok=True)
    shutil.copy2(local_abs,       save_local)
    shutil.copy2(str(remote_file), save_remote)

    clock_local  = my_ver["logical_clock"]  if my_ver     else 0
    clock_remote = remote_ver["logical_clock"] if remote_ver else 0

    _record_conflict(conn, rel_path,
                     NODE_NAME,    local_hash,  clock_local,  save_local,
                     remote_node,  remote_hash, clock_remote, save_remote)
    _log_event(conn, "conflict_detected", rel_path, from_node=remote_node,
               detail=f"local={local_hash[:8]} remote={remote_hash[:8]}")

    log.warning("CONFLICT  %s  local=%s  %s=%s  → saved to %s",
                rel_path, local_hash[:12], remote_node, remote_hash[:12], CONFLICT_DIR)


# ── watchdog handler (push on local change) ───────────────────────────────────

class SyncHandler(FileSystemEventHandler):
    def __init__(self, conn_factory):
        self._conn_factory = conn_factory
        self._conn         = conn_factory()
        self._lock         = threading.Lock()

    def _reconnect(self):
        try:
            self._conn.close()
        except Exception:
            pass
        self._conn = self._conn_factory()

    def _handle(self, path: str):
        if not os.path.isfile(path) or path.endswith(".tmp"):
            return
        rel = _rel(path)
        if rel.startswith(".."):
            return  # outside watch dir
        with self._lock:
            try:
                push_file(rel, self._conn)
            except (psycopg2.OperationalError, psycopg2.InterfaceError):
                log.warning("DB connection lost, reconnecting…")
                self._reconnect()
                push_file(rel, self._conn)

    def on_modified(self, event):
        if not event.is_directory:
            self._handle(event.src_path)

    def on_created(self, event):
        if not event.is_directory:
            self._handle(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._handle(event.dest_path)


# ── pull loop (background thread) ─────────────────────────────────────────────

class PullThread(threading.Thread):
    def __init__(self, conn_factory):
        super().__init__(daemon=True, name="pull-loop")
        self._conn_factory = conn_factory
        self._conn         = conn_factory()

    def run(self):
        while True:
            try:
                pull_all(self._conn)
            except (psycopg2.OperationalError, psycopg2.InterfaceError):
                log.warning("Pull thread DB reconnecting…")
                try:
                    self._conn = self._conn_factory()
                except Exception as e:
                    log.error("DB reconnect failed: %s", e)
            except Exception as e:
                log.error("pull_all error: %s", e)
            time.sleep(PULL_INTERVAL)


# ── startup ───────────────────────────────────────────────────────────────────

def _bootstrap_dirs():
    for d in [LOCAL_WATCH_DIR,
              os.path.join(SHARED_SYNC_DIR, NODE_NAME),
              CONFLICT_DIR]:
        os.makedirs(d, exist_ok=True)
        log.info("ensured dir: %s", d)


def main():
    log.info("ProxSyncQ sync agent starting  node=%s", NODE_NAME)
    log.info("  watch dir   : %s", LOCAL_WATCH_DIR)
    log.info("  shared sync : %s", SHARED_SYNC_DIR)
    log.info("  pull interval: %ds", PULL_INTERVAL)

    _bootstrap_dirs()

    # test DB connection early
    try:
        conn_test = _db_connect()
        conn_test.close()
        log.info("DB connection OK  (%s:%s/%s)", PG_HOST, PG_PORT, PG_DB)
    except Exception as e:
        log.error("DB connection FAILED: %s  — continuing without DB", e)

    # push any files already in local watch dir at startup
    try:
        conn = _db_connect()
        for root, _, files in os.walk(LOCAL_WATCH_DIR):
            for fname in files:
                abs_path = os.path.join(root, fname)
                push_file(_rel(abs_path), conn)
        conn.close()
    except Exception as e:
        log.warning("startup push scan failed: %s", e)

    # start pull loop
    pull_thread = PullThread(_db_connect)
    pull_thread.start()
    log.info("pull loop started (every %ds)", PULL_INTERVAL)

    # start watchdog
    handler  = SyncHandler(_db_connect)
    observer = Observer()
    observer.schedule(handler, LOCAL_WATCH_DIR, recursive=True)
    observer.start()
    log.info("watchdog started on %s", LOCAL_WATCH_DIR)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log.info("shutting down…")
        observer.stop()
    observer.join()
    log.info("sync agent stopped")


if __name__ == "__main__":
    main()
