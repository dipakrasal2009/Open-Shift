#!/bin/bash
# PHASE B: partition zone-a from zone-b (drop traffic from zone-b node CIDR)
set -x
ZONE_B_CIDR="10.0.2.0/24"    # <- replace with your zone-b node CIDR
oc debug node/worker-1 -- chroot /host \
  nft add rule inet filter input ip saddr $ZONE_B_CIDR drop
# PASS: cross-zone probes FAIL, in-zone probes SUCCEED, no kubelet NotReady
# flaps as long as the partition does not touch the API server path.
