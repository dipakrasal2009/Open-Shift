#!/usr/bin/env python3
"""
TC-01 AIOps detector: EWMA + 3-sigma on per-member etcd fsync p99.
Runs as a CronJob every minute (manifest: anomaly-cronjob.yaml).
PASS: fires within 3 min of injection, BEFORE stock etcdHighFsyncDurations
(which needs a sustained 10-minute window).
"""
import json, os, sys, urllib.request, ssl, statistics

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
QUERY = ('histogram_quantile(0.99, '
         'rate(etcd_disk_wal_fsync_duration_seconds_bucket[2m]))')
LOOKBACK_MIN = 60          # baseline window
EWMA_ALPHA = 0.3
SIGMA_K = 3.0
STATE_FILE = "/state/ewma.json"  # emptyDir-backed; survives within the pod run

def prom(path, params):
    tok = open(TOKEN_FILE).read().strip()
    url = f"{THANOS}{path}?" + "&".join(
        f"{k}={urllib.parse.quote(v)}" for k, v in params.items())
    ctx = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req, context=ctx))

import urllib.parse, time

def main():
    now = int(time.time())
    # 1. Baseline: range query over lookback for mean/std per member
    rng = prom("/api/v1/query_range", {
        "query": QUERY,
        "start": str(now - LOOKBACK_MIN * 60),
        "end": str(now - 300),          # exclude last 5 min from baseline
        "step": "30",
    })
    baseline = {}
    for series in rng["data"]["result"]:
        member = series["metric"].get("pod", series["metric"].get("instance", "?"))
        vals = [float(v[1]) for v in series["values"] if v[1] != "NaN"]
        if len(vals) >= 10:
            baseline[member] = (statistics.mean(vals), statistics.pstdev(vals) or 1e-6)

    # 2. Current instant value per member
    cur = prom("/api/v1/query", {"query": QUERY})
    anomalies = []
    ewma_state = {}
    if os.path.exists(STATE_FILE):
        ewma_state = json.load(open(STATE_FILE))

    for series in cur["data"]["result"]:
        member = series["metric"].get("pod", series["metric"].get("instance", "?"))
        val = float(series["value"][1])
        prev = ewma_state.get(member, val)
        ewma = EWMA_ALPHA * val + (1 - EWMA_ALPHA) * prev
        ewma_state[member] = ewma
        if member in baseline:
            mu, sd = baseline[member]
            z = (ewma - mu) / sd
            if z > SIGMA_K:
                anomalies.append({
                    "member": member, "ewma_p99_s": round(ewma, 5),
                    "baseline_mean_s": round(mu, 5), "z_score": round(z, 2),
                })

    os.makedirs("/state", exist_ok=True)
    json.dump(ewma_state, open(STATE_FILE, "w"))

    out = {"ts": now, "check": "etcd_fsync_p99_ewma_3sigma", "anomalies": anomalies}
    print(json.dumps(out))
    if anomalies:
        # Exit 1 => CronJob failure => route to Alertmanager via
        # kube-state-metrics job failure alert, or POST to a webhook here.
        sys.exit(1)

if __name__ == "__main__":
    main()
