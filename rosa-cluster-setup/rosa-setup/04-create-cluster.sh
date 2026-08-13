#!/bin/bash
# ============================================================
# STEP 4 - Create the ROSA with HCP cluster
# ============================================================
set -x
export CLUSTER_NAME="${CLUSTER_NAME:-glisten-rosa}"
export REGION="${REGION:-us-east-1}"
export OPERATOR_ROLES_PREFIX="${OPERATOR_ROLES_PREFIX:-glisten-rosa}"
export OIDC_CONFIG_ID="${OIDC_CONFIG_ID:-<PASTE_OIDC_CONFIG_ID>}"
export SUBNET_IDS="${SUBNET_IDS:-<subnet-a,subnet-b,subnet-c>}"   # PRIVATE subnets

### ---- Cluster sizing note --------------------------------------------
# HCP control plane is MANAGED by Red Hat (you don't see/patch etcd or masters).
# You only pay for + manage WORKER nodes. For the failure-injection suite you
# want >= 3 workers across 3 AZs:
#   - TC-02 Kafka drain: needs 3 broker-capable nodes
#   - TC-03 canary upgrade: needs workers to split canary vs paused pool
#   - TC-04 zone partition: needs workers in multiple zones
#   - TC-05 node eviction: needs somewhere to reschedule
# m5.2xlarge (8 vCPU / 32Gi) is a comfortable worker floor for this stack.

### ---- Create (multi-AZ, 3 workers) ----------------------------------
rosa create cluster \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION" \
  --version 4.20.8 \
  --hosted-cp \
  --sts --mode auto \
  --operator-roles-prefix "$OPERATOR_ROLES_PREFIX" \
  --oidc-config-id "$OIDC_CONFIG_ID" \
  --subnet-ids "$SUBNET_IDS" \
  --compute-machine-type m5.2xlarge \
  --replicas 3 \
  --yes

### ---- Watch the install (HCP is fast: ~10-15 min) -------------------
rosa logs install --cluster "$CLUSTER_NAME" --watch

### ---- Status --------------------------------------------------------
rosa describe cluster --cluster "$CLUSTER_NAME"
# Wait for State: ready

echo ">> Cluster up. Next: 05-access.sh"
