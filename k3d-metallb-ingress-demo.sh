#!/bin/bash

set -e

CLUSTER_NAME="test"
METALLB_SUBNET="172.18.0.0/16"   # Will auto-detect, fallback value here
METALLB_RANGE="172.18.255.200-172.18.255.250"

echo "1. Create k3d cluster (3 servers, 3 agents, no k3d loadbalancer)..."
k3d cluster create $CLUSTER_NAME \
  --servers 3 \
  --agents 3 \
  --no-lb \
  --k3s-arg "--disable=traefik@server:0"

echo "2. Install MetalLB (native mode)..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

echo "3. Wait for MetalLB pods to be ready..."
kubectl wait --namespace metallb-system --for=condition=Ready pod --selector=app=metallb --timeout=90s

# Auto-detect the Docker network subnet for the cluster
DOCKER_NET=$(docker network inspect k3d-$CLUSTER_NAME | grep Subnet | head -n 1 | awk -F '"' '{print $4}')
if [ -n "$DOCKER_NET" ]; then
  echo "Detected k3d Docker network subnet: $DOCKER_NET"
  METALLB_SUBNET="$DOCKER_NET"
  # Use last /24 for address pool
  IFS='.' read -r i1 i2 i3 i4 <<< "${METALLB_SUBNET%%/*}"
  METALLB_RANGE="$i1.$i2.255.200-$i1.$i2.255.250"
fi

echo "4. Configure MetalLB IPAddressPool ($METALLB_RANGE)..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: my-ip-pool
  namespace: metallb-system
spec:
  addresses:
    - $METALLB_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
EOF

echo "5. Install NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/cloud/deploy.yaml

echo "6. Patch Ingress controller service to LoadBalancer..."
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p '{"spec": {"type": "LoadBalancer"}}'

echo "Waiting for ingress-nginx pods to be ready..."
sleep 120

echo "7. Wait for Ingress controller external IP (via MetalLB)..."
for i in {1..30}; do
  INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$INGRESS_IP" ] && break
  sleep 3
done

if [ -z "$INGRESS_IP" ]; then
  echo "Failed to get external IP for Ingress controller! Exiting."
  exit 1
fi
echo "NGINX Ingress External IP (MetalLB): $INGRESS_IP"

echo "8. Deploy sample apps and services..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: hashicorp/http-echo
        args: ["-text=Hello from app1"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app1
spec:
  selector:
    app: app1
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: app2
        image: hashicorp/http-echo
        args: ["-text=Hello from app2"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app2
spec:
  selector:
    app: app2
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5678
EOF

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
    - host: app1.localtest.acmeaws.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app1
                port:
                  number: 80
    - host: app2.localtest.acmeaws.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app2
                port:
                  number: 80
EOF

echo "9. Set up iptables port forwarding (80, 443) from host to MetalLB IP..."
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $INGRESS_IP:80
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j DNAT --to-destination $INGRESS_IP:443
sudo iptables -t nat -A POSTROUTING -j MASQUERADE

echo "10. Done!"
echo ""
echo "You can now test your services:"
echo "  http://app1.localtest.acmeaws.com/"
echo "  http://app2.localtest.acmeaws.com/"
echo "Both should resolve to your host's IP (use /etc/hosts for custom domains if needed), or just use localtest.me for convenience."
echo ""
echo "To expose to the real Internet, port-forward 80 and 443 from your home router to this machine."