#!/usr/bin/env bash
set -eo pipefail

NAS_IP="192.168.178.138"
NAS_PORT="5000"
NTFY_TOPIC="https://ntfy.sh/homelab-piotr1215-backup"

send_alert() {
  local title="$1" message="$2" priority="${3:-4}" tags="${4:-warning}"
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
- name: nas-monitor
  crontab: "*/5 * * * *"
EOF
else
  echo "$(date): Running NAS monitor check..."

  CURRENT_STATE=$(kubectl get configmap nas-monitor-state -n monitoring -o jsonpath='{.data.state}' 2>/dev/null || echo "unknown")

  if wget -q --timeout=5 -O /dev/null "http://$NAS_IP:$NAS_PORT" 2>/dev/null; then
    echo "$(date): NAS is reachable"
    if [ "$CURRENT_STATE" != "up" ]; then
      if [ "$CURRENT_STATE" != "unknown" ]; then
        send_alert "NAS Recovered" "Synology NAS at $NAS_IP is now reachable." 1 "white_check_mark,nas"
      fi
      kubectl patch configmap nas-monitor-state -n monitoring --type merge -p '{"data":{"state":"up"}}'
    fi
  else
    echo "$(date): NAS is unreachable"
    if [ "$CURRENT_STATE" != "down" ]; then
      send_alert "NAS Unreachable" "Synology NAS at $NAS_IP:$NAS_PORT is not responding." 5 "rotating_light,warning,nas"
      kubectl patch configmap nas-monitor-state -n monitoring --type merge -p '{"data":{"state":"down"}}'
    fi
  fi
fi
