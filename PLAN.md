# ProxSyncQ Task List

This task list is derived directly from the project proposal and is organized by phases so work can be executed and demonstrated incrementally.

---

## Phase 0: Repo and planning baseline

### 0.1 Repo structure and documentation baseline
- [ ] Populate the repo scaffold files with initial content:
  - `README.md`
  - `docs/architecture.md`
  - `docs/quickstart.md`
  - `docs/demo.md`
  - `docs/evaluation.md`
  - `docs/networking.md`
  - `docs/storage-options.md`
  - `docs/failure-tests.md`
- [ ] Ensure `docs/quickstart.md` provides one clear "first run" path
- [ ] Ensure `docs/demo.md` contains a repeatable demo checklist

**Done when:** an evaluator can read Quickstart and Demo and understand how the system will be run and tested.

### 0.2 Define core system contracts
- [ ] Define and document the job message schema:
  - fields: `job_type`, `payload`, `idempotency_key`, `priority`, `timestamp`
- [ ] Define and document the sync scope directory (example: `/srv/proxsyncq/watch`)
- [ ] Define and document the conflict definition rule for MVP

**Done when:** docs precisely specify formats, paths, and MVP behavior.

---

## Phase 1: VM infrastructure and networking (3-node baseline)

### 1.1 Node identity, connectivity, and time sync
- [ ] Set hostnames: `vm1`, `vm2`, `vm3`
- [ ] Configure static IPs and update `/etc/hosts` on all nodes
- [ ] Confirm SSH connectivity to each node by hostname
- [ ] Confirm time sync is correct and consistent on all nodes

**Done when:** you can SSH by hostname to each node and timestamps are consistent across logs.

### 1.2 Ports and basic firewall policy
- [ ] Decide where control-plane services live for MVP (start on `vm1`)
- [ ] Apply firewall rules to allow only required ports on the private subnet
- [ ] Document the port matrix in `docs/networking.md`

**Done when:** only required ports are reachable and the network assumptions are documented.

---

## Phase 2: MVP control plane on a single node

### 2.1 Broker and database deployment
- [ ] Deploy a durable broker (initially RabbitMQ)
- [ ] Deploy Postgres for metadata and deduplication
- [ ] Create DB schema/tables for:
  - job idempotency and results
  - file version metadata
  - conflict records

**Done when:** broker accepts messages and DB tables can be queried and updated.

### 2.2 Common service standards
- [ ] Standardize health endpoint: `/health`
- [ ] Standardize metrics endpoint: `/metrics`
- [ ] Standardize configuration via `.env` and environment variables

**Done when:** each running service follows the same patterns for health, metrics, and configuration.

---

## Phase 3: Job queue core implementation

### 3.1 Job API service
- [ ] Implement `POST /jobs` to publish durable jobs to the broker
- [ ] Support `idempotency_key` propagation in job payloads
- [ ] Add basic request validation
- [ ] Add request and publish latency metrics

**Done when:** jobs can be submitted consistently and are visible in the broker queue.

### 3.2 Worker service
- [ ] Consume jobs using ack semantics and sensible prefetch
- [ ] Implement idempotency checks using the DB table
- [ ] Implement retry strategy:
  - attempt tracking
  - backoff
  - max retries
- [ ] Record job completion states in the database

**Done when:** killing a worker mid-processing results in safe retries and completion without unsafe duplicates.

---

## Phase 4: File sync MVP

### 4.1 Sync Agent event generation
- [ ] Implement watcher plus periodic scan (interval configurable)
- [ ] Compute and store content hashes for change detection
- [ ] Emit `sync_event` jobs when changes are detected
- [ ] Avoid re-emitting identical state repeatedly

**Done when:** editing a file on one node generates a sync job seen by workers.

### 4.2 Apply logic and atomic writes
- [ ] Implement apply path for `sync_event` jobs in worker logic
- [ ] Stage updates and perform atomic swap to prevent partial writes
- [ ] Update metadata store after successful apply

**Done when:** updates apply cleanly even when processing is interrupted or retried.

---

## Phase 5: Conflict detection MVP

### 5.1 Metadata versioning model
- [ ] Select MVP version model:
  - logical clock, or
  - vector clock (version vectors)
- [ ] Store version and origin node for each file
- [ ] Detect concurrent updates (conflict condition)

**Done when:** the system reliably identifies concurrency rather than overwriting silently.

### 5.2 Conflict workflow
- [ ] Preserve both versions of a conflicting file (deterministic naming or conflict directory)
- [ ] Record a conflict entry in the database
- [ ] Emit a conflict notification marker (job or log event)

**Done when:** concurrent edits produce a deterministic conflict record and both versions remain accessible.

---

## Phase 6: Observability (metrics and dashboards)

### 6.1 Metrics coverage
- [ ] Job API metrics: request counts, publish latency
- [ ] Worker metrics: processed jobs, retries, failures, dedupe skips
- [ ] Sync metrics: events emitted, apply success/fail, conflicts
- [ ] Expose `/metrics` endpoints consistently

**Done when:** key signals can be scraped and visualized for demo and report evidence.

### 6.2 Monitoring stack
- [ ] Configure Prometheus scraping
- [ ] Create Grafana dashboard(s) for:
  - queue depth
  - throughput
  - retry counts
  - conflict counts
  - convergence timing estimate

**Done when:** dashboards provide clear proof of system behavior during normal and failure conditions.

---

## Phase 7: Failure tests and repeatable demo scripts

### 7.1 Failure scenarios
- [ ] Worker crash test (kill worker mid-job)
- [ ] Service restart test (restart broker or API service)
- [ ] Partition test (isolate one node for N seconds, restore)
- [ ] Node down test (shutdown one VM, continue, restore and converge)

**Done when:** each test is repeatable and produces visible evidence in metrics/logs.

### 7.2 Evidence collection
- [ ] Save logs and command outputs with timestamps
- [ ] Export screenshots or snapshots of dashboards
- [ ] Record measured convergence time and retry behavior

**Done when:** evidence is organized and directly usable in the interim and final reports.

---

## Phase 8: Storage strategy comparison

### 8.1 Replication-first baseline
- [ ] Run experiments with local replicas:
  - convergence time
  - bandwidth usage
  - conflict behavior under stress

### 8.2 NAS-style shared storage path
- [ ] Add NAS setup and mount instructions
- [ ] Run the same experiments using NAS
- [ ] Compare and decide final approach with justification

**Done when:** a results table and narrative justify the chosen storage approach for final implementation.

---

## Phase 9: Report mapping and deliverable readiness

### 9.1 Interim report requirements (Mar 9)
- [ ] Draft abstract and introduction
- [ ] Design section near-final quality
- [ ] Partial implementation evidence (screenshots, early metrics, early failure tests)

### 9.2 Final report requirements (Mar 30)
- [ ] Architecture diagram and relevant sequence diagrams
- [ ] Implementation section with module breakdown and design decisions
- [ ] Results and analysis with plots/tables
- [ ] Failure and recovery discussion supported by evidence
- [ ] Future work section tied to stretch goals
- [ ] References section completed

**Done when:** the report is coherent, evidence-backed, and reproducible with the repo README and demo steps.

---

## Recommended first execution order
1) Phase 1.1 and 1.2 (network and ports)
2) Phase 2.1 (broker + DB + schema)
3) Phase 3.1 and 3.2 (Job API + Worker)
4) Phase 4.1 (Sync Agent emits jobs)

This sequence produces a working distributed core early, enabling resilience testing before the full feature set is complete.
