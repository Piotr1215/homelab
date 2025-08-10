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

# Utilities
get-kubeconfig:
  scp decoder@${KUBE_MAIN}:/etc/kubernetes/admin.conf ./kubeconfig

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
argo_password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Apply ArgoCD root applications
argo_sync_apps:
  kubectl apply -f gitops/clusters/homelab/

# Stop ArgoCD controller
argo_stop:
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=0

# Start ArgoCD controller
argo_start:
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=1

# Disable ArgoCD auto-sync for all apps
argo_suspend:
  #!/usr/bin/env bash
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    kubectl patch application $app -n argocd --type='json' \
      -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true
  done

# Enable ArgoCD auto-sync for all apps
argo_resume:
  #!/usr/bin/env bash
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    kubectl patch application $app -n argocd --type='merge' \
      -p='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
  done

# Check ArgoCD status
argo_status:
  @kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status