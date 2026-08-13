#!/bin/bash
# ============================================================
# STEP 9 - DELETE the cluster + all STS/IAM resources
# ROSA bills hourly. Tear down when not in use.
# Run IN ORDER; the operator/OIDC cleanup must come AFTER the cluster is gone.
# ============================================================
set -x
export CLUSTER_NAME="${CLUSTER_NAME:-glisten-rosa}"
export REGION="${REGION:-us-east-1}"
export OPERATOR_ROLES_PREFIX="${OPERATOR_ROLES_PREFIX:-glisten-rosa}"
export OIDC_CONFIG_ID="${OIDC_CONFIG_ID:-<PASTE_OIDC_CONFIG_ID>}"

### 9.1 Delete the cluster (watch until gone) ---------------------------
rosa delete cluster --cluster "$CLUSTER_NAME" --yes
rosa logs uninstall --cluster "$CLUSTER_NAME" --watch

### 9.2 Delete the cluster-specific operator roles ----------------------
rosa delete operator-roles --prefix "$OPERATOR_ROLES_PREFIX" --mode auto --yes

### 9.3 Delete the OIDC provider/config --------------------------------
rosa delete oidc-config --oidc-config-id "$OIDC_CONFIG_ID" --mode auto --yes

### 9.4 (Optional) delete account roles - ONLY if no other ROSA clusters
# rosa delete account-roles --prefix "$ACCOUNT_ROLES_PREFIX" --mode auto --yes

### 9.5 Delete the VPC CloudFormation stack ----------------------------
# Find the stack name, then:
aws cloudformation describe-stacks --region "$REGION" \
  --query "Stacks[?contains(StackName, '${CLUSTER_NAME}')].StackName" --output text
# aws cloudformation delete-stack --region "$REGION" --stack-name <STACK_NAME>

echo ">> Teardown complete. Verify no lingering ROSA charges in AWS billing."
