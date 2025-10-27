# Harbor Container Registry Setup

Harbor is a private container registry with vulnerability scanning, image signing, and Helm chart hosting capabilities.

## Access Information

- **URL**: http://192.168.178.100
- **Default Admin Username**: `admin`
- **Default Admin Password**: `Harbor12345` (⚠️ **CHANGE THIS IMMEDIATELY**)

## Features Enabled

- **Container Registry**: Store and distribute Docker/OCI images
- **Trivy Vulnerability Scanner**: Automatic security scanning for images
- **Chartmuseum**: Helm chart repository
- **Web UI**: User-friendly interface for managing images and projects
- **RBAC**: Role-based access control for projects

## Storage Allocation

| Component | Size | Storage Class |
|-----------|------|---------------|
| Registry | 50Gi | local-path |
| PostgreSQL Database | 5Gi | local-path |
| Redis Cache | 1Gi | local-path |
| Trivy Scanner | 5Gi | local-path |
| JobService | 1Gi | local-path |

## Initial Setup

### 1. Change Default Password

```bash
# Access Harbor UI at http://192.168.178.100
# Login with admin/Harbor12345
# Go to: User Profile (top right) → Change Password
```

### 2. Create Your First Project

1. Navigate to **Projects** → **New Project**
2. Set project name (e.g., `homelab`)
3. Choose **Private** or **Public** access level
4. Enable **Vulnerability scanning** for automatic scans

### 3. Configure Docker to Use Harbor

```bash
# Add Harbor as insecure registry (since we're using HTTP)
# On each node that will push/pull images:

# Edit Docker daemon config
sudo nano /etc/docker/daemon.json
```

Add:
```json
{
  "insecure-registries": ["192.168.178.100"]
}
```

Restart Docker:
```bash
sudo systemctl restart docker
```

### 4. Login to Harbor

```bash
# Login from command line
docker login 192.168.178.100
# Username: admin
# Password: Harbor12345 (or your changed password)
```

## Common Operations

### Push an Image to Harbor

```bash
# Tag your image
docker tag myapp:latest 192.168.178.100/homelab/myapp:latest

# Push to Harbor
docker push 192.168.178.100/homelab/myapp:latest
```

### Pull an Image from Harbor

```bash
docker pull 192.168.178.100/homelab/myapp:latest
```

### Use Harbor in Kubernetes

Create an image pull secret:
```bash
kubectl create secret docker-registry harbor-registry \
  --docker-server=192.168.178.100 \
  --docker-username=admin \
  --docker-password=Harbor12345 \
  --namespace=default
```

Use in pod spec:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp
spec:
  containers:
  - name: myapp
    image: 192.168.178.100/homelab/myapp:latest
  imagePullSecrets:
  - name: harbor-registry
```

## Vulnerability Scanning

Harbor automatically scans images with Trivy when pushed (if enabled in project settings).

### View Scan Results

1. Go to **Projects** → Select your project
2. Click on **Repositories** → Select a repository
3. Click on a specific tag to view scan results
4. Review vulnerabilities by severity (Critical, High, Medium, Low)

### Configure Scan Policies

1. Navigate to **Interrogation Services**
2. Configure scan schedules and policies
3. Set up CVE allowlists if needed

## Helm Chart Repository

Harbor includes Chartmuseum for hosting Helm charts.

### Add Harbor Helm Repository

```bash
# Add Harbor as a Helm repository
helm repo add harbor-homelab http://192.168.178.100/chartrepo/homelab
helm repo update
```

### Push Helm Charts

```bash
# Package your chart
helm package ./my-chart

# Install helm-push plugin
helm plugin install https://github.com/chartmuseum/helm-push

# Push to Harbor
helm cm-push my-chart-1.0.0.tgz harbor-homelab
```

## Monitoring

Harbor metrics are exposed for Prometheus scraping:
- Registry metrics
- Database connection pool metrics
- Job service metrics

## Backup

Harbor uses persistent volumes for all data:
- Registry data: `/storage` (50Gi)
- PostgreSQL data: `/var/lib/postgresql/data` (5Gi)
- Redis data: `/data` (1Gi)

These are backed up by Velero as part of cluster backups.

### Manual Database Backup

```bash
# Get Harbor database pod
kubectl get pods -n harbor | grep database

# Backup database
kubectl exec -n harbor harbor-database-0 -- \
  pg_dump -U postgres registry > harbor-backup.sql
```

## Troubleshooting

### Cannot Push Images - "unauthorized"

Check project access level and user permissions:
1. Ensure project exists
2. Verify user has at least **Developer** role
3. Confirm Docker is logged in: `docker login 192.168.178.100`

### Scan Failed

Check Trivy scanner logs:
```bash
kubectl logs -n harbor -l component=trivy
```

### Registry Storage Full

Check PVC usage:
```bash
kubectl get pvc -n harbor
kubectl exec -n harbor <registry-pod> -- df -h /storage
```

Increase storage:
```bash
# Edit harbor.yaml
# Update persistence.persistentVolumeClaim.registry.size to larger value
```

## Security Best Practices

1. **Change default password** immediately after installation
2. **Use projects** to organize images and apply access control
3. **Enable vulnerability scanning** on all projects
4. **Set up replication** for important images (to external registries)
5. **Configure garbage collection** to remove unused image layers
6. **Enable content trust** (Notary) for image signing (optional)
7. **Review access logs** regularly in Harbor UI
8. **Use robot accounts** for CI/CD automation instead of user accounts

## Upgrade

Harbor is managed by ArgoCD. To upgrade:
```bash
# Edit gitops/infra/harbor.yaml
# Update targetRevision to new version
# ArgoCD will automatically sync and upgrade
```

## Advanced Configuration

### Enable HTTPS with TLS

1. Update `harbor.yaml` expose section:
```yaml
expose:
  type: loadBalancer
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: harbor-tls
      notarySecretName: notary-tls
```

2. Create TLS secret with cert-manager or manual certificate

### Configure External Database

If you want to use an external PostgreSQL:
```yaml
database:
  type: external
  external:
    host: postgresql.example.com
    port: 5432
    username: harbor
    password: yourpassword
    coreDatabase: registry
```

### Enable Image Signing (Notary)

Update `harbor.yaml`:
```yaml
notary:
  enabled: true
```

## Resources

- Harbor Documentation: https://goharbor.io/docs
- Harbor GitHub: https://github.com/goharbor/harbor
- Trivy Scanner: https://github.com/aquasecurity/trivy
