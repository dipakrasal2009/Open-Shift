#!/bin/bash
# ============================================================
# CLEANUP - remove everything this lab created
# ============================================================
set -x

# Detector artifacts
oc delete job lag-detector-run -n kafka --ignore-not-found
oc delete configmap lag-detector-src -n kafka --ignore-not-found
oc delete podmonitor kafka-metrics -n kafka --ignore-not-found
oc adm policy remove-cluster-role-from-user cluster-monitoring-view \
  -z lag-detector -n kafka 2>/dev/null
oc delete sa lag-detector -n kafka --ignore-not-found

# Producer/consumer pods
oc delete pod perf-producer demo-consumer kafka-producer kafka-consumer lag-check \
  -n kafka --ignore-not-found

# Kafka cluster + topic + metrics config
oc delete -f 01-kafka-cluster.yaml --ignore-not-found
oc delete configmap kafka-metrics -n kafka --ignore-not-found

# Optional: turn user-workload monitoring back off (leave on if other labs use it)
# oc patch configmap cluster-monitoring-config -n openshift-monitoring \
#   --type merge -p '{"data":{"config.yaml":"enableUserWorkload: false\n"}}'

# Optional: delete the whole namespace
# oc delete project kafka

echo "Cleanup done. Verify nothing lingers:"
oc get all -n kafka
