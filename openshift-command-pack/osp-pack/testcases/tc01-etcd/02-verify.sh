#!/bin/bash
# TC-01 PLATFORM PASS CRITERIA - run DURING and AFTER injection
set -x
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring)
THANOS=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath="{.spec.host}")
Q() { curl -sk -H "Authorization: Bearer $TOKEN" "https://$THANOS/api/v1/query" --data-urlencode "query=$1" | python3 -c "import sys,json; [print(r[\"metric\"].get(\"pod\",r[\"metric\"].get(\"instance\",\"\")), r[\"value\"][1]) for r in json.load(sys.stdin)[\"data\"][\"result\"]]"; }

echo "== fsync p99 per member (PASS: >10ms on master-1 only, no quorum loss) =="
Q "histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[2m]))"

echo "== leader changes (PASS: increase <= 1 during window) =="
Q "etcd_server_leader_changes_seen_total"

echo "== apiserver p99 latency (PASS: within SLO) =="
Q "histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb!=\"WATCH\"}[5m])) by (le))"

echo "== apiserver etcd timeouts (PASS: none) =="
oc logs -n openshift-kube-apiserver -l app=openshift-kube-apiserver --since=15m --tail=-1 2>/dev/null \
  | grep -c "etcdserver: request timed out" || echo "0 timeouts"

echo "== quorum check =="
oc get etcd -o=jsonpath="{.items[0].status.conditions[?(@.type==\"EtcdMembersAvailable\")]}"
