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

# Configure Bitwarden secrets after ArgoCD sync (bootstrap External Secrets Operator)
patch-bitwarden:
  #!/usr/bin/env bash
  kubectl create secret generic bitwarden-access-token \
    --from-literal=token="$BITWARDEN_MACHINE_ACCOUNT_TOKEN" \
    --namespace=external-secrets \
    --dry-run=client -o yaml | kubectl apply -f -
  CA_BUNDLE=$(kubectl get secret bitwarden-sdk-server-tls -n external-secrets -o jsonpath='{.data.ca\.crt}')
  kubectl patch clustersecretstore bitwarden-secretsmanager --type=json \
    -p '[{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/organizationID","value":"'$BITWARDEN_ORG_ID'"},{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/projectID","value":"'$BITWARDEN_PROJECT_ID'"},{"op":"replace","path":"/spec/provider/bitwardensecretsmanager/caBundle","value":"'$CA_BUNDLE'"}]'

# Manual Velero backup with optional description
backup-velero description="manual-backup":
  @echo "Creating Velero backup: {{description}}-$(date +%Y%m%d-%H%M%S)"
  @NAME=$(echo "{{description}}" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')-$(date +%Y%m%d-%H%M%S); \
  velero backup create "$NAME" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease \
    --wait
  @echo "Backup complete. Listing recent backups:"
  velero backup get | head -10

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

# Kubespray Ansible Playbooks
# Edit Kubespray inventory file
ansible-edit-inventory:
  ${EDITOR:-vim} kubespray/inventory/homelab/inventory.ini

# Add new worker node to cluster (Kubespray auto-detects new nodes from inventory)
ansible-scale-worker:
  #!/usr/bin/env bash
  cd kubespray
  ansible-playbook -i inventory/homelab/inventory.ini scale.yml -b

# Deploy/update cluster (also used for adding control planes)
ansible-cluster:
  #!/usr/bin/env bash
  cd kubespray
  ansible-playbook -i inventory/homelab/inventory.ini cluster.yml -b

# Remove node from cluster
ansible-remove-node node:
  #!/usr/bin/env bash
  cd kubespray
  ansible-playbook -i inventory/homelab/inventory.ini remove-node.yml -b -e node={{node}}

# Upgrade Kubernetes cluster
ansible-upgrade-cluster:
  #!/usr/bin/env bash
  cd kubespray
  ansible-playbook -i inventory/homelab/inventory.ini upgrade-cluster.yml -b

# Reset cluster (WARNING: destructive)
ansible-reset-cluster:
  #!/usr/bin/env bash
  read -p "This will DESTROY the cluster. Type 'yes' to continue: " confirm
  [[ "$confirm" == "yes" ]] && cd kubespray && ansible-playbook -i inventory/homelab/inventory.ini reset.yml -b || echo "Aborted"

# VM Provisioning
# Create new worker VM with cloud-init
# Usage: just create-worker-vm-static pve2 kube-worker3 104 192.168.178.107
create-worker-vm-static pve_host name vmid ip:
  #!/usr/bin/env bash
  set -euo pipefail
  cd k8s-node-automation
  source lib/common.sh
  source lib/proxmox.sh

  # Resolve PVE host IP
  case "{{pve_host}}" in
    pve|pve1) PVE_IP="${PROXMOX_HOST}" ;;
    pve2) PVE_IP="${PROXMOX2_HOST}" ;;
    *) PVE_IP="{{pve_host}}" ;;
  esac

  echo "Creating VM {{vmid}} ({{name}}) on $(hostname_from_ip ${PVE_IP})..."
  echo "  CPU: 4 cores (standard)"
  echo "  RAM: 8192MB (standard)"
  echo "  Disk: 100GB (standard)"
  echo "  IP: {{ip}}/24"

  create_vm "${PVE_IP}" "{{vmid}}" "{{name}}" "4" "8192" "100"

  # Set static IP before starting
  ssh -o StrictHostKeyChecking=no root@${PVE_IP} \
    "qm set {{vmid}} --ipconfig0 ip={{ip}}/24,gw=192.168.178.1"

  start_vm "${PVE_IP}" "{{vmid}}"

  echo ""
  echo "VM created successfully with static IP {{ip}}"
  echo "Next steps:"
  echo "  1. Wait 2-3 minutes for cloud-init to complete"
  echo "  2. Verify: ping {{ip}}"
  echo "  3. Join cluster: just ansible-scale-worker"

# Create new worker VM with DHCP (default: 4 CPU, 8GB RAM, 100GB disk)
create-worker-vm pve_host name="auto" vmid="auto" cores="4" memory="8192" disk="100" ip="dhcp":
  #!/usr/bin/env bash
  set -euo pipefail
  cd k8s-node-automation
  source lib/common.sh
  source lib/proxmox.sh

  # Resolve PVE host IP
  case "{{pve_host}}" in
    pve|pve1) PVE_IP="${PROXMOX_HOST}" ;;
    pve2) PVE_IP="${PROXMOX2_HOST}" ;;
    *) PVE_IP="{{pve_host}}" ;;
  esac

  # Auto-generate name if not provided
  if [ "{{name}}" = "auto" ]; then
    NEXT_NUM=$(kubectl get nodes 2>/dev/null | grep -oP 'kube-worker\K[0-9]+' | sort -n | tail -1)
    NEXT_NUM=$((NEXT_NUM + 1))
    VM_NAME="kube-worker${NEXT_NUM}"
  else
    VM_NAME="{{name}}"
  fi

  # Auto-generate VMID if not provided
  if [ "{{vmid}}" = "auto" ]; then
    EXISTING=$(ssh -o StrictHostKeyChecking=no root@${PVE_IP} "qm list" | awk '{print $1}' | grep -E '^[0-9]+$' | sort -n | tail -1)
    VM_ID=$((EXISTING + 1))
  else
    VM_ID="{{vmid}}"
  fi

  echo "Creating VM ${VM_ID} (${VM_NAME}) on $(hostname_from_ip ${PVE_IP})..."
  echo "  CPU: {{cores}} cores"
  echo "  RAM: {{memory}}MB"
  echo "  Disk: {{disk}}GB"
  echo "  IP: {{ip}}"

  create_vm "${PVE_IP}" "${VM_ID}" "${VM_NAME}" "{{cores}}" "{{memory}}" "{{disk}}"

  # Set static IP if provided
  if [ "{{ip}}" != "dhcp" ]; then
    ssh -o StrictHostKeyChecking=no root@${PVE_IP} \
      "qm set ${VM_ID} --ipconfig0 ip={{ip}}/24,gw=192.168.178.1"
  fi

  start_vm "${PVE_IP}" "${VM_ID}"

  echo ""
  echo "VM created successfully!"
  if [ "{{ip}}" = "dhcp" ]; then
    echo "Next steps:"
    echo "  1. Wait 2-3 minutes for cloud-init to complete"
    echo "  2. Find VM IP: ssh root@${PVE_IP} 'qm guest cmd ${VM_ID} network-get-interfaces' | grep -oP '192\.168\.178\.\d+' | head -1"
    echo "  3. Add to inventory: just ansible-edit-inventory"
    echo "  4. Join cluster: just ansible-scale-worker"
  else
    echo "Static IP configured: {{ip}}"
    echo "Next steps:"
    echo "  1. Wait 2-3 minutes for cloud-init to complete"
    echo "  2. Add to inventory: just ansible-edit-inventory"
    echo "  3. Join cluster: just ansible-scale-worker"
  fi

# Disaster Recovery - Restore full cluster from etcd backup
cluster-restore:
  ./scripts/restore-cluster.sh

