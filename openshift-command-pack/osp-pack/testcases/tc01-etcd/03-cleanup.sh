#!/bin/bash
# TC-01 CLEANUP
set -x
oc debug node/master-1 -- chroot /host bash -c "pkill -f etcd-stress; rm -f /var/lib/etcd/etcd-stress*"
sleep 60
bash 02-verify.sh          # fsync p99 must return to baseline
oc adm wait-for-stable-cluster --minimum-stable-period=10m
oc adm must-gather --dest-dir=./must-gather-tc01-after
