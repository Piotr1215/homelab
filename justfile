default:
  just --list

ubuntu:
  ssh coder@192.168.178.76

get-kubeconfig:
  scp decoder@192.168.178.87:/etc/kubernetes/admin.conf ./kubeconfig

kube-main:
  ssh decoder@192.168.178.87

kube-worker1:
  ssh decoder@192.168.178.88

kube-worker2:
  ssh decoder@192.168.178.89

proxmox:
  ssh root@192.168.178.75

install_knative_operator:
  kubectl apply -f https://github.com/knative/operator/releases/download/knative-v1.16.1/operator.yaml

retrieve_headlamp_token:
  kubectl get secret headlamp-admin -n kube-system -o jsonpath="{.data.token}" | base64 --decode | xsel --clipboard

apply-storage:
  kubectl --kubeconfig=./kubeconfig apply -f yaml/local-storage-class.yaml -f yaml/vcluster-pv.yaml

# ArgoCD commands
argocd_port := "8080"
copy := if os() == "linux" { "xsel --clipboard" } else { "pbcopy" }
browse := if os() == "linux" { "xdg-open" } else { "open" }

launch_argo:
  #!/usr/bin/env bash
  echo "ArgoCD Admin Password (copied to clipboard):"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | tee >({{copy}})
  echo ""
  echo "Getting ArgoCD LoadBalancer IP..."
  ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening ArgoCD UI at http://$ARGO_IP"
  sleep 2
  nohup {{browse}} http://$ARGO_IP >/dev/null 2>&1 &

argo_password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

argo_sync_apps:
  kubectl apply -f gitops/clusters/homelab/

launch_vault:
  #!/usr/bin/env bash
  echo "Vault Root Token (copied to clipboard): root"
  echo "root" | {{copy}}
  VAULT_IP=$(kubectl get svc -n vault vault-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening Vault UI at http://$VAULT_IP:8200"
  sleep 2
  nohup {{browse}} http://$VAULT_IP:8200 >/dev/null 2>&1 &

launch_homepage:
  #!/usr/bin/env bash
  HOMEPAGE_IP=$(kubectl get svc -n homepage homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening Homepage at http://$HOMEPAGE_IP"
  nohup {{browse}} http://$HOMEPAGE_IP >/dev/null 2>&1 &
