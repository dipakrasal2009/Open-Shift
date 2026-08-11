#!/bin/bash
# TC-05 run: deploy tenant, quota, leaker. Start forecaster alongside.
set -x
oc apply -f tenant-setup.yaml
oc apply -f leaker.yaml
oc get quota -n tenant-a
# Prove quota isolation: try to schedule replacement leakers beyond allocation
oc scale deployment leaker -n tenant-a --replicas=20
oc get events -n tenant-a --field-selector reason=FailedCreate | tail -5
# Expected: forbidden: exceeded quota once requests.memory/pods cap is hit
oc scale deployment leaker -n tenant-a --replicas=1

echo "Now run the forecaster in a loop (see forecast.py) and watch:"
echo "  oc get events -n tenant-a --field-selector reason=Evicted -w"
