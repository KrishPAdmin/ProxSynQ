# Demo plan

## Goals
- show file updates propagate across nodes
- show conflict detection when two nodes update the same file
- show crash recovery for job processing
- show convergence after a temporary partition

## Demo sequence
### 1) Baseline operation
- start services on all nodes
- confirm each node is reachable
- submit a few test jobs and show they are processed

### 2) File propagation
- edit a file on node A
- show node B and node C receive the update

### 3) Conflict case
- edit the same file on node A and node B within a short interval
- show conflict is detected and both versions are preserved

### 4) Worker crash recovery
- submit a batch of jobs
- kill a worker mid-processing
- show redelivery and completion on another worker

### 5) Partition and convergence
- isolate node C temporarily
- apply updates on nodes A and B
- restore node C connectivity
- show node C converges to the latest consistent state

## Evidence to show
- queue depth and job acknowledgements
- logs for retries and dedupe behavior
- file hashes or audit output proving convergence
