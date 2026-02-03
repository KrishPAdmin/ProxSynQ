# ProxSyncQ

Private cloud platform for:
- distributed file replication with conflict detection
- reliable distributed job processing with retries and deduplication

This repository provides a reproducible deployment and a repeatable demo plan.

## Project summary
ProxSyncQ runs across three VM nodes and combines:
1) a file sync subsystem that propagates updates and detects concurrent changes
2) a job queue subsystem that distributes background work with crash recovery

A storage comparison is included:
- replication-first local replicas on each VM
- optional NAS-style shared storage path

## Architecture
See:
- `docs/architecture.md`
- `diagrams/architecture.drawio`

## Quickstart
Start here:
- `docs/quickstart.md`

## Demo
Repeatable demo procedure:
- `docs/demo.md`
- `docs/failure-tests.md`

## Evaluation
Metrics and experiments:
- `docs/evaluation.md`

## Networking
Network assumptions and ports:
- `docs/networking.md`
