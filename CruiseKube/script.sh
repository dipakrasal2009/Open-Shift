#!/usr/bin/env bash
# =============================================================================
# CruiseKube on OpenShift — Full Reset & Setup Script
# =============================================================================
# Usage:  chmod +x cruisekube-setup.sh && ./cruisekube-setup.sh
#
# What this script does:
#   1. Tears down any previous CruiseKube + Prometheus installation
#   2. Recreates everything from scratch (Prometheus → RBAC → CruiseKube)
#   3. Prints all URLs, usernames, and passwords at the end
#
# Requirements:
#   - oc CLI authenticated as cluster-admin
#   - helm v3 installed
#   - jq installed (for JSON parsing at the end)
#   - Outbound access to: prometheus-community Helm repo, tfy.jfrog.io, quay.io
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }

# ── Config — change these if needed ──────────────────────────────────────────
PROM_NAMESPACE="cruisekube-metrics"
CK_NAMESPACE="cruisekube-system"
PROM_RELEASE="cruisekube-prometheus"
CK_RELEASE="cruisekube"
PROM_VALUES_FILE="/tmp/standalone-prometheus-values.yaml"
PROM_SVC="cruisekube-prometheus-server"
CK_FRONTEND_SVC="cruisekube-frontend"
CK_SECRET="cruisekube-controller-admin-credentials"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight Checks"

command -v oc   >/dev/null 2>&1 || error "'oc' CLI not found. Install it and authenticate as cluster-admin."
command -v helm >/dev/null 2>&1 || error "'helm' v3 not found. Install it first."
command -v jq   >/dev/null 2>&1 || error "'jq' not found. Install it (e.g. yum install jq / apt install jq)."

# Verify cluster-admin
if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  error "Not authenticated as cluster-admin. Run 'oc login' with cluster-admin credentials first."
fi
success "Pre-flight checks passed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — TEARDOWN PREVIOUS INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 1 — Tearing Down Previous Installation"

info "Uninstalling Helm release: ${CK_RELEASE} (namespace: ${CK_NAMESPACE})"
helm uninstall "${CK_RELEASE}" -n "${CK_NAMESPACE}" 2>/dev/null && \
  success "CruiseKube Helm release removed." || \
  warn "CruiseKube release not found (skipping)."

info "Cleaning up any orphaned pre-install hook Jobs..."
oc delete job -n "${CK_NAMESPACE}" \
  -l "helm.sh/chart" --ignore-not-found 2>/dev/null || true
oc delete job cruisekube-controller-bootstrap-secrets \
  -n "${CK_NAMESPACE}" --ignore-not-found 2>/dev/null && \
  success "Orphaned bootstrap Job deleted." || true

info "Uninstalling Helm release: ${PROM_RELEASE} (namespace: ${PROM_NAMESPACE})"
helm uninstall "${PROM_RELEASE}" -n "${PROM_NAMESPACE}" 2>/dev/null && \
  success "Prometheus Helm release removed." || \
  warn "Prometheus release not found (skipping)."

info "Deleting namespace: ${CK_NAMESPACE}"
oc delete namespace "${CK_NAMESPACE}" --ignore-not-found --wait=true 2>/dev/null && \
  success "Namespace ${CK_NAMESPACE} deleted." || \
  warn "Namespace ${CK_NAMESPACE} not found (skipping)."

info "Deleting namespace: ${PROM_NAMESPACE}"
oc delete namespace "${PROM_NAMESPACE}" --ignore-not-found --wait=true 2>/dev/null && \
  success "Namespace ${PROM_NAMESPACE} deleted." || \
  warn "Namespace ${PROM_NAMESPACE} not found (skipping)."

success "Teardown complete — clean slate ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — WRITE PROMETHEUS VALUES FILE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 2 — Writing Prometheus values file"

cat > "${PROM_VALUES_FILE}" << 'EOF'
serverFiles:
  prometheus.yml:
    scrape_configs:
      # ── Scrape OpenShift's built-in kube-state-metrics (HTTPS + bearer token) ──
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
          - source_labels: [__meta_kubernetes_service_name]
            regex: kube-state-metrics
            action: keep
          - source_labels: [__meta_kubernetes_endpoint_port_name]
            regex: https-main
            action: keep

      # ── Scrape OpenShift's built-in node-exporter (HTTPS + bearer token) ──
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

      # ── Scrape kubelet metrics directly ──
      - job_name: kubelet
        scheme: https
        kubernetes_sd_configs:
          - role: node
        tls_config:
          insecure_skip_verify: true
        bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token

# Disable all bundled sub-charts — we reuse OpenShift's built-in exporters
prometheus-node-exporter:
  enabled: false

kube-state-metrics:
  enabled: false

prometheus-pushgateway:
  enabled: false

alertmanager:
  enabled: false

# Override hardcoded UIDs so OpenShift's restricted-v2 SCC accepts the pod
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
EOF

success "Prometheus values file written to ${PROM_VALUES_FILE}"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — INSTALL STANDALONE PROMETHEUS
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 3 — Installing Standalone Prometheus"

info "Adding prometheus-community Helm repo..."
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
success "Helm repo updated."

info "Installing Prometheus into namespace: ${PROM_NAMESPACE}"
helm install "${PROM_RELEASE}" prometheus-community/prometheus \
  --namespace "${PROM_NAMESPACE}" \
  --create-namespace \
  -f "${PROM_VALUES_FILE}"
success "Prometheus Helm install triggered."

info "Waiting for Prometheus server pod to be ready (up to 3 min)..."
oc wait pod \
  -n "${PROM_NAMESPACE}" \
  -l "app.kubernetes.io/component=server" \
  --for=condition=Ready \
  --timeout=180s
success "Prometheus pod is Ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — RBAC: GRANT cluster-monitoring-view TO PROMETHEUS SA
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 4 — Granting cluster-monitoring-view RBAC"

# Confirm the real ServiceAccount name (chart names it after the release)
PROM_SA=$(oc get pod -n "${PROM_NAMESPACE}" \
  -l "app.kubernetes.io/component=server" \
  -o jsonpath='{.items[0].spec.serviceAccountName}')
info "Prometheus ServiceAccount: ${PROM_SA}"

oc adm policy add-cluster-role-to-user cluster-monitoring-view \
  -z "${PROM_SA}" \
  -n "${PROM_NAMESPACE}"
success "cluster-monitoring-view granted to ${PROM_SA}."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — EXPOSE PROMETHEUS VIA OPENSHIFT ROUTE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 5 — Exposing Prometheus Route"

# Delete existing route if somehow still present
oc delete route "${PROM_SVC}" -n "${PROM_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Expose WITHOUT --port (auto-detects named port 'http')
oc expose svc/"${PROM_SVC}" -n "${PROM_NAMESPACE}"
PROM_URL="http://$(oc get route "${PROM_SVC}" -n "${PROM_NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
success "Prometheus Route created: ${PROM_URL}"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6 — INSTALL CRUISEKUBE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 6 — Installing CruiseKube"

info "Creating namespace: ${CK_NAMESPACE}"
oc create namespace "${CK_NAMESPACE}"

info "Granting anyuid SCC to all service accounts in ${CK_NAMESPACE}..."
oc adm policy add-scc-to-group anyuid \
  "system:serviceaccounts:${CK_NAMESPACE}"
success "anyuid SCC granted."

# Internal cluster URL for Prometheus (used by the controller — not the Route)
PROM_INTERNAL_URL="http://${PROM_SVC}.${PROM_NAMESPACE}.svc:80"
info "Prometheus internal URL wired into CruiseKube: ${PROM_INTERNAL_URL}"

info "Installing CruiseKube via OCI Helm chart..."
helm install "${CK_RELEASE}" oci://tfy.jfrog.io/tfy-helm/cruisekube \
  --namespace "${CK_NAMESPACE}" \
  --set cruisekubeController.env.CRUISEKUBE_DEPENDENCIES_INCLUSTER_PROMETHEUSURL="${PROM_INTERNAL_URL}"
success "CruiseKube Helm install triggered."

info "Waiting for CruiseKube pods to be ready (up to 5 min)..."
# Wait for each key deployment
for label in \
  "app.kubernetes.io/name=controller" \
  "app.kubernetes.io/name=frontend" \
  "app.kubernetes.io/name=webhook"; do
  oc wait pod \
    -n "${CK_NAMESPACE}" \
    -l "${label}" \
    --for=condition=Ready \
    --timeout=300s 2>/dev/null || \
    warn "Timed out waiting for pod with label ${label} — check 'oc get pods -n ${CK_NAMESPACE}'"
done

# PostgreSQL StatefulSet
oc rollout status statefulset cruisekube-postgresql \
  -n "${CK_NAMESPACE}" \
  --timeout=300s || \
  warn "PostgreSQL may still be starting — check 'oc get pods -n ${CK_NAMESPACE}'"

success "CruiseKube pods are Ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7 — EXPOSE CRUISEKUBE FRONTEND VIA ROUTE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 7 — Exposing CruiseKube Frontend Route"

# Expose WITHOUT --port (auto-detects named port 'http')
oc expose svc/"${CK_FRONTEND_SVC}" -n "${CK_NAMESPACE}"
CK_URL="http://$(oc get route "${CK_FRONTEND_SVC}" -n "${CK_NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
success "CruiseKube Dashboard Route created: ${CK_URL}"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8 — RETRIEVE ADMIN CREDENTIALS
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 8 — Retrieving Admin Credentials"

info "Waiting for bootstrap-secrets Job to complete (generates credentials)..."
oc wait job \
  -n "${CK_NAMESPACE}" \
  -l "helm.sh/hook=pre-install" \
  --for=condition=Complete \
  --timeout=120s 2>/dev/null || \
  warn "Bootstrap job timeout — credentials may still be available in the Secret."

CK_USER=$(oc get secret "${CK_SECRET}" -n "${CK_NAMESPACE}" \
  -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d) || \
  CK_USER="<not yet available — run: oc get secret ${CK_SECRET} -n ${CK_NAMESPACE} -o jsonpath='{.data.admin-user}' | base64 -d>"

CK_PASS=$(oc get secret "${CK_SECRET}" -n "${CK_NAMESPACE}" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d) || \
  CK_PASS="<not yet available — run: oc get secret ${CK_SECRET} -n ${CK_NAMESPACE} -o jsonpath='{.data.admin-password}' | base64 -d>"

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        CruiseKube Setup Complete — Access Details        ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}── Prometheus ──────────────────────────────────────────────${NC}"
echo -e "  URL        : ${CYAN}${PROM_URL}${NC}"
echo -e "  Targets    : ${CYAN}${PROM_URL}/targets${NC}"
echo -e "  Auth       : ${YELLOW}No authentication (open access via Route)${NC}"
echo ""
echo -e "${BOLD}── CruiseKube Dashboard ────────────────────────────────────${NC}"
echo -e "  URL        : ${CYAN}${CK_URL}${NC}"
echo -e "  Username   : ${GREEN}${CK_USER}${NC}"
echo -e "  Password   : ${GREEN}${CK_PASS}${NC}"
echo ""
echo -e "${BOLD}── Notes ───────────────────────────────────────────────────${NC}"
echo -e "  ${YELLOW}*${NC} CruiseKube waits 1 hour of metrics history before showing"
echo -e "    workload recommendations (by design). Dashboard will show"
echo -e "    0/0 workloads initially — this is normal."
echo -e "  ${YELLOW}*${NC} Leave workloads in ${BOLD}Recommend${NC} mode for several days"
echo -e "    before enabling ${BOLD}Cruise${NC} (auto-apply) mode."
echo -e "  ${YELLOW}*${NC} The anyuid SCC grant on ${CK_NAMESPACE} is dev/sandbox only."
echo -e "    Review with your security team before production use."
echo ""
echo -e "${BOLD}── Quick Credential Retrieval (anytime) ────────────────────${NC}"
echo -e "  oc get secret ${CK_SECRET} -n ${CK_NAMESPACE} \\"
echo -e "    -o jsonpath='{.data.admin-user}' | base64 -d && echo"
echo -e "  oc get secret ${CK_SECRET} -n ${CK_NAMESPACE} \\"
echo -e "    -o jsonpath='{.data.admin-password}' | base64 -d && echo"
echo ""
echo -e "${BOLD}── Verification Commands ───────────────────────────────────${NC}"
echo -e "  oc get pods -n ${PROM_NAMESPACE}"
echo -e "  oc get pods -n ${CK_NAMESPACE}"
echo -e "  curl -s '${PROM_URL}/api/v1/targets' | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'"
echo ""
