#!/bin/bash
# ============================================================
# STEP 0 - Install AMQ Streams (Strimzi) operator
# ============================================================
set -x

oc create namespace kafka 2>/dev/null || oc project kafka

# Check which channel is actually available on your cluster/catalog before subscribing
oc get packagemanifest amq-streams -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'
echo ""

cat << YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

# Wait until the CSV reaches Succeeded before continuing
echo "Watching CSV status - Ctrl+C once PHASE=Succeeded"
oc get csv -n openshift-operators -w | grep -i amqstreams
