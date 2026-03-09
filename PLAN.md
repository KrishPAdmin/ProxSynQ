# ProxSyncQ Task List (Updated with Professor Email Thread + Raspberry Pi Control Plane)

This task list reflects the latest expectations discussed in the email thread with Professor Jaseemuddin, including:
- Clear implementation approach using Python
- Explicit use of the ProxMox VE API for orchestration and fault injection
- A Raspberry Pi out of band quorum/arbiter coordinator option
- A centralized dashboard hosted on the Raspberry Pi for full system visibility

---

## Phase 0: Alignment, repo baseline, and implementation clarity

### 0.1 Confirm project direction with course staff
- [x] Meet or message Deepu to walk through the implementation approach end to end
- [x] Clarify “host vs guest OS” wording:
  - Sync Agent interacts with the guest OS inside each VM (filesystem monitoring, atomic writes)
  - ProxMox host actions happen via the ProxMox VE API (start/stop/reboot, fault injection)
- [x] Reiterate individual completion request and accountability
- [x] Capture Deepu feedback and adjust scope if needed

**Done when:** Deepu and the professor understand the approach clearly and the solo request is addressed.

### 0.2 Repo structure and documentation baseline
- [x] Populate these files with initial content:
  - `README.md`
  - `docs/architecture.md`
  - `docs/quickstart.md`
  - `docs/demo.md`
  - `docs/evaluation.md`
  - `docs/networking.md`
  - `docs/storage-options.md`
  - `docs/failure-tests.md`
- [x] Add a short “Implementation Approach” subsection in `docs/architecture.md` that explicitly mentions:
  - Python services inside VMs
  - ProxMox VE API usage for orchestration and fault injection
  - Optional Raspberry Pi out of band coordinator
- [x] Ensure `docs/demo.md` contains a repeatable demo checklist aligned with failures and recovery

**Done when:** someone can read the docs and understand exactly what will be built and how it will be demonstrated.

### 0.3 Define core system contracts
- [x] Define and document the job message schema:
  - fields: `job_type`, `payload`, `idempotency_key`, `priority`, `timestamp`
- [x] Define the sync scope directory and directory rules:
  - example: `/srv/proxsyncq/watch`
  - define what file types are included or excluded
- [x] Define “conflict” precisely for the Minimum Viable Product and how conflicts are stored/preserved

**Done when:** docs precisely specify formats, paths, and Minimum Viable Product behavior.

---

## Phase 1: VM infrastructure, networking, and ProxMox API access (3-node baseline)

### 1.1 Node identity, connectivity, and time sync
- [x] Set hostnames: `vm1`, `vm2`, `vm3`
- [x] Configure static IPs and update `/etc/hosts` on all nodes
- [x] Confirm SSH connectivity to each node by hostname
- [x] Confirm time sync is correct and consistent on all nodes

**Done when:** you can SSH by hostname to each node and timestamps are consistent across logs.

### 1.2 Ports and basic firewall policy
- [x] Decide where control plane services live for Minimum Viable Product (start on `vm1`)
- [x] Apply firewall rules to allow only required ports on the private subnet
- [x] Document the port matrix in `docs/networking.md`

**Done when:** only required ports are reachable and the network assumptions are documented.

### 1.3 ProxMox VE API integration for orchestration and fault injection
- [ ] Create a ProxMox API token and confirm permissions for:
  - VM status query
  - VM start/stop/reboot
  - snapshot operations (optional)
- [ ] Implement a small Python tool or module for ProxMox control:
  - list VMs, map VM IDs to names
  - reboot a VM by name
  - shutdown a VM by name
- [ ] Document ProxMox API usage in `docs/architecture.md` and `docs/failure-tests.md`

**Done when:** you can reliably trigger fault injections via API and log evidence of the action.

---

## Phase 2: Raspberry Pi control plane (quorum/arbiter + dashboard host)

This phase supports the professor’s emphasis on practical infrastructure and provides an out of band coordinator.

### 2.1 Raspberry Pi base setup
- [ ] Configure Pi static IP and hostname (example: `arbiter`)
- [ ] Secure SSH access
- [ ] Install baseline packages and Python environment or Docker runtime

**Done when:** Pi is stable and reachable, and can run services continuously.

### 2.2 Arbiter quorum coordinator (out of band decision maker)
- [ ] Implement a lightweight arbiter service that monitors node and service health:
  - ping checks
  - API health checks (`/health`)
  - worker heartbeat records (optional)
- [ ] Define quorum rules:
  - how many nodes must be healthy to proceed with certain actions
  - how to avoid repeated restart loops
- [ ] Implement actions the arbiter can initiate:
  - call ProxMox VE API to reboot an unresponsive VM
  - trigger “failover behavior” by requeueing jobs or shifting scheduled audits to healthy nodes
  - optional network isolation fault injection control

**Done when:** if a VM becomes unresponsive, the arbiter can detect it and initiate a controlled response.

### 2.3 Central dashboard hosted on the Raspberry Pi
Goal: a single place showing status of the three VMs and the arbiter.

- [ ] Deploy a monitoring stack on the Pi:
  - Prometheus on Pi
  - Grafana on Pi
- [ ] Add node telemetry from each VM:
  - CPU, memory, disk, network
  - recommend a node exporter per VM
- [ ] Add application telemetry:
  - current queue depth
  - job throughput and latency
  - retries and failures
  - conflicts detected
- [ ] Add operational visibility:
  - past job runs and outcomes (from DB)
  - scheduled tasks (audit schedule, repair schedule)
  - last arbiter actions taken (restart events, failover events)

**Done when:** Grafana dashboards on the Pi show VM health, queue state, job history, scheduled tasks, and arbiter decisions.

---

## Phase 3: Minimum Viable Product control plane services (broker + DB)

### 3.1 Broker and database deployment
- [ ] Deploy a durable broker (RabbitMQ for Minimum Viable Product)
- [ ] Deploy Postgres for metadata and deduplication
- [ ] Create DB schema/tables for:
  - job idempotency and results
  - file version metadata
  - conflict records
  - scheduled task tracking (optional but recommended)

**Done when:** broker accepts messages and DB tables can be queried and updated.

### 3.2 Common service standards
- [ ] Standardize health endpoint: `/health`
- [ ] Standardize metrics endpoint: `/metrics`
- [ ] Standardize configuration via `.env` and environment variables

**Done when:** each running service follows the same patterns for health, metrics, and configuration.

---

## Phase 4: Job queue core implementation

### 4.1 Job API service (Python)
- [ ] Implement `POST /jobs` to publish durable jobs to the broker
- [ ] Support `idempotency_key` propagation in job payloads
- [ ] Add basic request validation
- [ ] Add request and publish latency metrics

**Done when:** jobs can be submitted consistently and are visible in the broker queue.

### 4.2 Worker service (Python)
- [ ] Consume jobs using ack semantics and sensible prefetch
- [ ] Implement idempotency checks using the DB table
- [ ] Implement retry strategy:
  - attempt tracking
  - backoff
  - max retries
- [ ] Record job completion states in the database

**Done when:** killing a worker mid-processing results in safe retries and completion without unsafe duplicates.

### 4.3 Scheduled tasks framework
- [ ] Implement scheduled audit jobs (interval-based)
- [ ] Implement scheduled cleanup jobs (dedupe table retention)
- [ ] Show scheduled tasks in the Pi dashboard (visible schedule and last run state)

**Done when:** you can demonstrate periodic tasks and show their states on the dashboard.

---

## Phase 5: File sync Minimum Viable Product (agent + apply)

### 5.1 Sync Agent event generation (Python)
- [ ] Implement watcher plus periodic scan (interval configurable)
- [ ] Compute and store content hashes for change detection
- [ ] Emit `sync_event` jobs when changes are detected
- [ ] Avoid re-emitting identical state repeatedly

**Done when:** editing a file on one node generates a sync job seen by workers.

### 5.2 Apply logic and atomic writes
- [ ] Implement apply path for `sync_event` jobs in worker logic
- [ ] Stage updates and perform atomic swap to prevent partial writes
- [ ] Update metadata store after successful apply

**Done when:** updates apply cleanly even when processing is interrupted or retried.

---

## Phase 6: Conflict detection Minimum Viable Product

### 6.1 Metadata versioning model
- [ ] Select Minimum Viable Product version model:
  - logical clock, or
  - vector clock (version vectors)
- [ ] Store version and origin node for each file
- [ ] Detect concurrent updates (conflict condition)

**Done when:** the system reliably identifies concurrency rather than overwriting silently.

### 6.2 Conflict workflow
- [ ] Preserve both versions of a conflicting file (deterministic naming or conflict directory)
- [ ] Record a conflict entry in the database
- [ ] Emit a conflict notification marker (job or log event)
- [ ] Expose conflict count and conflict list on the Pi dashboard

**Done when:** concurrent edits produce a deterministic conflict record and both versions remain accessible and visible on the dashboard.

---

## Phase 7: Observability completion (system-wide)

### 7.1 Metrics coverage
- [ ] Job API metrics: request counts, publish latency
- [ ] Worker metrics: processed jobs, retries, failures, dedupe skips
- [ ] Sync metrics: events emitted, apply success/fail, conflicts
- [ ] Arbiter metrics: node health status, actions taken, quorum state
- [ ] Expose `/metrics` endpoints consistently

**Done when:** everything is observable, scrapeable, and dashboarded.

### 7.2 Dashboard completion on Raspberry Pi
- [ ] Dashboard panels:
  - node status: CPU, mem, disk, network for vm1, vm2, vm3, Pi
  - queue: depth, publish rate, consume rate
  - job history: recent jobs, success/fail, retries
  - scheduled tasks: next run time, last run status
  - sync: events emitted, apply rate, convergence signal
  - conflicts: count and latest conflict records
  - arbiter: decisions and last action timeline

**Done when:** the Pi dashboard shows the current status of everything end to end.

---

## Phase 8: Failure tests and repeatable demo scripts (includes ProxMox API + arbiter)

### 8.1 Failure scenarios
- [ ] Worker crash test (kill worker mid-job)
- [ ] Service restart test (restart broker or API service)
- [ ] Partition test (isolate one node for N seconds, restore)
- [ ] Node down test (shutdown one VM, continue, restore and converge)
- [ ] Arbiter response test:
  - make a VM unresponsive
  - confirm the Pi detects it
  - confirm the Pi initiates restart via ProxMox API
  - confirm recovery is visible on the dashboard

**Done when:** each test is repeatable and produces clear evidence in metrics/logs/dashboards.

### 8.2 Evidence collection
- [ ] Save logs and command outputs with timestamps
- [ ] Export screenshots or snapshots of dashboards
- [ ] Record measured convergence time and retry behavior

**Done when:** evidence is organized and directly usable in the interim and final reports.

---

## Phase 9: Storage strategy comparison

### 9.1 Replication-first baseline
- [ ] Run experiments with local replicas:
  - convergence time
  - bandwidth usage
  - conflict behavior under stress

### 9.2 NAS-style shared storage path
- [ ] Add NAS setup and mount instructions
- [ ] Run the same experiments using NAS
- [ ] Compare and decide final approach with justification

**Done when:** a results table and narrative justify the chosen storage approach for final implementation.

---

## Phase 10: Report mapping and deliverable readiness

### 10.1 Interim report requirements (Mar 9)
- [ ] Draft abstract and introduction
- [ ] Design section near-final quality
- [ ] Partial implementation evidence:
  - working job queue
  - working sync event pipeline
  - early dashboard
  - early failure test evidence

### 10.2 Final report requirements (Mar 30)
- [ ] Architecture diagrams:
  - system architecture
  - message flow for sync and job processing
  - arbiter decision flow
- [ ] Implementation section with module breakdown and design decisions
- [ ] Results and analysis with plots/tables
- [ ] Failure and recovery discussion supported by evidence
- [ ] Future work section tied to stretch goals
- [ ] References section completed

**Done when:** the report is coherent, evidence-backed, and reproducible with the repo README and demo steps.

---

## Recommended execution order
1) Phase 0.1 to 0.3 (staff alignment + docs + contracts)
2) Phase 1.1 to 1.3 (networking + ProxMox API tooling)
3) Phase 2.1 to 2.3 (Pi arbiter + Pi dashboard foundation)
4) Phase 3.1 to 3.2 (broker + DB + standards)
5) Phase 4.1 to 4.3 (Job API + Worker + scheduled tasks)
6) Phase 5.1 to 5.2 (Sync Agent emits jobs, worker applies updates)
7) Phase 6.1 to 6.2 (conflicts)
8) Phase 7.1 to 7.2 (dashboard fully complete)
9) Phase 8.1 to 8.2 (fault injection and evidence collection)
10) Phase 9 (storage comparison)
11) Phase 10 (interim and final report completion)

Note - Some automation and scripting support was assisted by AI-based tools, with overall implementation, validation, and integration carried out by me!
