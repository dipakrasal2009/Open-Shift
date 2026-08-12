#!/bin/bash
# ============================================================
# STEP 2 - Produce and consume (proves the cluster works)
# Run the producer and consumer in TWO separate terminals,
# OR run the perf-producer block, then the consumer block.
# ============================================================
set -x
oc project kafka

BOOT=dev-kafka-kafka-bootstrap:9092
IMG=quay.io/strimzi/kafka:latest-kafka-3.7.0

### ---- QUICK INTERACTIVE TEST ----
# Terminal 1 - console producer (type messages, Ctrl+C to stop):
#   oc run kafka-producer -ti -n kafka --image=$IMG --rm=true --restart=Never -- \
#     bin/kafka-console-producer.sh --bootstrap-server $BOOT --topic demo-topic
#
# Terminal 2 - console consumer (see the messages appear):
#   oc run kafka-consumer -ti -n kafka --image=$IMG --rm=true --restart=Never -- \
#     bin/kafka-console-consumer.sh --bootstrap-server $BOOT --topic demo-topic --from-beginning

### ---- STEADY LOAD (feeds the lag detector) ----
# Producer: modest rate so one worker copes. acks=1 (NOT all - min.insync=1 here).
oc run perf-producer -n kafka --image=$IMG --restart=Never -- \
  bin/kafka-producer-perf-test.sh --topic demo-topic \
  --num-records 500000 --record-size 512 --throughput 2000 \
  --producer-props bootstrap.servers=$BOOT acks=1

# Consumer group (creates lag we can measure):
oc run demo-consumer -n kafka --image=$IMG --restart=Never -- \
  bin/kafka-console-consumer.sh --bootstrap-server $BOOT \
  --topic demo-topic --group demo-group --from-beginning

### ---- INSPECT LAG (the metric the detector watches) ----
oc run lag-check -ti -n kafka --image=$IMG --rm=true --restart=Never -- \
  bin/kafka-consumer-groups.sh --bootstrap-server $BOOT \
  --describe --group demo-group
# Columns: CURRENT-OFFSET  LOG-END-OFFSET  LAG  <- watch LAG rise/fall
