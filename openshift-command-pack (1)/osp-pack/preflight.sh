#!/bin/bash
# ============================================================
# Preflight - run before starting the program
# ============================================================
set +e
echo "== cluster reachable / logged in =="
oc whoami || { echo "not logged in: oc login ..."; exit 1; }
oc version

echo "== cluster stable =="
oc get clusterversion
oc get co | grep -v "True.*False.*False" | grep -v "^NAME" \
  && echo "^ operators not fully healthy - investigate before injecting faults" \
  || echo "all cluster operators healthy"

echo "== nodes =="
oc get nodes -o wide
oc adm top nodes 2>/dev/null || echo "metrics not ready (needed for TC-05/lab5)"

echo "== monitoring stack (Thanos) reachable =="
oc get route thanos-querier -n openshift-monitoring \
  && echo "Thanos route present" \
  || echo "MISSING: thanos route - AIOps queries will fail"

echo "== zones present (needed for TC-02 rack, TC-04 partition) =="
oc get nodes -L topology.kubernetes.io/zone

echo "== operators you will install (informational) =="
echo " - Argo Rollouts (lab4, tc03)"
echo " - AMQ Streams / Strimzi (tc02)"

echo "== local tools =="
for t in oc kubectl python3 curl; do command -v $t >/dev/null && echo "  $t ok" || echo "  MISSING $t"; done
python3 -c "import scipy" 2>/dev/null && echo "  scipy ok (tc03)" || echo "  scipy MISSING: pip install scipy --user (needed for TC-03 ks-gate)"

echo "== done =="
