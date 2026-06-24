from flask import Flask, jsonify
import os
from kubernetes import client, config

app = Flask(__name__)

# Loads the in-cluster config using the ServiceAccount token
# that OpenShift automatically mounts into the pod.
k8s_loaded = True
k8s_error = None
try:
    config.load_incluster_config()
except Exception as e:
    k8s_loaded = False
    k8s_error = str(e)


@app.route("/")
def home():
    return jsonify({
        "app": "rbac-secrets-demo",
        "endpoints": {
            "/health": "liveness check",
            "/secret": "shows values loaded from a Kubernetes Secret",
            "/pods": "uses the pod's ServiceAccount to list pods (tests RBAC)"
        }
    })


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/secret")
def show_secret():
    username = os.environ.get("APP_USERNAME", "not-set")
    password = os.environ.get("APP_PASSWORD", "not-set")
    masked = (password[:2] + "***") if password != "not-set" else "not-set"
    return jsonify({
        "source": "Kubernetes Secret 'app-credentials' injected as env vars",
        "username": username,
        "password_masked": masked
    })


@app.route("/pods")
def list_pods():
    if not k8s_loaded:
        return jsonify({
            "rbac_test": "error",
            "details": "Could not load in-cluster config: " + str(k8s_error)
        }), 500

    namespace = os.environ.get("POD_NAMESPACE", "default")
    v1 = client.CoreV1Api()
    try:
        pods = v1.list_namespaced_pod(namespace=namespace)
        pod_names = [p.metadata.name for p in pods.items]
        return jsonify({
            "namespace": namespace,
            "rbac_test": "success - ServiceAccount is authorized to list pods",
            "pods": pod_names
        })
    except client.exceptions.ApiException as e:
        return jsonify({
            "namespace": namespace,
            "rbac_test": "failed - ServiceAccount is NOT authorized (check Role/RoleBinding)",
            "status_code": e.status,
            "reason": e.reason
        }), e.status


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
