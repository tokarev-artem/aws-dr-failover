#!/usr/bin/env bash
# One region: security groups, ALB (HTTPS), ECS cluster + service. Usage: 10-region.sh <region> <desired-count>
set -euo pipefail
source "$(dirname "$0")/env.sh"
R=$1; DESIRED=${2:-1}
export AWS_REGION=$R

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')
echo "== $R  VPC=$VPC  SUBNETS=$SUBNETS"

sg() { # name description
  local id; id=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=$1 \
    --query 'SecurityGroups[0].GroupId' --output text)
  [ "$id" != "None" ] && echo $id && return
  aws ec2 create-security-group --group-name $1 --description "$2" --vpc-id $VPC --query GroupId --output text; }
ALB_SG=$(sg $APP-alb "HTTP/HTTPS from the internet")
TASK_SG=$(sg $APP-task "Port 3000 from the ALB only")
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --ip-permissions \
  'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
  'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id $TASK_SG --protocol tcp --port 3000 --source-group $ALB_SG >/dev/null 2>&1 || true

echo "== Load balancer"
ALB_ARN=$(aws elbv2 describe-load-balancers --names $APP --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || \
  aws elbv2 create-load-balancer --name $APP --type application --scheme internet-facing \
    --subnets $SUBNETS --security-groups $ALB_SG --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names $APP --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || \
  aws elbv2 create-target-group --name $APP --protocol HTTP --port 3000 --vpc-id $VPC --target-type ip \
    --health-check-path /api/health --health-check-interval-seconds 10 --healthy-threshold-count 2 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=10 >/dev/null
CERT=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn|[0]" --output text)
if [ "$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query 'length(Listeners)')" = "0" ]; then
  aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTPS --port 443 --certificates CertificateArn=$CERT \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 --default-actions Type=forward,TargetGroupArn=$TG_ARN >/dev/null
  aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
    --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null
fi
read ALB_DNS ALB_ZONE < <(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text)

echo "== Regional name $R.$DOMAIN -> ALB (used by the health check and for direct tests)"
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",
  \"ResourceRecordSet\":{\"Name\":\"$R.$DOMAIN\",\"Type\":\"A\",
  \"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE\",\"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":false}}}]}" >/dev/null

echo "== ECS cluster, task definition, service"
aws logs create-log-group --log-group-name /ecs/$APP >/dev/null 2>&1 || true
aws logs put-retention-policy --log-group-name /ecs/$APP --retention-in-days 7
aws ecs create-cluster --cluster-name $APP >/dev/null
REPO=$ACCOUNT_ID.dkr.ecr.$R.amazonaws.com/$APP   # pull from the image replica in THIS region
TD=$(aws ecs register-task-definition --family $APP --requires-compatibilities FARGATE --network-mode awsvpc \
  --cpu 256 --memory 512 --runtime-platform cpuArchitecture=ARM64,operatingSystemFamily=LINUX \
  --execution-role-arn arn:aws:iam::$ACCOUNT_ID:role/$APP-exec --task-role-arn arn:aws:iam::$ACCOUNT_ID:role/$APP-task \
  --container-definitions "[{\"name\":\"app\",\"image\":\"$REPO:$TAG\",\"essential\":true,
    \"portMappings\":[{\"containerPort\":3000}],
    \"environment\":[{\"name\":\"APP_REGION\",\"value\":\"$R\"},{\"name\":\"TABLE_NAME\",\"value\":\"$APP\"}],
    \"logConfiguration\":{\"logDriver\":\"awslogs\",\"options\":{\"awslogs-group\":\"/ecs/$APP\",\"awslogs-region\":\"$R\",\"awslogs-stream-prefix\":\"app\"}}}]" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
NET="awsvpcConfiguration={subnets=[${SUBNETS// /,}],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}"
if [ "$(aws ecs describe-services --cluster $APP --services $APP --query 'services[0].status' --output text)" = "ACTIVE" ]; then
  aws ecs update-service --cluster $APP --service $APP --task-definition $TD --desired-count $DESIRED >/dev/null
else
  aws ecs create-service --cluster $APP --service-name $APP --task-definition $TD --desired-count $DESIRED \
    --launch-type FARGATE --network-configuration "$NET" --health-check-grace-period-seconds 30 \
    --load-balancers targetGroupArn=$TG_ARN,containerName=app,containerPort=3000 >/dev/null
fi
if [ "$DESIRED" -gt 0 ]; then aws ecs wait services-stable --cluster $APP --services $APP; fi
echo "URL=https://$R.$DOMAIN  ($ALB_DNS)  tasks=$DESIRED"
