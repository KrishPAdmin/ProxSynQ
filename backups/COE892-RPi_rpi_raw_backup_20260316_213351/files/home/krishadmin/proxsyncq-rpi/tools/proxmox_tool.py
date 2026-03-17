#!/usr/bin/env python3
"""
proxmox_tool.py  —  ProxSyncQ ProxMox VE API integration
Deploy to: /home/krishadmin/proxsyncq-rpi/tools/proxmox_tool.py

Usage (standalone):
  python3 proxmox_tool.py list
  python3 proxmox_tool.py status 171
  python3 proxmox_tool.py reboot 171
  python3 proxmox_tool.py shutdown 172
  python3 proxmox_tool.py start 173

Import (from arbiter or dashboard):
  from tools.proxmox_tool import ProxmoxClient
  px = ProxmoxClient()
  px.reboot_vm(171)
"""

import os
import sys
import json
import urllib.request
import urllib.error
import ssl
from datetime import datetime, timezone

# ── CONFIG ────────────────────────────────────────────────────────────────────
PROXMOX_HOST   = os.getenv("PROXMOX_HOST",  "10.26.0.50")
PROXMOX_PORT   = int(os.getenv("PROXMOX_PORT", "8006"))
PROXMOX_TOKEN  = os.getenv(
    "PROXMOX_TOKEN",
    "root@pam!proxsyncq=91e9c388-f1f5-41e4-80bc-1bda8ff96999"
)
PROXMOX_NODE   = os.getenv("PROXMOX_NODE", "prox")   # ProxMox node name (visible in UI sidebar)
VM_IDS         = [171, 172, 173]
VM_NAME_MAP    = {171: "COE892-VM-1", 172: "COE892-VM-2", 173: "COE892-VM-3"}
# ─────────────────────────────────────────────────────────────────────────────


class ProxmoxClient:
    def __init__(
        self,
        host: str = PROXMOX_HOST,
        port: int = PROXMOX_PORT,
        token: str = PROXMOX_TOKEN,
        node: str = PROXMOX_NODE,
    ):
        self.base = f"https://{host}:{port}/api2/json"
        self.node = node
        self.headers = {
            "Authorization": f"PVEAPIToken={token}",
            "Content-Type":  "application/json",
        }
        # ProxMox uses a self-signed cert in most lab setups — skip verify
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE

    # ── internal HTTP helpers ─────────────────────────────────────────────────

    def _get(self, path: str) -> dict:
        url = f"{self.base}{path}"
        req = urllib.request.Request(url, headers=self.headers, method="GET")
        with urllib.request.urlopen(req, context=self._ctx, timeout=10) as resp:
            return json.loads(resp.read().decode())

    def _post(self, path: str, data: dict | None = None) -> dict:
        url  = f"{self.base}{path}"
        body = json.dumps(data or {}).encode()
        req  = urllib.request.Request(url, data=body, headers=self.headers, method="POST")
        with urllib.request.urlopen(req, context=self._ctx, timeout=10) as resp:
            return json.loads(resp.read().decode())

    # ── VM query ──────────────────────────────────────────────────────────────

    def list_vms(self) -> list[dict]:
        """Return list of VMs on this ProxMox node."""
        resp = self._get(f"/nodes/{self.node}/qemu")
        vms  = resp.get("data", [])
        return sorted(vms, key=lambda v: v.get("vmid", 0))

    def vm_status(self, vmid: int) -> dict:
        """Return current status for a single VM."""
        resp = self._get(f"/nodes/{self.node}/qemu/{vmid}/status/current")
        data = resp.get("data", {})
        return {
            "vmid":   vmid,
            "name":   VM_NAME_MAP.get(vmid, data.get("name", str(vmid))),
            "status": data.get("status", "unknown"),
            "uptime": data.get("uptime", 0),
            "cpu":    round(data.get("cpu", 0) * 100, 2),
            "mem_mb": round(data.get("mem", 0) / 1024 / 1024, 1),
            "maxmem_mb": round(data.get("maxmem", 0) / 1024 / 1024, 1),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }

    def all_vm_statuses(self) -> list[dict]:
        return [self.vm_status(vmid) for vmid in VM_IDS]

    # ── VM actions ────────────────────────────────────────────────────────────

    def reboot_vm(self, vmid: int) -> dict:
        """Graceful reboot via ACPI (equivalent to clicking Reboot in UI)."""
        resp = self._post(f"/nodes/{self.node}/qemu/{vmid}/status/reboot")
        task = resp.get("data", "")
        _log("REBOOT", vmid, task)
        return {"action": "reboot", "vmid": vmid, "task": task}

    def shutdown_vm(self, vmid: int) -> dict:
        """Graceful shutdown via ACPI."""
        resp = self._post(f"/nodes/{self.node}/qemu/{vmid}/status/shutdown")
        task = resp.get("data", "")
        _log("SHUTDOWN", vmid, task)
        return {"action": "shutdown", "vmid": vmid, "task": task}

    def start_vm(self, vmid: int) -> dict:
        """Start a stopped VM."""
        resp = self._post(f"/nodes/{self.node}/qemu/{vmid}/status/start")
        task = resp.get("data", "")
        _log("START", vmid, task)
        return {"action": "start", "vmid": vmid, "task": task}

    def stop_vm(self, vmid: int) -> dict:
        """Hard stop (power cut — use for fault injection only)."""
        resp = self._post(f"/nodes/{self.node}/qemu/{vmid}/status/stop")
        task = resp.get("data", "")
        _log("STOP_HARD", vmid, task)
        return {"action": "stop", "vmid": vmid, "task": task}

    def task_status(self, upid: str) -> dict:
        """Check status of a running ProxMox task by UPID."""
        node = upid.split(":")[1] if ":" in upid else self.node
        resp = self._get(f"/nodes/{node}/tasks/{urllib.parse.quote(upid, safe='')}/status")
        return resp.get("data", {})


# ── helpers ───────────────────────────────────────────────────────────────────

def _log(action: str, vmid: int, task: str) -> None:
    ts   = datetime.now(timezone.utc).isoformat()
    name = VM_NAME_MAP.get(vmid, str(vmid))
    print(f"[{ts}] {action} vmid={vmid} ({name}) task={task}")


# ── CLI ───────────────────────────────────────────────────────────────────────

def _cli():
    import urllib.parse  # needed for task_status
    args = sys.argv[1:]
    if not args:
        print("Usage: proxmox_tool.py <list|status|reboot|shutdown|start|stop> [vmid]")
        sys.exit(1)

    cmd = args[0]
    px  = ProxmoxClient()

    try:
        if cmd == "list":
            vms = px.list_vms()
            print(f"{'VMID':<8} {'NAME':<20} {'STATUS':<12} {'CPU%':<8} {'MEM MB'}")
            print("-" * 60)
            for vm in vms:
                vmid   = vm.get("vmid", "?")
                name   = VM_NAME_MAP.get(vmid, vm.get("name", "?"))
                status = vm.get("status", "?")
                cpu    = round(vm.get("cpu", 0) * 100, 1)
                mem    = round(vm.get("mem", 0) / 1024 / 1024, 0)
                print(f"{vmid:<8} {name:<20} {status:<12} {cpu:<8} {mem}")

        elif cmd == "status":
            vmids = [int(args[1])] if len(args) > 1 else VM_IDS
            for vmid in vmids:
                s = px.vm_status(vmid)
                print(json.dumps(s, indent=2))

        elif cmd in ("reboot", "shutdown", "start", "stop"):
            if len(args) < 2:
                print(f"Usage: proxmox_tool.py {cmd} <vmid>")
                sys.exit(1)
            vmid = int(args[1])
            fn   = {"reboot": px.reboot_vm, "shutdown": px.shutdown_vm,
                    "start": px.start_vm,   "stop": px.stop_vm}[cmd]
            result = fn(vmid)
            print(json.dumps(result, indent=2))

        else:
            print(f"Unknown command: {cmd}")
            sys.exit(1)

    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"HTTP {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    import urllib.parse
    _cli()
