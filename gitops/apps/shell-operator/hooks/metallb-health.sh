#!/usr/bin/env bash
set -eo pipefail

NTFY_TOPIC="https://ntfy.sh/homelab-piotr1215-warning"
L2_NODE="kube-worker2"  # Node configured for L2 advertisement

send_ntfy() {
  local title="$1" priority="$2" tags="$3" message="$4"
  wget -q --no-check-certificate -O /dev/null --post-data="$message" \
    --header="Title: $title" \
    --header="Priority: $priority" \
    --header="Tags: $tags" \
    "$NTFY_TOPIC" 2>/dev/null || true
}

check_speaker_health() {
  # Get speaker pod on L2 node
  local pod
  pod=$(kubectl get pods -n metallb-system -l component=speaker \
    --field-selector spec.nodeName="$L2_NODE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -z "$pod" ]]; then
    echo "ERROR: No speaker pod found on $L2_NODE"
    return 1
  fi

  # Check pod is Ready (not just Running)
  local ready
  ready=$(kubectl get pod "$pod" -n metallb-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

  if [[ "$ready" != "True" ]]; then
    echo "ERROR: Speaker pod $pod not Ready (status: $ready)"
    return 1
  fi

  # Check for recent errors in speaker logs (last 2 minutes)
  local errors
  errors=$(kubectl logs "$pod" -n metallb-system --since=2m 2>/dev/null | grep -ci "error\|failed\|unable" || true)

  if [[ "$errors" -gt 5 ]]; then
    echo "WARNING: Speaker $pod has $errors errors in last 2 minutes"
    return 1
  fi

  echo "OK: Speaker $pod on $L2_NODE is healthy"
  return 0
}

restart_speakers() {
  echo "$(date): Restarting MetalLB speakers..."
  kubectl rollout restart daemonset speaker -n metallb-system

  # Wait for rollout
  kubectl rollout status daemonset speaker -n metallb-system --timeout=60s 2>/dev/null || true
}

if [[ $1 == "--config" ]]; then
  cat <<EOF
configVersion: v1
schedule:
- name: metallb-health
  crontab: "*/5 * * * *"
EOF
else
  echo "$(date): Running MetalLB health check..."

  if check_speaker_health; then
    exit 0
  fi

  # Speaker unhealthy - attempt recovery
  send_ntfy "MetalLB Auto-Recovery" "4" "warning,metallb,auto-fix" \
    "Speaker on $L2_NODE unhealthy. Auto-restarting speakers."

  restart_speakers

  # Wait for pods to stabilize
  sleep 15

  if check_speaker_health; then
    send_ntfy "MetalLB Recovered" "2" "white_check_mark,metallb" \
      "MetalLB auto-recovery successful. Speaker healthy."
  else
    send_ntfy "MetalLB Recovery FAILED" "5" "rotating_light,metallb,manual" \
      "MetalLB auto-recovery FAILED. Manual intervention required."
  fi
fi
