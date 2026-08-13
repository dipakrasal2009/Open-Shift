#!/bin/bash
# ============================================================
# STEP 3 - OIDC configuration + cluster Operator roles (auto mode)
# HCP requires the OIDC config to exist BEFORE cluster creation.
# ============================================================
set -x
export REGION="${REGION:-us-east-1}"
export ACCOUNT_ROLES_PREFIX="${ACCOUNT_ROLES_PREFIX:-glisten-rosa}"
export OPERATOR_ROLES_PREFIX="${OPERATOR_ROLES_PREFIX:-glisten-rosa}"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

### 3.1 Create the OIDC config (managed) --------------------------------
rosa create oidc-config --mode auto --yes
# Copy the OIDC config ID from the output, then set it here:
export OIDC_CONFIG_ID="<PASTE_OIDC_CONFIG_ID>"

# Verify:
rosa list oidc-config

### 3.2 Create the cluster Operator roles -------------------------------
rosa create operator-roles \
  --mode auto \
  --hosted-cp \
  --prefix "$OPERATOR_ROLES_PREFIX" \
  --oidc-config-id "$OIDC_CONFIG_ID" \
  --installer-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role" \
  --yes

# Verify:
rosa list operator-roles | grep "$OPERATOR_ROLES_PREFIX"

echo ">> OIDC + operator roles done. Next: 04-create-cluster.sh"
