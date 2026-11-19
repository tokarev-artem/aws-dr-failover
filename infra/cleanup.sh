#!/usr/bin/env bash
# Deletes everything the other scripts created. Safe to run more than once.
set -uo pipefail
source "$(dirname "$0")/env.sh"

echo "== Route 53 records and health checks"
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID --output json |
python3 -c '
import json,sys,os
d=os.environ["DOMAIN"]+"."
rs=[r for r in json.load(sys.stdin)["ResourceRecordSets"] if r["Name"]==d or r["Name"].endswith("."+d)]
print(json.dumps({"Changes":[{"Action":"DELETE","ResourceRecordSet":r} for r in rs]}) if rs else "")' > /tmp/$APP-del.json
[ -s /tmp/$APP-del.json ] && aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch file:///tmp/$APP-del.json >/dev/null
for id in $(aws route53 list-health-checks --query "HealthChecks[?ends_with(HealthCheckConfig.FullyQualifiedDomainName||'', '$DOMAIN')].Id" --output text); do
  aws route53 delete-health-check --health-check-id $id; done

for R in $PRIMARY $SECONDARY; do
  export AWS_REGION=$R; echo "== $R"
  aws ecs update-service --cluster $APP --service $APP --desired-count 0 >/dev/null 2>&1
  aws ecs delete-service --cluster $APP --service $APP --force >/dev/null 2>&1 && \
    aws ecs wait services-inactive --cluster $APP --services $APP
  for td in $(aws ecs list-task-definitions --family-prefix $APP --query taskDefinitionArns --output text); do
    aws ecs deregister-task-definition --task-definition $td >/dev/null; aws ecs delete-task-definitions --task-definitions $td >/dev/null 2>&1; done
  aws ecs delete-cluster --cluster $APP >/dev/null 2>&1
  ALB=$(aws elbv2 describe-load-balancers --names $APP --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
  if [ -n "$ALB" ] && [ "$ALB" != "None" ]; then
    aws elbv2 delete-load-balancer --load-balancer-arn $ALB
    aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB
  fi
  TG=$(aws elbv2 describe-target-groups --names $APP --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  for i in 1 2 3 4 5 6; do [ -z "$TG" ] || [ "$TG" = "None" ] && break
    aws elbv2 delete-target-group --target-group-arn $TG 2>/dev/null && break; sleep 10; done
  VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  for name in $APP-task $APP-alb; do   # task SG references the ALB SG, so delete it first
    id=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=$name --query 'SecurityGroups[0].GroupId' --output text)
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$id" = "None" ] && break
      aws ec2 delete-security-group --group-id $id 2>/dev/null && break; sleep 15; done   # ENIs take a while to go away
  done
  aws logs delete-log-group --log-group-name /ecs/$APP 2>/dev/null
  for c in $(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text); do
    aws acm delete-certificate --certificate-arn $c; done
done
unset AWS_REGION

echo "== DynamoDB global table (replica first, then the table)"
aws dynamodb update-table --table-name $APP --region $PRIMARY --replica-updates "Delete={RegionName=$SECONDARY}" >/dev/null 2>&1 && \
  until [ "$(aws dynamodb describe-table --table-name $APP --region $PRIMARY --query 'length(Table.Replicas||`[]`)')" = "0" ]; do sleep 20; done
aws dynamodb delete-table --table-name $APP --region $PRIMARY >/dev/null 2>&1

echo "== ECR (both regions) and the replication rule"
aws ecr put-replication-configuration --region $PRIMARY --replication-configuration '{"rules":[]}' >/dev/null
for R in $PRIMARY $SECONDARY; do aws ecr delete-repository --repository-name $APP --region $R --force >/dev/null 2>&1; done

echo "== IAM"
aws iam delete-role-policy --role-name $APP-task --policy-name dynamodb 2>/dev/null
aws iam delete-role-policy --role-name $APP-task --policy-name simulate-dynamodb-outage 2>/dev/null
aws iam delete-role --role-name $APP-task 2>/dev/null
aws iam detach-role-policy --role-name $APP-exec --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null
aws iam delete-role --role-name $APP-exec 2>/dev/null
echo "done"
