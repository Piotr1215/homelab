# HTTPRoute Webhook

Automatically generates Gateway API HTTPRoutes and ReferenceGrants from Service annotations.

## Problem Solved

Kubernetes Gateway API (and Traefik, NGINX) require explicit routing resources (HTTPRoute/IngressRoute) for each service. This webhook automates route generation from Service annotations - a capability missing from all major ingress controllers.

## How It Works

1. **Annotate your Service:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  annotations:
    gateway.homelab.local/expose: "true"
    gateway.homelab.local/hostname: "myapp.homelab.local"
spec:
  ports:
  - port: 80
```

2. **Webhook automatically creates:**
   - HTTPRoute pointing to your service
   - ReferenceGrant for cross-namespace access
   - Owner references for garbage collection

3. **Result:**
   - `https://myapp.homelab.local` → your service
   - Certificate auto-generated (via cert-manager + Gateway annotation)
   - DNS auto-resolves (via dnsmasq wildcard or ExternalDNS)

## Annotations

| Annotation | Required | Default | Description |
|------------|----------|---------|-------------|
| `gateway.homelab.local/expose` | Yes | - | Set to `"true"` to enable |
| `gateway.homelab.local/hostname` | Yes | - | DNS hostname (e.g., `myapp.homelab.local`) |
| `gateway.homelab.local/gateway` | No | `homelab-gateway` | Gateway name |
| `gateway.homelab.local/gateway-namespace` | No | `envoy-gateway-system` | Gateway namespace |
| `gateway.homelab.local/port` | No | First service port | Service port number |

## Installation

### Prerequisites

- Kubernetes 1.28+
- cert-manager (for webhook TLS)
- Gateway API CRDs
- A configured Gateway (e.g., Envoy Gateway, Traefik)

### Deploy via Helm

```bash
cd webhooks/httproute-webhook/deploy/helm
helm install httproute-webhook ./httproute-webhook \
  --namespace httproute-webhook \
  --create-namespace
```

### Build & Push Image

```bash
cd webhooks/httproute-webhook
docker build -t ghcr.io/piotr1215/httproute-webhook:0.1.0 .
docker push ghcr.io/piotr1215/httproute-webhook:0.1.0
```

## Architecture

```
Service (annotated)
    ↓
Webhook intercepts CREATE/UPDATE
    ↓
Generates HTTPRoute + ReferenceGrant
    ↓
Gateway routes traffic
    ↓
cert-manager provides TLS
    ↓
DNS resolves (dnsmasq/ExternalDNS)
```

## Fully Declarative HTTPS

This webhook completes the automation stack:

- ✓ **Certificates:** cert-manager + Gateway annotation
- ✓ **DNS:** dnsmasq wildcard or ExternalDNS
- ✓ **Routes:** This webhook (fills the ecosystem gap)

Result: **100% declarative HTTPS** - just annotate services!

## Example

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: prometheus
  annotations:
    gateway.homelab.local/expose: "true"
    gateway.homelab.local/hostname: "grafana.homelab.local"
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
```

**Auto-generated resources:**
- HTTPRoute: `envoy-gateway-system/prometheus-grafana`
- ReferenceGrant: `prometheus/grafana-backend`

**Access:** `https://grafana.homelab.local` (TLS + DNS automatic)

## Cleanup

When a Service is deleted, HTTPRoute and ReferenceGrant are automatically deleted (owner references).

## Development

```bash
# Run locally
go run cmd/webhook/main.go

# Build
make build

# Test
make test
```

## License

Apache 2.0
