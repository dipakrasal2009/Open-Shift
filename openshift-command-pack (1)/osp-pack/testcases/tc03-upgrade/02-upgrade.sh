#!/bin/bash
# TC-03 EXECUTION - full maintenance window
set -x
oc adm upgrade                              # list available versions
oc adm upgrade --to="TARGET_VERSION"    # <- replace with a version from the list above

# Control plane + canary MCP upgrade; main workers stay paused.
watch -n30 "oc get clusterversion; oc get co | grep -v \"True.*False.*False\"; oc get mcp"
# PLATFORM PASS:
#  - no ClusterOperator degraded > 30 min
#  - canary nodes reboot one at a time (maxUnavailable: 1), PDBs respected
