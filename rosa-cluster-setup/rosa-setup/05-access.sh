#!/bin/bash
# ============================================================
# STEP 5 - Access the cluster (admin user + oc login)
# ============================================================
set -x
export CLUSTER_NAME="${CLUSTER_NAME:-glisten-rosa}"

### 5.1 Quick cluster-admin (for a lab; use an IDP for anything real) ---
rosa create admin --cluster "$CLUSTER_NAME"
# This prints an `oc login ...` command with a generated password.
# It can take a couple of minutes for the admin user to become active.

### 5.2 Log in with the printed command --------------------------------
# oc login https://api.<cluster>.openshiftapps.com:443 \
#   --username cluster-admin --password <generated>

### 5.3 Confirm --------------------------------------------------------
oc whoami
oc get nodes -L topology.kubernetes.io/zone     # should show 3 workers, 3 AZs
oc get clusterversion

### 5.4 (Recommended) configure a proper identity provider -------------
# For GitHub/Google/htpasswd instead of the throwaway admin:
#   rosa create idp --cluster "$CLUSTER_NAME" --interactive
# then grant roles:
#   rosa grant user cluster-admin --user=<you> --cluster "$CLUSTER_NAME"

echo ">> You're in. The Part A labs, single-broker Kafka, AND the multi-node"
echo ">> test cases (TC-02/03/04/05) now run on this cluster."
