#!/usr/bin/env bash
set -eo pipefail

NAS_IP="192.168.178.138"
NAS_PORT="5000"
NTFY_TOPIC="https://ntfy.sh/homelab-piotr1215-backup"
PROBE_TIMEOUT=20

send_alert() {
  local title="$1" message="$2" priority="${3:-4}" tags="${4:-warning}"
  wget -q --no-check-certificate -O /dev/null --post-data="$message" \
    --header="Title: $title" \
    --header="Priority: $priority" \
    --header="Tags: $tags" \
    "$NTFY_TOPIC" 2>/dev/null || true
}

patch_state() {
  kubectl patch configmap nas-monitor-state -n monitoring --type merge \
    -p "{\"data\":{\"state\":\"$1\"}}"
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

  if wget -q --timeout="$PROBE_TIMEOUT" -O /dev/null "http://$NAS_IP:$NAS_PORT" 2>/dev/null; then
    echo "$(date): NAS is reachable (state=$CURRENT_STATE)"
    case "$CURRENT_STATE" in
      down)
        send_alert "NAS Recovered" "Synology NAS at $NAS_IP is now reachable." 1 "white_check_mark,nas"
        patch_state "up"
        ;;
      failing|unknown)
        # transient miss or first run — silent recovery
        patch_state "up"
        ;;
      up)
        : # already up, no-op
        ;;
      *)
        patch_state "up"
        ;;
    esac
  else
    echo "$(date): NAS probe failed (state=$CURRENT_STATE)"
    case "$CURRENT_STATE" in
      down)
        : # already alerted, stay down
        ;;
      failing)
        send_alert "NAS Unreachable" "Synology NAS at $NAS_IP:$NAS_PORT failed two consecutive probes (timeout ${PROBE_TIMEOUT}s)." 5 "rotating_light,warning,nas"
        patch_state "down"
        ;;
      *)
        # up or unknown: enter failing state silently, require a 2nd failure before alerting
        patch_state "failing"
        ;;
    esac
  fi
fi
