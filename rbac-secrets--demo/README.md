# RBAC & Secrets Test App (OpenShift)

A minimal Flask app for **testing RBAC and Secrets** on OpenShift. It exposes three endpoints:

| Endpoint  | Purpose                                                                                   |
|-----------|--------------------------------------------------------------------------------------------|
| `/health` | Basic liveness check                                                                       |
| `/secret` | Reads values from a Kubernetes **Secret** (`app-credentials`), injected as env vars         |
| `/pods`   | Uses the pod's **ServiceAccount** token to call the K8s API and list pods — fails without the right Role/RoleBinding |

This separation matters: `/`, `/health`, and `/secret` are reachable via the Service/Route regardless of RBAC — that's just normal HTTP traffic to the pod. **Only `/pods` actually exercises RBAC**, because it's the only thing that calls the Kubernetes API server using the ServiceAccount's token.

---

## Project structure

```
rbac-secrets-demo/
├── app/
│   ├── app.py            # Flask application
│   ├── requirements.txt
│   └── Dockerfile
└── manifests/
    ├── 00-namespace.yaml
    ├── 01-serviceaccount.yaml
    ├── 02-secret.yaml
    ├── 03-role.yaml
    ├── 04-rolebinding.yaml
    ├── 05-deployment.yaml
    ├── 06-service.yaml
    └── 07-route.yaml
```

---

## 1. Build and push the image

You need access to a container registry (Quay, Docker Hub, or OpenShift's internal registry).

```bash
cd app
docker build -t <your-registry>/rbac-secrets-demo:latest .
docker push <your-registry>/rbac-secrets-demo:latest
```

Then edit `manifests/05-deployment.yaml` and replace:
```yaml
image: <YOUR_REGISTRY>/rbac-secrets-demo:latest
```
with your actual image reference.

---

## 2. Deploy to OpenShift

```bash
oc apply -f manifests/
```

This creates, in order:
1. **Namespace** `rbac-secrets-demo`
2. **ServiceAccount** `rbac-demo-sa`
3. **Secret** `app-credentials` (username/password)
4. **Role** `pod-reader` — grants `get/list/watch` on `pods`
5. **RoleBinding** — binds the Role to `rbac-demo-sa`
6. **Deployment** — runs the app under `rbac-demo-sa`, injects the Secret as env vars
7. **Service** + **Route** — exposes the app

Get the route:
```bash
oc get route rbac-secrets-demo -n rbac-secrets-demo
```

---

## 3. Test the Secret

```bash
curl https://<route-host>/secret
```
Expected response — username in plain text, password masked:
```json
{
  "source": "Kubernetes Secret 'app-credentials' injected as env vars",
  "username": "demo-user",
  "password_masked": "Su***"
}
```

---

## 4. Test RBAC

### 4a. Confirm it works initially
```bash
curl https://<route-host>/pods
```
Expected:
```json
{
  "namespace": "rbac-secrets-demo",
  "rbac_test": "success - ServiceAccount is authorized to list pods",
  "pods": ["rbac-secrets-demo-xxxxxxx-yyyyy"]
}
```

### 4b. Remove the RoleBinding and retest
```bash
oc delete rolebinding rbac-demo-sa-pod-reader-binding -n rbac-secrets-demo
curl https://<route-host>/pods
```
Expected — a 403:
```json
{
  "rbac_test": "failed - ServiceAccount is NOT authorized (check Role/RoleBinding)",
  "status_code": 403,
  "reason": "Forbidden"
}
```

### 4c. Re-apply and confirm it works again
```bash
oc apply -f manifests/04-rolebinding.yaml
curl https://<route-host>/pods
```

> **Note:** `/`, `/health`, and `/secret` will keep working the entire time — removing the RoleBinding only blocks calls to the Kubernetes API server, not network access to the pod itself.

---

## 5. Verify RBAC directly (no app required)

You can test the ServiceAccount's permissions without going through the app at all:

```bash
oc auth can-i list pods \
  --as=system:serviceaccount:rbac-secrets-demo:rbac-demo-sa \
  -n rbac-secrets-demo
```
Returns `yes` or `no` depending on whether the RoleBinding exists.

### If `/pods` still works after deleting the RoleBinding
Check for a broader grant elsewhere in the cluster:
```bash
oc get clusterrolebinding -o wide | grep rbac-demo-sa
oc adm policy who-can list pods -n rbac-secrets-demo
```
A ClusterRoleBinding, or a cluster-wide grant to `system:authenticated` / `system:serviceaccounts`, would explain continued access even with the namespaced RoleBinding removed.

---

## 6. Cleanup

```bash
oc delete namespace rbac-secrets-demo
```
This removes everything created above in one shot.
