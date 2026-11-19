#!/usr/bin/env bash
# Dedicated subnets for the primary tasks + an AWS FIS template that cuts DynamoDB off in those subnets.
# Dedicated subnets keep the fault away from anything else in the default VPC.
set -euo pipefail
source "$(dirname "$0")/env.sh"
export AWS_REGION=$PRIMARY
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

echo "== Subnets $APP-a / $APP-b (tag fis-target=$APP)"
mk() { # cidr az name
  local id; id=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=tag:Name,Values=$3 --query 'Subnets[0].SubnetId' --output text)
  [ "$id" = "None" ] && id=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block $1 --availability-zone $2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$3},{Key=fis-target,Value=$APP}]" --query Subnet.SubnetId --output text)
  echo $id; }
SA=$(mk 172.31.200.0/24 ${PRIMARY}a $APP-a); SB=$(mk 172.31.201.0/24 ${PRIMARY}b $APP-b)
echo "   $SA $SB"

echo "== Move the $PRIMARY service into them"
TASK_SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=$APP-task --query 'SecurityGroups[0].GroupId' --output text)
aws ecs update-service --cluster $APP --service $APP \
  --network-configuration "awsvpcConfiguration={subnets=[$SA,$SB],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" >/dev/null
aws ecs wait services-stable --cluster $APP --services $APP

echo "== FIS role and experiment template"
aws iam get-role --role-name $APP-fis >/dev/null 2>&1 || {
  aws iam create-role --role-name $APP-fis --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"fis.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name $APP-fis --policy-arn arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess
  sleep 10; }
TPL=$(aws fis list-experiment-templates --query "experimentTemplates[?tags.Name=='$APP-dynamodb-outage'].id|[0]" --output text)
if [ "$TPL" = "None" ]; then
  TPL=$(aws fis create-experiment-template --cli-input-json "{
    \"description\": \"Cut DynamoDB off for the $APP tasks in $PRIMARY\",
    \"roleArn\": \"arn:aws:iam::$ACCOUNT_ID:role/$APP-fis\",
    \"stopConditions\": [{\"source\": \"none\"}],
    \"targets\": {\"subnets\": {\"resourceType\": \"aws:ec2:subnet\", \"selectionMode\": \"ALL\",
      \"resourceTags\": {\"fis-target\": \"$APP\"}, \"parameters\": {\"vpc\": \"$VPC\"}}},
    \"actions\": {\"cut-dynamodb\": {\"actionId\": \"aws:network:disrupt-connectivity\",
      \"parameters\": {\"duration\": \"${FIS_DURATION:-PT4M}\", \"scope\": \"dynamodb\"},
      \"targets\": {\"Subnets\": \"subnets\"}}},
    \"tags\": {\"Name\": \"$APP-dynamodb-outage\"}}" --query experimentTemplate.id --output text)
fi
echo "FIS_TEMPLATE=$TPL"
