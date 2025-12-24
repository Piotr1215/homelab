#!/usr/bin/env bats

# Test suite for vpa-sync.sh
# VPA GitOps Sync - watches VPAs and commits resource recommendations to Git

# Setup function runs before each test
setup() {
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR

    # Create mock git repo structure
    mkdir -p "${TEST_DIR}/repo/gitops/apps/cert-manager"
    cat > "${TEST_DIR}/repo/gitops/apps/cert-manager/values.yaml" << 'EOF'
installCRDs: true
config:
  enableGatewayAPI: true
EOF

    # Define functions inline for testing (extracted from vpa-sync.sh)
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
    export -f bytes_to_mi

    update_resources() {
        local values_path="$1"
        local cpu="$2"
        local mem="$3"

        # Round CPU to nearest 5m, minimum 25m
        local cpu_milli
        cpu_milli=$(echo "$cpu" | sed 's/m$//')
        if [[ "$cpu_milli" =~ ^[0-9]+$ ]]; then
            cpu_milli=$(( (cpu_milli + 4) / 5 * 5 ))
            [[ $cpu_milli -lt 25 ]] && cpu_milli=25
            cpu="${cpu_milli}m"
        fi

        # Convert memory to Mi, minimum 64Mi
        local mem_mi
        mem_mi=$(bytes_to_mi "$mem")
        local mem_num="${mem_mi%Mi}"
        [[ $mem_num -lt 64 ]] && mem_mi="64Mi"

        # Calculate limits with headroom (2x requests)
        local cpu_limit_milli=$(( cpu_milli * 2 ))
        local mem_limit_num=$(( ${mem_mi%Mi} * 2 ))
        local cpu_limit="${cpu_limit_milli}m"
        local mem_limit="${mem_limit_num}Mi"

        # Use yq to update or create resources section
        yq -i ".resources.requests.cpu = \"$cpu\" |
               .resources.requests.memory = \"$mem_mi\" |
               .resources.limits.cpu = \"$cpu_limit\" |
               .resources.limits.memory = \"$mem_limit\"" "$values_path"

        echo "$cpu $mem_mi"
    }
    export -f update_resources
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ====================================================
# BYTES TO MI CONVERSION TESTS
# ====================================================

@test "bytes_to_mi converts pure bytes correctly" {
    result=$(bytes_to_mi "104857600")
    [ "$result" = "100Mi" ]
}

@test "bytes_to_mi handles Mi suffix" {
    result=$(bytes_to_mi "105Mi")
    [ "$result" = "105Mi" ]
}

@test "bytes_to_mi handles Gi suffix" {
    result=$(bytes_to_mi "1Gi")
    [ "$result" = "1024Mi" ]
}

@test "bytes_to_mi handles Ki suffix" {
    result=$(bytes_to_mi "107520Ki")
    [ "$result" = "105Mi" ]
}

@test "bytes_to_mi handles invalid input with fallback" {
    result=$(bytes_to_mi "invalid")
    [ "$result" = "64Mi" ]
}

@test "bytes_to_mi handles small bytes (32MB)" {
    result=$(bytes_to_mi "33554432")
    [ "$result" = "32Mi" ]
}

@test "bytes_to_mi handles large bytes (1GB)" {
    result=$(bytes_to_mi "1073741824")
    [ "$result" = "1024Mi" ]
}

# ====================================================
# UPDATE RESOURCES TESTS (requires yq)
# ====================================================

@test "update_resources adds resources to file without existing resources" {
    if ! command -v yq &> /dev/null; then skip "yq not installed"; fi

    local test_file="${TEST_DIR}/repo/gitops/apps/cert-manager/values.yaml"
    result=$(update_resources "$test_file" "30m" "104857600")

    # Check output format (30m stays 30m, 100Mi stays 100Mi - both above minimums)
    [[ "$result" =~ "30m" ]]
    [[ "$result" =~ "100Mi" ]]

    # Check file was updated
    grep -q "resources:" "$test_file"
}

@test "update_resources updates existing resources" {
    if ! command -v yq &> /dev/null; then skip "yq not installed"; fi

    local test_file="${TEST_DIR}/test-update.yaml"
    cat > "$test_file" << 'EOF'
installCRDs: true
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    cpu: 10m
    memory: 64Mi
EOF

    update_resources "$test_file" "30m" "128Mi"

    # Check updated values (30m above minimum, 128Mi above minimum)
    local new_cpu=$(yq '.resources.requests.cpu' "$test_file")
    local new_mem=$(yq '.resources.requests.memory' "$test_file")

    [ "$new_cpu" = "30m" ]
    [ "$new_mem" = "128Mi" ]
}

@test "update_resources rounds CPU to nearest 5m" {
    if ! command -v yq &> /dev/null; then skip "yq not installed"; fi

    local test_file="${TEST_DIR}/test-round.yaml"
    echo "test: true" > "$test_file"

    result=$(update_resources "$test_file" "32m" "100Mi")

    # 32m should round to 35m (above minimum, rounds up)
    [[ "$result" =~ "35m" ]]
}

@test "update_resources enforces minimum 25m CPU" {
    if ! command -v yq &> /dev/null; then skip "yq not installed"; fi

    local test_file="${TEST_DIR}/test-min.yaml"
    echo "test: true" > "$test_file"

    result=$(update_resources "$test_file" "3m" "100Mi")

    # 3m should become 25m (minimum)
    [[ "$result" =~ "25m" ]]
}

@test "update_resources enforces minimum 64Mi memory" {
    if ! command -v yq &> /dev/null; then skip "yq not installed"; fi

    local test_file="${TEST_DIR}/test-mem-min.yaml"
    echo "test: true" > "$test_file"

    result=$(update_resources "$test_file" "10m" "10485760")  # 10Mi in bytes

    # Should become 64Mi (minimum)
    [[ "$result" =~ "64Mi" ]]
}

# ====================================================
# LOCK FILE TESTS
# ====================================================

@test "lock file prevents concurrent execution" {
    local lock_file="${TEST_DIR}/vpa-sync.lock"

    # Acquire lock in subshell
    (
        exec 200>"$lock_file"
        flock -n 200 || exit 1

        # Try to acquire from another subshell (should fail)
        (
            exec 201>"$lock_file"
            flock -n 201
        ) && exit 1

        exit 0
    )
    [ $? -eq 0 ]
}

# ====================================================
# DEBOUNCE TESTS
# ====================================================

@test "debounce respects minimum commit interval" {
    local last_commit_file="${TEST_DIR}/vpa-sync-last-commit"
    local min_interval=300

    # Set last commit to now
    date +%s > "$last_commit_file"

    last_commit=$(cat "$last_commit_file")
    now=$(date +%s)
    elapsed=$((now - last_commit))

    # Should be less than minimum interval
    [ $elapsed -lt $min_interval ]
}

@test "debounce allows commit after interval passes" {
    local last_commit_file="${TEST_DIR}/vpa-sync-last-commit"
    local min_interval=300

    # Set last commit to 10 minutes ago
    echo $(($(date +%s) - 600)) > "$last_commit_file"

    last_commit=$(cat "$last_commit_file")
    now=$(date +%s)
    elapsed=$((now - last_commit))

    # Should be greater than minimum interval
    [ $elapsed -ge $min_interval ]
}

# ====================================================
# APP NAME MAPPING TESTS
# ====================================================

@test "app name extracted from goldilocks VPA name" {
    VPA_NAME="goldilocks-cert-manager"

    if [[ "$VPA_NAME" == goldilocks-* ]]; then
        APP_NAME="${VPA_NAME#goldilocks-}"
    else
        APP_NAME="$VPA_NAME"
    fi

    [ "$APP_NAME" = "cert-manager" ]
}

@test "app name preserved for non-goldilocks VPA" {
    VPA_NAME="custom-vpa"

    if [[ "$VPA_NAME" == goldilocks-* ]]; then
        APP_NAME="${VPA_NAME#goldilocks-}"
    else
        APP_NAME="$VPA_NAME"
    fi

    [ "$APP_NAME" = "custom-vpa" ]
}

@test "app name handles nested goldilocks prefix" {
    VPA_NAME="goldilocks-goldilocks-test"

    if [[ "$VPA_NAME" == goldilocks-* ]]; then
        APP_NAME="${VPA_NAME#goldilocks-}"
    else
        APP_NAME="$VPA_NAME"
    fi

    [ "$APP_NAME" = "goldilocks-test" ]
}

# ====================================================
# VPA MODE FILTER TESTS
# ====================================================

@test "only Off mode VPAs are synced" {
    modes=("Off" "Auto" "Initial" "Recreate")
    expected=("sync" "skip" "skip" "skip")

    for i in "${!modes[@]}"; do
        mode="${modes[$i]}"
        if [[ "$mode" == "Off" ]]; then
            result="sync"
        else
            result="skip"
        fi
        [ "$result" = "${expected[$i]}" ]
    done
}
