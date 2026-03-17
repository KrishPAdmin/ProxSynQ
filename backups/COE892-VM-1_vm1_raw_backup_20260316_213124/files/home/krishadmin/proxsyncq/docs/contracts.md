# ProxSyncQ Contracts

## Shared path

Primary shared path:

/srv/proxsyncq/shared

Result artifacts for executed jobs are written under:

/srv/proxsyncq/shared/results

## Job schema

Each submitted job uses this logical schema:

- job_id
- job_type
- payload
- idempotency_key
- priority
- submitted_at
- submitted_by

## First supported job types

- demo_write
- sleep

## Initial job states

- queued
- claimed
- running
- succeeded
- failed
- retry_wait
- dead_lettered

## Lease model

A worker claims a job and records:
- claimed_by
- claimed_at
- lease_expires_at

While running, the worker periodically refreshes the lease.

If the lease expires before completion, the job may be reclaimed by another worker.

## Retry policy

- retryable failures move to retry_wait
- max attempts is configurable
- after max attempts, state becomes dead_lettered

## Idempotency rule

The same idempotency_key must not cause duplicate final side effects for the same logical job scope.

## First side effect rule

For demo_write, the result artifact must be written once per completed job_id under the shared results directory.
