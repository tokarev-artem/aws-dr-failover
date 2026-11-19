#!/usr/bin/env bash
# Shared, region-spanning pieces: DynamoDB global table, ECR + replication, image, IAM, certificates.
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo "== DynamoDB global table $APP ($PRIMARY + $SECONDARY)"
if ! aws dynamodb describe-table --table-name $APP --region $PRIMARY >/dev/null 2>&1; then
  aws dynamodb create-table --table-name $APP --region $PRIMARY \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=N \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES >/dev/null
  aws dynamodb wait table-exists --table-name $APP --region $PRIMARY
fi
aws dynamodb put-item --table-name $APP --region $PRIMARY --item '{"pk":{"S":"health"},"sk":{"N":"0"}}'
# A table that is UPDATING (e.g. a replica being added) rejects another update.
until [ "$(aws dynamodb describe-table --table-name $APP --region $PRIMARY --query Table.TableStatus --output text)" = "ACTIVE" ]; do
  echo "   table is updating..."; sleep 20; done
if ! aws dynamodb describe-table --table-name $APP --region $PRIMARY --query 'Table.Replicas[].RegionName' --output text | grep -q $SECONDARY; then
  # First use creates the AWSServiceRoleForDynamoDBReplication role; it can take a minute
  # before replication may use it, so retry on AccessDenied.
  for i in 1 2 3 4 5; do
    aws dynamodb update-table --table-name $APP --region $PRIMARY \
      --replica-updates "Create={RegionName=$SECONDARY}" >/dev/null && break
    echo "   retrying in 30 s (new service-linked role)..."; sleep 30
  done
fi
until [ "$(aws dynamodb describe-table --table-name $APP --region $PRIMARY --query "Table.Replicas[?RegionName=='$SECONDARY'].ReplicaStatus|[0]" --output text)" = "ACTIVE" ]; do
  echo "   replica in $SECONDARY: creating..."; sleep 20; done
echo "   replica in $SECONDARY: ACTIVE"

echo "== ECR repository (immutable tags, scan on push) + replication to $SECONDARY"
aws ecr describe-repositories --repository-names $APP --region $PRIMARY >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name $APP --region $PRIMARY \
    --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true >/dev/null
aws ecr put-replication-configuration --region $PRIMARY --replication-configuration "{
  \"rules\": [{
    \"destinations\": [{\"region\": \"$SECONDARY\", \"registryId\": \"$ACCOUNT_ID\"}],
    \"repositoryFilters\": [{\"filter\": \"$APP\", \"filterType\": \"PREFIX_MATCH\"}]
  }]}" >/dev/null

echo "== Image $TAG (linux/arm64)"
if ! aws ecr describe-images --repository-name $APP --region $PRIMARY --image-ids imageTag=$TAG >/dev/null 2>&1; then
  aws ecr get-login-password --region $PRIMARY | docker login --username AWS --password-stdin ${REPO_URI_P%%/*} >/dev/null
  docker buildx build --platform linux/arm64 --provenance=false \
    --build-arg APP_VERSION=$TAG -t $REPO_URI_P:$TAG --push "$(dirname "$0")/../app"
fi
until aws ecr describe-images --repository-name $APP --region $SECONDARY --image-ids imageTag=$TAG >/dev/null 2>&1; do
  echo "   waiting for the replicated image in $SECONDARY..."; sleep 10; done
echo "   $REPO_URI_S:$TAG is there"

echo "== IAM roles"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam get-role --role-name $APP-exec >/dev/null 2>&1 || {
  aws iam create-role --role-name $APP-exec --assume-role-policy-document "$TRUST" >/dev/null
  aws iam attach-role-policy --role-name $APP-exec --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy; }
aws iam get-role --role-name $APP-task >/dev/null 2>&1 || \
  aws iam create-role --role-name $APP-task --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name $APP-task --policy-name dynamodb --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
  \"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:Query\"],
  \"Resource\":[\"arn:aws:dynamodb:$PRIMARY:$ACCOUNT_ID:table/$APP\",\"arn:aws:dynamodb:$SECONDARY:$ACCOUNT_ID:table/$APP\"]}]}"

echo "== ACM certificates for $DOMAIN and *.$DOMAIN (both regions, DNS validation)"
for R in $PRIMARY $SECONDARY; do
  ARN=$(aws acm list-certificates --region $R --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn|[0]" --output text)
  if [ "$ARN" = "None" ]; then
    ARN=$(aws acm request-certificate --region $R --domain-name $DOMAIN --subject-alternative-names "*.$DOMAIN" \
      --validation-method DNS --query CertificateArn --output text)
    sleep 10
  fi
  aws acm describe-certificate --region $R --certificate-arn $ARN \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json |
  python3 -c '
import json,sys
recs={(r["Name"],r["Value"]) for r in json.load(sys.stdin) if r}
print(json.dumps({"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":n,"Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":v}]}} for n,v in recs]}))' > /tmp/$APP-acm.json
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch file:///tmp/$APP-acm.json >/dev/null
  aws acm wait certificate-validated --region $R --certificate-arn $ARN
  echo "   $R: ISSUED"
done
