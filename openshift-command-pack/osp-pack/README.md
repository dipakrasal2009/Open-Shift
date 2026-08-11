# OpenShift Production Readiness — Command Pack

Executable companion to the Lab Manual. Every lab and test case is a runnable
script with all supporting manifests and AIOps jobs pre-filled. Values you must
replace are UPPERCASE or clearly marked `# <- replace`.

## Golden rule
Run **block by block**, not end to end. Each script uses `set -x` so every
command echoes before it runs. Read the expected-output comments; they tell you
what "pass" looks like.

## The diagnostic sequence (memorize)
```
oc get events -n <ns> --sort-by='.lastTimestamp'   # what the platform said happened
oc describe pod <pod>                              # scheduling, probes, image, SCC
oc logs <pod> --previous                           # why the LAST container died
oc get co                                          # me, or the platform degraded?
oc adm top nodes && oc describe node <node>        # pressure, allocatable, taints
```
When pods are **missing** rather than failing, describe the controller
(Deployment / Job / CronJob) — the failure event lives there.

## Layout
```
labs/
  lab1-rolling-update.sh      rollout failures: bad image, readiness, crashloop
  lab2-batch-jobs.sh          "all jobs down": quota, concurrency, SCC
  lab3-bluegreen.sh           smoke-gated atomic route cutover + rollback
  lab4-canary/                Argo Rollouts + Prometheus analysis gate
    commands.sh, rollout.yaml, analysistemplate.yaml
  lab5-drills.sh              DNS / PVC / OOMKilled / Route-503 drills
testcases/
  tc01-etcd/                  etcd fsync latency + EWMA/3-sigma predictive alert
  tc02-kafka/                 broker drain under load + lag anomaly SUPPRESSION
  tc03-upgrade/               canary MCP upgrade + KS-test halt gate via GitOps
  tc04-ovn/                   OVN cp loss + zone partition + fault correlation
  tc05-memleak/               memory leak forecast + slope-based auto-remediation
INCIDENT-LOG-TEMPLATE.md      copy one per break; the completed log is an artifact
preflight.sh                  cluster readiness + tool checks before you start
```

## Order of execution
1. `bash preflight.sh`
2. Week 1 — labs 1→5 in a sandbox (`prod-sim` project).
3. Week 2 — test cases in risk order: **TC-05, TC-02, TC-04** (normal windows),
   then **TC-01, TC-03** (change windows; they touch control plane / upgrade).
4. Each test case: deploy AIOps job → inject → verify (paste output into the
   incident log) → cleanup. A case passes only when BOTH platform and AIOps
   criteria pass.

## AIOps reuse
The Python jobs in tc01/tc02/tc05 share one pattern: query Thanos, run a light
statistical model, emit JSON, exit non-zero to page (or zero to suppress). Build
the ServiceAccount + `cluster-monitoring-view` binding once and reuse it. The
canary analysis in lab4 is the same mechanism tc03 scales to cluster level.

## In-cluster TLS note
The standalone-run Python (`ks-gate.py`, `forecast.py`) disables TLS verify for
quick manual runs against the Thanos route. For the CronJob deployments, switch
to the in-cluster service CA at
`/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`
(as `anomaly-detector.py` already does). Do not ship verify-disabled to prod.
