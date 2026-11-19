# aws-dr-failover

A tested multi-region failover on AWS: one container app in Frankfurt (primary) and Ireland (standby),
a DynamoDB global table, ECR cross-region replication and Route 53 failover routing with health checks.
The scripts break the primary region on purpose and measure recovery time (RTO) and data loss (RPO).

| Path | What |
|---|---|
| `app/` | Node.js app: `/api/health` (shallow), `/api/health/deep` (reads DynamoDB), `POST /api/orders` (numbered writes) |
| `infra/00-shared.sh` | DynamoDB global table, ECR + replication, image, IAM roles, ACM certificates |
| `infra/10-region.sh <region> <tasks>` | ALB (HTTPS), ECS Fargate service in the default VPC |
| `infra/20-route53.sh [shallow\|deep]` | Health checks and PRIMARY/SECONDARY failover records |
| `infra/30-fis.sh` | Dedicated subnets for the primary tasks + FIS template that cuts DynamoDB off |
| `infra/31-fis-replication.sh` | FIS template that pauses global table replication |
| `test/failover.js` | k6: 10 numbered writes per second, one JSON line per request |
| `test/run-exp.sh` | One experiment: load, fault, undo, with timestamps in `results/raw/<run>.events` |
| `test/exp3-rpo.sh` | Experiment 3: pause replication, lose the primary, count missing writes |
| `test/break.sh` | Faults: `app-down`, `fis`, `pause-replication`, `pilot-failover`, `standby <n>` and undo |
| `test/analyze.py` | Timeline, RTO and missing writes per run |
| `test/summary.sh`, `test/charts.sh` | Recompute `results/summary.txt` and `results/charts/` |
| `results/raw/` | Every request of every run (JSON lines) and the fault timestamps |
| `infra/cleanup.sh` | Deletes everything |

Edit `infra/env.sh` (hosted zone, regions, AWS profile) before running.

## Results (10 writes/s from one client, Frankfurt primary, Ireland standby)

| Experiment | RTO | Acknowledged writes lost |
|---|---|---|
| 1. Primary tasks stopped, client reuses connections | never failed over (5.5 min outage) | 0 |
| 1b. Same, new connection per request | 84 s | 0 |
| 2a. DynamoDB cut off (FIS), shallow health check | never failed over (4.3 min outage) | 0 |
| 2b. Same, deep health check | 77 s | 0 |
| 3. Replication paused 28 s, then primary lost | 88 s | 272 at failover, 0 after catch-up |
| 4. Pilot light (standby 0 to 1 task at fault time) | 79 s | 0 |

## Order of operations

```bash
infra/00-shared.sh
infra/10-region.sh eu-central-1 2
infra/10-region.sh eu-west-1 1
infra/20-route53.sh shallow
infra/30-fis.sh && infra/31-fis-replication.sh
NO_REUSE=1 test/run-exp.sh exp1b app-down app-up 60 300 480
infra/cleanup.sh
```
