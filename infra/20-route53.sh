#!/usr/bin/env bash
# Health checks + failover records for $DOMAIN. Usage: 20-route53.sh [shallow|deep]
set -euo pipefail
source "$(dirname "$0")/env.sh"
MODE=${1:-shallow}
PATH_=/api/health; [ "$MODE" = "deep" ] && PATH_=/api/health/deep

hc() { # region -> health check id (create or update)
  local R=$1 id
  id=$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$R.$DOMAIN'].Id|[0]" --output text)
  if [ "$id" = "None" ]; then
    id=$(aws route53 create-health-check --caller-reference "$APP-$R-$(date +%s)" --health-check-config "{
      \"Type\":\"HTTPS\",\"FullyQualifiedDomainName\":\"$R.$DOMAIN\",\"Port\":443,\"ResourcePath\":\"$PATH_\",
      \"EnableSNI\":true,\"RequestInterval\":10,\"FailureThreshold\":3,\"MeasureLatency\":false}" \
      --query HealthCheck.Id --output text)
    aws route53 change-tags-for-resource --resource-type healthcheck --resource-id $id \
      --add-tags Key=Name,Value=$APP-$R >/dev/null
  else
    aws route53 update-health-check --health-check-id $id --resource-path $PATH_ >/dev/null
  fi
  echo $id; }

record() { # region failover-role health-check-id
  local R=$1 ROLE=$2 HC=$3 dns zone
  read dns zone < <(aws elbv2 describe-load-balancers --region $R --names $APP \
    --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text)
  echo "{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$DOMAIN\",\"Type\":\"A\",
    \"SetIdentifier\":\"$R\",\"Failover\":\"$ROLE\",\"HealthCheckId\":\"$HC\",
    \"AliasTarget\":{\"HostedZoneId\":\"$zone\",\"DNSName\":\"$dns\",\"EvaluateTargetHealth\":false}}}"; }

HC_P=$(hc $PRIMARY); HC_S=$(hc $SECONDARY)
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch \
  "{\"Changes\":[$(record $PRIMARY PRIMARY $HC_P),$(record $SECONDARY SECONDARY $HC_S)]}" >/dev/null
echo "health checks ($MODE, $PATH_): $PRIMARY=$HC_P $SECONDARY=$HC_S"
echo "URL=https://$DOMAIN"
