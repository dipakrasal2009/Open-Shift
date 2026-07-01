# OpenShift Security Practicals — SCC, OAuth, Image Security Policies

This document covers three hands-on exercises performed on top of the `rbac-secrets-demo` project:

1. Security Context Constraints (SCC)
2. OAuth in OpenShift (HTPasswd identity provider + tokens)
3. Image Security Policies

It also captures real issues hit during testing and how they were resolved — useful if you repeat this lab.

---

## 1. Security Context Constraints (SCC)

### What it is
SCCs are OpenShift's **pod-level** security gatekeeper. They control things RBAC never touches: which UID a container can run as, whether it can run privileged, which Linux capabilities it gets, host networking/volumes access, etc. Every pod is validated against an SCC before the API server lets it start.

By default, workloads run under **`restricted-v2`**, which:
- forces a **random UID** from the namespace's allocated range (e.g. `1000820000–1000829999`)
- blocks `runAsUser: 0` (root)
- requires `allowPrivilegeEscalation: false`, dropped capabilities, `seccompProfile`, etc.

### Practical performed

**Step 1 — try to force the container to run as root**
```bash
oc patch deployment rbac-secrets-demo -n rbac-secrets-demo --type=json -p '[
  {"op": "add", "path": "/spec/template/spec/containers/0/securityContext", "value": {"runAsUser": 0}}
]'
```
Result — the patch was accepted with a **PodSecurity admission warning**, and the new ReplicaSet failed to create any pods:
```
Error creating: pods "rbac-secrets-demo-6866cc79bf-" is forbidden:
unable to validate against any security context constraint:
provider restricted-v2: .containers[0].runAsUser: Invalid value: 0:
must be in the ranges: [1000820000, 1000829999]
... (also rejected by anyuid, restricted-v3, nonroot, privileged, etc.)
```
The **old pod kept running** (Deployments don't kill working replicas until new ones are ready), so `oc get pods` still showed `1/1 Running` — but the new ReplicaSet was stuck at 0 pods. Checked with:
```bash
oc describe pod rbac-secrets-demo-c8db54cfc-krjd5 -n rbac-secrets-demo | grep scc
# openshift.io/scc: restricted-v2
```

**Step 2 — create a custom SCC allowing root, and bind it to the ServiceAccount**
```yaml
# allow-root-scc.yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: allow-root-scc
allowPrivilegedContainer: false
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
fsGroup:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
users:
- system:serviceaccount:rbac-secrets-demo:rbac-demo-sa
```
```bash
oc apply -f allow-root-scc.yaml
oc delete pod -n rbac-secrets-demo -l app=rbac-secrets-demo
oc get pods -n rbac-secrets-demo
```

**Observation:** even after creating `allow-root-scc`, the new pod still came up under `restricted-v2`, not `allow-root-scc`. This is expected — OpenShift's admission controller picks the **most restrictive SCC that the pod's ServiceAccount is authorized to use**, and since the patched `runAsUser: 0` was never actually retried against the new SCC (the ReplicaSet template already had `runAsUser: 0`, but the SCC the SA had access to *changed* — yet the pod that successfully started here didn't request root explicitly enough to need `allow-root-scc`). In practice, to force the new SCC into play you'd want to confirm via:
```bash
oc describe pod <new-pod> -n rbac-secrets-demo | grep scc
```
and if it's still `restricted-v2`, double check the deployment's `runAsUser` value is still set, and that no more-restrictive SCC matches first. A clean re-test: remove `restricted-v2` priority conflicts or explicitly reference the SCC via a SCC-aware admission test (`oc adm policy who-can use scc/allow-root-scc`).

**Step 3 — clean up**
```bash
oc delete scc allow-root-scc
```
After deletion, any pod still requesting `runAsUser: 0` goes back to failing admission under `restricted-v2`.

### Key takeaway
SCCs are evaluated **per ServiceAccount**, independently of RBAC Roles. Granting `edit` or `admin` RBAC roles does **not** grant SCC permissions — they're separate authorization systems.

---

## 2. OAuth in OpenShift

### What it is
OpenShift's `oauth-server` authenticates users against an **identity provider** (HTPasswd in this case) and issues **Bearer tokens**. Every `oc login` is an OAuth2 flow under the hood — the token issued is exactly what gets validated on every subsequent API call, whether via `oc` or raw `curl`.

### Practical performed

**Step 1 — create local users via HTPasswd**
```bash
htpasswd -c -B -b /root/users.htpasswd admin-user admin123
htpasswd -B -b /root/users.htpasswd edit-user edit123
htpasswd -B -b /root/users.htpasswd view-user view123
```

> ⚠️ **Bug hit during testing:** the `-c` flag (create new file) was mistakenly repeated on the `edit-user` and `view-user` commands too:
> ```bash
> htpasswd -c -b /root/users.htpasswd edit-user edit123   # WRONG — -c truncates the file
> htpasswd -c -b /root/users.htpasswd view-user view123   # WRONG — -c truncates the file again
> ```
> Each `-c` **recreates the file from scratch**, wiping out previously added users. This is exactly why `admin-user` and `edit-user` later failed with `Login failed (401 Unauthorized)` — only the *last* user written (`view-user`) actually existed in the htpasswd Secret.
>
> **Fix:** only use `-c` on the very first user. All subsequent users must omit it:
> ```bash
> htpasswd -c -B -b /root/users.htpasswd admin-user admin123   # first user: -c creates file
> htpasswd -B -b /root/users.htpasswd edit-user edit123        # no -c — appends
> htpasswd -B -b /root/users.htpasswd view-user view123        # no -c — appends
> ```
> After fixing, re-create the secret and the auth pods need to roll out again:
> ```bash
> oc create secret generic htpass-secret --from-file=htpasswd=/root/users.htpasswd -n openshift-config --dry-run=client -o yaml | oc replace -f -
> oc get pods -n openshift-authentication -w
> ```

**Step 2 — register HTPasswd as identity provider**
```bash
oc edit oauth cluster
```
```yaml
spec:
  identityProviders:
  - name: htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
```
Wait for `oauth-openshift` pods in `openshift-authentication` to roll:
```bash
oc get pods -n openshift-authentication -w
```

**Step 3 — pre-create User/Identity objects (avoids waiting on first login)**
```bash
for user in admin-user edit-user view-user; do
  oc create user $user
  oc create identity htpasswd_provider:$user
  oc create useridentitymapping htpasswd_provider:$user $user
done
```

**Step 4 — bind RBAC roles to each user**
```bash
oc adm policy add-role-to-user admin admin-user -n rbac-secrets-demo
oc adm policy add-role-to-user edit  edit-user  -n rbac-secrets-demo
oc adm policy add-role-to-user view  view-user  -n rbac-secrets-demo

oc create rolebinding view-user-pod-reader \
  --role=pod-reader --user=view-user -n rbac-secrets-demo
```

**Step 5 — test as `view-user` (the one user with a correctly-set password)**
```bash
oc login -u view-user -p view123 https://api.<cluster>:6443
oc get pods -n rbac-secrets-demo        # works (view role)
oc get ns                               # Forbidden — cluster-scoped, no permission
oc delete pod <pod-name>                # Forbidden — view role is read-only
```
Confirmed expected results:
```
Error from server (Forbidden): namespaces is forbidden: User "view-user" cannot list resource "namespaces" ...
Error from server (Forbidden): pods "..." is forbidden: User "view-user" cannot delete resource "pods" ...
```

**Step 6 — extract and use the raw OAuth token directly with curl**
```bash
TOKEN=$(oc whoami -t)
API=$(oc whoami --show-server)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API/api/v1/namespaces/rbac-secrets-demo/pods" | jq '.items[].metadata.name'
```
Returned the pod name successfully — proving the Bearer token alone, without `oc`, is sufficient to authenticate to the API server.

**Step 7 — inspect and revoke the token as cluster-admin**
```bash
oc login -u kubeadmin -p <kubeadmin-password> https://api.<cluster>:6443
oc get oauthaccesstokens | grep view-user
oc describe oauthaccesstoken <token-name>
```
Example output:
```
Scopes:       [user:full]
Expires In:   24 hours
User Name:    view-user
Client Name:  openshift-challenging-client
```
To revoke without changing the password:
```bash
oc delete oauthaccesstoken <token-name>
```
(Re-running the `curl` call afterward should return `401 Unauthorized`.)

### Key takeaway
- `oc login` failures with `401 Unauthorized` after setting up HTPasswd are almost always caused by the **`-c` overwrite mistake** above, or by the secret/oauth rollout not having completed yet.
- A Bearer token *is* the identity — anyone holding it can call the API as that user until it's revoked or expires.

---

## 3. Image Security Policies

### What it is
Controls **which registries images are allowed to be pulled from**, cluster-wide — independent of RBAC and SCC. Configured via the cluster-scoped `image.config.openshift.io/cluster` object.

### Practical to perform
```bash
# check current policy
oc get image.config.openshift.io/cluster -o yaml

# block Docker Hub cluster-wide
oc patch image.config.openshift.io/cluster --type=merge -p '
{
  "spec": {
    "registrySources": {
      "blockedRegistries": ["docker.io"]
    }
  }
}'

# try to deploy an image from docker.io — should be blocked
oc run blocked-test --image=docker.io/library/nginx -n rbac-secrets-demo
oc describe pod blocked-test -n rbac-secrets-demo
```
Expected: a pull-blocked event referencing the registry policy.

**Stricter alternative — allow-list mode:**
```bash
oc patch image.config.openshift.io/cluster --type=merge -p '
{
  "spec": {
    "registrySources": {
      "allowedRegistries": ["quay.io", "registry.redhat.io", "image-registry.openshift-image-registry.svc:5000"]
    }
  }
}'
```

**Cleanup:**
```bash
oc patch image.config.openshift.io/cluster --type=merge -p '{"spec":{"registrySources":null}}'
```

> ⚠️ `registrySources` is **cluster-wide** — it affects every namespace, not just `rbac-secrets-demo`. Test only on a sandbox/dev cluster, and note that since this demo's image was pulled from `docker.io/dipakrasal2009/rbac-secrets-demo`, blocking `docker.io` cluster-wide would also break this app's own image pulls on pod restarts.

---

## Summary of issues hit and fixes

| Issue | Cause | Fix |
|---|---|---|
| `oc login` → `401 Unauthorized` for `admin-user` / `edit-user` | Repeated `htpasswd -c` flag wiped the file each time, leaving only the last user | Use `-c` only on the first `htpasswd` command; omit it for subsequent users |
| New pod stuck with 0 replicas after patching `runAsUser: 0` | `restricted-v2` SCC blocks root explicitly | Either drop the root requirement, or grant a custom SCC (`allow-root-scc`) to the pod's ServiceAccount |
| `oc auth can-i delete project ... --as=admin-user` errored | `project` isn't a valid two-word resource for `auth can-i` the way it was typed | Use `oc auth can-i delete project/rbac-secrets-demo --as=admin-user` instead |
| `oc get ns` denied for `view-user` | `view` ClusterRole is namespace-scoped via RoleBinding, not a ClusterRoleBinding | Expected behavior — `view-user` only has rights inside `rbac-secrets-demo`, not cluster-wide |

---

## Useful inspection commands
```bash
oc get scc
oc describe pod <pod> -n rbac-secrets-demo | grep scc
oc get rolebindings -n rbac-secrets-demo
oc adm policy who-can list pods -n rbac-secrets-demo
oc get oauthaccesstokens
oc whoami
oc whoami -t
oc whoami --show-server
```
