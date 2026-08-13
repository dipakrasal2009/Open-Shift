#!/bin/bash
set -x
oc delete -f leaker.yaml
oc delete -f tenant-setup.yaml
# Confirm no lingering node MemoryPressure:
oc get nodes -o=jsonpath="{range .items[*]}{.metadata.name}{\"	\"}{.status.conditions[?(@.type==\"MemoryPressure\")].status}{\"
\"}{end}"
