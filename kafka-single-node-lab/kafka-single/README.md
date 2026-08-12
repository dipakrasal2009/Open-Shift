# Single-Broker Kafka Lab (one-worker OpenShift, OCP 4.20.8)

Sized for your cluster: 1 schedulable worker (~15Gi), 2 AZs, real monitoring
stack present. This runs a working Kafka you can produce to, consume from, and
point the lag anomaly detector at — all on what you already have.

## What this is (and isn't)
- IS: real Strimzi Kafka, real produce/consume, real consumer-group lag, real
  Prometheus metrics, real EWMA/3-sigma anomaly detection.
- IS NOT: the TC-02 broker-drain failover test. That needs 3 brokers across
  3 nodes and cannot be faked on one worker. This is the detection half only.

## Run order
```
bash 00-install-operator.sh      # one-time; wait for CSV Succeeded
bash 02-deploy.sh                # deploy single-broker cluster + topic
bash 03-produce-consume.sh       # prove it works + generate lag
bash 04-lag-detector.sh          # wire detector to Thanos, run once
```
Files:
- `01-kafka-cluster.yaml`  single-broker Kafka + demo-topic (RF=1, ephemeral)
- `lag-detector.py`        EWMA/3-sigma on demo-group lag, in-cluster TLS
- `09-cleanup.sh`          removes everything

## The three things that MUST be right on one broker
1. Every replication factor = 1 (offsets, transaction-state, default). With one
   broker you cannot have RF>1 — topics stay under-replicated forever otherwise.
2. `min.insync.replicas: 1`. If left at 2, every `acks=all` produce hangs.
   That's why 03-produce-consume.sh uses `acks=1`.
3. No `rack` block. Rack awareness needs workers in multiple zones; you have
   two AZs but only one worker, so it has nothing to balance across.

## Memory watch
Everything lands on the single worker. If pods go Pending, check:
```
oc adm top node
oc describe node <worker> | grep -A5 Allocated
```
The resource requests in 01-kafka-cluster.yaml are deliberately small
(Kafka 1Gi, ZK 512Mi). Don't raise them unless the worker has headroom.

## When you add a 2nd/3rd worker later
Bump `replicas` to 3, set the RFs and `min.insync.replicas: 2` back, re-add the
`rack` block with `topologyKey: topology.kubernetes.io/zone`, and the TC-02
drain test from the main pack becomes runnable. Nothing else changes.
