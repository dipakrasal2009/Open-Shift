#!/usr/bin/env python3
"""
TC-02 AIOps: consumer-lag anomaly detection WITH maintenance-event suppression.
Detects the lag spike (EWMA z-score), then checks the Kubernetes events API for
a recent cordon/drain on the broker's node. If correlated -> classify as
"explained_by_maintenance" and SUPPRESS the page.
PASS: anomaly detected but no page emitted during the drain window.
Run as CronJob (same pattern as tc01/anomaly-cronjob.yaml, sa needs
cluster-monitoring-view + view on the kafka namespace + nodes/events read).
"""
import json, os, ssl, sys, time, urllib.parse, urllib.request, statistics

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
K8S = "https://kubernetes.default.svc"
TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA = "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
K8S_CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
LAG_QUERY = 'sum(kafka_consumergroup_lag) by (consumergroup)'
SIGMA_K = 3.0
MAINT_WINDOW_S = 900   # correlate drains within the last 15 min

def get(url, ca):
    tok = open(TOKEN_FILE).read().strip()
    ctx = ssl.create_default_context(cafile=ca)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req, context=ctx))

def prom_range(query, mins):
    now = int(time.time())
    qs = urllib.parse.urlencode({"query": query,
        "start": str(now - mins * 60), "end": str(now), "step": "30"})
    return get(f"{THANOS}/api/v1/query_range?{qs}", CA)

def maintenance_active():
    """True if any node was cordoned/drained recently (NodeNotSchedulable or
    unschedulable spec), or drain-related events exist in the window."""
    nodes = get(f"{K8S}/api/v1/nodes", K8S_CA)
    for n in nodes["items"]:
        if n["spec"].get("unschedulable"):
            return True, n["metadata"]["name"]
    cutoff = time.time() - MAINT_WINDOW_S
    evs = get(f"{K8S}/api/v1/events?fieldSelector="
              + urllib.parse.quote("reason=NodeNotSchedulable"), K8S_CA)
    for e in evs.get("items", []):
        ts = e.get("lastTimestamp") or e.get("eventTime") or ""
        if ts:
            t = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            if t >= cutoff:
                return True, e.get("involvedObject", {}).get("name", "?")
    return False, None

def main():
    rng = prom_range(LAG_QUERY, 60)
    findings = []
    for series in rng["data"]["result"]:
        group = series["metric"].get("consumergroup", "?")
        vals = [float(v[1]) for v in series["values"]]
        if len(vals) < 20:
            continue
        base, cur = vals[:-6], vals[-1]          # last 3 min = "current"
        mu, sd = statistics.mean(base), statistics.pstdev(base) or 1.0
        z = (cur - mu) / sd
        if z > SIGMA_K:
            findings.append({"group": group, "lag": cur,
                             "baseline_mean": round(mu, 1), "z": round(z, 2)})

    maint, node = maintenance_active()
    result = {"ts": int(time.time()), "check": "kafka_lag_anomaly",
              "anomalies": findings, "maintenance_detected": maint,
              "maintenance_node": node}
    if findings and maint:
        result["classification"] = "explained_by_maintenance"
        result["action"] = "SUPPRESSED - no page"
        print(json.dumps(result)); sys.exit(0)     # exit 0 = no page
    if findings:
        result["classification"] = "unexplained"
        result["action"] = "PAGE"
        print(json.dumps(result)); sys.exit(1)     # exit 1 = page
    print(json.dumps(result))

if __name__ == "__main__":
    main()
