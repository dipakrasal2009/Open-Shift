#!/bin/bash
# TC-02 PLATFORM PASS CRITERIA
set -x
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath="{.spec.host}")
Q() { curl -sk -H "Authorization: Bearer $TOKEN" "https://$THANOS/api/v1/query" --data-urlencode "query=$1"; }

echo "== under-replicated partitions (PASS: 0 within 5 min of rejoin) =="
Q "sum(kafka_server_replicamanager_underreplicatedpartitions)" | python3 -m json.tool

echo "== consumer lag (expected: spike, then drain back down) =="
Q "sum(kafka_consumergroup_lag) by (consumergroup)" | python3 -m json.tool

echo "== producer errors (PASS: zero with acks=all) =="
oc logs producer -n kafka --tail=50 | grep -i "error\|exception" || echo "no producer errors"
