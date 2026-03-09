# ProxSyncQ Demo

## Cluster readiness proof

Run:

./scripts/verify_cluster.sh

Expected proof:
- each VM is reachable
- /srv/proxsyncq/shared is mounted
- each VM can write a proof file
- proof files are visible from the shared path

## Distributed job execution proof

Run the node agent on vm1, vm2, and vm3.

Submit test jobs:

./scripts/submit_batch.sh http://10.26.0.171:8000/jobs 20

Expected proof:
- jobs are accepted by the API on vm1
- workers on multiple VMs consume from the shared queue
- demo_write jobs create result artifacts under /srv/proxsyncq/shared/results
- claimed_by values show which VM executed each job

To inspect DB-backed state:

./scripts/show_jobs.sh

<!-- PROXSYNCQ_DEMO_CONTROL_PLANE -->
## Raspberry Pi control plane demo

Open the Raspberry Pi control plane UI.

Expected proof:

- cluster health is visible for VM1, VM2, VM3, and Pi
- queue summary is visible
- recent jobs are visible
- CPU, memory, root filesystem, and shared mount usage are visible
- the Gluster failover ring is shown as VM1 -> VM2 -> VM3 -> VM1

## Cyclic storage failover proof

Demonstrate the configured client failover mapping:

- VM1 uses backup server VM2
- VM2 uses backup server VM3
- VM3 uses backup server VM1

Expected proof:

- the shared mount remains visible from a client after the current Gluster endpoint is unavailable
- the cyclic next-hop mapping is documented and visible in the control plane
