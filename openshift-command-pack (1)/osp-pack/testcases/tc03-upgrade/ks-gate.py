#!/usr/bin/env python3
"""
TC-03 AIOps gate: Kolmogorov-Smirnov test on canary latency distributions.
Compares 2h post-upgrade vs pre-upgrade baseline. Decides the fleet rollout:

  distributions match      -> git commit: worker MCP paused: false  (PROCEED)
  p < 0.01 AND worse median -> git commit: halt annotation           (HALT)
                               + Slack notification

ArgoCD syncs the MCP paused field from Git, so the decision is executed
hands-off through GitOps. Run once, ~2h after canary nodes finish upgrading:

  python3 ks-gate.py --baseline-end "2026-08-10T20:00:00Z"

Requires: scipy (pip install scipy), git configured with push access to the
GitOps repo, SLACK_WEBHOOK env var.
PROVE BOTH BRANCHES: one clean run, one with a 50ms latency sidecar injected
on canary pods to force the halt path. Never demo only the happy path.
"""
import argparse, json, os, ssl, subprocess, sys, time, urllib.parse, urllib.request

try:
    from scipy import stats
except ImportError:
    sys.exit("pip install scipy --user  # required for ks_2samp")

THANOS = os.environ.get("THANOS_URL",
    "https://thanos-querier.openshift-monitoring.svc:9091")
TOKEN = os.environ.get("PROM_TOKEN") or open(
    "/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
# Per-request latency samples: adjust metric to your app's histogram
QUERY = ('histogram_quantile(0.5, sum(rate('
         'http_request_duration_seconds_bucket{app="canary-synth"}[1m])) by (le))')
GITOPS_REPO = os.environ.get("GITOPS_REPO", "/repo")   # cloned working copy
MCP_FILE = "clusters/prod/machineconfigpool-worker.yaml"
P_THRESHOLD = 0.01
WINDOW_H = 2

def prom_range(query, start, end):
    qs = urllib.parse.urlencode({"query": query, "start": start,
                                 "end": end, "step": "60"})
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE   # in-cluster: use service-ca instead
    req = urllib.request.Request(f"{THANOS}/api/v1/query_range?{qs}",
        headers={"Authorization": f"Bearer {TOKEN}"})
    data = json.load(urllib.request.urlopen(req, context=ctx))
    vals = []
    for s in data["data"]["result"]:
        vals += [float(v[1]) for v in s["values"] if v[1] not in ("NaN", "")]
    return vals

def git_decide(proceed, evidence):
    os.chdir(GITOPS_REPO)
    if proceed:
        subprocess.run(["sed", "-i", "s/paused: true/paused: false/", MCP_FILE],
                       check=True)
        msg = f"tc03: canary gate PASS (KS p={evidence['p']:.4f}) - unpause worker MCP"
    else:
        subprocess.run(["bash", "-c",
            f"grep -q 'tc03.halt' {MCP_FILE} || "
            f"sed -i '/annotations:/a\\    tc03.halt: \"KS p={evidence['p']:.2e} "
            f"median {evidence['base_med']:.3f}->{evidence['can_med']:.3f}\"' {MCP_FILE}"],
            check=True)
        msg = f"tc03: canary gate HALT (KS p={evidence['p']:.2e}, median regressed)"
    subprocess.run(["git", "add", MCP_FILE], check=True)
    subprocess.run(["git", "commit", "-m", msg], check=True)
    subprocess.run(["git", "push"], check=True)
    return msg

def slack(text):
    hook = os.environ.get("SLACK_WEBHOOK")
    if not hook:
        return
    req = urllib.request.Request(hook, data=json.dumps({"text": text}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-end", required=True,
        help="ISO ts when the upgrade started (end of clean baseline)")
    a = ap.parse_args()
    base_end = int(time.mktime(time.strptime(a.baseline_end, "%Y-%m-%dT%H:%M:%SZ")))
    now = int(time.time())

    baseline = prom_range(QUERY, str(base_end - WINDOW_H * 3600), str(base_end))
    canary   = prom_range(QUERY, str(now - WINDOW_H * 3600), str(now))
    if len(baseline) < 30 or len(canary) < 30:
        sys.exit(f"insufficient samples: baseline={len(baseline)} canary={len(canary)}")

    ks = stats.ks_2samp(baseline, canary)
    import statistics
    ev = {"p": ks.pvalue, "stat": ks.statistic,
          "base_med": statistics.median(baseline),
          "can_med": statistics.median(canary),
          "n_base": len(baseline), "n_canary": len(canary)}
    regressed = ks.pvalue < P_THRESHOLD and ev["can_med"] > ev["base_med"]

    print(json.dumps({"decision": "HALT" if regressed else "PROCEED", **ev},
                     default=float, indent=2))
    msg = git_decide(proceed=not regressed, evidence=ev)
    slack(msg)

if __name__ == "__main__":
    main()
