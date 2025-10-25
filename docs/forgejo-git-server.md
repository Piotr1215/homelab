# Forgejo Git Server

## Overview

Forgejo is a self-hosted, lightweight Git server deployed in the homelab Kubernetes cluster. It provides a complete Git repository hosting solution with a web UI, REST API, and Git protocol support.

**Version:** 8.0.0 (based on Gitea 1.22.0)
**Mode:** Rootless (security-enhanced)
**Database:** SQLite (embedded, no external dependencies)

## Access Information

### Web UI
```
http://192.168.178.101:3000
```

### Admin Credentials
- **Username:** `decoder-git`
- **Email:** `piotrzan@gmail.com`
- **Password:** Stored in Bitwarden (synced via ExternalSecrets Operator)

### API Endpoint
```
http://192.168.178.101:3000/api/v1/
```

## Quick Start

### 1. Access the Web UI

Open your browser and navigate to:
```
http://192.168.178.101:3000
```

Log in with the admin credentials above.

### 2. Create a Repository

**Via Web UI:**
1. Click the **"+"** button in the top right
2. Select **"New Repository"**
3. Fill in repository details
4. Click **"Create Repository"**

**Via API:**
```bash
curl -X POST http://192.168.178.101:3000/api/v1/user/repos \
  -u "decoder-git:YOUR_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-repo",
    "description": "My repository",
    "private": false
  }'
```

### 3. Clone a Repository

**HTTPS Clone:**
```bash
git clone http://192.168.178.101:3000/decoder-git/my-repo.git
```

**Configure Git credentials (first time):**
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### 4. Push Changes

```bash
cd my-repo
git add .
git commit -m "Initial commit"
git push origin main
```

When prompted, use your Forgejo username and password.

## Features

### Enabled Features
- ✅ **Git LFS (Large File Storage)** - Store large files efficiently
- ✅ **SSH Access** - Git operations over SSH (port 2222 internal)
- ✅ **HTTP/HTTPS Access** - Git operations over HTTP
- ✅ **Web UI** - Full-featured web interface
- ✅ **REST API** - Programmatic access to all features
- ✅ **Issues & Pull Requests** - Project management features
- ✅ **Wiki** - Documentation per repository
- ✅ **Actions** - CI/CD workflows (Forgejo Actions)
- ✅ **Packages** - Container registry and package hosting
- ✅ **Organizations** - Team collaboration
- ✅ **Webhooks** - Integration with external services

### Monitoring
- **Prometheus Metrics:** Available at `/metrics` endpoint
- **Grafana Dashboard:** Available in Grafana at `http://192.168.178.96`
  - Search for "Forgejo Git Server" dashboard
  - Shows: Organizations, Repositories, Users, HTTP requests, CPU/Memory usage

## API Examples

### Get Version
```bash
curl http://192.168.178.101:3000/api/v1/version
```

### List Repositories
```bash
curl -u "decoder-git:PASSWORD" \
  http://192.168.178.101:3000/api/v1/user/repos
```

### Get Repository Info
```bash
curl -u "decoder-git:PASSWORD" \
  http://192.168.178.101:3000/api/v1/repos/decoder-git/my-repo
```

### Create Organization
```bash
curl -X POST http://192.168.178.101:3000/api/v1/orgs \
  -u "decoder-git:PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "my-org",
    "full_name": "My Organization",
    "description": "Organization for team projects"
  }'
```

## Deployment Details

### Kubernetes Resources
- **Namespace:** `git-mirror`
- **Pod:** `forgejo-*` (1 replica)
- **Service:** `forgejo-http` (LoadBalancer)
- **Storage:** 10Gi PVC (`gitea-shared-storage`)
- **Database:** SQLite at `/data/gitea/gitea.db`

### Resource Usage
- **CPU:** ~50m idle, burst to 200m during operations
- **Memory:** ~150Mi stable
- **Storage:** ~500Mi with empty repos, grows with data

### GitOps Configuration
- **ArgoCD Application:** `forgejo`
- **Helm Chart:** `oci://code.forgejo.org/forgejo-helm/forgejo:8.0.0`
- **Manifests:** `gitops/forgejo/`
- **Values:** `gitops/forgejo/forgejo-values.yaml`

### Credentials Management
Admin credentials are stored in Bitwarden and synced to Kubernetes via ExternalSecrets Operator:
- **ExternalSecret:** `forgejo-admin-credentials`
- **Bitwarden Secrets:**
  - `forgejo-admin-user`
  - `forgejo-admin-password`
  - `forgejo-admin-email`

## Backup and Disaster Recovery

### Storage
All Forgejo data is stored in a persistent volume:
- **PVC:** `gitea-shared-storage` (10Gi)
- **StorageClass:** `local-path`
- **Data:** Repositories, database, configuration

### Backup Strategy
1. **PVC Backup:** Included in Velero cluster backups
2. **Manual Backup:** Use Forgejo's built-in dump command
   ```bash
   kubectl exec -n git-mirror deployment/forgejo -- \
     gitea dump -c /data/gitea/conf/app.ini
   ```
   Creates `gitea-dump-<timestamp>.zip` with:
   - All repositories
   - Database dump
   - Configuration files

### Disaster Recovery
1. Restore from Velero backup (automatic with cluster restore)
2. Or manually restore from dump file
3. Database survives pod restarts/deletions

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -n git-mirror
```

### View Logs
```bash
kubectl logs -n git-mirror deployment/forgejo --tail=100
```

### Check LoadBalancer IP
```bash
kubectl get svc forgejo-http -n git-mirror
```

### Test API Connectivity
```bash
curl http://192.168.178.101:3000/api/v1/version
```

### Check ExternalSecret Status
```bash
kubectl get externalsecret -n git-mirror
kubectl describe externalsecret forgejo-admin-credentials -n git-mirror
```

## Links

- **Web UI:** http://192.168.178.101:3000
- **API Docs:** http://192.168.178.101:3000/api/swagger
- **Grafana Dashboard:** http://192.168.178.96 (search: "Forgejo")
- **Forgejo Docs:** https://forgejo.org/docs/
- **Gitea API Docs:** https://docs.gitea.com/api/ (100% compatible)

## Security Notes

- Runs in rootless mode (non-root user)
- Admin credentials stored in Bitwarden (not in Git)
- Pod Security Admission: Baseline level
- No secrets committed to GitOps repository
- All sensitive data managed via ExternalSecrets Operator

## Future Enhancements

Potential improvements (not yet implemented):
- Ingress with TLS termination
- PostgreSQL for high availability
- Repository mirroring from GitHub
- Automated CI/CD pipeline integration
- OIDC/OAuth authentication
