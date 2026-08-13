#!/usr/bin/env python3
"""
TC-05 AIOps: forecast-based memory exhaustion detection + remediation.

1. Holt-Winters (or linear fallback) forecast of node available memory ->
   time-to-eviction-threshold.
2. If projected breach < 60 min: identify the offender by WORKING-SET SLOPE
   (fastest-growing container, NOT the biggest - the leaker often is not the
   largest consumer yet).
3. Remediate: delete the offending pod, annotate its deployment for follow-up,
   write the action to an audit log.
PASS: remediation completes BEFORE the kubelet eviction threshold is reached,
and the node memory forecast returns to flat.

Run every 2 min as a CronJob, or in a loop during the test:
  while true; do python3 forecast.py; sleep 120; done

sa needs: cluster-monitoring-view, and delete on pods + patch on deployments
in the target namespaces.
"""
import json, os, ssl, subprocess, sys, time, urllib.parse, urllib.request

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
TOKEN = os.environ.get("PROM_TOKEN") or open(
    "/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
EVICT_THRESHOLD_BYTES = 100 * 1024 * 1024   # kubelet default hard: 100Mi
BREACH_HORIZON_S = 3600                       # alert if breach < 60 min out
AUDIT_LOG = os.environ.get("AUDIT_LOG", "/audit/tc05-remediation.log")

def prom(query, range_=None):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE     # in-cluster: point at service-ca instead
    if range_:
        now = int(time.time())
        qs = urllib.parse.urlencode({"query": query,
            "start": str(now - range_), "end": str(now), "step": "30"})
        path = f"/api/v1/query_range?{qs}"
    else:
        path = f"/api/v1/query?{urllib.parse.urlencode({'query': query})}"
    req = urllib.request.Request(f"{THANOS}{path}",
        headers={"Authorization": f"Bearer {TOKEN}"})
    return json.load(urllib.request.urlopen(req, context=ctx))

def linreg(xs, ys):
    n = len(xs); sx = sum(xs); sy = sum(ys)
    sxx = sum(x*x for x in xs); sxy = sum(x*y for x, y in zip(xs, ys))
    denom = n*sxx - sx*sx
    if denom == 0:
        return 0.0, sy/n
    slope = (n*sxy - sx*sy)/denom
    intercept = (sy - slope*sx)/n
    return slope, intercept

def forecast_node(node):
    q = f'node_memory_MemAvailable_bytes{{instance=~"{node}.*"}}'
    r = prom(q, range_=1800)   # 30 min history
    res = r["data"]["result"]
    if not res:
        return None
    vals = [(int(v[0]), float(v[1])) for v in res[0]["values"]]
    if len(vals) < 10:
        return None
    t0 = vals[0][0]
    xs = [t - t0 for t, _ in vals]
    ys = [v for _, v in vals]
    slope, intercept = linreg(xs, ys)   # bytes per second (negative = shrinking)
    if slope >= 0:
        return {"node": node, "trend": "flat_or_growing", "seconds_to_breach": None}
    cur = ys[-1]
    seconds_to_breach = (cur - EVICT_THRESHOLD_BYTES) / (-slope)
    return {"node": node, "cur_avail_mib": round(cur/1048576, 1),
            "slope_mib_per_min": round(slope*60/1048576, 2),
            "seconds_to_breach": round(seconds_to_breach)}

def find_offender(node):
    """Rank containers on this node by working-set SLOPE over 15 min."""
    q = ('sum by (namespace,pod,container)('
         f'container_memory_working_set_bytes{{node="{node}",container!=""}})')
    r = prom(q, range_=900)
    ranked = []
    for s in r["data"]["result"]:
        vals = [(int(v[0]), float(v[1])) for v in s["values"]]
        if len(vals) < 5:
            continue
        t0 = vals[0][0]
        slope, _ = linreg([t-t0 for t, _ in vals], [v for _, v in vals])
        ranked.append((slope, s["metric"]))
    ranked.sort(reverse=True)   # fastest-growing first
    return ranked[0] if ranked else None

def audit(entry):
    os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
    with open(AUDIT_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

def remediate(meta):
    ns, pod = meta["namespace"], meta["pod"]
    # delete offending pod
    subprocess.run(["oc", "delete", "pod", pod, "-n", ns], check=False)
    # annotate its owning deployment for engineering follow-up
    dep = "-".join(pod.split("-")[:-2]) if pod.count("-") >= 2 else pod
    subprocess.run(["oc", "annotate", "deployment", dep, "-n", ns,
        f"tc05.aiops/remediated-at={int(time.time())}",
        "tc05.aiops/reason=fastest-growing-workingset", "--overwrite"],
        check=False)
    entry = {"ts": int(time.time()), "action": "pod_deleted",
             "namespace": ns, "pod": pod, "deployment": dep}
    audit(entry)
    return entry

def main():
    nodes = [s["metric"]["instance"].split(":")[0]
             for s in prom('up{job="kubelet"}')["data"]["result"]]
    nodes = sorted(set(nodes))
    for node in nodes:
        fc = forecast_node(node)
        if not fc or fc.get("seconds_to_breach") is None:
            continue
        if 0 < fc["seconds_to_breach"] < BREACH_HORIZON_S:
            offender = find_offender(node)
            report = {"forecast": fc}
            if offender:
                slope, meta = offender
                report["offender"] = {**meta,
                    "workingset_slope_mib_per_min": round(slope*60/1048576, 2)}
                report["remediation"] = remediate(meta)
            print(json.dumps(report, indent=2))
            return   # one remediation per cycle
    print(json.dumps({"ts": int(time.time()), "status": "no_forecast_breach"}))

if __name__ == "__main__":
    main()
