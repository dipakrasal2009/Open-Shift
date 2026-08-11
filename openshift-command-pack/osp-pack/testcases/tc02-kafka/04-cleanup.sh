#!/bin/bash
set -x
NODE=$(oc get nodes -o name | xargs -I{} sh -c "oc get {} -o jsonpath=\"{.metadata.name} {.spec.unschedulable}\"; echo" | grep true | awk "{print \$1}")
[ -n "$NODE" ] && oc adm uncordon $NODE
# Preferred leader election to rebalance leadership:
oc exec -n kafka prod-kafka-kafka-0 -- bin/kafka-leader-election.sh \
  --bootstrap-server localhost:9092 --election-type preferred --all-topic-partitions
oc delete pod producer consumer -n kafka --ignore-not-found
