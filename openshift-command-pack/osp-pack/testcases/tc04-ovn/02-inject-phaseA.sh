#!/bin/bash
# PHASE A: kill OVN control plane on one node
set -x
oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node \
  --field-selector spec.nodeName=worker-3
# PASS: EXISTING flows on worker-3 keep working (OVS flows already programmed);
# only NEW pod network programming stalls until the ovnkube-node pod restarts.
oc get pod -n openshift-ovn-kubernetes -o wide | grep worker-3
