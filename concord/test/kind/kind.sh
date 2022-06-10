#!/bin/sh
set -o errexit

# Based on https://sookocheff.com/post/kubernetes/local-kubernetes-development-with-kind/

reg_name='kind-registry'
reg_port='5000'
k8s_version='1.19.11'

# Start a local Docker registry (unless it already exists)
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run \
    -d --restart=always -p "${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

# Create a kind cluster
# - Configures containerd to use the local Docker registry
# - Enables Ingress on ports 80 and 443
cat <<EOF | kind create cluster --image kindest/node:v${k8s_version} --wait 5m --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

# Connect the local Docker registry with the kind network
docker network connect "kind" "${reg_name}" > /dev/null 2>&1 &

# Deploy the nginx Ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml

echo

# Wait for nginx ingress controller to be ready
for i in {1..6}
do
  echo "Attempting to query nginx ingress ready status ..."
  kubectl wait \
    --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s > /dev/null 2>&1 && break || sleep 10
done

if [ "${deleteWebHook}" = "true" ]
then
  kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
fi
