#!/bin/bash
# ============================================================
# STEP 4 - Enable metrics scraping + run the lag anomaly detector
# ============================================================
set -x
oc project kafka

# WARNING: this OVERWRITES cluster-monitoring-config if one already exists.
# If you already have user-workload monitoring configured, merge manually instead.
oc apply -f 06-podmonitor.yaml

# Give Prometheus a minute to pick up the new scrape target
sleep 60
oc get podmonitor -n kafka

# Build the RBAC + ConfigMap (real file content) + run the Job
oc apply -f 07-lag-detector-job.yaml
oc create configmap lag-detector-src --from-file=lag-detector.py -n kafka \
  --dry-run=client -o yaml | oc apply -f -

oc delete job kafka-lag-detector -n kafka --ignore-not-found
oc create -f 07-lag-detector-job.yaml 2>/dev/null   # recreate Job cleanly if edited
oc wait --for=condition=complete job/kafka-lag-detector -n kafka --timeout=120s
oc logs job/kafka-lag-detector -n kafka
