# Velero Backup Solution for Kubernetes

## Overview
Velero provides backup and restore capabilities for Kubernetes cluster resources and persistent volumes.

## Components

### 1. MinIO (S3-Compatible Storage)
- **File**: `minio.yaml`
- Provides S3-compatible object storage for Velero backups
- Deployed in `minio` namespace
- Console accessible via LoadBalancer service

### 2. Velero
- **File**: `velero.yaml`
- Deployed as ArgoCD Application for GitOps management
- Uses AWS plugin for S3-compatible storage
- Configured with MinIO as backup location

### 3. Bucket Setup
- **File**: `velero-bucket-setup.yaml`
- One-time job to create the `velero-backups` bucket in MinIO

## Installation Steps

1. **Add Velero Helm repository** (if not already added):
   ```bash
   helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
   helm repo update
   ```

2. **Deploy MinIO storage**:
   ```bash
   kubectl apply -f minio.yaml
   ```

3. **Wait for MinIO to be ready**:
   ```bash
   kubectl wait --for=condition=ready pod -l app=minio -n minio --timeout=300s
   ```

4. **Create the backup bucket**:
   ```bash
   kubectl apply -f velero-bucket-setup.yaml
   ```

5. **Deploy Velero via ArgoCD**:
   ```bash
   kubectl apply -f velero.yaml
   ```

## Access Points

### MinIO Console
After deployment, get the MinIO console URL:
```bash
kubectl get svc minio-console -n minio
```
- Username: `minio`
- Password: `minio123`

### Velero CLI
Install the Velero CLI:
```bash
wget https://github.com/vmware-tanzu/velero/releases/latest/download/velero-linux-amd64.tar.gz
tar -xvf velero-linux-amd64.tar.gz
sudo mv velero-*/velero /usr/local/bin/
```

## Basic Operations

### Create a backup
```bash
velero backup create my-backup --include-namespaces default
```

### List backups
```bash
velero backup get
```

### Restore from backup
```bash
velero restore create --from-backup my-backup
```

### Schedule periodic backups
```bash
velero schedule create daily-backup --schedule="0 2 * * *" --include-namespaces default,homepage,portainer
```

## Configuration Details

### Backup Storage Location
- Provider: AWS (S3-compatible)
- Bucket: `velero-backups`
- Region: `minio`
- S3 URL: `http://minio.minio.svc.cluster.local:9000`

### Node Agent
- Enabled for filesystem backups
- Pod volume path: `/var/lib/kubelet/pods`
- Runs with privileged access for volume snapshots

## Troubleshooting

### Check Velero logs
```bash
kubectl logs deployment/velero -n velero
```

### Check backup status
```bash
velero backup describe <backup-name>
velero backup logs <backup-name>
```

### Verify MinIO connectivity
```bash
kubectl run -it --rm debug --image=minio/mc:latest --restart=Never -n velero -- \
  mc alias set minio http://minio.minio.svc.cluster.local:9000 minio minio123
```
