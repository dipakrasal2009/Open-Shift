#!/bin/bash
set -x
oc debug node/worker-1 -- chroot /host nft flush ruleset
oc wait --for=condition=Ready pod -l app=ovnkube-node -n openshift-ovn-kubernetes --timeout=180s
# Re-run full mesh -> expect 100%
bash 01-deploy-mesh.sh
