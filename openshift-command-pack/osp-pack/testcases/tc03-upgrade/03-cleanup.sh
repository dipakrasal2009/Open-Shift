#!/bin/bash
set -x
# After fleet completes (paused flipped false by the gate or manually):
oc label node worker-5 node-role.kubernetes.io/canary-
oc label node worker-6 node-role.kubernetes.io/canary-
oc delete mcp canary
oc adm wait-for-stable-cluster --minimum-stable-period=15m
