#!/bin/bash
# ============================================================
# UPGRADE - bump Kafka version (e.g. 4.1.0 -> 4.2.0)
# Run in TWO passes: version first, metadataVersion second,
# after confirming the version bump is stable. Don't skip the wait.
# ============================================================
set -x
TARGET_VERSION="${1:-4.2.0}"   # override: ./05b-upgrade-kafka.sh 4.2.0
oc project kafka

echo "== current state =="
oc get kafka dev-kafka -n kafka -o jsonpath='{.status.kafkaVersion}{"\n"}'
oc get pods -n kafka -l strimzi.io/cluster=dev-kafka

echo "== PASS 1: bump spec.kafka.version to $TARGET_VERSION =="
oc patch kafka dev-kafka -n kafka --type merge \
  -p "{\"spec\":{\"kafka\":{\"version\":\"$TARGET_VERSION\"}}}"

echo "Watching rollout (single node = brief downtime while it restarts)..."
oc wait kafka/dev-kafka --for=condition=Ready --timeout=300s -n kafka
oc get pods -n kafka -l strimzi.io/cluster=dev-kafka -w &
WPID=$!
sleep 60
kill $WPID 2>/dev/null

echo "== confirm the new version is actually running =="
oc get kafka dev-kafka -n kafka -o jsonpath='{.status.kafkaVersion}{"\n"}'
oc exec -n kafka $(oc get pods -n kafka -l strimzi.io/cluster=dev-kafka,strimzi.io/broker-role=true -o name | head -1) \
  -- bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 --version

echo "Version bump applied. Let it run for a while and confirm produce/consume"
echo "still works before bumping metadataVersion (PASS 2, separate + irreversible)."
echo ""
echo "When ready, run:"
echo "  oc patch kafka dev-kafka -n kafka --type merge -p '{\"spec\":{\"kafka\":{\"metadataVersion\":\"$TARGET_VERSION\"}}}'"
