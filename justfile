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
