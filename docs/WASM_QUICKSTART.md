# WASM on Kubernetes

Run WebAssembly workloads using Spin Operator and containerd-shim-spin.

**Live Example**: http://192.168.178.115/hello

**Learn More**: [Building a WebAssembly Application - Blog Post](https://medium.com/@piotrzan/building-a-webassembly-application-b3e3c7e83e3a)

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
kubectl get pods -l core.spinkube.dev/app-name=hello-spin

# Test HTTP endpoints (LoadBalancer)
curl http://192.168.178.115/hello
curl http://192.168.178.115/go-hello

# Or via port-forward (ClusterIP)
kubectl port-forward svc/hello-spin 8080:80
curl localhost:8080/hello
```

**Available Routes**:
- `/hello` - Simple "Hello world from Spin!" response
- `/go-hello` - Detailed request info and "Hello Spin Shim!" response

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

**Complete Tutorial**: See the [Building a WebAssembly Application](https://medium.com/@piotrzan/building-a-webassembly-application-b3e3c7e83e3a) blog post for detailed instructions on creating, building, and packaging Spin apps.

**Quick Start**:

```bash
# Install Spin CLI
curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash
mv spin /usr/local/bin/spin

# Add WASM target for Rust
rustup target add wasm32-wasi

# Update Spin templates
spin templates install --update

# Create new app
spin new http-rust my-app
cd my-app

# Build
spin build

# Test locally
spin up

# In another terminal, test it
curl http://localhost:3000

# Push to registry (example using ttl.sh for ephemeral hosting)
APP_PREFIX=$(echo $RANDOM)
spin registry push --build ttl.sh/"$APP_PREFIX"my-app:1h

# Deploy to Kubernetes (requires spin kube plugin)
spin plugin install kube -y
spin kube scaffold --from ttl.sh/"$APP_PREFIX"my-app:1h --out spinapp.yaml
kubectl apply -f spinapp.yaml
```

**Using Your Own Registry**:

```bash
# Push to GitHub Container Registry (requires authentication)
spin registry push ghcr.io/your-org/my-app:v1.0.0

# Push to Docker Hub
spin registry push docker.io/your-username/my-app:v1.0.0
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

## Architecture Comparison

**Traditional Containers**:
```
Application → Container Runtime → Kernel → Hardware
```

**WebAssembly (Spin)**:
```
Application → WASM Runtime → containerd-shim-spin → Hardware
```

The WASM approach eliminates OS-level overhead, resulting in faster startup times and lower resource consumption.

## Version Notes

This guide uses **Spin Operator v0.6.1** (Nov 2025). For building Spin apps from scratch, see the [blog post](https://medium.com/@piotrzan/building-a-webassembly-application-b3e3c7e83e3a) which covers the developer workflow with earlier versions.

**Key Differences from v0.2.0**:
- No KWasm Operator dependency (uses native node-installer DaemonSet)
- SpinApp CRD changes: `runtimeClassName` field removed
- containerd config path: `plugins."io.containerd.cri.v1.runtime"` (not `grpc.v1.cri`)
- Direct OCI Helm chart installation

## Next Steps

1. Try the example app: http://192.168.178.115/hello
2. Read the [building Spin apps guide](https://medium.com/@piotrzan/building-a-webassembly-application-b3e3c7e83e3a)
3. Build your own Spin app using the guide above
4. Add more nodes: `kubectl label node kube-worker2 spin=true`
5. Explore [SpinKube docs](https://www.spinkube.dev/docs/)
6. Deep dive into [WebAssembly](https://developer.mozilla.org/en-US/docs/WebAssembly)
