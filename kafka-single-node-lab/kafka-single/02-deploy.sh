#!/bin/bash
# ============================================================
# STEP 1 - Deploy the single-broker Kafka cluster + topic
# ============================================================
set -x
oc project kafka

# 1. Metrics ConfigMap (JMX -> Prometheus rules). Fetch Strimzi's example once.
#    This is what the metricsConfig in 01-kafka-cluster.yaml references.
curl -sL https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/examples/metrics/kafka-metrics.yaml \
  | oc apply -n kafka -f -
# If the curl is blocked, create a minimal ConfigMap instead:
oc get configmap kafka-metrics -n kafka >/dev/null 2>&1 || \
  oc create configmap kafka-metrics -n kafka \
    --from-literal=kafka-metrics-config.yml='lowercaseOutputName: true'

# 2. Deploy the Kafka cluster + topic
oc apply -f 01-kafka-cluster.yaml

# 3. Wait for readiness (single broker + ZK come up in ~2-4 min)
echo "Waiting for Kafka to be Ready (this takes a few minutes)..."
oc wait kafka/dev-kafka --for=condition=Ready --timeout=600s -n kafka

# 4. Confirm what is running
oc get pods -n kafka
oc get kafka,kafkatopic -n kafka
echo
echo "Bootstrap service (use this from clients inside the cluster):"
echo "  dev-kafka-kafka-bootstrap.kafka.svc:9092"
