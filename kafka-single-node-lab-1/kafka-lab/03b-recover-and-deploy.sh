#!/bin/bash
# ============================================================
# RECOVERY - clean up the broken (ZK/3.7.0) attempt and leftover
# test pods, then redeploy with the KRaft/4.1.0 manifest.
# Run this ONCE after replacing 02-kafka-cluster.yaml.
# ============================================================
set -x
oc project kafka

# Delete the old, permanently-NotReady Kafka CR
oc delete kafka dev-kafka -n kafka --ignore-not-found

# Clean up every leftover test pod from the earlier failed attempts
oc delete pod producer consumer kafka-producer kafka-consumer -n kafka --ignore-not-found

# Deploy the corrected KRaft manifest (KafkaNodePool + Kafka)
oc apply -f 02-kafka-cluster.yaml

echo "Watching for pods to appear (should see dev-kafka-dual-role-X within ~30s)..."
for i in $(seq 1 12); do
  COUNT=$(oc get pods -n kafka -l strimzi.io/cluster=dev-kafka --no-headers 2>/dev/null | wc -l)
  echo "  [$i/12] pods found: $COUNT"
  [ "$COUNT" -gt 0 ] && break
  sleep 10
done

oc get pods -n kafka -l strimzi.io/cluster=dev-kafka
oc get kafka dev-kafka -n kafka

echo "If READY is still blank after a few minutes, run:"
echo "  oc describe kafka dev-kafka -n kafka"
