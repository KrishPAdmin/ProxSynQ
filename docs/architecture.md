# Architecture

## Overview
ProxSyncQ runs across multiple VM nodes and integrates two infrastructure subsystems:
1) file synchronization with conflict detection
2) distributed job processing with retries and deduplication

The design targets eventual convergence under partitions and node restarts, and safe at-least-once job execution using idempotency.

## Components
### File sync
- Sync Agent (per node)
  - watches a directory and detects changes
  - produces sync events and schedules replication jobs
  - applies remote updates using an atomic staging approach
- Metadata
  - tracks file version information for concurrency detection
  - stores file hashes to validate correctness

### Job processing
- Job API
  - accepts job submissions with job type, payload, and idempotency key
- Broker
  - durable queue with ack and redelivery
- Worker (per node)
  - consumes jobs and processes them
  - uses idempotency and a dedupe store to prevent unsafe duplicates

## Integration
- File changes become jobs so replication can be throttled, retried, and replayed.
- Periodic audit jobs validate convergence and schedule repairs.

## Execution semantics
- Jobs: at-least-once with idempotency keys and deduplication
- Replication: eventual convergence with explicit conflict detection
