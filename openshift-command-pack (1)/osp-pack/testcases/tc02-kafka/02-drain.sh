#!/bin/bash
# TC-02 INJECTION: drain the node hosting a broker, under load
set -x
# Find a node running a broker:
NODE=$(oc get pod -n kafka -l strimzi.io/name=prod-kafka-kafka -o jsonpath="{.items[0].spec.nodeName}")
echo "Draining broker node: $NODE"

oc adm cordon $NODE
oc adm drain $NODE --ignore-daemonsets --delete-emptydir-data \
  --pod-selector=strimzi.io/cluster=prod-kafka --timeout=600s
# EXPECTED: Drain Cleaner intercepts the eviction and rolls the broker in a
# controlled way (or PDB blocks a 2nd broker). Watch:
oc get pods -n kafka -w   # Ctrl+C once broker rejoins
