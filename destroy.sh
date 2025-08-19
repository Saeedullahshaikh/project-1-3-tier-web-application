#!/bin/bash
set -euo pipefail  # Script fail hote hi exit ho, undefined vars use na ho, pipes me error pakdo

# Variables
REGION="${REGION:-ap-south-1}"             # AWS region (default ap-south-1)
TAG_PREFIX="${TAG_PREFIX:-three-tier-demo}" # Tag prefix jo tumhare resources me laga hoga

echo "[INFO] Finding instances by tag prefix $TAG_PREFIX ..."

# Step 1: Find all instance IDs with tag names matching db, app, web
IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${TAG_PREFIX}-db,${TAG_PREFIX}-app,${TAG_PREFIX}-web" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text || true)

# Step 2: Terminate instances if found
if [ -n "$IDS" ]; then
  echo "[INFO] Terminating instances: $IDS"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
else
  echo "[INFO] No matching instances found."
fi

# Step 3: Delete security groups
for SG in web-sg app-sg db-sg; do
  GID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${TAG_PREFIX}-${SG}" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

  if [[ "$GID" != "None" && -n "$GID" ]]; then
    echo "[INFO] Deleting security group $GID ..."
    aws ec2 delete-security-group --region "$REGION" --group-id "$GID" || true
  fi
done

echo "[INFO] Done. (Key pair was not deleted; remove manually if desired.)"
