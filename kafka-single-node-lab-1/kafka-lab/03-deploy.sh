#!/bin/bash
# ============================================================
# STEP 2 - Deploy the single-broker Kafka cluster
# ============================================================
set -x
oc project kafka

oc apply -f 02-kafka-cluster.yaml
oc wait kafka/dev-kafka --for=condition=Ready --timeout=600s -n kafka

# Confirm the topology - should be exactly 1 kafka pod + 1 zookeeper pod
oc get pods -n kafka -l strimzi.io/cluster=dev-kafka
oc get kafka dev-kafka -n kafka
