# Failure tests

## Worker crash
- submit a batch of jobs
- terminate a worker mid-job
- verify redelivery and completion by another worker
- confirm idempotency prevents unsafe duplicate writes

## Node partition
- isolate one VM from the network for a fixed interval
- continue updates on remaining nodes
- restore connectivity
- verify convergence through hashes or audit checks

## Service restart
- restart the broker or metadata service
- verify the system recovers without manual cleanup
