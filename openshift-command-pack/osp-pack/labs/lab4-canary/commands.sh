#!/bin/bash
# ============================================================
# LAB 4 - Canary with Argo Rollouts + automated analysis
# ============================================================
set -x

### 1. Install Argo Rollouts operator (one-time)
cat << YAML | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: argo-rollouts
  namespace: openshift-operators
spec:
  channel: alpha
  name: argo-rollouts-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML
# Wait for CSV to reach Succeeded:
oc get csv -n openshift-operators -w   # Ctrl+C when argo-rollouts Succeeded

# kubectl-argo-rollouts plugin (workstation):
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64 && sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

### 2. RBAC so the analysis can query Thanos
oc project prod-sim
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z default -n prod-sim

### 3. Deploy the Rollout + AnalysisTemplate
oc apply -f analysistemplate.yaml
oc apply -f rollout.yaml
oc expose rollout web-canary --port=8080 2>/dev/null || \
  oc create service clusterip web-canary --tcp=8080:8080
kubectl argo rollouts get rollout web-canary -n prod-sim --watch   # Ctrl+C when Healthy

### 4. CLEAN RUN - happy path
kubectl argo rollouts set image web-canary web=quay.io/openshifttest/hello-openshift:multiarch -n prod-sim
kubectl argo rollouts get rollout web-canary -n prod-sim --watch
# Expect: 20% -> pause -> analysis PASS -> 60% -> pause -> 100% -> Healthy

### 5. FORCED ABORT - prove the gate fires
# Deploy a version that returns 500 on ~10% of requests (any image whose app
# emits http_requests_total with status=5xx works; use your instrumented test image)
kubectl argo rollouts set image web-canary web=quay.io/YOUR_ORG/hello-500s:latest -n prod-sim
kubectl argo rollouts get rollout web-canary -n prod-sim --watch
# Expect: analysis FAIL at step 3 -> automatic abort -> rollback to stable
kubectl argo rollouts status web-canary -n prod-sim   # Degraded -> then re-promote stable

### 6. Evidence capture
kubectl argo rollouts get rollout web-canary -n prod-sim > evidence-rollout-state.txt
oc get analysisruns -n prod-sim -o yaml > evidence-analysisruns.yaml
