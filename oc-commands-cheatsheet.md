# OpenShift `oc` CLI – Commands Cheatsheet

## ── CLUSTER & LOGIN ─────────────────────────────────────────

# Login to cluster
oc login https://api.<cluster>.<domain>:6443 -u kubeadmin -p <password>

# Login with token
oc login --token=<token> --server=https://api.<cluster>.<domain>:6443

# View current context / cluster info
oc whoami
oc cluster-info
oc version

# Switch between clusters
oc config get-contexts
oc config use-context <context-name>


## ── PROJECTS (NAMESPACES) ───────────────────────────────────

oc new-project demo-app                      # Create a new project
oc project demo-app                          # Switch to a project
oc get projects                              # List all projects
oc delete project demo-app                   # Delete a project


## ── APPLY / DELETE MANIFESTS ────────────────────────────────

oc apply -f deployment.yaml                  # Apply a single manifest
oc apply -f .                                # Apply all YAMLs in current dir
oc apply -f openshift-manifests.yaml         # Apply the sample manifest file
oc delete -f deployment.yaml                 # Delete resources from manifest
oc diff -f deployment.yaml                   # Preview changes before applying


## ── PODS ────────────────────────────────────────────────────

oc get pods                                  # List pods (current project)
oc get pods -n demo-app                      # List pods in specific namespace
oc get pods -o wide                          # Show node assignment
oc get pods --all-namespaces                 # All namespaces
oc describe pod <pod-name>                   # Detailed pod info
oc logs <pod-name>                           # View logs
oc logs <pod-name> -f                        # Stream (follow) logs
oc logs <pod-name> --previous               # Logs from crashed container
oc exec -it <pod-name> -- /bin/bash          # Shell into a pod
oc exec -it <pod-name> -- env                # List env vars in pod
oc delete pod <pod-name>                     # Delete (restarts via Deployment)


## ── DEPLOYMENTS ─────────────────────────────────────────────

oc get deployments
oc describe deployment nginx-deployment
oc scale deployment nginx-deployment --replicas=4     # Scale manually
oc rollout status deployment/nginx-deployment         # Watch rollout
oc rollout history deployment/nginx-deployment        # View history
oc rollout undo deployment/nginx-deployment           # Rollback
oc set image deployment/nginx-deployment nginx=nginx:1.25  # Update image


## ── SERVICES & ROUTES ───────────────────────────────────────

oc get services
oc get svc -n demo-app
oc describe svc nginx-service

oc get routes                                # List all routes
oc describe route nginx-route
oc expose svc nginx-service                  # Auto-create a route from service
oc delete route nginx-route


## ── CONFIGMAPS & SECRETS ────────────────────────────────────

oc get configmaps
oc describe configmap app-config
oc create configmap my-config --from-literal=KEY=VALUE
oc create configmap my-config --from-file=app.properties

oc get secrets
oc describe secret app-secret
oc create secret generic my-secret --from-literal=password=mypass
oc get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d


## ── PERSISTENT VOLUMES ──────────────────────────────────────

oc get pvc                                   # Persistent Volume Claims
oc get pv                                    # Persistent Volumes (cluster-wide)
oc describe pvc app-pvc


## ── NODES ───────────────────────────────────────────────────

oc get nodes
oc get nodes -o wide
oc describe node <node-name>
oc adm top nodes                             # CPU/Memory usage per node
oc adm top pods                              # CPU/Memory usage per pod


## ── EVENTS & DEBUGGING ──────────────────────────────────────

oc get events                                # Events in current namespace
oc get events --sort-by=.lastTimestamp       # Sorted by time
oc get events -n demo-app

# Debug a failing pod
oc debug pod/<pod-name>
oc debug node/<node-name>                    # SSH-like access to a node

# Port-forward to test locally
oc port-forward svc/nginx-service 8080:80
oc port-forward pod/<pod-name> 8080:80


## ── BUILDS & IMAGESTREAMS (OpenShift-specific) ──────────────

oc get builds
oc get buildconfigs
oc start-build my-app-build                  # Trigger a build manually
oc logs -f bc/my-app-build                   # Stream build logs
oc get imagestreams
oc describe imagestream my-app-image


## ── RBAC & SERVICE ACCOUNTS ─────────────────────────────────

oc get serviceaccounts
oc create serviceaccount demo-sa
oc adm policy add-role-to-user edit developer -n demo-app
oc adm policy add-cluster-role-to-user cluster-admin <username>
oc get rolebindings -n demo-app


## ── RESOURCE QUOTAS & LIMITS ────────────────────────────────

oc get resourcequota
oc describe resourcequota demo-quota
oc get limitrange


## ── OPERATOR / CRD INSPECTION ───────────────────────────────

oc get crds                                  # All Custom Resource Definitions
oc get operators -n openshift-operators
oc get csv -n openshift-operators            # ClusterServiceVersions


## ── CLUSTER OPERATORS & HEALTH ──────────────────────────────

oc get clusteroperators                      # All cluster operators status
oc get clusterversion                        # Cluster version & upgrade status
oc adm upgrade                               # Check available upgrades


## ── USEFUL OUTPUT FORMATS ───────────────────────────────────

oc get pods -o json                          # JSON output
oc get pods -o yaml                          # YAML output
oc get pods -o jsonpath='{.items[*].metadata.name}'   # Extract field values
oc get pods --no-headers | awk '{print $1}' # Parse names with awk


## ── QUICK PRACTICE SEQUENCE ─────────────────────────────────
# Run through this to practice the full lifecycle:

# 1. Create project
oc new-project demo-app

# 2. Apply all manifests
oc apply -f openshift-manifests.yaml

# 3. Watch pods come up
oc get pods -w

# 4. Check the route URL
oc get routes

# 5. Scale up
oc scale deployment nginx-deployment --replicas=4

# 6. Check HPA
oc get hpa

# 7. View resource usage
oc adm top pods

# 8. Clean up
oc delete project demo-app
