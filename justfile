set export

copy := if os() == "linux" { "xsel --clipboard" } else { "pbcopy" }
browse := if os() == "linux" { "xdg-open" } else { "open" }

default:
  just --list

# SSH connections
ubuntu:
  ssh coder@${UBUNTU_HOST}

kube-main:
  ssh decoder@${KUBE_MAIN}

kube-worker1:
  ssh decoder@${KUBE_WORKER1}

kube-worker2:
  ssh decoder@${KUBE_WORKER2}

proxmox:
  ssh root@${PROXMOX_HOST}

# key based ssh
nas:
  ssh nas

# Utilities
get-kubeconfig:
  #!/usr/bin/env bash
  ssh -o StrictHostKeyChecking=no decoder@${KUBE_MAIN} "sudo cat /etc/kubernetes/admin.conf" > ./kubeconfig
  sed -i "s|server: https://127.0.0.1:6443|server: https://${KUBE_MAIN}:6443|" ./kubeconfig

# Launch ArgoCD UI
launch_argo:
  #!/usr/bin/env bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | {{copy}}
  ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  nohup {{browse}} http://$ARGO_IP >/dev/null 2>&1 &

# Launch Homepage
launch_homepage:
  #!/usr/bin/env bash
  HOMEPAGE_IP=$(kubectl get svc -n homepage homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  nohup {{browse}} http://$HOMEPAGE_IP >/dev/null 2>&1 &

# Get ArgoCD password
argo-password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Check scanning jobs status
scan_status:
  @kubectl get cronjobs,jobs -n cluster-scanning

# Clean up completed scan jobs
scan_cleanup:
  @echo "Cleaning up completed scan jobs..."
  @kubectl delete jobs --field-selector status.successful=1 -n cluster-scanning 2>/dev/null || echo "No successful jobs to delete"
  @kubectl delete jobs --field-selector status.successful=1 -n cluster-scanning 2>/dev/null || echo "No failed jobs to delete"
  @kubectl delete jobs --field-selector status.successful=1 -n metallb-system 2>/dev/null || echo "No failed jobs to delete"
  @echo "Cleanup complete"


# Manual Velero backup with optional description
backup-velero description="manual-backup":
  @echo "Creating Velero backup: {{description}}-$(date +%Y%m%d-%H%M%S)"
  @NAME=$(echo "{{description}}" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(date +%Y%m%d-%H%M%S); \
  velero backup create "$NAME" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease \
    --wait
  @echo "Backup complete. Listing recent backups:"
  velero backup get | head -10


# Interactive Kubernetes upgrade - shows versions and lets you choose
k8s-upgrade:
  #!/usr/bin/env bash
  CURRENT=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  echo "Current version: $CURRENT"
  echo
  CURRENT_MINOR=$(echo "$CURRENT" | cut -d. -f2)
  NEXT_MINOR=$((CURRENT_MINOR + 1))
  echo "Available upgrades:"
  VERSIONS=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/releases | \
    jq -r '.[] | .tag_name' | grep -E "^v1\.${NEXT_MINOR}\.[0-9]+$" | sort -V | head -5)
  if [ -z "$VERSIONS" ]; then
    echo "Already at latest supported version"
    exit 0
  fi
  echo "$VERSIONS" | nl -w2 -s'. '
  echo
  read -p "Enter version number or 'q' to quit: " CHOICE
  [[ "$CHOICE" == "q" ]] && exit 0
  TARGET=$(echo "$VERSIONS" | sed -n "${CHOICE}p")
  echo "Upgrading to $TARGET"
  read -p "Continue? (y/n) " -n1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] && ./scripts/k8s-upgrade.sh "$TARGET"


# Configure Bitwarden secrets after ArgoCD sync
patch-bitwarden:
  #!/usr/bin/env bash
  kubectl create secret generic bitwarden-access-token \
    --from-literal=token="$BITWARDEN_MACHINE_ACCOUNT_TOKEN" \
    --namespace=external-secrets \
    --dry-run=client -o yaml | kubectl apply -f -
  CA_BUNDLE=$(kubectl get secret bitwarden-sdk-server-tls -n external-secrets -o jsonpath='{.data.ca\.crt}')
  kubectl patch clustersecretstore bitwarden-secretsmanager --type=json \
    -p '[{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/organizationID","value":"'$BITWARDEN_ORG_ID'"},{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/projectID","value":"'$BITWARDEN_PROJECT_ID'"},{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/caBundle","value":"'$CA_BUNDLE'"}]'

# Restart vCluster YAML MCP Server deployment
restart-vcluster-yaml:
  @echo "Restarting vcluster-yaml-mcp deployment..."
  kubectl rollout restart deployment/vcluster-yaml-mcp -n default
  @echo "Waiting for rollout to complete..."
  kubectl rollout status deployment/vcluster-yaml-mcp -n default --timeout=2m
  @echo "Deployment restarted successfully"

# Query ntopng high-score flows (default: score >= 50)
ntopng-alerts score="50" limit="20":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Fetching ntopng alerts database..."
  POD=$(kubectl get pod -n ntopng -l app=ntopng -o jsonpath='{.items[0].metadata.name}')
  kubectl cp ntopng/$POD:/var/lib/ntopng/0/alerts/alert_store_v11.db /tmp/ntopng_alerts.db -c ntopng 2>/dev/null
  echo "Querying flows with score >= {{score}} (limit {{limit}})..."
  echo
  sqlite3 -header -column /tmp/ntopng_alerts.db "
    SELECT
      datetime(tstamp, 'unixepoch', 'localtime') as time,
      printf('%3d', score) as score,
      printf('%-15s', cli_ip) as source_ip,
      printf('%-15s', srv_ip) as dest_ip,
      printf('%5d', srv_port) as port,
      CASE
        WHEN alert_id = 42 THEN 'HTTP Suspicious UA'
        WHEN alert_id = 101 THEN 'TCP Probe'
        WHEN alert_id = 69 THEN 'Known Proto Wrong Port'
        WHEN alert_id = 30 THEN 'Known Proto Non-Std Port'
        WHEN alert_id = 53 THEN 'DNS Issue'
        ELSE 'Alert-' || alert_id
      END as alert_type,
      substr(info, 1, 30) as info
    FROM flow_alerts
    WHERE score >= {{score}}
    ORDER BY tstamp DESC
    LIMIT {{limit}};
  "
  echo
  echo "Total alerts in database: $(sqlite3 /tmp/ntopng_alerts.db 'SELECT COUNT(*) FROM flow_alerts;')"
  echo "High-score (>={{score}}) count: $(sqlite3 /tmp/ntopng_alerts.db 'SELECT COUNT(*) FROM flow_alerts WHERE score >= {{score}};')"

# Kubernetes Resource Template System
# List available K8s resource templates
k8s-templates:
  @./scripts/k8s-resource-generator.sh -l

# Interactive K8s resource generator wizard
k8s-new:
  @./scripts/k8s-resource-wizard.sh

# Generate K8s resource from config file (usage: just k8s-gen <template-type> <config-file>)
k8s-gen template config:
  @./scripts/k8s-resource-generator.sh -v "{{template}}" "{{config}}"

# Preview K8s resource generation (dry-run)
k8s-preview template config:
  @./scripts/k8s-resource-generator.sh -d "{{template}}" "{{config}}"

# Quick ArgoCD app generator (usage: just k8s-argocd-app <app-name> <source-path>)
k8s-argocd-app name path namespace="default":
  #!/usr/bin/env bash
  CONFIG=$(mktemp /tmp/argocd-config.XXXXXX.yaml)
  cat > "$CONFIG" <<EOF
  app_name: {{name}}
  source_path: {{path}}
  namespace: {{namespace}}
  project: applications
  EOF
  ./scripts/k8s-resource-generator.sh -v argocd-app-directory "$CONFIG"
  rm -f "$CONFIG"
  echo "ArgoCD Application created: gitops/clusters/homelab/{{name}}.yaml"

