# Kafka + AIOps Lag Detection Lab (single-node OpenShift)

A hands-on lab that deploys a real Kafka cluster on OpenShift, generates real
consumer lag, and runs a lightweight AIOps anomaly detector against it —
sized specifically for a **1 master + 1 worker** cluster, where the full
3-broker production Kafka setup (drain tests, rack awareness) can't run.

This document explains what the project does, why it's built this way, what
every file is for, and the exact sequence to run it — including the real
problems hit while building it and how they were fixed, so you don't have to
rediscover them.

---

## 1. What this project actually does

Three things, in order:

1. **Deploys a working single-broker Kafka cluster** using the Strimzi
   operator (AMQ Streams), in **KRaft mode** (no ZooKeeper).
2. **Generates real producer/consumer traffic** against it, including
   deliberately-created consumer lag (a backlog of unread messages).
3. **Runs an AIOps-style anomaly detector** — a small Python job that queries
   Prometheus/Thanos for consumer lag, compares the current value against a
   rolling statistical baseline (EWMA + 3-sigma), and reports whether the lag
   pattern is anomalous, the same way a real production alerting pipeline
   would.

The point isn't just "run Kafka" — it's the full loop: **data plane → metrics
plane → detection plane**, so you can see exactly how an AIOps pipeline is
wired end to end, and practice diagnosing it when a piece is missing (which,
as the history below shows, happens constantly in real deployments too).

---

## 2. Architecture

```
 Producer & consumer pods
          │  read/write "load-topic"
          ▼
 Kafka broker (KRaft, single node: dev-kafka-dual-role-0)
          │
          ├─────────────────────────┐
          ▼                         ▼
   JMX exporter                Kafka Exporter
   :9404 - broker metrics      :9404 - CONSUMER LAG metrics
   (kafka_server_*, etc)       (kafka_consumergroup_lag, etc)
          │                         │
          └───────────┬─────────────┘
                       ▼
          Prometheus + Thanos (openshift-user-workload-monitoring)
          scrapes both exporters via two separate PodMonitors
                       │
                       ▼
          AIOps lag-detector Job (lag-detector.py)
          queries Thanos, runs EWMA + 3-sigma check
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
       No anomaly           Anomaly detected
       exit 0                exit 1 (would page in prod)
```

**The one thing worth understanding clearly**: the broker's JMX exporter and
the Kafka Exporter are **two completely separate components** that both
happen to use port 9404. The JMX exporter reports broker-internal JVM/Kafka
metrics. Only the **Kafka Exporter** produces `kafka_consumergroup_lag` — it
polls consumer group offsets via the Kafka admin API and exposes them
separately. Missing this distinction was the single biggest time sink while
building this lab (see section 5).

---

## 3. Why single-broker / KRaft (not the "real" 3-broker setup)

The original production lab this was adapted from (`testcases/tc02-kafka/`)
assumes 3 brokers across 3 nodes, so it can drain one broker's node and prove
the other two hold traffic. On a 1 master + 1 worker cluster:

- There's no second node to drain, so that test is physically impossible here.
- Kafka replication factor > 1 is meaningless with one broker (permanently
  under-replicated).
- `min.insync.replicas` must be 1, or every `acks=all` produce hangs forever
  waiting for a second replica that will never exist.

This lab keeps everything **except** the multi-node failover test: real
Strimzi deployment, real produce/consume, real lag, real Prometheus-based
detection. The README section 7 below explains exactly what to change if you
later add more workers.

---

## 4. File-by-file explanation

### Setup / deployment

| File | Purpose |
|---|---|
| `00-install-operator.sh` | Installs the AMQ Streams (Strimzi) operator via OperatorHub subscription. Polls the CSV status in a loop until it reaches `Succeeded` (non-blocking — avoids the earlier bug where a `-w`/watch command would hang forever waiting for manual Ctrl+C). |
| `01-metrics-configmap.sh` | Fetches Strimzi's upstream JMX exporter rules and applies **only the ConfigMap** from that file. Upstream's `kafka-metrics.yaml` on the `main` branch also bundles a full example Kafka cluster (`my-cluster` + node pools) — this script filters that out with a small Python step so it doesn't create a second, resource-competing cluster on your one worker. |
| `02-kafka-cluster.yaml` | The actual Kafka cluster definition. Two resources: a `KafkaNodePool` (1 replica, roles `[controller, broker]` combined since there's only one node) and the `Kafka` CR itself (version 4.1.0, KRaft mode, no `zookeeper` block, **includes `kafkaExporter`** so consumer lag metrics exist from the start). |
| `03-deploy.sh` | Applies `02-kafka-cluster.yaml` and waits for the cluster to become `Ready`. Use this for a clean, first-time deploy. |
| `03b-recover-and-deploy.sh` | Recovery script — deletes a broken/stuck `Kafka` CR and any leftover test pods (`producer`, `consumer`, etc.) before reapplying the manifest. Needed because a `Kafka` CR rejected for an unsupported version (see section 5) never becomes `Ready` on its own; `oc apply` alone won't fix it, it must be deleted and recreated. |
| `04-topic.yaml` | The `KafkaTopic` used throughout the lab (`load-topic`), 6 partitions, replication factor 1. |

### Traffic generation

| File | Purpose |
|---|---|
| `05-produce-consume.sh` | The main traffic script: creates the topic, runs an interactive producer/consumer smoke test (type messages, see them read back), then launches a steady background producer + consumer pair (`producer` / `consumer`) that generates continuous load and a real, tracked consumer group (`lag-lab-group`). |
| `11-create-lag.sh` | Deliberately creates lag **fast**: stops the `consumer` pod, then fires an unthrottled producer burst (`--throughput -1`). Good for an instant, large lag spike. |
| `15-create-lag-over-time.sh [minutes] [msgs/sec]` | Creates lag **gradually** over a chosen duration (default 10 min @ 1000 msg/s) instead of an instant jump. This is what you want if you need to see the detector catch a *rising trend*, not just a step change — a throttled, sustained producer with the consumer stopped, so Prometheus captures multiple samples along a climbing curve. |
| `05b-upgrade-kafka.sh [version]` | Upgrades the running Kafka version (e.g. `4.1.0` → `4.2.0`). Patches `spec.kafka.version` first, waits for the rolling restart, and prints (but does not auto-run) the follow-up `metadataVersion` patch — kept as a separate manual step because it's a one-way KRaft log-format bump; you confirm the version change is stable before committing to it. |

### Metrics / observability

| File | Purpose |
|---|---|
| `06-podmonitor.yaml` | Enables OpenShift user-workload monitoring (`enableUserWorkload: true`) and creates a `PodMonitor` for the broker's **JMX exporter** (broker-internal metrics). ⚠️ This ConfigMap patch can overwrite an existing `cluster-monitoring-config` if one is already configured for something else — check first before applying blind on a shared cluster. |
| `13-enable-kafka-exporter.sh` | Patches the `Kafka` CR to add `spec.kafkaExporter` (if not already present from a fresh `02-kafka-cluster.yaml` deploy), waits for the exporter pod, and **prints its actual port name and pod labels** rather than assuming them — this project hit two separate wrong-assumption bugs (pod naming, label selectors) so this script verifies before you wire up scraping. |
| `14-exporter-podmonitor.yaml` | The `PodMonitor` for the **Kafka Exporter** specifically — the actual source of `kafka_consumergroup_lag`. Selector uses `strimzi.io/component-type: kafka-exporter` + `strimzi.io/cluster: dev-kafka` (confirmed against real pod labels — see section 5, this was originally guessed wrong). |
| `08b-diagnose-metrics.sh` | Full diagnostic sweep when metrics aren't showing up: checks whether user-workload-monitoring actually deployed (and isn't `Pending` from resource pressure), whether the PodMonitor's port name matches the pod's actual port, whether the JMX exporter is serving data locally on the pod, whether Prometheus is actively scraping the target, and a final direct Thanos query. Run this instead of guessing when `08-run-detector.sh` reports `no_lag_data`. |
| `12-watch-lag-live.sh` | Live side-by-side view: polls the Kafka CLI (`kafka-consumer-groups.sh`, ground truth from the broker) and the Thanos PromQL query (what the detector actually sees) every 10 seconds, so you can watch both agree — or catch a discrepancy — in real time. |

### AIOps detection

| File | Purpose |
|---|---|
| `lag-detector.py` | The actual AIOps logic. Queries Thanos for 30 minutes of `kafka_consumergroup_lag` history, computes a baseline mean/stddev from that window, and flags the current value as anomalous only if it's **more than 3 standard deviations from that rolling baseline** — not just "lag is high" in absolute terms. This means: a lag that's been flat for a long time (even at a large number) is *not* anomalous; a lag that just jumped sharply *is*. Exits 1 on anomaly (the "page" signal), 0 otherwise. |
| `07-lag-detector-job.yaml` | Kubernetes manifests to run `lag-detector.py` as a one-shot Job: a dedicated `ServiceAccount`, a `ClusterRoleBinding` granting `cluster-monitoring-view` (so it can query Thanos), and the `Job` itself, which mounts the script from a ConfigMap. |
| `08-run-detector.sh` | Applies the PodMonitor (idempotent), waits for scraping, deploys/recreates the detector Job, waits for completion, and prints its JSON output. Run this any time you want a fresh detection pass. |

### Verification / cleanup

| File | Purpose |
|---|---|
| `10-verify.sh` | End-to-end health check across 9 layers: operator status → Kafka CR ready → pods running → bootstrap connectivity → topic config → produce/consume round trip → JMX metrics exporting → Prometheus scraping → lag metric queryable. Run this after any deploy to confirm everything is actually wired correctly before generating load. |
| `09-cleanup.sh` | Tears down everything this lab created: test pods, topic, Kafka cluster, PodMonitors, ConfigMaps, RBAC. Leaves the namespace itself — check `oc get all -n kafka` is empty before deleting it manually. |

---

## 5. Problems hit while building this (read this before your next deploy)

These are documented because every one of them cost real debugging time —
knowing them up front saves repeating the same cycle.

**1. Kafka 3.7.0 + ZooKeeper is not supported on this operator.**
The installed AMQ Streams version (3.2.x) only supports Kafka `4.1.0`/`4.2.0`,
and ZooKeeper-based clusters are removed entirely since Strimzi 0.46. The
`Kafka` CR silently sat at `NotReady` with zero pods created — not hanging,
*rejecting*. Fixed by rewriting to KRaft mode with a `KafkaNodePool` and
`version: 4.1.0` (now baked into `02-kafka-cluster.yaml`).

**2. Broker pod naming changed under KRaft/node pools.**
Old ZooKeeper-era assumption: `<cluster>-kafka-0`. Actual name under node
pools: `<cluster>-<pool-name>-0` (here, `dev-kafka-dual-role-0`). Any script
referencing the old pattern fails with `pods "dev-kafka-kafka-0" not found`.
Current scripts look this up dynamically via
`oc get pods -l strimzi.io/cluster=dev-kafka,strimzi.io/broker-role=true`
instead of hardcoding it.

**3. Upstream `kafka-metrics.yaml` bundles more than a ConfigMap.**
Applying it directly created a stray second Kafka cluster (`my-cluster` +
node pools) competing for resources on the one worker node. `01-metrics-configmap.sh`
now filters the fetched YAML down to just the `ConfigMap` document.

**4. `kafka_consumergroup_lag` doesn't exist without the Kafka Exporter.**
The broker's JMX exporter (wired up by `06-podmonitor.yaml`) exposes broker
metrics only — never consumer group lag. No amount of waiting or generating
lag fixes `no_lag_data` if this component isn't enabled. Fixed by adding
`spec.kafkaExporter` to the `Kafka` CR and creating a **second**, separate
`PodMonitor` (`14-exporter-podmonitor.yaml`) pointed at it.

**5. Guessed pod labels were wrong.**
Assumed `strimzi.io/kind: KafkaExporter` for the exporter's `PodMonitor`
selector — the actual label is `strimzi.io/kind: Kafka` (same as the broker)
with `strimzi.io/component-type: kafka-exporter` as the actual distinguishing
label. Always verify with
`oc get pod <name> -o jsonpath='{.metadata.labels}'` before writing a
selector, rather than assuming Strimzi's naming convention.

**6. Anomaly detection needs *change*, not just a high number.**
Lag sitting flat at 1,000,000+ for 30+ minutes produces `findings: []` from
the detector — correctly. EWMA + 3-sigma flags deviation from a rolling
baseline, not absolute magnitude. If lag has been constant, the baseline
*is* that constant, so there's no deviation to detect. To see a real
detection, lag needs to actually be climbing or changing during the
detector's 30-minute lookback window — use `15-create-lag-over-time.sh` for
this rather than a single instant burst that then goes flat.

---

## 6. How to run it (clean, first-time setup)

```bash
export KUBECONFIG=/root/openshift/auth/kubeconfig   # adjust to your cluster

# 1. Install the operator (waits for Succeeded automatically)
bash 00-install-operator.sh

# 2. Metrics ConfigMap (JMX exporter rules)
bash 01-metrics-configmap.sh

# 3. Deploy the Kafka cluster (KRaft, includes kafkaExporter already)
bash 03-deploy.sh

# 4. Confirm everything is actually healthy before continuing
bash 10-verify.sh

# 5. Wire up metrics scraping - BOTH exporters
oc apply -f 06-podmonitor.yaml
oc apply -f 14-exporter-podmonitor.yaml
sleep 90   # give Prometheus time to discover the new scrape targets

# 6. Generate real traffic (topic + smoke test + steady background load)
bash 05-produce-consume.sh

# 7. Generate a real, gradual lag spike for the detector to catch
bash 15-create-lag-over-time.sh 10 1000

# 8. (optional, separate terminal) watch it live
bash 12-watch-lag-live.sh

# 9. Run the AIOps detector while lag is actively changing
bash 08-run-detector.sh

# 10. Clean up when done
bash 09-cleanup.sh
```

### If something breaks mid-way

```bash
bash 08b-diagnose-metrics.sh      # metrics/Prometheus not showing data
bash 03b-recover-and-deploy.sh    # Kafka CR stuck NotReady, needs recreation
bash 13-enable-kafka-exporter.sh  # kafka_consumergroup_lag missing entirely
```

### If you only need more lag on an already-running cluster

```bash
bash 11-create-lag.sh                    # fast, instant burst
bash 15-create-lag-over-time.sh 5 2000   # 5 min @ 2000 msg/s, gradual
```

---

## 7. Path to the full 3-broker setup (if you add more workers)

This lab intentionally can't run the real broker-drain/failover test — that
needs nodes to actually lose. If you add 2 more workers (3 total):

1. In `02-kafka-cluster.yaml`, change the `KafkaNodePool` to `replicas: 3`
   with roles split (dedicated `controller` and `broker` pools instead of
   combined `dual-role`).
2. Restore `default.replication.factor: 3`, `min.insync.replicas: 2`,
   `offsets.topic.replication.factor: 3`.
3. Add a `rack: { topologyKey: topology.kubernetes.io/zone }` block if your
   3 workers span multiple availability zones.
4. Use `storage: persistent-claim` instead of `ephemeral` so broker restarts
   don't lose data — this matters once you're testing real failover.
5. You can then run a genuine drain test:
   `oc adm drain <broker-node> --ignore-daemonsets --delete-emptydir-data`
   and watch the other two brokers hold traffic while Strimzi rolls the
   drained one back in.

---

## 8. Quick reference — what "healthy" looks like

```bash
oc get kafka dev-kafka -n kafka
# READY should show True

oc get pods -n kafka
# dev-kafka-dual-role-0            1/1 Running
# dev-kafka-kafka-exporter-xxxxx   1/1 Running
# dev-kafka-entity-operator-xxxxx  2/2 Running

oc get podmonitor -n kafka
# dev-kafka-metrics             (broker JMX metrics)
# dev-kafka-exporter-metrics    (consumer lag metrics)
```
