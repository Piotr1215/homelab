#!/usr/bin/env bash
set -eo pipefail

# VPA GitOps Sync Hook
# Watches VPA objects and commits resource recommendations to Git
#
# FLOW:
# 1. Label namespace: kubectl label ns <name> goldilocks.fairwinds.com/enabled=true
# 2. Goldilocks creates VPAs for all deployments in namespace
# 3. VPAs get label: source=goldilocks
# 4. This hook watches VPAs with that label
# 5. On VPA update, commits recommendations to gitops/apps/<app>/values.yaml
# 6. ArgoCD syncs and applies resources

REPO_URL="${GIT_REPO_URL:-https://github.com/Piotr1215/homelab.git}"
REPO_DIR="/tmp/homelab"
BRANCH="${GIT_BRANCH:-main}"
VALUES_BASE_PATH="gitops/apps"
LOCK_FILE="/tmp/vpa-sync.lock"
MIN_COMMIT_INTERVAL=300  # 5 minutes between commits

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Convert bytes to human-readable Mi
bytes_to_mi() {
  local bytes="$1"
  if [[ "$bytes" =~ ^([0-9]+)(Ki|Mi|Gi)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      Ki) echo "$(( num / 1024 ))Mi" ;;
      Gi) echo "$(( num * 1024 ))Mi" ;;
      Mi) echo "${num}Mi" ;;
    esac
  elif [[ "$bytes" =~ ^[0-9]+$ ]]; then
    echo "$(( bytes / 1048576 ))Mi"
  else
    echo "64Mi"
  fi
}

# Shell-operator config
if [[ $1 == "--config" ]]; then
  cat <<EOF
configVersion: v1
kubernetes:
- name: vpa-recommendations
  apiVersion: autoscaling.k8s.io/v1
  kind: VerticalPodAutoscaler
  executeHookOnEvent: ["Modified"]
  jqFilter: |
    {
      name: .metadata.name,
      namespace: .metadata.namespace,
      targetRef: .spec.targetRef,
      updateMode: .spec.updatePolicy.updateMode,
      recommendations: .status.recommendation.containerRecommendations
    }
  labelSelector:
    matchLabels:
      source: goldilocks
EOF
  exit 0
fi

# Acquire lock to prevent concurrent git operations
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "Another sync in progress, skipping"
  exit 0
fi

# Check minimum interval between commits
LAST_COMMIT_FILE="/tmp/vpa-sync-last-commit"
if [[ -f "$LAST_COMMIT_FILE" ]]; then
  last_commit=$(cat "$LAST_COMMIT_FILE")
  now=$(date +%s)
  elapsed=$((now - last_commit))
  if [[ $elapsed -lt $MIN_COMMIT_INTERVAL ]]; then
    log "Last commit was ${elapsed}s ago, waiting for ${MIN_COMMIT_INTERVAL}s interval"
    exit 0
  fi
fi

# Get binding context
BINDING_CONTEXT_PATH="${BINDING_CONTEXT_PATH:-}"
if [[ -z "$BINDING_CONTEXT_PATH" || ! -f "$BINDING_CONTEXT_PATH" ]]; then
  log "No binding context, skipping"
  exit 0
fi

# Process each event in the binding context
EVENT_COUNT=$(jq 'length' "$BINDING_CONTEXT_PATH")
log "Processing $EVENT_COUNT events"

for i in $(seq 0 $((EVENT_COUNT - 1))); do
  EVENT_TYPE=$(jq -r ".[$i].type // \"unknown\"" "$BINDING_CONTEXT_PATH")

  if [[ "$EVENT_TYPE" == "Synchronization" ]]; then
    OBJECT_COUNT=$(jq -r ".[$i].objects | length" "$BINDING_CONTEXT_PATH")
    log "Sync event with $OBJECT_COUNT VPAs - skipping initial sync"
    continue
  fi

  # For Event type, get filterResult
  VPA_DATA=$(jq -c ".[$i].filterResult // empty" "$BINDING_CONTEXT_PATH")
  if [[ -z "$VPA_DATA" || "$VPA_DATA" == "null" ]]; then
    VPA_DATA=$(jq -c ".[$i].object | {name: .metadata.name, namespace: .metadata.namespace, updateMode: .spec.updatePolicy.updateMode, recommendations: .status.recommendation.containerRecommendations}" "$BINDING_CONTEXT_PATH" 2>/dev/null)
    if [[ -z "$VPA_DATA" || "$VPA_DATA" == "null" ]]; then
      log "No VPA data in event $i, skipping"
      continue
    fi
  fi

  VPA_NAME=$(echo "$VPA_DATA" | jq -r '.name // empty')
  VPA_NS=$(echo "$VPA_DATA" | jq -r '.namespace // empty')
  UPDATE_MODE=$(echo "$VPA_DATA" | jq -r '.updateMode // empty')
  RECOMMENDATIONS=$(echo "$VPA_DATA" | jq -c '.recommendations // empty')

  if [[ -z "$VPA_NAME" || "$VPA_NAME" == "null" ]]; then
    log "No VPA name in event $i, skipping"
    continue
  fi

  log "Event $i: VPA $VPA_NAME in $VPA_NS (mode: $UPDATE_MODE)"
  break
done

if [[ -z "$VPA_NAME" || "$VPA_NAME" == "null" ]]; then
  log "No valid VPA found to process"
  exit 0
fi

log "Processing VPA: $VPA_NAME in namespace $VPA_NS (mode: $UPDATE_MODE)"

# Skip if no recommendations yet
if [[ "$RECOMMENDATIONS" == "null" || -z "$RECOMMENDATIONS" ]]; then
  log "No recommendations yet for $VPA_NAME, skipping"
  exit 0
fi

# Skip if not in Off mode (we only sync Off mode - GitOps managed)
if [[ "$UPDATE_MODE" != "Off" ]]; then
  log "VPA $VPA_NAME in $UPDATE_MODE mode (not Off), skipping - only Off mode syncs to Git"
  exit 0
fi

# Goldilocks VPA naming: goldilocks-<deployment-name>
if [[ "$VPA_NAME" == goldilocks-* ]]; then
  APP_NAME="${VPA_NAME#goldilocks-}"
else
  APP_NAME="$VPA_NAME"
fi

log "Mapped VPA $VPA_NAME to app: $APP_NAME"

VALUES_FILE="$VALUES_BASE_PATH/$APP_NAME/values.yaml"

# Clone/update repo
setup_git() {
  local auth_url
  if [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
    local encoded_pass
    encoded_pass=$(printf '%s' "$GIT_PASSWORD" | sed 's/@/%40/g; s/:/%3A/g; s/\//%2F/g')
    auth_url="https://${GIT_USERNAME}:${encoded_pass}@github.com/Piotr1215/homelab.git"
  else
    auth_url="$REPO_URL"
  fi

  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Updating existing repo..."
    cd "$REPO_DIR"
    git remote set-url origin "$auth_url"
    git fetch origin
    git reset --hard "origin/$BRANCH"
  else
    log "Cloning repo..."
    rm -rf "$REPO_DIR"
    git clone --depth 1 --branch "$BRANCH" "$auth_url" "$REPO_DIR"
    cd "$REPO_DIR"
  fi
  git config user.email "vpa-sync@homelab.local"
  git config user.name "VPA GitOps Sync"
}

# Update resources using yq (proper YAML handling)
update_resources() {
  local values_path="$1"
  local cpu="$2"
  local mem="$3"

  # Round CPU to nearest 5m, minimum 10m
  local cpu_milli
  cpu_milli=$(echo "$cpu" | sed 's/m$//')
  if [[ "$cpu_milli" =~ ^[0-9]+$ ]]; then
    cpu_milli=$(( (cpu_milli + 4) / 5 * 5 ))
    [[ $cpu_milli -lt 10 ]] && cpu_milli=10
    cpu="${cpu_milli}m"
  fi

  # Convert memory to Mi, minimum 32Mi
  local mem_mi
  mem_mi=$(bytes_to_mi "$mem")
  local mem_num="${mem_mi%Mi}"
  [[ $mem_num -lt 32 ]] && mem_mi="32Mi"

  log "Setting resources: CPU=$cpu, Memory=$mem_mi"

  # Use yq to update or create resources section
  yq -i ".resources.requests.cpu = \"$cpu\" |
         .resources.requests.memory = \"$mem_mi\" |
         .resources.limits.cpu = \"$cpu\" |
         .resources.limits.memory = \"$mem_mi\"" "$values_path"

  # Return formatted values for commit message
  echo "$cpu $mem_mi"
}

# Main sync logic
sync_vpa_to_git() {
  setup_git

  local values_path="$REPO_DIR/$VALUES_FILE"

  if [[ ! -f "$values_path" ]]; then
    log "No values.yaml found at $VALUES_FILE for app $APP_NAME, skipping"
    return 0
  fi

  log "Found values.yaml at $values_path"

  # Get first container recommendation (most apps have one container)
  local cpu_target mem_target container_name
  container_name=$(echo "$RECOMMENDATIONS" | jq -r '.[0].containerName')
  cpu_target=$(echo "$RECOMMENDATIONS" | jq -r '.[0].target.cpu')
  mem_target=$(echo "$RECOMMENDATIONS" | jq -r '.[0].target.memory')

  log "Container: $container_name - CPU: $cpu_target, Memory: $mem_target"

  # Check current values
  local current_cpu current_mem
  current_cpu=$(yq '.resources.requests.cpu // ""' "$values_path" 2>/dev/null || echo "")
  current_mem=$(yq '.resources.requests.memory // ""' "$values_path" 2>/dev/null || echo "")

  # Normalize for comparison
  local new_mem_mi
  new_mem_mi=$(bytes_to_mi "$mem_target")

  if [[ "$current_cpu" == "$cpu_target" && "$current_mem" == "$new_mem_mi" ]]; then
    log "Resources unchanged ($cpu_target, $new_mem_mi), skipping"
    return 0
  fi

  log "Updating resources: $current_cpu,$current_mem -> $cpu_target,$new_mem_mi"

  # Update the values.yaml
  local formatted
  formatted=$(update_resources "$values_path" "$cpu_target" "$mem_target")
  local new_cpu="${formatted% *}"
  local new_mem="${formatted#* }"

  # Check if there are actual changes
  if git diff --quiet "$VALUES_FILE"; then
    log "No actual changes to commit"
    return 0
  fi

  log "Committing changes..."
  git add "$VALUES_FILE"
  git commit -m "chore($APP_NAME): update resources from VPA recommendations

Container: $container_name
- CPU: $new_cpu
- Memory: $new_mem

Auto-synced by vpa-gitops-sync operator"

  log "Pushing to origin/$BRANCH..."
  if git push origin "$BRANCH"; then
    log "Successfully synced VPA recommendations for $APP_NAME"
    # Record commit time for rate limiting
    date +%s > "$LAST_COMMIT_FILE"
  else
    log "Failed to push, will retry on next event"
  fi
}

# Run the sync
sync_vpa_to_git
