#!/usr/bin/env bash
set -eo pipefail

# VPA GitOps Sync Hook
# Watches VPA objects and commits resource recommendations to Git

REPO_URL="${GIT_REPO_URL:-https://github.com/Piotr1215/homelab.git}"
REPO_DIR="/tmp/homelab"
BRANCH="${GIT_BRANCH:-main}"
VALUES_BASE_PATH="gitops/apps"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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
      app.kubernetes.io/managed-by: goldilocks
EOF
  exit 0
fi

# Get binding context
BINDING_CONTEXT_PATH="${BINDING_CONTEXT_PATH:-}"
if [[ -z "$BINDING_CONTEXT_PATH" || ! -f "$BINDING_CONTEXT_PATH" ]]; then
  log "No binding context, skipping"
  exit 0
fi

# Parse the VPA event
VPA_DATA=$(jq -r '.[0].filterResult' "$BINDING_CONTEXT_PATH")
VPA_NAME=$(echo "$VPA_DATA" | jq -r '.name')
VPA_NS=$(echo "$VPA_DATA" | jq -r '.namespace')
UPDATE_MODE=$(echo "$VPA_DATA" | jq -r '.updateMode')
RECOMMENDATIONS=$(echo "$VPA_DATA" | jq -r '.recommendations')

log "Processing VPA: $VPA_NAME in namespace $VPA_NS (mode: $UPDATE_MODE)"

# Skip if no recommendations yet
if [[ "$RECOMMENDATIONS" == "null" || -z "$RECOMMENDATIONS" ]]; then
  log "No recommendations yet for $VPA_NAME, skipping"
  exit 0
fi

# Skip if not in Off or Auto mode (we sync both)
# Off = recommendations only (GitOps sync), Auto = VPA also evicts pods
if [[ "$UPDATE_MODE" != "Auto" && "$UPDATE_MODE" != "Off" ]]; then
  log "VPA $VPA_NAME in unsupported mode ($UPDATE_MODE), skipping"
  exit 0
fi

# Goldilocks VPA naming: goldilocks-<deployment-name>
# Extract app name from VPA name using parameter expansion
if [[ "$VPA_NAME" == goldilocks-* ]]; then
  APP_NAME="${VPA_NAME#goldilocks-}"
else
  APP_NAME="$VPA_NAME"
fi

log "Mapped VPA $VPA_NAME to app: $APP_NAME"

# Check if values.yaml exists for this app
VALUES_FILE="$VALUES_BASE_PATH/$APP_NAME/values.yaml"

# Clone/update repo with credential auth
setup_git() {
  # Configure git to use credentials for GitHub
  local auth_url
  if [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
    # URL encode special characters in password
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

# Generate resources YAML fragment for a container
generate_resources_yaml() {
  local container_name="$1"
  local cpu_target="$2"
  local mem_target="$3"

  # Round CPU to reasonable values (minimum 10m, step by 5m)
  local cpu_milli
  cpu_milli=$(echo "$cpu_target" | sed 's/m$//')
  if [[ "$cpu_milli" =~ ^[0-9]+$ ]]; then
    # Round to nearest 5m, minimum 10m
    cpu_milli=$(( (cpu_milli + 4) / 5 * 5 ))
    [[ $cpu_milli -lt 10 ]] && cpu_milli=10
    cpu_target="${cpu_milli}m"
  fi

  # Round memory to reasonable values (minimum 32Mi)
  local mem_value
  mem_value=$(echo "$mem_target" | sed -E 's/([0-9]+)(Mi|Gi|Ki)/\1 \2/')
  local mem_num="${mem_value% *}"
  local mem_unit="${mem_value#* }"

  if [[ "$mem_unit" == "Ki" ]]; then
    # Convert Ki to Mi
    mem_num=$(( mem_num / 1024 ))
    mem_unit="Mi"
  fi

  # Round to reasonable values
  if [[ "$mem_unit" == "Mi" && $mem_num -lt 32 ]]; then
    mem_num=32
  fi
  mem_target="${mem_num}${mem_unit}"

  echo "  resources:"
  echo "    requests:"
  echo "      cpu: $cpu_target"
  echo "      memory: $mem_target"
  echo "    limits:"
  echo "      cpu: $cpu_target"
  echo "      memory: $mem_target"
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

  # Extract recommendations
  local container_recs
  container_recs=$(echo "$RECOMMENDATIONS" | jq -c '.[]')

  local changes_made=false

  while IFS= read -r rec; do
    local container_name cpu_target mem_target
    container_name=$(echo "$rec" | jq -r '.containerName')
    cpu_target=$(echo "$rec" | jq -r '.target.cpu')
    mem_target=$(echo "$rec" | jq -r '.target.memory')

    log "Container: $container_name - CPU: $cpu_target, Memory: $mem_target"

    # Check if values.yaml already has resources section
    if grep -q "resources:" "$values_path"; then
      log "Resources section exists, checking if update needed..."

      # Extract current values
      local current_cpu current_mem
      current_cpu=$(grep -A5 "requests:" "$values_path" | grep "cpu:" | head -1 | awk '{print $2}' | tr -d '"')
      current_mem=$(grep -A5 "requests:" "$values_path" | grep "memory:" | head -1 | awk '{print $2}' | tr -d '"')

      if [[ "$current_cpu" == "$cpu_target" && "$current_mem" == "$mem_target" ]]; then
        log "Resources unchanged, skipping"
        continue
      fi
    fi

    # For now, append resources to the end of values.yaml if not present
    # This is a simple approach - more sophisticated would use yq
    if ! grep -q "resources:" "$values_path"; then
      log "Adding resources section to $values_path"
      echo "" >> "$values_path"
      echo "# VPA recommendations (auto-synced)" >> "$values_path"
      generate_resources_yaml "$container_name" "$cpu_target" "$mem_target" >> "$values_path"
      changes_made=true
    else
      log "Resources section exists - manual update may be needed"
      # Could use yq here for precise YAML editing
    fi

  done <<< "$container_recs"

  if [[ "$changes_made" == "true" ]]; then
    log "Committing changes..."
    git add "$VALUES_FILE"
    git commit -m "chore($APP_NAME): update resources from VPA recommendations

Container recommendations from VPA $VPA_NAME:
$(echo "$RECOMMENDATIONS" | jq -r '.[] | "- \(.containerName): CPU \(.target.cpu), Memory \(.target.memory)"')

Auto-synced by vpa-gitops-sync operator"

    log "Pushing to origin/$BRANCH..."
    git push origin "$BRANCH"
    log "Successfully synced VPA recommendations for $APP_NAME"
  else
    log "No changes to commit"
  fi
}

# Run the sync
sync_vpa_to_git
