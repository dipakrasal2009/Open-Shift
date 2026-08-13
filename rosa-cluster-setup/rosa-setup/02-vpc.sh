#!/bin/bash
# ============================================================
# STEP 2 - VPC (ROSA with HCP is bring-your-own-VPC)
# Uses the built-in 'rosa create network' helper (CloudFormation).
# Requires ROSA CLI >= 1.2.48.
# ============================================================
set -x
# Assumes env vars from 01-account-roles.sh are exported. If not, re-export:
export REGION="${REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-glisten-rosa}"

### -------- CHOOSE ONE: single-AZ (cheap) or multi-AZ (real) ----------
#
# For the failure-injection test suite you want MULTI-AZ (3 zones), because
# TC-02 rack awareness and TC-04 zone partition are defined by zones.
# For a cheap learning cluster, single-AZ is fine.

### Option A - MULTI-AZ (3 public + 3 private subnets across 3 AZs) ------
rosa create network \
  --region "$REGION" \
  --param Name="${CLUSTER_NAME}-vpc" \
  --param AvailabilityZoneCount=3
# The command prints subnet IDs on completion. Capture the PRIVATE subnet IDs
# (and public if you want a public cluster) into an env var:
#   export SUBNET_IDS="subnet-aaa,subnet-bbb,subnet-ccc"

### Option B - SINGLE-AZ (1 public + 1 private) - cheaper -------------
# rosa create network \
#   --region "$REGION" \
#   --param Name="${CLUSTER_NAME}-vpc" \
#   --param AvailabilityZoneCount=1

### Verify the CloudFormation stack + subnets --------------------------
aws cloudformation describe-stacks --region "$REGION" \
  --query "Stacks[?contains(StackName, '${CLUSTER_NAME}')].StackStatus" --output text

echo ">> Copy the private subnet IDs into SUBNET_IDS, then run 03-oidc-operator-roles.sh"
echo ">> Example: export SUBNET_IDS=subnet-0aaa,subnet-0bbb,subnet-0ccc"
