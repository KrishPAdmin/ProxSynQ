# ProxSynQ

**ProxSynQ** is a distributed cluster management platform built on Proxmox VE, designed for the COE892 course project. It provides job orchestration, bidirectional file synchronization with conflict detection, automated failure recovery, and a real-time monitoring dashboard — all coordinated across a Raspberry Pi control plane and three worker VMs.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    COE892-RPi (10.26.0.170)                 │
│   ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌─────────┐    │
│   │Dashboard │  │Prometheus│  │  Grafana   │ │ Arbiter │    │
│   │ :8080    │  │  :9090   │  │   :3000    │ │  :8090  │    │
│   └──────────┘  └──────────┘  └───────────┘  └─────────┘    │
└────────────────────────┬────────────────────────────────────┘
                         │ health checks / metrics / API
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ COE892-VM-1  │ │ COE892-VM-2  │ │ COE892-VM-3  │
│  10.26.0.171 │ │  10.26.0.172 │ │  10.26.0.173 │
│              │ │              │ │              │
│ Node Agent   │ │ Node Agent   │ │ Node Agent   │
│ Sync Agent   │ │ Sync Agent   │ │ Sync Agent   │
│ Worker       │ │ Worker       │ │ Worker       │
│              │ │              │ │              │
│ Postgres ◄───┼─┼──────────────┼─|─┘            │
│ RabbitMQ     │ │ GlusterFS ◄──┼─|────────┘     │
└──────────────┘ └──────────────┘ └──────────────┘
```

## Repository Structure

```
ProxSynQ/
├── rpi/                        # Raspberry Pi control plane
│   ├── arbiter.py              # Out-of-band quorum coordinator
│   ├── docker-compose.yml      # Prometheus + Grafana + Dashboard
│   ├── control_ui/             # FastAPI dashboard application
│   │   ├── app.py              # Dashboard backend (parallel data fetching)
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── templates/
│   │       ├── index.html      # Dashboard frontend (instant hydration)
│   │       └── login.html
│   ├── prometheus/
│   │   └── prometheus.yml      # Scrape config for all nodes
│   ├── grafana/                # Grafana provisioning + dashboards
│   └── tools/
│       └── proxmox_tool.py     # ProxMox VE API utility
├── node-agent/                 # Deployed to each worker VM
│   ├── app.py                  # FastAPI node agent (/health, /metrics, /jobs)
│   ├── worker.py               # Job executor (demo_write, sleep, crypto_burn)
│   ├── sync_agent.py           # Bidirectional file sync with conflict detection
│   └── requirements.txt
├── db/
│   └── schema.sql              # PostgreSQL schema (6 tables)
├── systemd/                    # Service unit files (reference)
│   ├── proxsyncq-arbiter.service
│   └── proxsyncq-sync-agent.service
└── README.md
```

## Key Features

- **Job Orchestration** — Submit jobs via the dashboard with auto-balancing across healthy nodes based on CPU, memory, and load scoring
- **Bidirectional File Sync** — Watchdog-based push on local changes + periodic pull from GlusterFS shared storage, with version tracking via logical clocks in Postgres
- **Conflict Detection** — Detects concurrent modifications across nodes, preserves both versions, and records conflicts in the database
- **Automated Failure Recovery** — The arbiter polls node health every 30 seconds, detects failures after 3 consecutive misses, and triggers VM start/reboot via the Proxmox API with quorum validation and cooldown enforcement
- **Real-Time Dashboard** — Server-side rendered with instant JSON hydration; 5-second background refresh with parallel data fetching
- **Monitoring Stack** — Prometheus scrapes node exporters and custom agent metrics; Grafana provides historical visualization

## Cluster Topology

| Node | IP | Role |
|---|---|---|
| COE892-RPi | 10.26.0.170 | Dashboard, Prometheus, Grafana, Arbiter |
| COE892-VM-1 | 10.26.0.171 | Worker |
| COE892-VM-2 | 10.26.0.172 | Worker |
| COE892-VM-3 | 10.26.0.173 | Worker |

## Tech Stack

- **Proxmox VE** — Hypervisor and VM lifecycle management
- **Python / FastAPI** — All services (dashboard, node agent, arbiter, sync agent)
- **PostgreSQL** — Job state, file versions, conflicts, sync events, arbiter actions
- **RabbitMQ** — Job queue transport
- **GlusterFS** — Distributed shared storage across all 3 VMs
- **Prometheus + Grafana** — Metrics collection and visualization
- **Docker Compose** — Container orchestration on the RPi

## Acknowledgement

> AI-assisted tooling was used in a limited capacity to help streamline parts of the scripting and automation workflow, while the primary work, system integration, and validation were completed by the author.
