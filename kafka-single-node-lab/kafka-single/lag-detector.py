#!/usr/bin/env python3
"""
Single-broker lag anomaly detector (EWMA + 3-sigma).
Queries user-workload Thanos for kafka_consumergroup_lag on demo-group.
No maintenance-suppression here (that needs multi-node); this is the pure
detection half, adapted for the single-worker dev cluster.

Runs in-cluster: uses the service CA and the pod's ServiceAccount token.
"""
import json, os, ssl, sys, time, urllib.parse, urllib.request, statistics

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SVC_CA = "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
CA = SVC_CA if os.path.exists(SVC_CA) else \
     "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
QUERY = 'sum(kafka_consumergroup_lag{consumergroup="demo-group"})'
SIGMA_K = 3.0

def prom_range(query, mins):
    tok = open(TOKEN_FILE).read().strip()
    now = int(time.time())
    qs = urllib.parse.urlencode({"query": query,
        "start": str(now - mins * 60), "end": str(now), "step": "30"})
    ctx = ssl.create_default_context(cafile=CA)
    req = urllib.request.Request(f"{THANOS}/api/v1/query_range?{qs}",
        headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req, context=ctx))

def main():
    data = prom_range(QUERY, 30)
    result = data["data"]["result"]
    if not result:
        print(json.dumps({"ts": int(time.time()), "status": "no_lag_data",
              "hint": "produce/consume first; wait for scrape (~1-2 min)"}))
        return
    vals = [float(v[1]) for v in result[0]["values"]]
    if len(vals) < 20:
        print(json.dumps({"ts": int(time.time()), "status": "warming_up",
              "samples": len(vals)}))
        return

    baseline, current = vals[:-6], vals[-1]      # last 3 min = current
    mu = statistics.mean(baseline)
    sd = statistics.pstdev(baseline) or 1.0
    z = (current - mu) / sd

    out = {"ts": int(time.time()), "check": "kafka_lag_ewma_3sigma",
           "current_lag": current, "baseline_mean": round(mu, 1),
           "z_score": round(z, 2),
           "anomaly": z > SIGMA_K}
    print(json.dumps(out))
    sys.exit(1 if z > SIGMA_K else 0)   # exit 1 = would page

if __name__ == "__main__":
    main()
