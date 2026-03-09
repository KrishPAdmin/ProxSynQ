# ProxSyncQ Networking

## Node IP map

- COE892-RPi: 10.26.0.170
- COE892-VM-1: 10.26.0.171
- COE892-VM-2: 10.26.0.172
- COE892-VM-3: 10.26.0.173

## Shared storage

The shared Gluster-backed path used by the VMs is:

/srv/proxsyncq/shared

## Hostname mapping

- coe892-rpi / COE892-RPi
- coe892-vm1 / COE892-VM-1
- coe892-vm2 / COE892-VM-2
- coe892-vm3 / COE892-VM-3

## Verification

Cluster readiness is checked with:

./scripts/verify_cluster.sh

<!-- PROXSYNCQ_NETWORKING_CONTROL_PLANE -->
## Raspberry Pi control plane ports

The Raspberry Pi at `10.26.0.170` hosts the monitoring and control plane.

Expected services:

- Prometheus: `9090`
- Grafana: `3000`
- ProxSyncQ Control UI: `8080`
- Node Exporter: `9100`

Application metrics targets:

- VM1 node agent: `10.26.0.171:8000`
- VM2 node agent: `10.26.0.172:8000`
- VM3 node agent: `10.26.0.173:8000`

Host metrics targets:

- Pi node exporter: `10.26.0.170:9100`
- VM1 node exporter: `10.26.0.171:9100`
- VM2 node exporter: `10.26.0.172:9100`
- VM3 node exporter: `10.26.0.173:9100`

## Shared storage failover map

- VM1 mount path `/srv/proxsyncq/shared`: primary `10.26.0.171`, backup `10.26.0.172`
- VM2 mount path `/srv/proxsyncq/shared`: primary `10.26.0.172`, backup `10.26.0.173`
- VM3 mount path `/srv/proxsyncq/shared`: primary `10.26.0.173`, backup `10.26.0.171`
