# Source me. Every script uses these.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=${AWS_PROFILE:-lz-mgmt}
export AWS_PAGER=""
export APP=dr-demo
export PRIMARY=eu-central-1
export SECONDARY=eu-west-1
export ZONE_NAME=tokarevartem.cloud
export DOMAIN=dr.$ZONE_NAME
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name $ZONE_NAME --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')
export REPO_URI_P=$ACCOUNT_ID.dkr.ecr.$PRIMARY.amazonaws.com/$APP
export REPO_URI_S=$ACCOUNT_ID.dkr.ecr.$SECONDARY.amazonaws.com/$APP
export TAG=${TAG:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --short HEAD 2>/dev/null || echo dev)}
