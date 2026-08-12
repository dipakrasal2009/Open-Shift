#!/bin/bash
# ============================================================
# STEP 3 - Wire the consumer-lag anomaly detector to Thanos
# Runs the detector as a pod IN the cluster (uses service CA,
# no scipy/pip needed on the bastion).
# ============================================================
set -x

# 1. Enable user-workload monitoring so YOUR namespace metrics are scraped
cat << 'YAML' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
YAML

# 2. Tell Prometheus to scrape the Kafka JMX metrics (PodMonitor)
cat << 'YAML' | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: kafka-metrics
  namespace: kafka
  labels: { app: strimzi }
spec:
  selector:
    matchLabels:
      strimzi.io/kind: Kafka
  podMetricsEndpoints:
  - path: /metrics
    port: tcp-prometheus
YAML

# 3. ServiceAccount for the detector + read access to monitoring
oc create sa lag-detector -n kafka 2>/dev/null
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z lag-detector -n kafka

# 4. Load the detector script as a ConfigMap
#    (lag-detector.py is single-broker-adapted: no maintenance suppression,
#     just pure EWMA/3-sigma on demo-group lag)
oc create configmap lag-detector-src -n kafka \
  --from-file=lag-detector.py --dry-run=client -o yaml | oc apply -f -

# 5. Run it once as a Job to see output
cat << 'YAML' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: lag-detector-run
  namespace: kafka
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: lag-detector
      restartPolicy: Never
      containers:
      - name: detector
        image: registry.access.redhat.com/ubi9/python-311
        command: ["python3","/src/lag-detector.py"]
        env:
        - name: THANOS_URL
          value: "https://thanos-querier.openshift-monitoring.svc:9091"
        volumeMounts: [{ name: src, mountPath: /src }]
      volumes:
      - name: src
        configMap: { name: lag-detector-src }
YAML

oc wait --for=condition=complete job/lag-detector-run -n kafka --timeout=120s
oc logs job/lag-detector-run -n kafka   # JSON: anomalies + z-scores

# To run continuously, convert to a CronJob (schedule: "* * * * *").
