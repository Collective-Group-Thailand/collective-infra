#!/bin/bash
# Run from a laptop: start the UAT box outside office hours (the 20:00 stop schedule still applies).
#   AWS_PROFILE=collective ./wake.sh uat
set -euo pipefail
ENV="${1:-uat}"; REGION="${AWS_REGION:-ap-southeast-7}"
ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=collective-${ENV}-app" "Name=instance-state-name,Values=stopped,stopping,running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ "$ID" != None ] || { echo "no instance collective-${ENV}-app"; exit 1; }
aws ec2 start-instances --region "$REGION" --instance-ids "$ID" >/dev/null
echo "starting $ID …"; aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$ID"
echo "ready"
