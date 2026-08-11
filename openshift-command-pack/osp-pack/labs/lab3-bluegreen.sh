#!/bin/bash
# ============================================================
# LAB 3 - Blue-Green with smoke-gated atomic cutover
# Run block by block.
# ============================================================
set -x
oc project prod-sim

### ---- DEPLOY BOTH COLORS ----
oc new-app --name=web-blue quay.io/openshifttest/hello-openshift:1.2.0
oc new-app --name=web-green quay.io/openshifttest/hello-openshift:multiarch
oc expose svc/web-blue --name=prod-route
ROUTE=$(oc get route prod-route -o jsonpath='{.spec.host}')
curl -s http://$ROUTE/    # serving blue

### ---- SMOKE-GATED CUTOVER (production pattern) ----
# Gate Job curls green via its SERVICE (not the route). Route only flips on exit 0.
cat << 'YAML' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: smoke-green
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: smoke
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/sh","-c"]
        args:
        - |
          for i in 1 2 3 4 5; do
            curl -sf --max-time 3 http://web-green:8080/ || exit 1
            sleep 2
          done
          echo "SMOKE PASS"
YAML

oc wait --for=condition=complete job/smoke-green --timeout=120s && \
  oc patch route prod-route -p '{"spec":{"to":{"name":"web-green"}}}' && \
  echo "CUTOVER DONE" || echo "SMOKE FAILED - route untouched"

curl -s http://$ROUTE/    # now serving green

### ---- INSTANT ROLLBACK (same command, pointed back) ----
oc patch route prod-route -p '{"spec":{"to":{"name":"web-blue"}}}'
curl -s http://$ROUTE/

### ---- PROVE THE GATE BLOCKS A BAD CUTOVER ----
oc delete job smoke-green
oc scale deployment web-green --replicas=0        # green is now broken
cat << 'YAML' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: smoke-green
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: smoke
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/sh","-c"]
        args:
        - |
          for i in 1 2 3 4 5; do
            curl -sf --max-time 3 http://web-green:8080/ || exit 1
            sleep 2
          done
YAML
oc wait --for=condition=complete job/smoke-green --timeout=120s && \
  oc patch route prod-route -p '{"spec":{"to":{"name":"web-green"}}}' || \
  echo "GATE HELD: cutover blocked, still serving blue"
oc scale deployment web-green --replicas=1
oc delete job smoke-green

# REVIEW POINTS (defend these):
# 1. Blue-green doubles resource cost during the window - plan quota.
# 2. DB schema must be backward-compatible across both colors (expand/contract).
# 3. Long-lived connections (websockets, Kafka consumers) do NOT cut over with
#    the route - they drain on old pods. terminationGracePeriodSeconds must
#    match the longest connection.
