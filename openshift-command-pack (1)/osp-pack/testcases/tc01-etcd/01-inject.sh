#!/bin/bash
# ============================================================
# TC-01 INJECTION - etcd disk latency degradation on master-1
# CHANGE WINDOW REQUIRED. Pre-prod first.
# ============================================================
set -x

### PRE-FLIGHT
oc get etcd -o=jsonpath="{.items[0].status.conditions}" | python3 -m json.tool
oc adm wait-for-stable-cluster --minimum-stable-period=5m
oc adm must-gather --dest-dir=./must-gather-tc01-before &

### BASELINE SNAPSHOT (record these values in the test log)
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath="{.spec.host}")
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS/api/v1/query" \
  --data-urlencode "query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))" \
  | python3 -m json.tool

### INJECT - 10 minutes of fsync-heavy load on the etcd volume
oc debug node/master-1 -- chroot /host bash -c \
  "fio --name=etcd-stress --directory=/var/lib/etcd --rw=randwrite \
   --bs=8k --size=2G --iodepth=32 --runtime=600 --time_based --fsync=1"
