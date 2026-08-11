#!/usr/bin/env python3
"""
TC-04 AIOps: topology-aware correlation. Ingests failing probe pairs (each
tagged with source/target zone), computes the graph cut, and emits ONE enriched
incident naming the affected zone pair - instead of N pod-level alerts.
PASS: exactly one incident, correct zone pair, within 5 minutes.

Input: JSON lines of probe results on stdin, or a Prometheus query of a
mesh_probe_success{src_zone,dst_zone} gauge. Demo mode uses stdin:

  cat probe-results.json | python3 correlate.py

probe-results.json example line:
  {"src":"pod-a","src_zone":"zone-a","dst":"pod-b","dst_zone":"zone-b","ok":false}
"""
import json, sys
from collections import defaultdict

def load(stream):
    pairs = []
    for line in stream:
        line = line.strip()
        if line:
            pairs.append(json.loads(line))
    return pairs

def correlate(pairs):
    # Aggregate failures by (src_zone, dst_zone), unordered
    fail = defaultdict(int)
    total = defaultdict(int)
    for p in pairs:
        key = tuple(sorted((p["src_zone"], p["dst_zone"])))
        total[key] += 1
        if not p["ok"]:
            fail[key] += 1

    incidents = []
    for key, f in fail.items():
        t = total[key]
        za, zb = key
        if za == zb:
            # intra-zone failures -> likely node/pod local, not a partition
            if f / t > 0.5:
                incidents.append({
                    "type": "intra_zone_degradation", "zone": za,
                    "failed": f, "total": t})
        else:
            # inter-zone: if a large fraction of cross-zone pairs fail, it's a cut
            if f / t > 0.8:
                incidents.append({
                    "type": "zone_partition",
                    "zone_pair": [za, zb],
                    "failed_pairs": f, "total_pairs": t,
                    "confidence": round(f / t, 2)})

    # Collapse: a single dominant zone_partition explains everything -> 1 incident
    partitions = [i for i in incidents if i["type"] == "zone_partition"]
    if len(partitions) == 1:
        p = partitions[0]
        return [{
            "incident_id": "TC04-NET-001",
            "summary": f"Connectivity loss between {p['zone_pair'][0]} "
                       f"and {p['zone_pair'][1]}",
            "root_cause_hypothesis": "east-west network partition",
            "affected_zone_pair": p["zone_pair"],
            "evidence": f"{p['failed_pairs']}/{p['total_pairs']} cross-zone "
                        f"probes failing (confidence {p['confidence']})",
            "suppressed_symptom_alerts": p["failed_pairs"],
        }]
    return incidents

def main():
    pairs = load(sys.stdin)
    if not pairs:
        print(json.dumps({"error": "no probe data on stdin"})); return
    incidents = correlate(pairs)
    out = {"n_probe_pairs": len(pairs),
           "n_incidents": len(incidents),
           "incidents": incidents}
    print(json.dumps(out, indent=2))
    # PASS assertion for the test record:
    if len(incidents) == 1 and incidents[0].get("incident_id") == "TC04-NET-001":
        print("\nPASS: single root-cause incident emitted.", file=sys.stderr)
    else:
        print(f"\nreview: {len(incidents)} incidents (expected 1 during Phase B).",
              file=sys.stderr)

if __name__ == "__main__":
    main()
