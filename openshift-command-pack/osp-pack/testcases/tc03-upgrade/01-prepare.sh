#!/bin/bash
# TC-03 preparation - run at least 7 days BEFORE the upgrade window
# so Prometheus holds a real latency baseline.
set -x

# 1. Pick 2 canary workers and label them
oc label node worker-5 node-role.kubernetes.io/canary=""
oc label node worker-6 node-role.kubernetes.io/canary=""

# 2. Create the canary MCP; PAUSE the main worker pool
oc apply -f canary-mcp.yaml
oc patch mcp worker --type merge -p "{\"spec\":{\"paused\":true}}"
oc get mcp   # canary: 2 machines; worker: paused

# 3. Pin a representative synthetic workload to canary nodes
cat << YAML | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: canary-synth, namespace: prod-sim }
spec:
  replicas: 4
  selector: { matchLabels: { app: canary-synth } }
  template:
    metadata: { labels: { app: canary-synth } }
    spec:
      nodeSelector: { node-role.kubernetes.io/canary: "" }
      tolerations: [{ operator: Exists }]
      containers:
      - name: web
        image: quay.io/openshifttest/hello-openshift:1.2.0
        ports: [{ containerPort: 8080 }]
YAML
# Plus a steady load generator against it (any hey/vegeta job) so
# http_request_duration histograms accumulate the 7-day baseline.
