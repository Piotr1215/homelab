# Build and Deploy Guide

## Build Image

```bash
cd webhooks/httproute-webhook

# Login to Harbor (first time only)
make harbor-login
# Username: admin
# Password: <your-harbor-password>

# Build Docker image
make docker-build

# Push to Harbor
make docker-push
```

## Deploy to Cluster

```bash
# Deploy webhook via Helm
make deploy

# Or manually:
helm upgrade --install httproute-webhook deploy/helm/httproute-webhook \
  --namespace httproute-webhook \
  --create-namespace

# Verify deployment
kubectl get pods -n httproute-webhook
kubectl logs -n httproute-webhook -l app.kubernetes.io/name=httproute-webhook
```

## Test

Create a test service with annotations:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: default
  annotations:
    gateway.homelab.local/expose: "true"
    gateway.homelab.local/hostname: "test.homelab.local"
spec:
  selector:
    app: test
  ports:
  - port: 80
EOF
```

Check if HTTPRoute was created:

```bash
kubectl get httproute -n envoy-gateway-system
kubectl get referencegrant -n default
```

Test DNS and HTTPS:

```bash
curl -k https://test.homelab.local
```

## Troubleshooting

Check webhook logs:

```bash
kubectl logs -n httproute-webhook -l app.kubernetes.io/name=httproute-webhook -f
```

Check webhook configuration:

```bash
kubectl get mutatingwebhookconfiguration
kubectl describe mutatingwebhookconfiguration httproute-webhook
```

Check certificate:

```bash
kubectl get certificate -n httproute-webhook
kubectl describe certificate -n httproute-webhook httproute-webhook
```
