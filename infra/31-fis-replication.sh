#!/usr/bin/env bash
# FIS template: pause DynamoDB global table replication for the primary table.
set -euo pipefail
source "$(dirname "$0")/env.sh"
export AWS_REGION=$PRIMARY
aws iam put-role-policy --role-name $APP-fis --policy-name pause-replication --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:PutResourcePolicy\",\"dynamodb:DeleteResourcePolicy\",\"dynamodb:GetResourcePolicy\",\"dynamodb:DescribeTable\"],
    \"Resource\":[\"arn:aws:dynamodb:*:$ACCOUNT_ID:table/$APP\",\"arn:aws:dynamodb:*:$ACCOUNT_ID:table/$APP/stream/*\"]},
   {\"Effect\":\"Allow\",\"Action\":[\"tag:GetResources\"],\"Resource\":\"*\"}]}"
TPL=$(aws fis list-experiment-templates --query "experimentTemplates[?tags.Name=='$APP-pause-replication'].id|[0]" --output text)
if [ "$TPL" = "None" ]; then
  sleep 10
  TPL=$(aws fis create-experiment-template --cli-input-json "{
    \"description\": \"Pause replication of the $APP global table\",
    \"roleArn\": \"arn:aws:iam::$ACCOUNT_ID:role/$APP-fis\",
    \"stopConditions\": [{\"source\": \"none\"}],
    \"targets\": {\"table\": {\"resourceType\": \"aws:dynamodb:global-table\", \"selectionMode\": \"ALL\",
      \"resourceArns\": [\"arn:aws:dynamodb:$PRIMARY:$ACCOUNT_ID:table/$APP\"]}},
    \"actions\": {\"pause\": {\"actionId\": \"aws:dynamodb:global-table-pause-replication\",
      \"parameters\": {\"duration\": \"${PAUSE_DURATION:-PT5M}\"}, \"targets\": {\"Tables\": \"table\"}}},
    \"tags\": {\"Name\": \"$APP-pause-replication\"}}" --query experimentTemplate.id --output text)
fi
echo "FIS_PAUSE_TEMPLATE=$TPL"
