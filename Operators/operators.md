# OpenShift Operators Setup Guide

This README documents the setup and purpose of key OpenShift operators used in this cluster: **ODF**, **ACM**, **ACS**, **Compliance Operator**, and **OADP**. It explains what each operator does, when to use it, and includes practical setup steps and examples.

---

## Table of Contents

1. [Overview](#overview)
2. [ODF (OpenShift Data Foundation)](#1-odf-openshift-data-foundation)
3. [ACM (Advanced Cluster Management)](#2-acm-advanced-cluster-management)
4. [ACS (Advanced Cluster Security)](#3-acs-advanced-cluster-security)
5. [Compliance Operator](#4-compliance-operator)
6. [OADP (OpenShift API for Data Protection)](#5-oadp-openshift-api-for-data-protection)
7. [Which Operator to Use When](#which-operator-to-use-when)
8. [Common Issues](#common-issues)

---

## Overview

| Operator | Purpose | Namespace |
|---|---|---|
| ODF | Persistent storage (block, file, object) for workloads | `openshift-storage` |
| ACM | Manage multiple OpenShift/Kubernetes clusters from one place | `open-cluster-management` |
| ACS | Container/Kubernetes security (vulnerabilities, runtime threats, network policy) | `stackrox` / `rhacs-operator` |
| Compliance Operator | Scan cluster against security benchmarks (CIS, PCI-DSS, etc.) | `openshift-compliance` |
| OADP | Backup and restore of applications and persistent data | `openshift-adp` |

---

## 1. ODF (OpenShift Data Foundation)

**What it does:** Provides persistent storage for applications running on OpenShift — block storage (RWO), shared file storage (RWX via CephFS), and S3-compatible object storage (via NooBaa). Built on Ceph under the hood.

**Use it when:** Any application needs a PersistentVolumeClaim — databases, file shares between pods, or an S3 bucket for application data, backups, or logs.

### Setup Steps

1. Install operator from OperatorHub into `openshift-storage` namespace.
2. Create the StorageCluster (Internal or Internal-Attached devices mode):
   ```
   oc get storagecluster -n openshift-storage
   ```
3. Confirm pods are running: mon, osd, mgr, csi, noobaa.
4. Confirm StorageClasses exist:
   ```
   oc get storageclass
   ```

### Example: Create and use a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 1Gi
```

```
oc apply -f odf-test-pvc.yaml
oc get pvc odf-test-pvc -n default
```

### Verify it works

```
oc rsh -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)
ceph status
```

---

## 2. ACM (Advanced Cluster Management)

**What it does:** A central hub for managing multiple OpenShift/Kubernetes clusters — provisioning, policy enforcement, application lifecycle (GitOps), and observability across clusters. It also feeds into ACS for multi-cluster security visibility.

**Use it when:** You have (or plan to have) more than one cluster and want a single pane of glass for management, governance, and policy compliance across all of them (e.g., enforcing that every cluster has network policies applied, or rolling out an app to dev/stage/prod clusters at once).

### Setup Steps

1. Install operator into `open-cluster-management` namespace.
2. Create the MultiClusterHub:
   ```yaml
   apiVersion: operator.open-cluster-management.io/v1
   kind: MultiClusterHub
   metadata:
     name: multiclusterhub
     namespace: open-cluster-management
   spec: {}
   ```
3. Apply and wait for `Running` phase:
   ```
   oc apply -f multiclusterhub.yaml
   oc get multiclusterhub -n open-cluster-management
   ```
4. Access console:
   ```
   oc get route multicloud-console -n open-cluster-management
   ```

### Example use case

Import a second OpenShift cluster into ACM, then create a `Policy` resource to enforce that all namespaces in both clusters have a default NetworkPolicy — applied centrally from the ACM hub instead of manually on each cluster.

---

## 3. ACS (Advanced Cluster Security)

**What it does:** Red Hat Advanced Cluster Security for Kubernetes (built on StackRox) provides image vulnerability scanning, runtime threat detection, network segmentation visualization, and security policy enforcement for containerized workloads.

**Use it when:** You need to scan container images for CVEs before/after deployment, detect anomalous runtime behavior (e.g., a pod spawning a shell unexpectedly), or enforce security policies like "block deployments using images with critical vulnerabilities."

### Setup Steps

1. Install operator into `rhacs-operator` namespace.
2. Create `stackrox` namespace and deploy Central:
   ```yaml
   apiVersion: platform.stackrox.io/v1alpha1
   kind: Central
   metadata:
     name: stackrox-central-services
     namespace: stackrox
   spec:
     central:
       exposure:
         route:
           enabled: true
   ```
3. Get admin credentials:
   ```
   oc -n stackrox get secret central-htpasswd -o go-template='{{index .data "password" | base64decode}}'
   oc get route central -n stackrox
   ```
4. Generate a Cluster Init Bundle from the Central UI, then deploy SecuredCluster:
   ```yaml
   apiVersion: platform.stackrox.io/v1alpha1
   kind: SecuredCluster
   metadata:
     name: stackrox-secured-cluster-services
     namespace: stackrox
   spec:
     clusterName: my-ocp-cluster
   ```

### Example use case

A developer pushes an image with a critical CVE to your internal registry. ACS scans it automatically and, if a policy is configured to block on critical severity, prevents the deployment from succeeding and alerts via the Central dashboard.

---

## 4. Compliance Operator

**What it does:** Scans the cluster (nodes and platform configuration) against industry-standard security benchmarks such as CIS, PCI-DSS, and NIST, and reports pass/fail results per control. Can also generate remediations for some failed checks.

**Use it when:** You need to prove regulatory or organizational compliance (e.g., "is this cluster CIS-compliant?") or want a scheduled audit of cluster security posture, independent of runtime threat detection (which is what ACS focuses on).

### Setup Steps

1. Install operator into `openshift-compliance` namespace.
2. Bind a profile (e.g., CIS) using a ScanSettingBinding:
   ```yaml
   apiVersion: compliance.openshift.io/v1alpha1
   kind: ScanSettingBinding
   metadata:
     name: cis-compliance
     namespace: openshift-compliance
   profiles:
     - name: ocp4-cis
       kind: Profile
       apiGroup: compliance.openshift.io/v1alpha1
     - name: ocp4-cis-node
       kind: Profile
       apiGroup: compliance.openshift.io/v1alpha1
   settingsRef:
     name: default
     kind: ScanSetting
     apiGroup: compliance.openshift.io/v1alpha1
   ```
3. Apply and monitor:
   ```
   oc apply -f cis-binding.yaml
   oc get compliancescan -n openshift-compliance
   ```

### Example: View failed checks

```
oc get compliancecheckresult -n openshift-compliance -l compliance.openshift.io/check-status=FAIL
```

### Example use case

Before a security audit, run the `ocp4-cis` profile scan, export the failed checks, and apply available auto-remediations to bring the cluster closer to CIS benchmark compliance.

---

## 5. OADP (OpenShift API for Data Protection)

**What it does:** Provides backup and restore capability for OpenShift applications and their persistent data, using Velero under the hood. Backs up to S3-compatible object storage (can be AWS S3, or ODF/NooBaa).

**Use it when:** You need to back up an application (its Kubernetes resources + PVC data) before an upgrade or risky change, migrate an application between clusters, or recover from accidental deletion/disaster.

> **Note:** Keep OADP setup separate from ACS/ACM/Compliance — it has no dependency on them. It only needs an S3-compatible bucket and credentials.

### Setup Steps

1. Install operator into `openshift-adp` namespace.
2. Create credentials secret:
   ```
   cat <<EOF > credentials-velero
   [default]
   aws_access_key_id=<ACCESS_KEY>
   aws_secret_access_key=<SECRET_KEY>
   EOF

   oc create secret generic cloud-credentials \
     -n openshift-adp \
     --from-file cloud=credentials-velero
   ```
3. Create the DataProtectionApplication CR:
   ```yaml
   apiVersion: oadp.openshift.io/v1alpha1
   kind: DataProtectionApplication
   metadata:
     name: dpa-sample
     namespace: openshift-adp
   spec:
     configuration:
       velero:
         defaultPlugins:
           - openshift
           - aws
       nodeAgent:
         enable: true
         uploaderType: kopia
     backupLocations:
       - velero:
           provider: aws
           default: true
           credential:
             name: cloud-credentials
             key: cloud
           objectStorage:
             bucket: <your-bucket-name>
             prefix: velero
           config:
             region: <region>
             s3ForcePathStyle: "true"
             s3Url: <https://your-s3-endpoint>
   ```
4. Verify:
   ```
   oc get dpa -n openshift-adp
   oc get backupstoragelocation -n openshift-adp
   ```

### Example: Run a backup

```yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: test-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - default
```

```
oc apply -f test-backup.yaml
oc get backup test-backup -n openshift-adp -o yaml
```

### Example use case

Before upgrading a critical application in the `default` namespace, run an OADP backup. If the upgrade breaks something, restore from the backup to roll back quickly.

---

## Which Operator to Use When

| Scenario | Operator to Use |
|---|---|
| App needs a database with persistent disk storage | **ODF** |
| Need a shared file system across multiple pods | **ODF** (CephFS) |
| Need an S3-compatible bucket for app/log storage | **ODF** (NooBaa) |
| Managing 3+ OpenShift clusters from one console | **ACM** |
| Enforcing the same policy/config across multiple clusters | **ACM** |
| Scanning container images for vulnerabilities (CVEs) | **ACS** |
| Detecting unusual runtime behavior in pods/containers | **ACS** |
| Blocking deployments that don't meet security policy | **ACS** |
| Auditing cluster against CIS/PCI-DSS benchmarks | **Compliance Operator** |
| Need a compliance report for an audit | **Compliance Operator** |
| Backing up an application before an upgrade | **OADP** |
| Migrating an application + data to another cluster | **OADP** |
| Disaster recovery / accidental deletion recovery | **OADP** |

---

## Common Issues

### OOM errors on worker nodes

If worker nodes run out of memory while deploying these operators (common on small lab clusters), you can temporarily allow workloads on master/control-plane nodes:

```
oc adm taint nodes --all node-role.kubernetes.io/master-
```

> **Caution:** This permits application pods to schedule on master nodes, which can affect etcd/API server stability if traffic load increases. Acceptable for lab/practice clusters; not recommended for production. To revert:
> ```
> oc adm taint nodes --all node-role.kubernetes.io/master=:NoSchedule
> ```

### Recommended install order

For a resource-constrained practice cluster, install one operator at a time and confirm pods are `Running` before moving to the next:

1. ODF (if storage is needed by other operators, e.g., OADP backend)
2. ACM
3. ACS
4. Compliance Operator
5. OADP (independent — can be done anytime)

---

## Quick Reference Commands

```bash
# Check all operator pods across namespaces
oc get pods -n openshift-storage
oc get pods -n open-cluster-management
oc get pods -n stackrox
oc get pods -n openshift-compliance
oc get pods -n openshift-adp

# Check installed operators (CSVs)
oc get csv --all-namespaces | grep -E "odf|acm|stackrox|compliance|oadp"
```
