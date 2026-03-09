## Current shared storage failover behavior

ProxSyncQ currently uses a Gluster-backed shared mount at:

/srv/proxsyncq/shared

Each VM mounts the same volume using a primary Gluster server and a backup Gluster server, forming a cyclic failover chain:

- VM1: primary 10.26.0.171, backup 10.26.0.172
- VM2: primary 10.26.0.172, backup 10.26.0.173
- VM3: primary 10.26.0.173, backup 10.26.0.171

This means that if the current Gluster endpoint used by a client becomes unavailable, the client can reconnect through the next server in the ring. This behavior is configured in scripts/setup_node.sh and persisted into /etc/fstab using backupvolfile-server.

This failover chain is part of the current storage access path and should be demonstrated in the failure tests and demo checklist.

<!-- PROXSYNCQ_GLUSTER_FAILOVER_RING -->
## Current shared storage failover behavior

ProxSyncQ currently uses a Gluster-backed shared mount at:

/srv/proxsyncq/shared

Each VM mounts the same volume using a primary Gluster server and a backup Gluster server, forming a cyclic failover chain:

- VM1: primary 10.26.0.171, backup 10.26.0.172
- VM2: primary 10.26.0.172, backup 10.26.0.173
- VM3: primary 10.26.0.173, backup 10.26.0.171

This failover pattern is configured in `scripts/setup_node.sh` through `backupvolfile-server` and persisted into `/etc/fstab`.

This means the current storage access path is cyclic from a client perspective:

- VM1 -> VM2
- VM2 -> VM3
- VM3 -> VM1

If a client loses its current Gluster endpoint, it can reconnect through the next server in the ring.

## Current storage visibility goals

The Raspberry Pi control plane will show:

- shared mount presence on each VM
- shared mount usage on each VM
- the cyclic Gluster failover mapping
- failure-test evidence showing the next-hop backup path
