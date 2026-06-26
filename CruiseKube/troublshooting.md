# CruiseKube on OpenShift — Setup Journey & Troubleshooting Log

This document is a chronological record of everything done to get **CruiseKube** (Kubernetes resource right-sizing controller) running on OpenShift, backed by a standalone **Prometheus**, integrated with OpenShift's **built-in cluster monitoring** (node-exporter, kube-state-metrics). It captures every issue hit, why it happened, and exactly how it was resolved — for future reference and onboarding.

---

## Architecture Overview

| Component | Namespace | Role |
|---|---|---|
| Prometheus (standalone) | `cruisekube-metrics` | Central metrics store; scrapes kubelet, OpenShift's built-in node-exporter, and OpenShift's built-in kube-state-metrics |
| CruiseKube Controller | `cruisekube-system` | Queries Prometheus, computes resource recommendations |
| CruiseKube Webhook | `cruisekube-system` | Admission webhook — applies recommendations to pods at creation time |
| CruiseKube Frontend | `cruisekube-system` | Dashboard UI (port 3000) |
| PostgreSQL (bundled) | `cruisekube-system` | Stores CruiseKube's stats, history, and recommendations |
| OpenShift built-in `node-exporter` | `openshift-monitoring` | Already shipped by OpenShift — reused instead of installing a duplicate |
| OpenShift built-in `kube-state-metrics` | `openshift-monitoring` | Already shipped by OpenShift — reused instead of installing a duplicate |

**Key lesson learned across this whole exercise:** OpenShift already ships its own `node-exporter` and `kube-state-metrics` as part of cluster monitoring. Don't deploy duplicates — point your Prometheus at the existing ones instead. This avoids hostPort conflicts, duplicate scraping, and wasted SCC troubleshooting.

---

## Issue Log (in order encountered)

### Issue 1 — Prometheus pod rejected by OpenShift SCC

**Symptom:**
```
unable to validate against any security context constraint:
provider restricted-v2: .containers[0].runAsUser: Invalid value: 65534:
must be in the ranges: [1000740000, 1000749999]
```

**Cause:** The upstream `prometheus-community/prometheus` Helm chart hardcodes `runAsUser: 65534` / `fsGroup: 65534` (the standard "nobody" UID on vanilla Kubernetes). OpenShift assigns each namespace its own allowed UID range and rejects any pod requesting a UID outside it.

**Fix:** Override the chart's security context to `null`, letting OpenShift auto-assign a valid UID:

```yaml
server:
  securityContext:
    runAsUser: null
    runAsNonRoot: true
    fsGroup: null
  containerSecurityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
```

---

### Issue 2 — Browser shows "Application is not available" despite healthy pod

**Symptom:** Pod `2/2 Running`, Service has valid endpoints, but the OpenShift Route shows:
```
Application is not available
Route and path matches, but all pods are down.
```

**Cause:** The Route was created with an **explicit numeric port** (`oc expose svc/... --port=80`), but the chart's Service exposes a **named port** (`http`), not the bare number `80`. OpenShift's router couldn't match the two, so it served a generic error page — even though the backend was completely healthy.

**Fix:** Delete and recreate the Route **without** specifying `--port`, letting OpenShift auto-detect the named port:

```bash
oc delete route <name> -n <namespace>
oc expose svc/<name> -n <namespace>
```

Verified working via `curl` from inside the cluster (returned `302 Found → /query`, Prometheus's normal redirect) before confirming in browser.

---

### Issue 3 — CruiseKube chart has no `securityContext` override available

**Symptom:** Same SCC rejection pattern as Issue 1, but for CruiseKube's `bootstrap-secrets` pre-install hook job:
```
provider restricted-v2: .containers[0].runAsUser: Invalid value: 1001:
must be in the ranges: [1000750000, 1000759999]
```

**Cause:** Unlike the Prometheus community chart, CruiseKube's `values.yaml` has **no `securityContext` key exposed anywhere** for any component (controller, webhook, postgres, frontend, or the bootstrap job) — confirmed by searching the full default values output. There was no values-based fix available.

**Fix:** Grant the `anyuid` SCC to the entire namespace's service accounts before installing:

```bash
oc create namespace cruisekube-system
oc adm policy add-scc-to-group anyuid system:serviceaccounts:cruisekube-system
```

> ⚠️ This loosens UID enforcement for every pod in that namespace. Acceptable for dev/sandbox; flag to a security owner before using in shared/production clusters.

---

### Issue 4 — Orphaned pre-install hook Job after a failed install

**Symptom:**
```
Error creating: pods "cruisekube-controller-bootstrap-secrets-" is forbidden:
error looking up service account cruisekube-system/cruisekube-controller-admin-credential-generator: serviceaccount "..." not found
```

**Cause:** An earlier `helm install` failed and timed out (due to Issue 3). Helm's rollback deleted the ServiceAccount the hook Job depended on, but the Job object itself — protected by `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded` — wasn't cleaned up automatically. It kept retrying against a now-nonexistent SA.

**Fix:** Full clean slate before retrying:

```bash
helm uninstall cruisekube -n cruisekube-system --ignore-not-found
oc delete job cruisekube-controller-bootstrap-secrets -n cruisekube-system --ignore-not-found
```

Then reinstall with the SCC grant from Issue 3 already in place.

---

### Issue 5 — Installing a second node-exporter conflicts with OpenShift's built-in one

**Symptom:** After granting the `node-exporter` SCC (a built-in, scoped SCC — unlike `anyuid`) and successfully getting pods scheduled past security checks, the DaemonSet pods got stuck:
```
0/2 nodes are available:
1 node(s) didn't have free ports for the requested pod ports
1 node(s) didn't satisfy plugin(s) [NodeAffinity]
```

**Cause:** The chart's node-exporter uses `hostPort: 9100`. OpenShift's cluster monitoring **already runs its own node-exporter DaemonSet on every node**, bound to that same hostPort — two DaemonSets can't share it. The second node (control-plane/master) additionally failed NodeAffinity since the chart's DaemonSet had no toleration for master nodes.

**Confirmed via:**
```bash
oc get ds -n openshift-monitoring | grep node-exporter   # already present, 2/2 nodes
oc get nodes                                              # confirmed 1 worker + 1 control-plane
```

**Fix:** Don't install a duplicate. Uninstall it and reuse OpenShift's existing exporter instead:

```bash
helm uninstall prometheus-node-exporter -n rbac-secrets-demo
```

---

### Issue 6 — OpenShift's built-in node-exporter/kube-state-metrics require HTTPS + auth, not plain HTTP

**Symptom:** Standard plain-HTTP scrape jobs (originally written for the Helm-chart-installed exporters) returned nothing, since OpenShift's built-in exporters are wrapped in a `kube-rbac-proxy` sidecar (visible as the `2/2 Running` container count) requiring TLS + a bearer token.

**Fix:** Updated scrape jobs to use HTTPS + the Prometheus pod's own ServiceAccount token:

```yaml
- job_name: node-exporter
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
          - openshift-monitoring
  scheme: https
  tls_config:
    insecure_skip_verify: true
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      regex: node-exporter
      action: keep
    - source_labels: [__meta_kubernetes_endpoint_port_name]
      regex: https
      action: keep
```

Same pattern applied to `kube-state-metrics`, with port name `https-main` (confirmed via `oc get endpoints kube-state-metrics -n openshift-monitoring -o yaml`).

**Required RBAC grant** (without this, the bearer token has no read permission and scraping returns `403 Forbidden`):

```bash
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z cruisekube-prometheus-server \
  -n cruisekube-metrics
```

> ⚠️ **Common mistake made during this step:** the RBAC role was first (incorrectly) bound to an unrelated ServiceAccount (`rbac-demo-sa` in a demo namespace) instead of the actual Prometheus pod's ServiceAccount (`cruisekube-prometheus-server` in `cruisekube-metrics`). Always confirm the real SA first:
> ```bash
> oc get pod -n <namespace> -l app.kubernetes.io/name=prometheus \
>   -o jsonpath='{.items[0].spec.serviceAccountName}'
> ```

---

### Issue 7 — `kube-state-metrics` scrape job pointed at a service that never existed

**Symptom:** CruiseKube dashboard showed all-zero values: `0 cores`, `0 GB`, `0%` cluster utilization, `0 / 0` workloads — despite Prometheus itself being healthy.

**Cause:** The original scrape config's `kube-state-metrics` job searched for a service literally named `prometheus-kube-state-metrics`, which was never deployed (its subchart was explicitly `enabled: false`). With no data source for "requested," "allocatable," or "recommended" values, CruiseKube had nothing to compute from — even though *usage* data (from node-exporter) may have been partially flowing.

**Fix:** Same HTTPS+bearer-token pattern as Issue 6, pointed at OpenShift's real `kube-state-metrics` service in `openshift-monitoring`.

**Verified working via:**
```bash
curl -s "http://<prometheus-route>/api/v1/targets" | jq '.data.activeTargets[] | select(.labels.job=="kube-state-metrics")'
# → "health": "up", "lastError": ""
```

---

### Issue 8 — Dashboard still shows `0 / 0` workloads after everything is fixed

**Symptom:** All Prometheus targets `UP`, controller logs show zero errors and successful queries every cycle (`fetchmetrics` every 1 min, confirmed via logs) — but dashboard still shows no workloads.

**Cause:** Not a bug — by design. The chart's default setting:
```yaml
CRUISEKUBE_RECOMMENDATIONSETTINGS_NEWWORKLOADTHRESHOLDHOURS: "1"
```
means CruiseKube deliberately waits **1 hour** of usage history per workload before generating/displaying recommendations for it, to avoid acting on insufficient data. Test workloads deployed minutes earlier simply hadn't crossed that threshold yet.

**Resolution:** Wait. No fix needed — confirmed the entire pipeline (Prometheus → scrape → query → controller) was already working correctly; this was purely a time-based gate.

**Optional for faster testing in a sandbox only:**
```bash
helm upgrade cruisekube oci://tfy.jfrog.io/tfy-helm/cruisekube \
  --namespace cruisekube-system \
  --reuse-values \
  --set cruisekubeController.env.CRUISEKUBE_RECOMMENDATIONSETTINGS_NEWWORKLOADTHRESHOLDHOURS="0"
```
⚠️ Revert to `"1"` (or higher) after testing — this threshold exists to protect recommendation quality.

---

## Final Working Configuration

### `standalone-prometheus-values.yaml`

```yaml
serverFiles:
  prometheus.yml:
    scrape_configs:
      - job_name: kube-state-metrics
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names:
                - openshift-monitoring
        scheme: https
        tls_config:
          insecure_skip_verify: true
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - source_labels:
              - __meta_kubernetes_service_name
            regex: kube-state-metrics
            action: keep
          - source_labels:
              - __meta_kubernetes_endpoint_port_name
            regex: https-main
            action: keep

      - job_name: node-exporter
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names:
                - openshift-monitoring
        scheme: https
        tls_config:
          insecure_skip_verify: true
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
        relabel_configs:
          - source_labels:
              - __meta_kubernetes_service_name
            regex: node-exporter
            action: keep
          - source_labels:
              - __meta_kubernetes_endpoint_port_name
            regex: https
            action: keep

      - job_name: kubelet
        scheme: https
        kubernetes_sd_configs:
          - role: node
        tls_config:
          insecure_skip_verify: true
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

prometheus-node-exporter:
  enabled: false

kube-state-metrics:
  enabled: false

prometheus-pushgateway:
  enabled: false

alertmanager:
  enabled: false

server:
  securityContext:
    runAsUser: null
    runAsNonRoot: true
    fsGroup: null
  containerSecurityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

configmapReload:
  prometheus:
    containerSecurityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
```

### Full command sequence (clean install, start to finish)

```bash
# --- Prometheus ---
mkdir cruisekube && cd cruisekube
# (create standalone-prometheus-values.yaml as above)

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install cruisekube-prometheus prometheus-community/prometheus \
  --namespace cruisekube-metrics \
  --create-namespace \
  -f standalone-prometheus-values.yaml

oc expose svc/cruisekube-prometheus-server -n cruisekube-metrics   # no --port flag

# --- RBAC for reading OpenShift's built-in monitoring metrics ---
oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z cruisekube-prometheus-server \
  -n cruisekube-metrics

# --- CruiseKube ---
oc create namespace cruisekube-system
oc adm policy add-scc-to-group anyuid system:serviceaccounts:cruisekube-system

helm install cruisekube oci://tfy.jfrog.io/tfy-helm/cruisekube \
  --namespace cruisekube-system \
  --set cruisekubeController.env.CRUISEKUBE_DEPENDENCIES_INCLUSTER_PROMETHEUSURL="http://cruisekube-prometheus-server.cruisekube-metrics.svc:80"

oc expose svc/cruisekube-frontend -n cruisekube-system   # no --port flag

# --- Retrieve dashboard credentials ---
NAMESPACE=cruisekube-system
SECRET=cruisekube-controller-admin-credentials
kubectl get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.data.admin-user}' | base64 -d && echo
kubectl get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

---

## Verification Checklist

Use this to confirm a healthy setup at a glance:

```bash
# Prometheus pod healthy
oc get pods -n cruisekube-metrics

# All scrape targets UP
curl -s "http://<prometheus-route>/api/v1/targets" | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# CruiseKube pods healthy
oc get pods -n cruisekube-system

# Controller successfully querying Prometheus (no errors)
oc logs -n cruisekube-system -l app.kubernetes.io/name=controller --tail=200 | grep -i "error\|fail"
# (expect: no output)

# Confirm correct Prometheus URL wired into controller
oc get deploy cruisekube-controller -n cruisekube-system \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CRUISEKUBE_DEPENDENCIES_INCLUSTER_PROMETHEUSURL")].value}'
```

---

## General Lessons Learned

1. **OpenShift SCCs ≠ vanilla Kubernetes PodSecurity.** Charts written for generic Kubernetes almost always hardcode UIDs that OpenShift will reject. Check for a `securityContext` override in chart values first; if none exists, scope an SCC grant to the specific ServiceAccount (or, as a last resort, the namespace).
2. **Never install monitoring exporters that OpenShift already ships.** Check `openshift-monitoring` first (`oc get ds -n openshift-monitoring`, `oc get pods -n openshift-monitoring`) before deploying your own node-exporter/kube-state-metrics — duplicates cause hostPort conflicts and wasted effort.
3. **OpenShift's built-in monitoring is locked down by design.** Anything scraping it needs `scheme: https`, a `bearer_token_file`, and a `cluster-monitoring-view` RBAC grant on the *correct* ServiceAccount — always confirm the real SA name rather than assuming.
4. **`oc expose svc` without `--port` is safer than guessing the port.** Many charts use named Service ports; specifying a numeric `--port` that doesn't match causes a confusing "Application is not available" error even when everything is healthy.
5. **A "stuck at zero" dashboard isn't always a bug.** Check time-based thresholds (like CruiseKube's 1-hour new-workload gate) before assuming something is broken — check the actual backend logs/queries first.
6. **Failed Helm installs can leave orphaned hook Jobs.** Always `helm uninstall` + manually delete any leftover hook Job before retrying, especially when pre-install hooks are involved.
