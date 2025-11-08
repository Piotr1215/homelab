# Kubernetes Resource Templates - MCP-style Automation System

This directory contains an MCP-style template system for generating common Kubernetes resources in the homelab repository. The system provides fully automated resource generation from simple configuration files.

## Overview

The template system allows you to:
- Generate Kubernetes resources from simple YAML, JSON, or shell variable configs
- Maintain consistency across your homelab deployments
- Reduce errors through standardized templates
- Validate resources before committing
- Support both new resource creation and updates

## Directory Structure

```
.k8s-templates/
├── README.md                              # This file
├── *.yaml.tmpl                           # Template files
├── examples/                             # Example configuration files
│   ├── argocd-app-example.yaml
│   ├── deployment-service-example.yaml
│   ├── helm-app-example.yaml
│   ├── externalsecret-example.yaml
│   ├── configmap-example.yaml
│   └── cronjob-example.yaml
└── schemas/                              # JSON schemas for validation (optional)
```

## Available Templates

### ArgoCD Applications

1. **argocd-app-directory** - ArgoCD Application with Git directory source
2. **argocd-app-helm** - ArgoCD Application with Helm chart source
3. **argocd-app-multisource** - ArgoCD Application with multiple sources (Helm + values from Git)

### Kubernetes Resources

4. **deployment-service** - Deployment + Service combo
5. **configmap** - ConfigMap
6. **externalsecret** - ExternalSecret for external secret stores
7. **ingress** - Ingress resource
8. **cronjob** - CronJob
9. **pvc** - PersistentVolumeClaim
10. **namespace** - Namespace
11. **serviceaccount-rbac** - ServiceAccount + ClusterRole + ClusterRoleBinding

## Usage

### Basic Usage

```bash
# Generate a resource from a config file
./scripts/k8s-resource-generator.sh <template-type> <config-file>

# Example: Create an ArgoCD Application
./scripts/k8s-resource-generator.sh argocd-app-directory my-app-config.yaml
```

### Options

```bash
-o, --output <dir>      # Output directory (default: gitops/<type>)
-f, --file <name>       # Output filename (auto-generated if not specified)
-v, --validate          # Validate generated resources with kubectl
-d, --dry-run           # Print output to stdout instead of file
-l, --list              # List available templates
-h, --help              # Show help message
```

### Examples

#### Example 1: Create a New ArgoCD Application

1. Create a config file `my-app.yaml`:
```yaml
app_name: redis
source_path: gitops/apps/redis
namespace: redis
project: applications
```

2. Generate the resource:
```bash
./scripts/k8s-resource-generator.sh argocd-app-directory my-app.yaml
```

3. Output will be created at: `gitops/clusters/homelab/redis.yaml`

#### Example 2: Deploy a Helm Chart via ArgoCD

1. Create a config file `loki-config.yaml`:
```yaml
app_name: loki
chart_name: loki
chart_repo_url: https://grafana.github.io/helm-charts
chart_version: 6.0.0
namespace: logging
project: infrastructure
helm_values: |
  loki:
    auth_enabled: false
    storage:
      type: filesystem
```

2. Generate:
```bash
./scripts/k8s-resource-generator.sh argocd-app-helm loki-config.yaml
```

#### Example 3: Create Deployment + Service

1. Create config `web-app.yaml`:
```yaml
app_name: my-web-app
image: nginx:latest
namespace: default
replicas: 2
container_port: 80
service_type: LoadBalancer
service_port: 80
cpu_request: 100m
memory_request: 128Mi
```

2. Generate with validation:
```bash
./scripts/k8s-resource-generator.sh -v deployment-service web-app.yaml
```

#### Example 4: Dry Run (Preview Output)

```bash
./scripts/k8s-resource-generator.sh -d argocd-app-directory my-app.yaml
```

#### Example 5: Custom Output Location

```bash
./scripts/k8s-resource-generator.sh \
  -o gitops/apps \
  -f custom-name.yaml \
  deployment-service my-app.yaml
```

## Configuration File Formats

### YAML Format (Recommended)

```yaml
app_name: my-app
namespace: default
image: nginx:latest
replicas: 3
```

### JSON Format

```json
{
  "app_name": "my-app",
  "namespace": "default",
  "image": "nginx:latest",
  "replicas": 3
}
```

### Shell Variables Format

```bash
export APP_NAME="my-app"
export NAMESPACE="default"
export IMAGE="nginx:latest"
export REPLICAS=3
```

## Template Variable Reference

### Common Variables

All variable names should be in lowercase in config files (automatically converted to uppercase internally):

- `app_name` - Application name (required for most templates)
- `namespace` - Kubernetes namespace (default: default)
- `labels` - Custom labels (YAML block)

### ArgoCD Application Variables

- `project` - ArgoCD project (default: applications or default)
- `repo_url` - Git repository URL
- `source_path` - Path in repository
- `target_revision` - Git branch/tag (default: HEAD)
- `auto_prune` - Enable auto-pruning (default: true)
- `auto_self_heal` - Enable self-healing (default: true)
- `sync_wave` - Sync wave for ordering
- `chart_name` - Helm chart name
- `chart_repo_url` - Helm chart repository
- `chart_version` - Helm chart version

### Deployment Variables

- `image` - Container image
- `replicas` - Number of replicas (default: 1)
- `container_port` - Container port
- `service_type` - Service type (ClusterIP, LoadBalancer, NodePort)
- `cpu_request`, `memory_request` - Resource requests
- `cpu_limit`, `memory_limit` - Resource limits

### Advanced Features

#### Multi-line Values

For complex YAML blocks (like env vars, volumes, etc.), use the pipe operator:

```yaml
env_vars: |
  - name: DATABASE_URL
    value: "postgresql://localhost/mydb"
  - name: SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: app-secrets
        key: secret-key
```

#### Conditional Sections

Templates support conditional sections. If a variable is set, its section will be included:

```yaml
# In config file
load_balancer_ip: 192.168.178.100

# This will include the loadBalancerIP field in the output
```

#### Default Values

Many fields have sensible defaults based on homelab conventions:
- Storage class: `local-path`
- Auto-prune: `true`
- Auto-heal: `true`
- Namespace: `default`
- Service type: `ClusterIP`

## Integration with ArgoCD

Generated resources are automatically placed in appropriate directories:

- ArgoCD Applications → `gitops/clusters/homelab/`
- Other resources → `gitops/apps/`

After generation:
1. Review the file
2. Commit to Git
3. Push to trigger ArgoCD sync

```bash
git add gitops/clusters/homelab/my-app.yaml
git commit -m "Add my-app ArgoCD application"
git push
```

## Best Practices

1. **Use YAML configs** - More readable and supports multi-line values
2. **Start with examples** - Copy from `examples/` directory and modify
3. **Validate before commit** - Use `-v` flag to validate with kubectl
4. **Preview first** - Use `-d` flag to see output before creating files
5. **Keep configs versioned** - Store config files in `configs/` directory
6. **Use sync waves** - Order ArgoCD applications properly (-2, 0, 1, 2...)

## Extending the System

To add a new template:

1. Create a new `.tmpl` file in `.k8s-templates/`
2. Use `{{VARIABLE_NAME}}` for substitution
3. Use `{{#VARIABLE}}...{{/VARIABLE}}` for conditional sections
4. Use `{{VARIABLE|default:value}}` for defaults
5. Add example config in `examples/`
6. Update this README

## Troubleshooting

### Common Issues

**Issue**: Template not found
```bash
./scripts/k8s-resource-generator.sh -l  # List available templates
```

**Issue**: Variable not substituted
- Ensure variable names are lowercase in config
- Check for typos in variable names
- Use `-d` flag to preview output

**Issue**: Validation fails
```bash
kubectl apply --dry-run=client -f <generated-file>
# Review error message and fix config
```

**Issue**: YAML parsing error
- Ensure proper indentation in multi-line blocks
- Use pipe operator `|` for multi-line values
- Check for special characters that need quoting

## Support

For issues or questions:
1. Check examples in `examples/` directory
2. Review existing resources in `gitops/` for patterns
3. Use dry-run mode to debug: `-d` flag
4. Validate with kubectl: `-v` flag

## License

Part of the homelab repository.
