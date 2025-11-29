#!/usr/bin/env bash
set -eo pipefail

NTFY_TOPIC="https://ntfy.sh/homelab-piotr1215-warning"
TEST_URL="https://homepage.homelab.local/"

# Use wget (available in Alpine) instead of curl
check_url() {
  wget -q --no-check-certificate --timeout=10 -O /dev/null "$1" 2>/dev/null
}

send_ntfy() {
  local title="$1" priority="$2" tags="$3" message="$4"
  wget -q --no-check-certificate -O /dev/null --post-data="$message" \
    --header="Title: $title" \
    --header="Priority: $priority" \
    --header="Tags: $tags" \
    "$NTFY_TOPIC" 2>/dev/null || true
}

if [[ $1 == "--config" ]]; then
  cat <<EOF
configVersion: v1
schedule:
- name: metallb-health
  crontab: "*/15 * * * *"
EOF
else
  echo "$(date): Running MetalLB health check..."

  if check_url "$TEST_URL"; then
    echo "$(date): Homepage reachable, MetalLB healthy"
    exit 0
  fi

  echo "$(date): Homepage unreachable, restarting MetalLB..."

  # Send alert BEFORE restart (in case restart also fails)
  send_ntfy "MetalLB Auto-Recovery" "4" "warning,metallb,auto-fix" \
    "Homepage unreachable. Auto-restarting MetalLB speakers."

  # Restart MetalLB
  kubectl rollout restart deployment controller -n metallb-system
  kubectl delete pod -l component=speaker -n metallb-system

  # Wait and verify
  sleep 20

  if check_url "$TEST_URL"; then
    send_ntfy "MetalLB Recovered" "2" "white_check_mark,metallb" \
      "MetalLB auto-recovery successful. Homepage is back."
  else
    send_ntfy "MetalLB Recovery FAILED" "5" "rotating_light,metallb,manual" \
      "MetalLB auto-recovery FAILED. Manual intervention required."
  fi
fi
