#!/usr/bin/env python3
"""
Single-broker lab lag detector: EWMA + 3-sigma anomaly check on consumer lag,
queried from Thanos. Simplified from the production tc02 detector - no
maintenance-window suppression logic, since there's no second broker/node to
correlate a drain against on this cluster.

sa needs: cluster-monitoring-view
Run as a one-off Job, or loop it: while true; do python3 lag-detector.py; sleep 60; done
"""
import json, os, ssl, statistics, sys, time, urllib.parse, urllib.request

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA = "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
LAG_QUERY = 'sum(kafka_consumergroup_lag) by (consumergroup)'
SIGMA_K = 3.0
LOOKBACK_MIN = 30

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
    rng = prom_range(LAG_QUERY, LOOKBACK_MIN)
    results = rng.get("data", {}).get("result", [])
    if not results:
        print(json.dumps({"ts": int(time.time()), "status": "no_lag_data",
            "note": "metrics not scraped yet, or no consumer group active"}))
        return

    findings = []
    for series in results:
        group = series["metric"].get("consumergroup", "?")
        vals = [float(v[1]) for v in series["values"]]
        if len(vals) < 10:
            continue
        base, cur = vals[:-3], vals[-1]
        mu, sd = statistics.mean(base), statistics.pstdev(base) or 1.0
        z = (cur - mu) / sd
        entry = {"group": group, "lag": cur, "baseline_mean": round(mu, 1), "z": round(z, 2)}
        if z > SIGMA_K:
            entry["anomaly"] = True
        findings.append(entry)

    out = {"ts": int(time.time()), "check": "kafka_lag_anomaly_single_broker",
           "findings": findings}
    print(json.dumps(out, indent=2))
    if any(f.get("anomaly") for f in findings):
        sys.exit(1)   # page
    sys.exit(0)

if __name__ == "__main__":
    main()
