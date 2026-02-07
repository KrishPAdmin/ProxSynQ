# Storage Options

This document describes the storage requirements for ProxSynQ, the storage approach currently implemented in the COE892 lab environment, and alternative designs that can be evaluated.

## Table of Contents
- [1. Storage requirements](#1-storage-requirements)
- [2. Current implementation in the lab](#2-current-implementation-in-the-lab)
  - [2.1 What is stored where](#21-what-is-stored-where)
  - [2.2 GlusterFS replicated shared directory](#22-glusterfs-replicated-shared-directory)
  - [2.3 Mount and failover strategy](#23-mount-and-failover-strategy)
  - [2.4 Permissions model](#24-permissions-model)
  - [2.5 Verification procedure](#25-verification-procedure)
  - [2.6 Failure behavior and expectations](#26-failure-behavior-and-expectations)
  - [2.7 Split brain risk and mitigation](#27-split-brain-risk-and-mitigation)
- [3. Alternative storage options](#3-alternative-storage-options)
  - [3.1 NFS share (centralized)](#31-nfs-share-centralized)
  - [3.2 Samba share (centralized)](#32-samba-share-centralized)
  - [3.3 Rsync and scheduled replication](#33-rsync-and-scheduled-replication)
  - [3.4 Syncthing (peer replication)](#34-syncthing-peer-replication)
  - [3.5 CephFS or RBD (Proxmox-native distributed storage)](#35-cephfs-or-rbd-proxmox-native-distributed-storage)
  - [3.6 DRBD (block replication)](#36-drbd-block-replication)
  - [3.7 Object storage (S3 compatible)](#37-object-storage-s3-compatible)
- [4. Comparison matrix](#4-comparison-matrix)
- [5. Evaluation plan](#5-evaluation-plan)
- [6. Recommendations for ProxSynQ](#6-recommendations-for-proxsynq)

---

## 1. Storage requirements

ProxSynQ needs storage that supports:

1) Shared artifacts
- Job input bundles and output artifacts
- Logs, status reports, and debug evidence for demos
- A single shared path that any node can read and write

2) Availability under node failure
- If one VM fails, the remaining VMs should still access shared artifacts

3) Consistency and safety
- Writes should be visible to peers quickly
- The system should avoid silent divergence where two nodes believe different versions are correct

4) Reasonable performance
- Enough throughput for file sync tasks and moderate job outputs
- Predictable latency for small metadata operations

5) Operational simplicity in a lab environment
- Setup and recovery must be repeatable with scripts
- Debugging should be feasible during a live demo

---

## 2. Current implementation in the lab

### 2.1 What is stored where

Current approach separates responsibilities:

A) Shared file artifacts
- Stored on a replicated shared directory mounted at:
  /srv/proxsyncq/shared

B) Job coordination and job state
- Implemented separately from the filesystem layer
- The filesystem is not the job queue. It is the shared artifact store.

This separation prevents filesystem issues from directly corrupting job state logic.

### 2.2 GlusterFS replicated shared directory

The lab uses GlusterFS with a replicated volume across three VM peers.

Nodes:
- VM1: 10.26.0.171  COE892-VM-1
- VM2: 10.26.0.172  COE892-VM-2
- VM3: 10.26.0.173  COE892-VM-3

Volume:
- Volume name: proxsyncqvol
- Brick path on each VM:
  /gluster/brick1/proxsyncq

Client mounts:
- VMs mount the GlusterFS volume at:
  /srv/proxsyncq/shared
- RPi mounts the same volume as a client for monitoring and reading artifacts:
  10.26.0.170  COE892-RPi

### 2.3 Mount and failover strategy

Each node mounts using a primary volfile server and one backup. The goal is that no single node is a permanent bootstrap dependency.

Recommended /etc/fstab lines:

VM1:
  10.26.0.171:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.172 0 0

VM2:
  10.26.0.172:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.173 0 0

VM3:
  10.26.0.173:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.171 0 0

RPi:
  10.26.0.172:/proxsyncqvol /srv/proxsyncq/shared glusterfs defaults,_netdev,backupvolfile-server=10.26.0.173 0 0

This ensures that if VM1 is down, VM2 and VM3 still have an available volfile server for remount operations.

### 2.4 Permissions model

To allow clean multi-node writes, a shared group is used.

On VM1, VM2, VM3:
    sudo groupadd -f proxsyncq
    sudo usermod -aG proxsyncq krishadmin

Then set ownership and enable setgid on the mounted directory so new files inherit the group:
    sudo chown -R krishadmin:proxsyncq /srv/proxsyncq/shared
    sudo chmod 2775 /srv/proxsyncq/shared

Expected:
- Directory group is proxsyncq
- Permissions resemble drwxrwsr-x

### 2.5 Verification procedure

A) Confirm the mount is GlusterFS on each node:
    sudo findmnt /srv/proxsyncq/shared
    stat -f -c '%T  %m' /srv/proxsyncq/shared

Expected filesystem type:
- glusterfs for findmnt
- fuse.glusterfs from stat

B) Create a proof file on one VM and confirm it appears on the others:

On VM2:
    TS=$(date +%s)
    echo "proof from $(hostname) at $TS" > /srv/proxsyncq/shared/proof_$(hostname)_$TS.txt
    sync

On VM1 and VM3:
    ls -l /srv/proxsyncq/shared | tail -n 10
    cat /srv/proxsyncq/shared/proof_* | tail -n 5

C) Confirm RPi can see the same artifacts:
    ls -l /srv/proxsyncq/shared | tail -n 10

### 2.6 Failure behavior and expectations

With a 3-way replicated volume:

- If one VM is down, reads and writes should still work from the remaining VMs.
- If two VMs are down, the volume is effectively unavailable because there is not enough replication to serve consistent data.

Important:
- The filesystem may remain mounted during a single-node failure, but performance can degrade and operations may block depending on the failure mode.

### 2.7 Split brain risk and mitigation

Any replicated filesystem can encounter split brain during network partitions or abrupt failures.

Recommended mitigations:

1) Prefer majority behavior
- In a 3-node setup, a 2-node partition should be treated as authoritative over a 1-node partition.

2) Enable and verify quorum related settings for replicate volumes
- Check current settings:
    sudo gluster volume get proxsyncqvol all | grep -i quorum

- If quorum is not set, consider enabling a quorum mode aligned with a 3-node replicate design:
    sudo gluster volume set proxsyncqvol cluster.quorum-type auto

Notes:
- Exact quorum behavior depends on Gluster version and volume options.
- Any change to quorum policy should be tested using an intentional partition test.

3) Operational rule
- During a suspected partition, treat the system as degraded and avoid making conflicting manual edits on different nodes.

---

## 3. Alternative storage options

### 3.1 NFS share (centralized)

Description:
- One node exports an NFS share, other nodes mount it.

Pros:
- Simple setup
- Good performance for many workloads

Cons:
- Single point of failure unless paired with HA mechanisms
- HA NFS adds complexity (floating IP, pacemaker, DRBD, etc.)

Use case:
- Fastest path for a basic demo, not ideal for peer-first resilience.

### 3.2 Samba share (centralized)

Description:
- Similar to NFS but often used for Windows interoperability.

Pros:
- Easy in mixed OS environments

Cons:
- Not a good fit for Linux-first distributed systems where HA is required
- Same single point of failure problem unless HA is added

### 3.3 Rsync and scheduled replication

Description:
- Periodic push or pull replication between nodes.

Pros:
- Simple and transparent
- Works without special kernel filesystems

Cons:
- Not real-time
- Conflict resolution is hard
- Not ideal for shared directory semantics

Use case:
- Backups, archival, or periodic sync tasks.

### 3.4 Syncthing (peer replication)

Description:
- Peer-to-peer file sync daemon with conflict handling.

Pros:
- Peer-first and easy to scale
- Good for user file sync style workloads

Cons:
- Conflict behavior can be surprising for automation workflows
- Does not provide a strict single shared directory semantic like a mounted filesystem
- Harder to reason about atomic operations

Use case:
- Distributing artifacts and configs, not ideal as the primary shared job workspace.

### 3.5 CephFS or RBD (Proxmox-native distributed storage)

Description:
- Distributed storage system integrated into Proxmox ecosystems.
- CephFS provides a shared filesystem. RBD provides block devices.

Pros:
- Designed for HA and scale
- Fits strongly with Proxmox and cluster architecture

Cons:
- Higher resource and operational complexity
- More tuning and monitoring required

Use case:
- Strong candidate if the lab resources support it and you want a Proxmox-aligned story.

### 3.6 DRBD (block replication)

Description:
- Replicates a block device between nodes, often used with an HA cluster manager.

Pros:
- Strong consistency and mature HA patterns

Cons:
- Typically active-passive for a filesystem, not active-active
- Requires HA stack orchestration for failover

Use case:
- HA single-writer designs, not ideal for peer active-active shared directory needs.

### 3.7 Object storage (S3 compatible)

Description:
- Store artifacts as objects instead of a mounted shared directory.

Pros:
- Strong durability patterns
- Scales well

Cons:
- Not POSIX filesystem semantics
- Requires application changes to read and write objects

Use case:
- Artifact store for reports and outputs if you prefer API-first storage.

---

## 4. Comparison matrix

| Option | Model | Availability | Consistency | Complexity | Notes |
|---|---|---:|---:|---:|---|
| GlusterFS replicate 3 | mounted shared FS | medium-high | medium-high | medium | Active-active shared path, needs partition testing |
| NFS | mounted shared FS | low | high | low | Central server becomes a dependency |
| Samba | mounted shared FS | low | medium | low | Better for Windows use cases |
| Rsync | periodic replication | medium | low-medium | low | Not real-time, conflicts possible |
| Syncthing | peer replication | medium-high | low-medium | medium | Conflict files possible, semantics differ from shared FS |
| CephFS | mounted shared FS | high | high | high | Strong HA, heavier footprint |
| DRBD | replicated block device | high (with HA) | high | high | More active-passive patterns |
| Object storage | API store | high | high | medium-high | Requires application changes |

Interpretation:
- For a peer-first shared directory, GlusterFS and CephFS are the most aligned.
- For minimal complexity, NFS is easiest but centralizes failure risk.

---

## 5. Evaluation plan

For each candidate, measure:

1) Setup time and recovery time
- Time to bootstrap on clean VMs
- Time to rejoin after a node rebuild

2) Behavior under failure
- One node down
- Network partition 1 vs 2
- Service crash and restart

3) Consistency validation
- Create file on node A, confirm immediate visibility on node B and C
- Simultaneous writes, measure conflict behavior

4) Performance
- Small file metadata performance (create, rename, delete)
- Throughput for moderate sized artifact files

5) Operational simplicity
- How easy it is to debug during a demo
- Whether behavior is explainable with clear logs and commands

---

## 6. Recommendations for ProxSynQ

Current recommendation for the lab:
- Keep GlusterFS replicate 3 as the shared artifact store at /srv/proxsyncq/shared.
- Treat the filesystem as artifact storage, not as the job queue.
- Implement peer job coordination separately (distributed DB or consensus-based coordination).
- Add explicit failure tests for partitions and validate quorum settings to reduce split brain risk.

If future scope expands:
- Evaluate CephFS if Proxmox-aligned HA storage becomes a priority and resources allow it.
- Consider object storage if artifacts grow large and filesystem semantics become less important.
