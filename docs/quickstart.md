# Quickstart

## Assumptions
- Multiple VMs on a private network with static IPs
- Each VM has the same CPU and memory profile
- A job broker and metadata store are reachable on the network

## Initial setup
1) Copy `.env.example` to `.env` and adjust values for each VM.
2) Create the watch directory:
   - `/srv/proxsyncq/watch`

## Run plan
Implementation will support two run modes:
- local dev mode on one machine
- multi-node mode with services split across VMs

## What to verify first
- The Job API responds on its health endpoint
- Workers can consume a test job from the queue
- Creating or editing a file in the watch directory produces a sync event

## Next steps
- Implement minimal Job API
- Implement minimal Worker that logs job execution
- Implement Sync Agent that scans the watch directory periodically
