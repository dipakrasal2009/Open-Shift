#!/bin/bash
set -x
oc project prod-sim
oc apply -f mesh-probe.yaml
oc rollout status ds/mesh-probe -n prod-sim
# Baseline full-mesh reachability (should be 100%):
for p in $(oc get pod -l app=mesh-probe -o jsonpath="{.items[*].status.podIP}"); do
  oc exec ds/mesh-probe -- curl -sf --max-time 2 http://$p:8080/ >/dev/null \
    && echo "$p OK" || echo "$p FAIL"
done
