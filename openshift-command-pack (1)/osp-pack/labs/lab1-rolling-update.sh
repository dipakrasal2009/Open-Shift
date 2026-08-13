#!/bin/bash
# ============================================================
# LAB 1 - Rolling Update Failures
# Run block by block. Do NOT run end-to-end blindly.
# ============================================================
set -x

### ---- 1A. DEPLOY ----
oc new-project prod-sim
oc new-app --name=web --image=quay.io/openshifttest/hello-openshift:1.2.0
oc scale deployment/web --replicas=4
oc expose deployment web --port=8080
oc expose svc/web
oc set probe deployment/web --readiness --get-url=http://:8080/ --initial-delay-seconds=5

# Production-grade rollout parameters: never reduce serving capacity
oc patch deployment web -p "{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":1,\"maxUnavailable\":0}}}}"
oc rollout status deployment/web

### ---- 1B. BREAK 1: bad image tag ----
oc set image deployment/web web=quay.io/openshifttest/hello-openshift:doesnotexist
oc get pods -w   # Ctrl+C after observing: 1 new pod ImagePullBackOff, 4 old pods still serving

# DIAGNOSE
oc get events -n prod-sim --sort-by=.lastTimestamp | tail -20
oc describe pod -l deployment=web | grep -A5 "Events:"
# Expected event: Failed to pull image ... manifest unknown

# FIX
oc rollout undo deployment/web
oc rollout status deployment/web

# CONTRAST RUN: same break with weaker settings - watch capacity drop
oc patch deployment web -p "{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":1,\"maxUnavailable\":\"25%\"}}}}"
oc set image deployment/web web=quay.io/openshifttest/hello-openshift:doesnotexist
oc get pods    # note: an old pod IS terminated this time
oc rollout undo deployment/web
oc patch deployment web -p "{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":1,\"maxUnavailable\":0}}}}"

### ---- 1C. BREAK 2: readiness failure (Running but not Ready) ----
oc set probe deployment/web --readiness --get-url=http://:8080/nonexistent
oc get pods              # new pods: Running 0/1
oc rollout status deployment/web --timeout=60s   # hangs -> times out

# DIAGNOSE
oc describe pod -l deployment=web | grep -B2 -A2 "Readiness probe failed"
oc get endpoints web -o wide   # new pod NEVER appears here = why traffic never broke

# FIX
oc rollout undo deployment/web
oc get endpoints web -o wide   # endpoints repopulated

### ---- 1D. BREAK 3: CrashLoopBackOff ----
oc patch deployment web --type=json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":[\"/bin/sh\",\"-c\",\"exit 1\"]}]"
oc get pods -w   # Ctrl+C after seeing CrashLoopBackOff

# DIAGNOSE - the critical habit:
POD=$(oc get pod -l deployment=web -o name | head -1)
oc logs $POD --previous          # the DEAD container logs, not the current one
oc describe $POD | grep -A3 "Last State"
oc get events --sort-by=.lastTimestamp | grep -i backoff | tail -5
# Note backoff doubling: 10s, 20s, 40s ... capped 5m

# FIX
oc rollout undo deployment/web
oc rollout status deployment/web
