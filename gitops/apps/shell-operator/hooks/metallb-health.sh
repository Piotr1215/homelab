#!/usr/bin/env bash
set -eo pipefail

NTFY_TOPIC="https://ntfy.sh/homelab-piotr1215-warning"

send_ntfy() {
  local title="$1" priority="$2" tags="$3" message="$4"
  wget -q --no-check-certificate -O /dev/null --post-data="$message" \
    --header="Title: $title" \
    --header="Priority: $priority" \
    --header="Tags: $tags" \
    "$NTFY_TOPIC" 2>/dev/null || true
}

check_speaker_health() {
  # Count Ready speakers (need at least 1 for L2 announcements)
  local ready_count
  ready_count=$(kubectl get pods -n metallb-system -l component=speaker \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo "0")

  if [[ "$ready_count" -lt 1 ]]; then
    echo "ERROR: No Ready speaker pods"
    return 1
  fi

  echo "OK: $ready_count speaker pods Ready"
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
