#!/bin/bash
# ============================================================
# LAB 2 - "All Jobs Went Down" batch failure drill
# Run block by block.
# ============================================================
set -x
oc project prod-sim

### ---- 2A. DEPLOY ----
oc create cronjob report-gen --image=registry.access.redhat.com/ubi9/ubi-minimal \
  --schedule="*/2 * * * *" -- /bin/sh -c "echo processing && sleep 30 && echo done"

# Watch two successful cycles first
oc get jobs -w   # Ctrl+C after 2 completions

### ---- 2B. BREAK 1: quota kills all future jobs (silently) ----
oc create quota batch-quota --hard=pods=2
# Wait 2 schedule cycles (4+ min). No CrashLoop. No red pod. Jobs just... stop.

# DIAGNOSE - failure lives on the CONTROLLER, not a pod (no pod ever existed)
oc get jobs                       # 0/1 completions on new jobs
JOB=$(oc get jobs --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc describe $JOB | grep -A5 "Events:"
# Expected: Error creating: pods "report-gen-..." is forbidden: exceeded quota

# FIX + CLEANUP
oc delete quota batch-quota
oc delete jobs --all

### ---- 2C. BREAK 2: concurrencyPolicy pile-up ----
oc patch cronjob report-gen --type=json \
  -p '[{"op":"replace","path":"/spec/jobTemplate/spec/template/spec/containers/0/args","value":["-c","echo processing && sleep 300 && echo done"]}]'
# sleep 300 > 2-min schedule; default concurrencyPolicy: Allow -> jobs stack up
sleep 400
oc get jobs        # multiple active jobs stacked
oc get pods        # pod pile-up

# FIX - the three fields that make a CronJob production-grade:
oc patch cronjob report-gen -p \
  '{"spec":{"concurrencyPolicy":"Forbid","startingDeadlineSeconds":120,"failedJobsHistoryLimit":3}}'
# startingDeadlineSeconds is critical: >100 missed schedules with no deadline
# = controller PERMANENTLY stops scheduling this CronJob.
oc delete jobs --all

### ---- 2D. BREAK 3: SCC denial ----
oc patch cronjob report-gen --type=json \
  -p '[{"op":"add","path":"/spec/jobTemplate/spec/template/spec/securityContext","value":{"runAsUser":0}}]'
sleep 130
oc get jobs
JOB=$(oc get jobs --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc describe $JOB | grep -i -A3 "forbidden\|security"
# Expected: unable to validate against any security context constraint

# DIAGNOSE - which SCC would admit this workload?
oc get $JOB -o yaml > /tmp/jobspec.yaml
oc adm policy scc-subject-review -u system:serviceaccount:prod-sim:default -f /tmp/jobspec.yaml

# FIX (the right way - never blanket-grant anyuid):
oc patch cronjob report-gen --type=json \
  -p '[{"op":"remove","path":"/spec/jobTemplate/spec/template/spec/securityContext"}]'
oc delete jobs --all
