#!/bin/bash
# ============================================================
# STEP 3 - Topic + produce/consume smoke test, then steady load
# ============================================================
set -x
oc project kafka

oc apply -f 04-topic.yaml
oc wait kafkatopic/load-topic --for=condition=Ready --timeout=60s -n kafka

### ---- Quick interactive smoke test ----
# Producer (Ctrl+D to end input after typing a few lines)
oc run kafka-producer -n kafka -ti --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-producer.sh --bootstrap-server dev-kafka-kafka-bootstrap:9092 \
  --topic load-topic

# Consumer (separate terminal, Ctrl+C to stop)
oc run kafka-consumer -n kafka -ti --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-consumer.sh --bootstrap-server dev-kafka-kafka-bootstrap:9092 \
  --topic load-topic --from-beginning

### ---- Steady background load to generate real consumer lag ----
# acks=1 (NOT acks=all) - with min.insync.replicas=1 this is fine, but acks=all
# on a single broker with min.insync=1 would also work; acks=1 is lower latency for a lab.
oc run producer -n kafka --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 --restart=Never -- \
  bin/kafka-producer-perf-test.sh --topic load-topic \
  --num-records 2000000 --record-size 512 --throughput 500 \
  --producer-props bootstrap.servers=dev-kafka-kafka-bootstrap:9092 acks=1

oc run consumer -n kafka --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 --restart=Never -- \
  bin/kafka-console-consumer.sh --bootstrap-server dev-kafka-kafka-bootstrap:9092 \
  --topic load-topic --group lag-lab-group --from-beginning

# Watch lag build up and drain:
oc exec -n kafka dev-kafka-kafka-0 -- bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group lag-lab-group
