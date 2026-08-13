#!/bin/bash
# ============================================================
# LAB 5 - Platform drills. Timed: 15 min each to root cause.
# Run block by block.
# ============================================================
set -x
oc project prod-sim

### ================= DRILL 1: DNS breakage =================
cat << 'YAML' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: break-dns
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector: {}     # allow in-namespace only; DNS egress to openshift-dns now blocked
YAML

# SYMPTOM: new lookups fail, EXISTING connections still work (DNS-vs-network signature)
oc run dnstest --rm -it --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
  sh -c "getent hosts kubernetes.default.svc.cluster.local || echo LOOKUP-FAILED"

# DIAGNOSE (always from INSIDE the affected namespace):
oc run dnstest2 --rm -it --image=registry.access.redhat.com/ubi9/ubi-minimal --restart=Never -- \
  sh -c "nslookup kubernetes.default.svc.cluster.local 172.30.0.10; echo exit=\$?"
oc get networkpolicy      # <- the culprit reveals itself
# LESSON: DNS problems are frequently NetworkPolicy problems wearing a disguise.

# FIX
oc delete networkpolicy break-dns

### ================= DRILL 2: PVC stuck Pending =================
cat << 'YAML' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bad-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: does-not-exist
  resources: { requests: { storage: 1Gi } }
YAML
oc describe pvc bad-pvc | grep -A3 "Events:"
# Expected: storageclass.storage.k8s.io "does-not-exist" not found
oc delete pvc bad-pvc

# Harder variant: valid SC + WaitForFirstConsumer + impossible nodeSelector
SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
cat << YAML | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: wfc-pvc }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $SC
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: wfc-pod }
spec:
  nodeSelector: { disktype: unobtainium }
  containers:
  - name: c
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["sleep","3600"]
    volumeMounts: [{ name: v, mountPath: /data }]
  volumes: [{ name: v, persistentVolumeClaim: { claimName: wfc-pvc } }]
YAML
oc describe pod wfc-pod | grep -A5 "Events:"   # scheduling constraint shown here
oc describe pvc wfc-pvc | grep -A3 "Events:"   # waiting for first consumer
# LESSON: storage and scheduling failures interlock - PVC and pod wait on each other.
oc delete pod wfc-pod; oc delete pvc wfc-pvc

### ================= DRILL 3: OOMKilled vs evicted =================
cat << 'YAML' | oc apply -f -
apiVersion: v1
kind: Pod
metadata: { name: oom-pod }
spec:
  containers:
  - name: hog
    image: registry.access.redhat.com/ubi9/python-311
    command: ["python3","-c","a=[]\nwhile True: a.append(' '*1048576)"]
    resources:
      limits: { memory: "64Mi" }
      requests: { memory: "64Mi" }
YAML
sleep 30
oc describe pod oom-pod | grep -A5 "Last State"
# Expected: Reason: OOMKilled, Exit Code: 137
# OOMKill = cgroup-level: limit breached, container killed, pod restarts IN PLACE.
# Eviction (see TC-05) = kubelet-level: node pressure, pod REMOVED + rescheduled.
oc delete pod oom-pod

### ================= DRILL 4: Route 503 =================
oc get route web -o jsonpath='{.spec.host}' > /tmp/host
oc delete svc web
curl -s -o /dev/null -w "%{http_code}\n" http://$(cat /tmp/host)/   # 503

# DIAGNOSE CHAIN: route -> service -> endpoints
oc get route web
oc get svc web            # gone
oc expose deployment web --port=8080   # restore
curl -s -o /dev/null -w "%{http_code}\n" http://$(cat /tmp/host)/   # 200

# Subtler variant: wrong selector -> endpoints object EXISTS but is EMPTY
oc patch svc web -p '{"spec":{"selector":{"deployment":"wrong-name"}}}'
oc get endpoints web      # <none>  <- THE tell for router 503
curl -s -o /dev/null -w "%{http_code}\n" http://$(cat /tmp/host)/   # 503 again
# RULE: router 503 = empty endpoints. Exactly three causes:
#   no matching pods | pods not Ready | wrong selector
oc patch svc web -p '{"spec":{"selector":{"deployment":"web"}}}'
oc get endpoints web
