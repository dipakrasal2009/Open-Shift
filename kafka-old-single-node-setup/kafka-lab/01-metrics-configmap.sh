#!/bin/bash
# ============================================================
# STEP 1 - JMX exporter rules ConfigMap (Strimzi upstream example)
# Needed so Kafka exposes Prometheus-scrapable metrics (incl. consumer lag)
# ============================================================
set -x
oc project kafka

curl -sL https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/examples/metrics/kafka-metrics.yaml \
  | oc apply -n kafka -f -

oc get configmap kafka-metrics -n kafka
