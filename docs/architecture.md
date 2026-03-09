
<!-- PROXSYNCQ_ARCH_RPI_CONTROL_PLANE -->
## Raspberry Pi control plane

The Raspberry Pi acts as the ProxSyncQ control and visibility plane.

It hosts:

- Prometheus for metrics collection
- Grafana for dashboards
- a ProxSyncQ Control UI for job submission, queue visibility, cluster health, and Gluster failover visibility

The VM nodes continue to host the distributed worker logic, while the Pi provides a single operational surface for observing and driving the system.
