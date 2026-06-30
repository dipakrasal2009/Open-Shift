# CruiseKube on OpenShift — Setup Guide

This README documents the complete, tested setup of **CruiseKube** (Kubernetes resource right-sizing controller) on an OpenShift cluster, including a standalone **Prometheus** metrics source, all OpenShift-specific SCC fixes, and dashboard access via Routes.

> Environment used in this guide: OpenShift cluster `ocp.glistopenshift.online`, AWS-backed storage (`ebs.csi.aws.com`), Helm v3, `oc` CLI as cluster-admin.

---

## Table of Contents

1. [What is CruiseKube](#1-what-is-cruisekube)
2. [Prerequisites](#2-prerequisites)
3. [Part A — Install standalone Prometheus](#3-part-a--install-standalone-prometheus)
4. [Part B — Install CruiseKube](#4-part-b--install-cruisekube)
5. [Part C — Access the CruiseKube Dashboard](#5-part-c--access-the-cruisekube-dashboard)
6. [Part D — Retrieve Admin Credentials](#6-part-d--retrieve-admin-credentials)
7. [Troubleshooting Reference](#7-troubleshooting-reference)
8. [Useful Commands Cheat Sheet](#8-useful-commands-cheat-sheet)

---

## 1. What is CruiseKube

CruiseKube is an open-source Kubernetes controller (by TrueFoundry) that automatically right-sizes CPU and memory requests for workloads — continuously, in-place, and without manual YAML edits.

**Architecture components installed by the Helm chart:**

| Component | Role |
|---|---|
| `cruisekube-controller` | Runs scheduled tasks: `CreateStats`, `FetchMetrics`, `ApplyRecommendation`, `NodeLoadMonitoring`, `Cleanup`. Pulls metrics from Prometheus. |
| `cruisekube-webhook` | Admission webhook — intercepts new pod creation and applies recommendations at admission time. |
| `cruisekube-postgresql` | Bundled Postgres DB — stores stats, history, and recommendations. |
| `cruisekube-frontend` | Web dashboard UI (port 3000). |
| Pre-install hook (`bootstrap-secrets`) | One-time Job that generates admin login credentials and an install ID. |

**Why use it:** eliminates chronic CPU/memory over-provisioning caused by developers padding requests out of fear of OOM kills or CPU throttling — without requiring manual tuning or rewriting manifests.

---

## 2. Prerequisites

- `oc` CLI authenticated to the OpenShift cluster with **cluster-admin** (needed to grant SCCs)
- `helm` v3 installed
- Cluster has a working default StorageClass (PVCs are needed for Prometheus and Postgres)
- Outbound network access to:
  - `prometheus-community` Helm repo
  - `tfy.jfrog.io` (CruiseKube Helm chart + images)
  - `quay.io`, `registry-1.docker.io` (container images)

---

## 3. Part A — Install standalone Prometheus

CruiseKube needs a Prometheus instance as its metrics source. This sets up a dedicated, standalone Prometheus (not the OpenShift in-cluster monitoring stack) scraping `kubelet`, `kube-state-metrics`, and `node-exporter`.

### 3.1 Create working directory

```bash
mkdir cruisekube && cd cruisekube
```

### 3.2 Create `standalone-prometheus-values.yaml`

```bash
cat > standalone-prometheus-values.yaml << 'EOF'
serverFiles:
  prometheus.yml:
    scrape_configs:
      - job_name: kube-state-metrics
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - source_labels:
              - __meta_kubernetes_service_name
            regex: prometheus-kube-state-metrics
            action: keep
      - job_name: node-exporter
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - source_labels:
              - __meta_kubernetes_service_name
            regex: prometheus-prometheus-node-exporter
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
EOF
```

> **Why the `securityContext` block matters:** the upstream `prometheus-community/prometheus` chart hardcodes `runAsUser: 65534` / `fsGroup: 65534` by default. OpenShift's default `restricted-v2` SCC only allows UIDs from the namespace's auto-allocated range (e.g. `1000740000–1000749999`), so the pod gets rejected with `unable to validate against any security context constraint` unless these values are overridden to `null` (letting OpenShift assign a UID automatically).

### 3.3 Add the Helm repo and install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install cruisekube-prometheus prometheus-community/prometheus \
  --namespace cruisekube-metrics \
  --create-namespace \
  -f standalone-prometheus-values.yaml
```

### 3.4 Verify the pod is running

```bash
oc get pods -n cruisekube-metrics
```

Expected: `cruisekube-prometheus-server-xxxxx` → `2/2 Running`.

### 3.5 Expose Prometheus via OpenShift Route

```bash
oc expose svc/cruisekube-prometheus-server -n cruisekube-metrics
```

> ⚠️ **Do NOT pass `--port=80`.** The chart's Service exposes a **named port** (`http`), not the literal number `80`. Using `--port=80` creates a Route the OpenShift router can't match to the Service's actual port, resulting in an "Application is not available" page even though the pod is healthy. Let `oc expose` auto-detect the named port instead.

### 3.6 Confirm the Route

```bash
oc get route cruisekube-prometheus-server -n cruisekube-metrics
```

The `PORT` column should show `http` (not a number). Open the printed `HOST/PORT` URL + `/targets` in your browser to confirm scrape targets are healthy.

### 3.7 Verify scraping works (CLI sanity check)

```bash
curl -s http://cruisekube-prometheus-server.cruisekube-metrics.svc:80/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

> Note: `kube-state-metrics` and `node-exporter` jobs were intentionally disabled as subcharts in this setup (`enabled: false`). Their scrape configs reference service names (`prometheus-kube-state-metrics`, `prometheus-prometheus-node-exporter`) that won't exist unless you deploy them separately or point the regex at OpenShift's own monitoring stack service names. Only the `kubelet` job is guaranteed to populate targets out of the box.

---

## 4. Part B — Install CruiseKube

### 4.1 Create the namespace and grant SCC permissions

The CruiseKube chart (controller, webhook, Postgres, frontend, bootstrap job) hardcodes non-root UIDs (e.g. `1001`) with **no values.yaml override available** for `securityContext`. The fix is to grant the `anyuid` SCC to all service accounts in the namespace **before** installing.

```bash
oc create namespace cruisekube-system
oc adm policy add-scc-to-group anyuid system:serviceaccounts:cruisekube-system
```

> ⚠️ This loosens UID enforcement for everything in `cruisekube-system`. Acceptable for dev/sandbox clusters. Flag this to your security/platform team before doing this on a shared or production cluster.

### 4.2 Install CruiseKube via Helm (OCI chart)

```bash
helm install cruisekube oci://tfy.jfrog.io/tfy-helm/cruisekube \
  --namespace cruisekube-system \
  --set cruisekubeController.env.CRUISEKUBE_DEPENDENCIES_INCLUSTER_PROMETHEUSURL="http://cruisekube-prometheus-server.cruisekube-metrics.svc:80"
```

> Don't use `--create-namespace` here since the namespace + SCC grant must already exist from Step 4.1 — applying the SCC grant *after* the namespace is created but *before* Helm schedules any pods avoids the SCC `FailedCreate` errors seen during initial testing.

### 4.3 Watch the rollout

```bash
oc get pods -n cruisekube-system -w
```

Expected final state (Ctrl+C once stable):

```
NAME                                     READY   STATUS    RESTARTS   AGE
cruisekube-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          ~1m
cruisekube-frontend-xxxxxxxxxx-xxxxx     1/1     Running   0          ~1m
cruisekube-postgresql-0                  1/1     Running   0          ~1m
cruisekube-webhook-xxxxxxxxxx-xxxxx      1/1     Running   0          ~1m
```

> A transient `Unhealthy: Readiness probe failed ... connection refused` event on the controller pod during startup is normal — it resolves once the app finishes booting (took ~15–20s in testing).

### 4.4 Confirm all resources

```bash
oc get all -n cruisekube-system
```

Should show 4 Deployments/StatefulSet, 5 Services (`cruisekube-controller`, `cruisekube-frontend`, `cruisekube-postgresql`, `cruisekube-postgresql-hl`, `cruisekube-webhook-webhook`), and matching ReplicaSets.

---

## 5. Part C — Access the CruiseKube Dashboard

### 5.1 Confirm the frontend Service's port name

```bash
oc get svc cruisekube-frontend -n cruisekube-system -o jsonpath='{.spec.ports[*].name}'
```

Expected output: `http`

### 5.2 Expose via Route (no explicit `--port`)

```bash
oc expose svc/cruisekube-frontend -n cruisekube-system
```

### 5.3 Get the Route URL

```bash
oc get routes -n cruisekube-system
```

Open the `HOST/PORT` value shown in your browser, e.g.:

```
http://cruisekube-frontend-cruisekube-system.apps.<your-cluster-domain>
```

---

## 6. Part D — Retrieve Admin Credentials

The chart auto-generates dashboard login credentials via a pre-install hook Job, stored in a Secret.

```bash
NAMESPACE=cruisekube-system
SECRET=cruisekube-controller-admin-credentials

# Username
kubectl get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.admin-user}' | base64 -d && echo

# Password
kubectl get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

> 🔒 **Security note:** treat this password as a real credential. Don't paste it into chat logs, tickets, or shared docs in plaintext. Rotate it if it's ever been exposed outside a secure channel. Store it in a password manager or your org's secrets vault instead of a plain text file.

Log into the dashboard at the Route URL from Part C using these credentials.

---

## 7. Troubleshooting Reference

| Symptom | Root Cause | Fix |
|---|---|---|
| `FailedCreate ... unable to validate against any security context constraint` | Chart hardcodes a UID/GID outside the namespace's OpenShift-allocated range | For charts exposing `securityContext` in values (Prometheus): override `runAsUser`/`fsGroup` to `null`. For charts without that override (CruiseKube): grant `anyuid` SCC to the namespace's service accounts (Part B, Step 4.1) |
| Job stuck `Running 0/1`, eventually `serviceaccount "<name>" not found` | A previous failed `helm install` rolled back and deleted the ServiceAccount, but left the pre-install hook Job orphaned, still retrying | `helm uninstall <release> -n <namespace>` then manually `oc delete job <job-name> -n <namespace>` before retrying install |
| Browser shows **"Application is not available"** even though pod is `Running` and has healthy Endpoints | Route was created with an explicit numeric `--port` that doesn't match the Service's **named** port | `oc delete route <name>` then `oc expose svc/<name>` **without** `--port` — let OpenShift auto-detect the named port |
| Can't reach `localhost:9090` from a local browser after `oc port-forward` | `port-forward` binds to `localhost` on the remote bastion/server, not your laptop | Use an OpenShift Route (`oc expose svc`) for persistent access, or an SSH tunnel (`ssh -L 9090:localhost:9090 user@host`) for a temporary session |
| Debug pod (e.g. `curl-test`) shows a `PodSecurity "restricted:latest"` **warning** but still runs | Cluster enforces PSA warnings for ad-hoc pods without explicit security contexts; usually non-blocking | Safe to ignore for short-lived debug pods; add explicit `securityContext` if it starts hard-failing instead of warning |

---

## 8. Useful Commands Cheat Sheet

```bash
# Check pod status across both namespaces
oc get pods -n cruisekube-metrics
oc get pods -n cruisekube-system

# Check Prometheus targets/scrape health
curl -s http://cruisekube-prometheus-server.cruisekube-metrics.svc:80/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Check Route URLs
oc get routes -n cruisekube-metrics
oc get routes -n cruisekube-system

# Get recent events for debugging
oc get events -n cruisekube-system --sort-by='.lastTimestamp' | tail -30
oc get events -n cruisekube-metrics --sort-by='.lastTimestamp' | tail -30

# Describe a problem pod
oc describe pod <pod-name> -n <namespace>

# Retrieve admin credentials again later
kubectl get secret cruisekube-controller-admin-credentials -n cruisekube-system \
  -o jsonpath='{.data.admin-user}' | base64 -d && echo
kubectl get secret cruisekube-controller-admin-credentials -n cruisekube-system \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Uninstall everything (clean slate)
helm uninstall cruisekube -n cruisekube-system
helm uninstall cruisekube-prometheus -n cruisekube-metrics
oc delete namespace cruisekube-system
oc delete namespace cruisekube-metrics
```

---

## Next Steps (Not Yet Covered)

- **Enable optimization tasks carefully:** the chart ships with `ApplyRecommendation` enabled by default. In the dashboard, leave workloads in **Recommend mode** (observe-only) for several days before promoting any workload to **Cruise mode** (auto-apply), so you can validate recommendations against real traffic first.
- **Set disruption windows** in the dashboard per-workload to avoid CruiseKube applying changes during deploys or launch windows.
- **Fix `kube-state-metrics` / `node-exporter` scrape targets** if you need full metrics coverage beyond `kubelet` — either deploy those exporters separately or repoint the scrape config's `regex` at your cluster's actual exporter service names (check with `oc get svc -A | grep -E "kube-state-metrics|node-exporter"`).
- **Review the `anyuid` SCC grant** (Section 4.1) with your security team before using this setup outside a sandbox/dev cluster.
