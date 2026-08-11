#!/bin/bash
# TC-02 setup: cluster, drain cleaner, producer load, consumer group
set -x
oc new-project kafka 2>/dev/null; oc project kafka

# Metrics ConfigMap (Strimzi example rules - fetch once from upstream)
curl -sL https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/examples/metrics/kafka-metrics.yaml | oc apply -n kafka -f -

oc apply -f kafka-cluster.yaml
oc wait kafka/prod-kafka --for=condition=Ready --timeout=600s -n kafka

# Strimzi Drain Cleaner (intercepts eviction -> controlled rolling restart)
oc apply -f https://github.com/strimzi/drain-cleaner/releases/latest/download/openshift.yaml

# PRODUCER LOAD: 50k msg/s, acks=all (min.insync must hold for zero errors)
oc run producer -n kafka --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 --restart=Never -- \
  bin/kafka-producer-perf-test.sh --topic load-topic \
  --num-records 30000000 --record-size 512 --throughput 50000 \
  --producer-props bootstrap.servers=prod-kafka-kafka-bootstrap:9092 acks=all

# CONSUMER GROUP
oc run consumer -n kafka --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 --restart=Never -- \
  bin/kafka-console-consumer.sh --bootstrap-server prod-kafka-kafka-bootstrap:9092 \
  --topic load-topic --group tc02-group --from-beginning
