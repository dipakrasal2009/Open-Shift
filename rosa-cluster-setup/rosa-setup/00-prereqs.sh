#!/bin/bash
# ============================================================
# STEP 0 - ROSA prerequisites (one-time per workstation/account)
# Target: ROSA with HCP (Hosted Control Plane) - the current default.
# Run block by block; read the notes.
# ============================================================
set -x

### 0.1 Install the CLIs -------------------------------------------------
# AWS CLI v2 (if not present):
#   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
#   unzip awscliv2.zip && sudo ./aws/install
aws --version

# ROSA CLI - need >= 1.2.48 for the 'rosa create network' helper.
# Download the latest from the OpenShift downloads page, then:
#   tar -xzf rosa-linux.tar.gz && sudo mv rosa /usr/local/bin/
rosa version

# (Optional) oc CLI - rosa can install it for you:
rosa download openshift-client
# tar -xzf openshift-client-linux.tar.gz && sudo mv oc kubectl /usr/local/bin/

### 0.2 Enable ROSA in the AWS account (one-time) -----------------------
# In the AWS console: search "ROSA" -> "Get started" -> enable the service
# (accepts the AWS Marketplace/ROSA terms). This cannot be done via CLI.
echo ">> Enable ROSA in the AWS console if you have not already."

### 0.3 ELB service-linked role (one-time; ignore error if it exists) ---
aws iam create-service-linked-role \
  --aws-service-name "elasticloadbalancing.amazonaws.com" 2>/dev/null \
  || echo "ELB service-linked role already exists"

### 0.4 Log in to ROSA / Red Hat -----------------------------------------
# Get a token from https://console.redhat.com/openshift/token/rosa
# Then either:
rosa login --token="<PASTE_YOUR_OFFLINE_TOKEN>"
# or interactive browser auth:
#   rosa login --use-auth-code

rosa whoami        # confirms Red Hat + AWS identity are linked

### 0.5 Verify service quotas -------------------------------------------
rosa verify quota --region us-east-1
# If this fails, request quota increases in the AWS console (EC2 vCPUs, EIPs,
# NAT gateways) before continuing.

echo ">> Prereqs done. Next: 01-account-roles.sh"
