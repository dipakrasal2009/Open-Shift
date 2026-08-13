#!/bin/bash
# ============================================================
# VERIFY - run this after 03-deploy.sh to confirm each layer works
# ============================================================
set -x
oc project kafka

echo "== 1. Strimzi operator healthy =="
oc get csv -n openshift-operators | grep -i amqstreams
oc get pods -n openshift-operators -l name=amq-streams-cluster-operator

echo "== 2. Kafka custom resource is Ready =="
oc get kafka dev-kafka -n kafka
oc get kafka dev-kafka -n kafka -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo ""
# Expect: True. If blank/False, run: oc describe kafka dev-kafka -n kafka

echo "== 3. Broker + zookeeper pods actually running =="
oc get pods -n kafka -l strimzi.io/cluster=dev-kafka -o wide
# Expect exactly: dev-kafka-kafka-0 (1/1 Running), dev-kafka-zookeeper-0 (1/1 Running),
# dev-kafka-entity-operator-xxxx (2/2 Running)

echo "== 4. Bootstrap service resolves and accepts connections =="
oc run kafka-conn-test -n kafka -ti --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 \
  --rm=true --restart=Never -- \
  bin/kafka-broker-api-versions.sh --bootstrap-server dev-kafka-kafka-bootstrap:9092 \
  | head -5
# PASS: prints broker API version info, no connection refused / timeout

echo "== 5. Topic exists with the config we expect =="
oc exec -n kafka dev-kafka-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --describe --topic load-topic
# PASS: Leader present, Isr has the 1 broker, ReplicationFactor: 1

echo "== 6. End-to-end produce/consume round trip =="
MSG="verify-$(date +%s)"
oc exec -n kafka dev-kafka-kafka-0 -- bash -c \
  "echo '$MSG' | bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic load-topic"
oc exec -n kafka dev-kafka-kafka-0 -- bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic load-topic --from-beginning \
  --max-messages 1 --timeout-ms 10000 | tail -1
# PASS: the message you just produced comes back out

echo "== 7. Metrics endpoint is actually exporting JMX/Prometheus data =="
oc exec -n kafka dev-kafka-kafka-0 -- curl -s localhost:9404/metrics | grep -c kafka_
# PASS: non-zero count. 0 = metricsConfig/JMX exporter misconfigured

echo "== 8. Prometheus is scraping it (via Thanos) =="
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath="{.spec.host}")
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS/api/v1/query" \
  --data-urlencode "query=up{namespace=\"kafka\"}" | python3 -m json.tool
# PASS: at least one result with value "1". Empty result = PodMonitor not
# picked up yet (wait 1-2 min) or user-workload-monitoring not enabled.

echo "== 9. Lag metric is queryable =="
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS/api/v1/query" \
  --data-urlencode "query=kafka_consumergroup_lag" | python3 -m json.tool
# PASS: results present once a consumer group has read at least once.
# Empty = no consumer group has run yet, or metrics not flowing (see step 7/8).

echo "== ALL CHECKS COMPLETE =="
