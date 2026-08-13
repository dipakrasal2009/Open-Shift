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

# Wait until the CSV reaches Succeeded before continuing (polls, no manual Ctrl+C needed)
echo "Waiting for amqstreams CSV to reach Succeeded (timeout 5 min)..."
for i in $(seq 1 30); do
  PHASE=$(oc get csv -n openshift-operators -o json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((i['status'].get('phase','') for i in d['items'] if 'amqstreams' in i['metadata']['name']), ''))" 2>/dev/null)
  echo "  [$i/30] phase=${PHASE:-not found yet}"
  [ "$PHASE" = "Succeeded" ] && break
  sleep 10
done
if [ "$PHASE" != "Succeeded" ]; then
  echo "TIMEOUT: CSV did not reach Succeeded in 5 min. Check: oc get csv -n openshift-operators"
  exit 1
fi
echo "Operator ready."
