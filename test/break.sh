#!/usr/bin/env bash
# Inject or undo a fault in the PRIMARY region. Prints the epoch-ms timestamp of the change.
# usage: break.sh app-down|app-up|db-down|db-up
set -euo pipefail
source "$(dirname "$0")/../infra/env.sh"
now() { python3 -c 'import time;print(int(time.time()*1000))'; }
case $1 in
  app-down) aws ecs update-service --region $PRIMARY --cluster $APP --service $APP --desired-count 0 >/dev/null
            T=$(now); aws ecs list-tasks --region $PRIMARY --cluster $APP --query taskArns --output text | tr '\t' '\n' |
            while read t; do [ -n "$t" ] && aws ecs stop-task --region $PRIMARY --cluster $APP --task $t >/dev/null; done ;;
  app-up)   aws ecs update-service --region $PRIMARY --cluster $APP --service $APP --desired-count ${2:-1} >/dev/null; T=$(now) ;;
  db-down)  # The app keeps running, but it can no longer reach DynamoDB in the primary region.
            aws iam put-role-policy --role-name $APP-task --policy-name simulate-dynamodb-outage --policy-document "{
              \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"dynamodb:*\",
              \"Resource\":\"arn:aws:dynamodb:$PRIMARY:$ACCOUNT_ID:table/$APP\"}]}"; T=$(now) ;;
  db-up)    aws iam delete-role-policy --role-name $APP-task --policy-name simulate-dynamodb-outage; T=$(now) ;;
  *) echo "usage: $0 app-down|app-up [n]|db-down|db-up"; exit 1 ;;
esac
echo "$1 at $T ($(date -u +%H:%M:%S) UTC)"
