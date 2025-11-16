# AlertManager Setup

AlertManager handles alerts from Prometheus and routes them to notification channels like Slack, Discord, email, or webhooks.

## Access Information

- **URL**: http://192.168.178.91:9093
- **Namespace**: `prometheus`
- **Service**: `kube-prometheus-stack-alertmanager`

## Overview

AlertManager is configured with:
- **Grouping**: Alerts are grouped by alertname, cluster, and service
- **Routing**: Different severity levels route to different receivers
- **Inhibition**: Critical alerts suppress warning alerts for the same issue
- **Persistence**: Alert state is stored in a 1Gi PVC

## Current Alert Rules

The homelab has comprehensive alerting for:

### Pod & Container Alerts
- **PodCrashLooping**: Pod restarting frequently
- **PodNotReady**: Pod stuck in Pending/Unknown/Failed state
- **ContainerMemoryUsageHigh**: Container using >90% memory

### Node Alerts
- **NodeNotReady**: Node unavailable
- **NodeMemoryPressure**: Node experiencing memory pressure
- **NodeDiskPressure**: Node disk space issues
- **NodeDiskSpaceLow**: Less than 10% disk space
- **NodeDiskSpaceCritical**: Less than 5% disk space

### Storage Alerts
- **PersistentVolumeSpaceLow**: PV less than 20% free
- **PersistentVolumeSpaceCritical**: PV less than 10% free

### Certificate Alerts
- **CertificateExpiringSoon**: Certificate expires in <7 days
- **CertificateExpiryCritical**: Certificate expires in <24 hours
- **CertificateNotReady**: cert-manager certificate issue

### Backup Alerts
- **VeleroBackupFailed**: Velero backup failure
- **VeleroBackupPartialFailure**: Partial backup failure
- **NoBackupInLast24Hours**: Missing scheduled backup

### ArgoCD Alerts
- **ArgoApplicationOutOfSync**: Application not synced for >15min
- **ArgoApplicationHealthDegraded**: Application health degraded
- **ArgoApplicationSyncFailed**: Application sync failed

### Vault Alerts
- **VaultSealed**: Vault is sealed (critical!)
- **VaultHighMemoryUsage**: Vault using >85% memory

### Service Alerts
- **ServiceDown**: Service unavailable for >5min
- **HighErrorRate**: High HTTP 5xx error rate
- **TooManyPods**: >100 pods running (potential issue)
- **KubernetesJobFailed**: Kubernetes job failed

## Configuring Notification Channels

AlertManager configuration is managed via Helm values in `gitops/infra/kube-prometheus-stack.yaml` (see `alertmanager.config` section).

Reference standalone config available at: `docs/alertmanager-config-reference.yaml`

### Option 1: Slack Notifications

1. Create a Slack webhook:
   - Go to https://api.slack.com/apps
   - Create new app → Incoming Webhooks
   - Add webhook to workspace
   - Copy webhook URL

2. Edit `alertmanager-config.yaml`:

```yaml
receivers:
  - name: 'critical'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
        channel: '#homelab-alerts'
        title: 'CRITICAL: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
        send_resolved: true
```

3. Create a Kubernetes secret for the webhook:

```bash
kubectl create secret generic alertmanager-slack \
  --from-literal=url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  -n prometheus
```

### Option 2: Discord Notifications

1. Create Discord webhook:
   - Server Settings → Integrations → Webhooks
   - Create webhook and copy URL

2. Edit `alertmanager-config.yaml`:

```yaml
receivers:
  - name: 'critical'
    webhook_configs:
      - url: 'https://discord.com/api/webhooks/YOUR/WEBHOOK/URL/slack'
        send_resolved: true
```

Note: Add `/slack` to the Discord webhook URL for compatibility.

### Option 3: Email Notifications

Edit `alertmanager-config.yaml`:

```yaml
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: 'alertmanager@homelab.local'
  smtp_auth_username: 'your-email@gmail.com'
  smtp_auth_password: 'your-app-password'
  smtp_require_tls: true

receivers:
  - name: 'critical'
    email_configs:
      - to: 'your-email@example.com'
        headers:
          Subject: '[CRITICAL] Homelab Alert: {{ .GroupLabels.alertname }}'
```

For Gmail, create an [App Password](https://myaccount.google.com/apppasswords).

### Option 4: ntfy.sh (Simple Push Notifications)

ntfy.sh is perfect for homelabs - no signup required!

```yaml
receivers:
  - name: 'critical'
    webhook_configs:
      - url: 'https://ntfy.sh/my-homelab-alerts'
        send_resolved: true
```

Subscribe to alerts:
```bash
# On your phone or computer
curl -s ntfy.sh/my-homelab-alerts/json
# Or install ntfy app: https://ntfy.sh
```

### Option 5: Custom Webhook

```yaml
receivers:
  - name: 'critical'
    webhook_configs:
      - url: 'http://my-webhook-handler.homelab.svc:8080/alerts'
        send_resolved: true
        max_alerts: 0  # Send all alerts
```

## Apply Configuration Changes

After editing AlertManager config in `gitops/infra/kube-prometheus-stack.yaml`:

```bash
# Commit changes to Git, ArgoCD will automatically sync
# Or force sync:
kubectl patch application kube-prometheus-stack -n argocd --type merge -p '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {}}}'
```

## Testing Alerts

### Trigger Test Alert

```bash
# Create a pod that will crash
kubectl run crasher --image=busybox --restart=Never -- sh -c "exit 1"

# This should trigger PodNotReady alert after 10 minutes
```

### Send Manual Test Alert

```bash
# Port-forward to AlertManager
kubectl port-forward -n prometheus svc/kube-prometheus-stack-alertmanager 9093:9093

# Send test alert
curl -H "Content-Type: application/json" -d '[{
  "labels": {
    "alertname": "TestAlert",
    "severity": "warning"
  },
  "annotations": {
    "summary": "This is a test alert",
    "description": "Testing AlertManager configuration"
  }
}]' http://localhost:9093/api/v1/alerts
```

## Viewing Active Alerts

### AlertManager UI

Access at http://192.168.178.91:9093:
- View active alerts
- See alert groups
- Check silences
- View inhibited alerts

### Prometheus UI

Access at http://192.168.178.90:9090:
- Go to **Alerts** tab
- See firing and pending alerts
- View alert rules

### Grafana

Access at http://192.168.178.96:
- Create dashboard with **Alert List** panel
- Shows all active alerts in one place

## Silencing Alerts

Sometimes you need to silence alerts during maintenance.

### Web UI Method

1. Go to http://192.168.178.91:9093
2. Click **Silences** → **New Silence**
3. Add matchers (e.g., `alertname="NodeDiskPressure"`)
4. Set duration and comment
5. Click **Create**

### CLI Method

```bash
# Install amtool
go install github.com/prometheus/alertmanager/cmd/amtool@latest

# Create silence
amtool silence add alertname=NodeNotReady --duration=2h \
  --comment="Planned maintenance" \
  --alertmanager.url=http://192.168.178.91:9093
```

### During Cluster Upgrades

```bash
# Silence all node alerts during upgrade
amtool silence add severity=warning severity=critical \
  --duration=30m \
  --comment="Cluster upgrade in progress" \
  --alertmanager.url=http://192.168.178.91:9093
```

## Custom Alert Rules

To add custom alerts, edit `gitops/infra/prometheus-rules-homelab.yaml`:

```yaml
spec:
  groups:
    - name: my-custom-alerts
      interval: 30s
      rules:
        - alert: MyCustomAlert
          expr: my_metric > 100
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "My metric is too high"
            description: "Value is {{ $value }}"
```

## Alert Routing Examples

### Route by Namespace

```yaml
route:
  routes:
    - match:
        namespace: production
      receiver: pagerduty
    - match:
        namespace: development
      receiver: slack-dev
```

### Route by Severity

```yaml
route:
  routes:
    - match:
        severity: critical
      receiver: pagerduty
      repeat_interval: 1h
    - match:
        severity: warning
      receiver: slack
      repeat_interval: 12h
```

### Time-based Routing

```yaml
route:
  routes:
    - match:
        severity: critical
      receiver: pagerduty
      active_time_intervals:
        - business_hours
    - match:
        severity: warning
      receiver: slack

time_intervals:
  - name: business_hours
    time_intervals:
      - weekdays: ['monday:friday']
        times:
          - start_time: '09:00'
            end_time: '17:00'
```

## Monitoring AlertManager

Check AlertManager health:
```bash
# Check service
kubectl get svc -n prometheus | grep alertmanager

# Check pods
kubectl get pods -n prometheus | grep alertmanager

# View logs
kubectl logs -n prometheus alertmanager-kube-prometheus-stack-alertmanager-0
```

## Troubleshooting

### Alerts Not Firing

1. Check Prometheus rules:
```bash
# Access Prometheus UI: http://192.168.178.90:9090
# Go to Status → Rules
# Verify your rule is loaded and active
```

2. Check PromQL query:
```bash
# In Prometheus UI, run your alert query manually
# Ensure it returns results when condition is met
```

### Notifications Not Received

1. Check AlertManager logs:
```bash
kubectl logs -n prometheus alertmanager-kube-prometheus-stack-alertmanager-0
```

2. Check receiver configuration:
```bash
# Verify receiver is configured correctly
kubectl get configmap -n prometheus alertmanager-config -o yaml
```

3. Test webhook endpoint:
```bash
curl -X POST http://your-webhook-url -d '{}'
```

### AlertManager Not Loading Config

```bash
# Check ConfigMap
kubectl get configmap -n prometheus alertmanager-config

# Restart AlertManager
kubectl rollout restart statefulset -n prometheus alertmanager-kube-prometheus-stack-alertmanager
```

## Best Practices

1. **Start with critical alerts only** - Avoid alert fatigue
2. **Use appropriate `for` durations** - Prevent flapping
3. **Write clear descriptions** - Include troubleshooting steps
4. **Test notifications** - Ensure they reach you
5. **Document runbooks** - Link from alert annotations
6. **Review alerts regularly** - Remove/tune noisy alerts
7. **Use inhibition rules** - Reduce duplicate notifications
8. **Set up on-call rotation** - If running production workloads

## Resources

- AlertManager Docs: https://prometheus.io/docs/alerting/latest/alertmanager/
- Alert Rule Writing: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Notification Integrations: https://prometheus.io/docs/alerting/latest/configuration/
