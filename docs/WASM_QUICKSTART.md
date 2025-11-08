# WASM on Kubernetes

Run WebAssembly workloads using Spin Operator and containerd-shim-spin.

## Setup (5 Commands)

```bash
# 1. Label node for WASM workloads
kubectl label node kube-worker1 spin=true

# 2. Deploy Spin Operator via ArgoCD
kubectl apply -f gitops/clusters/homelab/spin-operator.yaml

# 3. Configure containerd on target node
scp scripts/configure-containerd-spin.sh decoder@kube-worker1:/tmp/
ssh decoder@kube-worker1 "sudo bash /tmp/configure-containerd-spin.sh"

# 4. Verify setup
kubectl get runtimeclass wasmtime-spin-v2
kubectl get pods -n spin-operator

# 5. Deploy example app
kubectl apply -f gitops/apps/spin-example-app.yaml
```

## Test

```bash
# Check app
kubectl get spinapp
kubectl get pods -l app=hello-spin

# Test HTTP endpoint
kubectl port-forward svc/hello-spin 8080:80
curl localhost:8080
```

## Deploy Your Own WASM App

```yaml
apiVersion: core.spinkube.dev/v1alpha1
kind: SpinApp
metadata:
  name: my-app
  namespace: default
spec:
  image: ghcr.io/your-org/my-app:v1.0.0
  replicas: 2
  executor: containerd-shim-spin
  runtimeClassName: wasmtime-spin-v2
  resources:
    requests:
      cpu: "10m"      # WASM is very efficient!
      memory: "16Mi"
    limits:
      cpu: "100m"
      memory: "64Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
```

## Build Spin Apps

```bash
# Install Spin CLI
curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash

# Create new app
spin new http-rust my-app
cd my-app

# Build
spin build

# Test locally
spin up

# Push to registry
spin registry push ghcr.io/your-org/my-app:v1.0.0
```

## Debug

```bash
# Operator status
kubectl get pods -n spin-operator
kubectl logs -n spin-operator -l app=spin-operator

# List all SpinApps
kubectl get spinapp -A

# App logs
kubectl logs -l app=my-app

# Pod details
kubectl describe pod <pod-name>

# Node installer status
kubectl logs -n spin-operator -l app=spin-node-installer
```

## Architecture

```
SpinApp CRD → Spin Operator → Deployment → Pods (RuntimeClass: wasmtime-spin-v2)
                                              ↓
                                          containerd
                                              ↓
                                      containerd-shim-spin
                                              ↓
                                          WASM Runtime
```

## Files

| File | Purpose |
|------|---------|
| `gitops/clusters/homelab/spin-operator.yaml` | ArgoCD app |
| `gitops/infra/spin-operator.yaml` | Operator deployment |
| `gitops/infra/spin-operator-crds.yaml` | SpinApp CRD |
| `gitops/infra/spin-operator-runtimeclass.yaml` | RuntimeClass |
| `gitops/infra/spin-node-setup.yaml` | DaemonSet installer |
| `gitops/apps/spin-example-app.yaml` | Example SpinApp |
| `scripts/configure-containerd-spin.sh` | Node config script |

## Why WASM?

- **10x resource efficiency**: 10m CPU vs 100m for containers
- **Sub-millisecond startup**: Cold start in <1ms
- **Portable**: Same binary runs on ARM/x86
- **Secure**: Sandboxed by default, no syscalls
- **Polyglot**: Rust, Go, JS, Python, C++

## Next Steps

1. Try the example app
2. Build your own Spin app
3. Add more nodes: `kubectl label node kube-worker2 spin=true`
4. Explore [SpinKube docs](https://www.spinkube.dev/docs/)
