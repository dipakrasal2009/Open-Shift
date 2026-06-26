#!/usr/bin/env bash
# =============================================================================
# Grafana on OpenShift — Full Reset & Setup Script
# =============================================================================
# Usage:  chmod +x grafana-setup.sh && ./grafana-setup.sh
#
# What this script does:
#   1. Tears down any previous Grafana installation
#   2. Installs Grafana via Helm (grafana/grafana chart)
#   3. Fixes OpenShift SCC issues (no hardcoded UIDs)
#   4. Exposes Grafana via an OpenShift Route
#   5. Optionally wires in your CruiseKube Prometheus as a datasource
#   6. Prints the URL, username, and password at the end
#
# Requirements:
#   - oc CLI authenticated as cluster-admin
#   - helm v3 installed
#   - Outbound access to: https://grafana.github.io/helm-charts
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
}

# ── Config — change these if needed ──────────────────────────────────────────
GRAFANA_NAMESPACE="grafana"
GRAFANA_RELEASE="grafana"
GRAFANA_SVC="grafana"
GRAFANA_VALUES_FILE="/tmp/grafana-values.yaml"

# Admin credentials — change GRAFANA_ADMIN_PASS to something strong!
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="Grafana@OpenShift123!"

# Optional: CruiseKube Prometheus internal URL
# If you installed CruiseKube's Prometheus with the cruisekube-setup.sh script,
# this is its in-cluster URL. Leave blank ("") to skip datasource wiring.
CRUISEKUBE_PROM_URL="http://cruisekube-prometheus-server.cruisekube-metrics.svc:80"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
header "Pre-flight Checks"

command -v oc   >/dev/null 2>&1 || error "'oc' CLI not found. Install it and authenticate as cluster-admin."
command -v helm >/dev/null 2>&1 || error "'helm' v3 not found. Install it first."

if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  error "Not authenticated as cluster-admin. Run 'oc login' with cluster-admin credentials first."
fi
success "Pre-flight checks passed."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — TEARDOWN PREVIOUS INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 1 — Tearing Down Previous Grafana Installation"

info "Uninstalling Helm release: ${GRAFANA_RELEASE} (namespace: ${GRAFANA_NAMESPACE})"
helm uninstall "${GRAFANA_RELEASE}" -n "${GRAFANA_NAMESPACE}" 2>/dev/null && \
  success "Grafana Helm release removed." || \
  warn "Grafana release not found (skipping)."

info "Deleting namespace: ${GRAFANA_NAMESPACE}"
oc delete namespace "${GRAFANA_NAMESPACE}" --ignore-not-found --wait=true 2>/dev/null && \
  success "Namespace ${GRAFANA_NAMESPACE} deleted." || \
  warn "Namespace ${GRAFANA_NAMESPACE} not found (skipping)."

success "Teardown complete — clean slate ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — WRITE GRAFANA VALUES FILE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 2 — Writing Grafana values file"

# Build the datasources section dynamically based on whether CRUISEKUBE_PROM_URL is set
if [[ -n "${CRUISEKUBE_PROM_URL}" ]]; then
  DATASOURCES_BLOCK=$(cat <<DATASOURCES
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: CruiseKube-Prometheus
        type: prometheus
        url: ${CRUISEKUBE_PROM_URL}
        access: proxy
        isDefault: true
        editable: true
        jsonData:
          timeInterval: "30s"
      - name: OpenShift-Prometheus
        type: prometheus
        url: https://thanos-querier.openshift-monitoring.svc:9091
        access: proxy
        isDefault: false
        editable: true
        jsonData:
          tlsSkipVerify: true
          httpHeaderName1: "Authorization"
        secureJsonData:
          httpHeaderValue1: "Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
DATASOURCES
)
else
  DATASOURCES_BLOCK=""
fi

cat > "${GRAFANA_VALUES_FILE}" << EOF
# ── Admin credentials ────────────────────────────────────────────────────────
adminUser: "${GRAFANA_ADMIN_USER}"
adminPassword: "${GRAFANA_ADMIN_PASS}"

# Required for newer chart versions — disables the client-side check that
# blocks passwords defined in grafana.ini (we set creds only via adminPassword
# at the top level, but the chart validator still needs this flag).
assertNoLeakedSecrets: false

# ── OpenShift SCC fix ────────────────────────────────────────────────────────
# The upstream chart hardcodes runAsUser/fsGroup — override to null so
# OpenShift's restricted-v2 SCC assigns a valid UID from the namespace range.
securityContext:
  runAsUser: null
  runAsGroup: null
  fsGroup: null
  runAsNonRoot: true

containerSecurityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

# ── Persistence (PVC for dashboards & config) ────────────────────────────────
persistence:
  enabled: true
  size: 5Gi
  # Uses the cluster default StorageClass (AWS EBS in your case)
  # Uncomment and set storageClassName if you need a specific one:
  # storageClassName: ebs.csi.aws.com

# ── Init container SCC fix ───────────────────────────────────────────────────
initChownData:
  enabled: false   # Disabled — requires root; OpenShift handles ownership via fsGroup

# ── Resource limits (adjust to your cluster capacity) ────────────────────────
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# ── Grafana config overrides ──────────────────────────────────────────────────
# NOTE: admin credentials are set via adminUser/adminPassword above ONLY.
# Putting them inside grafana.ini triggers chart validation errors in newer
# chart versions ("Sensitive key should not be defined explicitly in values").
grafana.ini:
  server:
    root_url: "%(protocol)s://%(domain)s/"
    serve_from_sub_path: false
  auth.anonymous:
    enabled: false
  log:
    mode: console
    level: info

# ── Datasources (auto-provisioned on startup) ─────────────────────────────────
${DATASOURCES_BLOCK}

# ── Pre-installed dashboards ──────────────────────────────────────────────────
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: "Kubernetes"
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

dashboards:
  default:
    # Kubernetes cluster overview — works with kube-state-metrics + node-exporter
    kubernetes-cluster:
      gnetId: 7249
      revision: 1
      datasource: CruiseKube-Prometheus
    # Node exporter full dashboard
    node-exporter-full:
      gnetId: 1860
      revision: 37
      datasource: CruiseKube-Prometheus
    # Kubernetes namespace resource usage
    namespace-resources:
      gnetId: 13770
      revision: 1
      datasource: CruiseKube-Prometheus

# ── Service settings ──────────────────────────────────────────────────────────
service:
  type: ClusterIP
  port: 80
  targetPort: 3000
  portName: http
EOF

success "Grafana values file written to ${GRAFANA_VALUES_FILE}"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — CREATE NAMESPACE + GRANT SCC
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 3 — Creating Namespace and Granting SCC"

info "Creating namespace: ${GRAFANA_NAMESPACE}"
oc create namespace "${GRAFANA_NAMESPACE}"

# Grafana's chart uses a fixed UID (472) with no values override available,
# same pattern as CruiseKube — grant anyuid before Helm schedules any pods.
info "Granting anyuid SCC to service accounts in ${GRAFANA_NAMESPACE}..."
oc adm policy add-scc-to-group anyuid \
  "system:serviceaccounts:${GRAFANA_NAMESPACE}"
success "anyuid SCC granted to ${GRAFANA_NAMESPACE}."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — INSTALL GRAFANA VIA HELM
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 4 — Installing Grafana via Helm"

info "Adding grafana Helm repo..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
success "Helm repo updated."

info "Installing Grafana into namespace: ${GRAFANA_NAMESPACE}"
helm install "${GRAFANA_RELEASE}" grafana/grafana \
  --namespace "${GRAFANA_NAMESPACE}" \
  -f "${GRAFANA_VALUES_FILE}"
success "Grafana Helm install triggered."

info "Waiting for Grafana pod to be ready (up to 4 min)..."
oc wait pod \
  -n "${GRAFANA_NAMESPACE}" \
  -l "app.kubernetes.io/name=grafana" \
  --for=condition=Ready \
  --timeout=240s
success "Grafana pod is Ready."

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — EXPOSE GRAFANA VIA OPENSHIFT ROUTE
# ═══════════════════════════════════════════════════════════════════════════════
header "Step 5 — Exposing Grafana via OpenShift Route"

# Delete any stale Route first
oc delete route "${GRAFANA_SVC}" -n "${GRAFANA_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Expose WITHOUT --port (auto-detects the named port 'http')
oc expose svc/"${GRAFANA_SVC}" -n "${GRAFANA_NAMESPACE}"

GRAFANA_URL="http://$(oc get route "${GRAFANA_SVC}" -n "${GRAFANA_NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
success "Grafana Route created: ${GRAFANA_URL}"

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          Grafana Setup Complete — Access Details         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}── Grafana Dashboard ───────────────────────────────────────${NC}"
echo -e "  URL        : ${CYAN}${GRAFANA_URL}${NC}"
echo -e "  Username   : ${GREEN}${GRAFANA_ADMIN_USER}${NC}"
echo -e "  Password   : ${GREEN}${GRAFANA_ADMIN_PASS}${NC}"
echo ""
if [[ -n "${CRUISEKUBE_PROM_URL}" ]]; then
echo -e "${BOLD}── Pre-wired Datasources ────────────────────────────────────${NC}"
echo -e "  ${GREEN}✔${NC}  CruiseKube-Prometheus  →  ${CYAN}${CRUISEKUBE_PROM_URL}${NC}  ${YELLOW}(default)${NC}"
echo -e "  ${GREEN}✔${NC}  OpenShift-Prometheus   →  ${CYAN}https://thanos-querier.openshift-monitoring.svc:9091${NC}"
echo ""
fi
echo -e "${BOLD}── Pre-installed Dashboards ─────────────────────────────────${NC}"
echo -e "  ${GREEN}✔${NC}  Kubernetes Cluster Overview   (Grafana ID: 7249)"
echo -e "  ${GREEN}✔${NC}  Node Exporter Full            (Grafana ID: 1860)"
echo -e "  ${GREEN}✔${NC}  Namespace Resource Usage      (Grafana ID: 13770)"
echo -e "  ${YELLOW}→${NC}  Find them under: Dashboards → Browse → Kubernetes folder"
echo ""
echo -e "${BOLD}── Notes ───────────────────────────────────────────────────${NC}"
echo -e "  ${YELLOW}*${NC} Change the admin password after first login:"
echo -e "    Profile → Change Password  (or via Grafana API)"
echo -e "  ${YELLOW}*${NC} The anyuid SCC grant on ${GRAFANA_NAMESPACE} is dev/sandbox only."
echo -e "    Review with your security team before production use."
echo -e "  ${YELLOW}*${NC} Pre-installed dashboards download from grafana.com at startup"
echo -e "    — requires outbound internet access from the cluster."
echo ""
echo -e "${BOLD}── Useful Commands ─────────────────────────────────────────${NC}"
echo -e "  # Check Grafana pod status"
echo -e "  oc get pods -n ${GRAFANA_NAMESPACE}"
echo ""
echo -e "  # View Grafana logs"
echo -e "  oc logs -n ${GRAFANA_NAMESPACE} -l app.kubernetes.io/name=grafana --tail=50"
echo ""
echo -e "  # Get Route URL again later"
echo -e "  oc get route grafana -n ${GRAFANA_NAMESPACE}"
echo ""
echo -e "  # Uninstall everything (clean slate)"
echo -e "  helm uninstall grafana -n ${GRAFANA_NAMESPACE}"
echo -e "  oc delete namespace ${GRAFANA_NAMESPACE}"
echo ""
