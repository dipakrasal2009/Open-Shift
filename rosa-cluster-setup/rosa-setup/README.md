# ROSA Cluster Setup (ROSA with HCP)

Step-by-step to create a Red Hat OpenShift Service on AWS cluster via the
`rosa` CLI, sized for the failure-injection test suite. Run the files in order.

## The one thing that changes for your test suite
ROSA defaults to **HCP (Hosted Control Plane)**: Red Hat runs the control plane
(API server, etcd, schedulers) in their own account. **You do not have access
to etcd or the master nodes.** Consequences:

- **TC-01 (etcd disk latency)** — NOT runnable on ROSA HCP. You can't `oc debug`
  a master or run fio on etcd; that layer is managed. Drop TC-01 here.
- **TC-02, TC-03, TC-04, TC-05** — all runnable, because they operate on WORKER
  nodes, which you own. This is the big win over your single EC2 box.

If you specifically need to exercise etcd/control-plane faults, that requires
ROSA **Classic** (self-managed control plane) or a self-installed IPI cluster —
not HCP. For everything else, HCP is simpler and cheaper.

## Order of execution
```
bash 00-prereqs.sh              # CLIs, ROSA login, quotas (one-time)
source 01-account-roles.sh      # source it so env vars persist
bash  02-vpc.sh                 # BYO-VPC via rosa create network (multi-AZ)
bash  03-oidc-operator-roles.sh # OIDC config + operator roles
bash  04-create-cluster.sh      # create + watch install (~10-15 min)
bash  05-access.sh              # admin user + oc login
# ... run your labs and test cases ...
bash  09-delete.sh              # FULL teardown - stops billing
```

## Env vars you must set (in 01-account-roles.sh)
- `CLUSTER_NAME`, `REGION`
- `ACCOUNT_ROLES_PREFIX`, `OPERATOR_ROLES_PREFIX`
Then, captured from command output as you go:
- `OIDC_CONFIG_ID` (from step 3.1)
- `SUBNET_IDS` (private subnets from step 2)

## Sizing for the suite
- **3 workers, m5.2xlarge, across 3 AZs.** The 3-AZ spread is what makes TC-02
  rack awareness and TC-04 zone partition real. 3 workers lets TC-03 split a
  canary pool and TC-05 reschedule after eviction.
- Cheaper learning-only option: single-AZ, 2 workers — runs Part A labs and the
  single-broker Kafka, but not the zone-based cases.

## Cost reality
ROSA has an hourly service fee ON TOP of the AWS infra (EC2 workers, NAT
gateways, load balancers, EBS). 3× m5.2xlarge + HCP fee runs continuously =
real money. Spin up for a session, run your tests, then `09-delete.sh`. The
teardown removes the cluster, IAM roles, OIDC, and (last step) the VPC stack.

## Verify before you trust it
After 05-access.sh:
```
oc get nodes -L topology.kubernetes.io/zone   # 3 workers, 3 distinct AZs
oc get co                                     # note: fewer COs than IPI - HCP
oc get route thanos-querier -n openshift-monitoring   # monitoring present
```
Once that checks out, the multi-node test cases from the main command pack
(TC-02, TC-03, TC-04, TC-05) run as written — restore the production Kafka
manifest (RF=3, min.insync=2, rack block) since you now have the nodes for it.
