#!/bin/bash
# ============================================================
# STEP 0 - Install the Strimzi / AMQ Streams operator (one-time)
# Cluster: OCP 4.20.8, single worker (~15Gi). Run block by block.
# ============================================================
set -x

# Create the namespace we will run Kafka in
oc new-project kafka 2>/dev/null || oc project kafka

# --- Option A: AMQ Streams (Red Hat supported build) via OperatorHub ---
# This is the recommended path on OpenShift. Check the channel name first:
oc get packagemanifest amq-streams -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}{"\n"}' 2>/dev/null

cat << 'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable          # if the command above printed a different channel, use that
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML

# --- Option B: community Strimzi (only if AMQ Streams is unavailable) ---
# cat << 'YAML' | oc apply -f -
# apiVersion: operators.coreos.com/v1alpha1
# kind: Subscription
# metadata:
#   name: strimzi-kafka-operator
#   namespace: openshift-operators
# spec:
#   channel: stable
#   name: strimzi-kafka-operator
#   source: community-operators
#   sourceNamespace: openshift-marketplace
#   installPlanApproval: Automatic
# YAML

# Wait for the operator CSV to reach Succeeded (Ctrl+C once it does):
echo "Waiting for operator to install..."
oc get csv -n openshift-operators -w | grep -i 'amq-streams\|strimzi'

# Confirm the Kafka CRD is registered before moving on:
oc get crd kafkas.kafka.strimzi.io && echo "Kafka CRD ready"
