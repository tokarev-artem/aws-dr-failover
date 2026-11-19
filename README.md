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
| `test/failover.js` | k6: 10 numbered writes per second, one JSON line per request |
| `test/break.sh` | Faults: `app-down`, `db-down` and their undo |
| `test/analyze.py` | Timeline, RTO and missing writes per run |
| `infra/cleanup.sh` | Deletes everything |

Edit `infra/env.sh` (hosted zone, regions, AWS profile) before running.
