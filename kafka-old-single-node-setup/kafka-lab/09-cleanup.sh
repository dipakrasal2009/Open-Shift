#!/bin/bash
# ============================================================
# CLEANUP - remove everything this lab created
# ============================================================
set -x
oc project kafka

oc delete job kafka-lag-detector producer consumer --ignore-not-found -n kafka
oc delete kafkatopic load-topic -n kafka --ignore-not-found
oc delete kafka dev-kafka -n kafka --ignore-not-found
oc delete podmonitor dev-kafka-metrics -n kafka --ignore-not-found
oc delete configmap lag-detector-src kafka-metrics -n kafka --ignore-not-found
oc delete clusterrolebinding kafka-lag-detector-monitoring-view --ignore-not-found
oc delete serviceaccount kafka-lag-detector -n kafka --ignore-not-found

# Only delete the namespace if nothing else lives in it
oc get all -n kafka
# oc delete namespace kafka   # uncomment once you've confirmed it's empty
