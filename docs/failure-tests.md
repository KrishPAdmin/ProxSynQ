
<!-- PROXSYNCQ_FAILURE_TESTS_RING -->
## Gluster client failover ring test

Goal: show that each VM client mount has a next-hop backup Gluster server.

Configuration under test:

- VM1: primary `10.26.0.171`, backup `10.26.0.172`
- VM2: primary `10.26.0.172`, backup `10.26.0.173`
- VM3: primary `10.26.0.173`, backup `10.26.0.171`

Test pattern:

1. confirm `/srv/proxsyncq/shared` is mounted
2. perform a shared read or write
3. make the current Gluster endpoint unavailable
4. verify the client continues through the configured backup server
5. capture evidence in logs, screenshots, and control-plane metrics

Expected outcome:

- shared storage remains reachable from the client
- the cyclic next-hop path matches the configured backup server
