# Kafka Lab — Single-Broker (sized for 1 master + 1 worker)

Adapted from the main pack's `testcases/tc02-kafka/` (3-broker production
setup) down to a single broker, because TC-02's actual test — draining a
broker node while the other two hold traffic — needs at least 3 workers.
This lab keeps everything else: real Strimzi cluster, real produce/consume,
real consumer lag, real Prometheus-based anomaly detection.

## What this can and cannot prove

| Capability | Works here? |
|---|---|
| Deploy Strimzi Kafka + ZooKeeper | Yes |
| Produce / consume, topics, consumer groups | Yes |
| JMX metrics -> Prometheus -> PromQL | Yes |
| EWMA/3-sigma lag anomaly detection | Yes |
| Broker drain / failover (TC-02's actual point) | **No** — needs 3 brokers on 3+ nodes |
| Rack awareness across zones | **No** — needs multiple schedulable nodes |

## Run order

```
bash 00-install-operator.sh      # install AMQ Streams, wait for CSV Succeeded
bash 01-metrics-configmap.sh     # JMX exporter rules
bash 03-deploy.sh                # deploy dev-kafka (uses 02-kafka-cluster.yaml)
bash 05-produce-consume.sh       # topic + smoke test + steady load/lag
bash 08-run-detector.sh          # enable scraping, run anomaly detector
bash 09-cleanup.sh               # tear down when done
```

## Single-broker gotchas (the ones that bite first-timers)

- **min.insync.replicas must be 1.** Leaving it at the production default of 2
  with only 1 broker means every `acks=all` produce blocks forever — there's
  no second replica to ever catch up to.
- **All replication factors must be 1** (`default.replication.factor`,
  `offsets.topic.replication.factor`, `transaction.state.log.replication.factor`).
  RF > 1 on a single broker is permanently under-replicated.
- **No `rack` block.** Rack awareness needs multiple nodes/zones to spread
  replicas across; with one broker it does nothing but adds config surface.
- `06-podmonitor.yaml` **overwrites** `cluster-monitoring-config` in
  `openshift-monitoring` if you already have user-workload monitoring
  configured for something else — merge by hand instead of applying blind.
- After producing, give Prometheus 1-2 minutes to scrape before running the
  detector, or you'll see `no_lag_data` — that's expected, not broken.

## Path to the real TC-02 (3-broker drain test)

Add 2 more workers (3 total) and switch back to the production manifest in
`testcases/tc02-kafka/kafka-cluster.yaml`:
- `replicas: 3` for both Kafka and ZooKeeper
- restore `default.replication.factor: 3`, `min.insync.replicas: 2`
- restore the `rack: { topologyKey: topology.kubernetes.io/zone }` block
- run `testcases/tc02-kafka/02-drain.sh` to cordon/drain the broker's node
  and watch Strimzi's Drain Cleaner (or the PDB) hold the line — that's the
  test this single-broker version can't do.
