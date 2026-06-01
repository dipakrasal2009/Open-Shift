# openshift_blue_green_deployment

# Perform in-place Kubernetes updates with a Blue/Green Deployment




oc new-app quay.io/rhdevelopers/gethostname:v1 --name gethostname-v1

oc expose service/gethostname-v1 --name gethostname-microservice

oc get routes

for ((i=1;i<=10000;i++)); do curl http://gethostname-microservice-rhn-engineering-foo-dev.apps.sandbox.x8i5.p1.openshiftapps.com/hostname; echo -e; sleep .01; done;


oc new-app quay.io/rhdevelopers/gethostname:v2 --name gethostname-v2

oc patch route/gethostname-microservice -p '{"spec": {"to": {"name": "gethostname-v2" }}}'

oc patch route/gethostname-microservice -p '{"spec": {"to": {"name": "gethostname-v1" }}}'
