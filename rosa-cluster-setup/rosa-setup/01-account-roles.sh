#!/bin/bash
# ============================================================
# STEP 1 - Account-wide IAM roles + policies (auto mode)
# ROSA uses AWS STS; these are the account-level roles it assumes.
# Create once per account; reused by every cluster.
# ============================================================
set -x

# Shared env vars - edit these, then `source` this file or export them yourself
export CLUSTER_NAME="glisten-rosa"
export REGION="us-east-1"
export ACCOUNT_ROLES_PREFIX="glisten-rosa"          # prefix for account roles
export OPERATOR_ROLES_PREFIX="glisten-rosa"         # prefix for operator roles
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS account: $AWS_ACCOUNT_ID"

### Create the account-wide roles for HCP -------------------------------
rosa create account-roles \
  --mode auto \
  --hosted-cp \
  --prefix "$ACCOUNT_ROLES_PREFIX" \
  --force-policy-creation \
  --yes

### Verify -------------------------------------------------------------
rosa list account-roles | grep "$ACCOUNT_ROLES_PREFIX"

echo ">> Account roles done. Next: 02-vpc.sh"
