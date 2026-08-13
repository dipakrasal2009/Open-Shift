# TC-01: etcd disk latency + predictive anomaly detection

Order of execution:
1. Deploy AIOps layer FIRST (needs ~60 min of baseline before injection):
   oc create ns aiops
   oc create sa etcd-anomaly -n aiops
   oc adm policy add-cluster-role-to-user cluster-monitoring-view -z etcd-anomaly -n aiops
   oc create configmap etcd-anomaly-src --from-file=anomaly-detector.py -n aiops
   oc apply -f anomaly-cronjob.yaml
2. bash 01-inject.sh        (change window)
3. bash 02-verify.sh        (during + after; paste output into test record)
4. Watch detector: oc get jobs -n aiops -w
   PASS = a failed job (= anomaly, exit 1) within 3 min of injection,
   before etcdHighFsyncDurations fires in Alertmanager.
   Evidence: oc logs job/<failed-job> -n aiops  -> JSON anomaly record.
5. bash 03-cleanup.sh
