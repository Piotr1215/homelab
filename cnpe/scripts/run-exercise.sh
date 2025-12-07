#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXERCISES_DIR="${SCRIPT_DIR}/../exercises"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Domain descriptions for context
declare -A DOMAIN_DESC=(
    ["01-gitops-cd"]="GitOps and Continuous Delivery (25%)"
    ["02-platform-apis"]="Platform APIs and Self-Service (25%)"
    ["03-observability"]="Observability and Operations (20%)"
    ["04-architecture"]="Platform Architecture (15%)"
    ["05-security"]="Security and Policy Enforcement (15%)"
    ["00-test-setup"]="Test Setup (validation only)"
)

usage() {
    cat <<EOF
Usage: $0 <exercise-path> [options]

Examples:
  $0 01-gitops-cd/01-fix-broken-sync
  $0 01-gitops-cd/02-canary-deployment --timeout 300

Options:
  --setup-only   Create broken state only (practice mode, no cleanup)
  --check-only   Run assertions only (verify your fix)
  --timeout N    Override timeout in seconds (default: 420)
  --no-cleanup   Skip cleanup after exercise (for debugging)

Workflow:
  1. Setup creates broken state
  2. You fix the problem using kubectl/CLI
  3. KUTTL validates your fix
  4. Cleanup removes all exercise resources
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage

EXERCISE_PATH="$1"
SETUP_ONLY=false
CHECK_ONLY=false
NO_CLEANUP=false
TIMEOUT=""

shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --setup-only) SETUP_ONLY=true; shift ;;
        --check-only) CHECK_ONLY=true; shift ;;
        --no-cleanup) NO_CLEANUP=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) usage ;;
    esac
done

# Parse domain and exercise
DOMAIN="${EXERCISE_PATH%%/*}"
EXERCISE="${EXERCISE_PATH#*/}"
DOMAIN_DIR="${EXERCISES_DIR}/${DOMAIN}"
EXERCISE_DIR="${DOMAIN_DIR}/${EXERCISE}"

if [[ ! -d "$EXERCISE_DIR" ]]; then
    echo -e "${RED}Exercise not found: ${EXERCISE_DIR}${NC}"
    echo ""
    echo "Available exercises:"
    find "$EXERCISES_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | \
        sed "s|${EXERCISES_DIR}/||" | sort
    exit 1
fi

# Extract namespace from setup file for cleanup
EXERCISE_NS=""
SETUP_FILE="${EXERCISE_DIR}/setup.yaml"
if [[ -f "$SETUP_FILE" ]]; then
    # Find namespace resource or first namespace reference
    EXERCISE_NS=$(grep -E "^  name: cnpe-" "$SETUP_FILE" 2>/dev/null | head -1 | awk '{print $2}' || true)
    if [[ -z "$EXERCISE_NS" ]]; then
        EXERCISE_NS=$(grep -E "namespace: cnpe-" "$SETUP_FILE" 2>/dev/null | head -1 | awk '{print $2}' || true)
    fi
fi

# Cleanup function - removes exercise namespace and resources
cleanup_exercise() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        echo -e "${YELLOW}Skipping cleanup (--no-cleanup)${NC}"
        return
    fi

    if [[ -n "$EXERCISE_NS" ]]; then
        echo -e "${YELLOW}Cleaning up namespace: ${EXERCISE_NS}...${NC}"
        kubectl delete namespace "$EXERCISE_NS" --wait=false 2>/dev/null || true
    fi

    # Also cleanup any ArgoCD apps created by exercise
    if [[ -f "$SETUP_FILE" ]]; then
        kubectl delete -f "$SETUP_FILE" 2>/dev/null || true
    fi
}

# Master cleanup - timer + resources
cleanup_all() {
    local exit_code=$?

    # Kill timer if running
    [[ -n "${TIMER_PID:-}" ]] && kill $TIMER_PID 2>/dev/null || true

    # Clear timer display
    printf "\e[s\e[1;$((${COLUMNS:-80} - 22))H%22s\e[u" " " 2>/dev/null || true

    # Remove temp files
    rm -f "${KUTTL_STATUS:-}" 2>/dev/null || true

    # Cleanup exercise resources
    if [[ "${CLEANUP_ON_EXIT:-false}" == "true" ]]; then
        echo ""
        cleanup_exercise
    fi

    exit $exit_code
}

# Get timeout from config or use default
if [[ -z "$TIMEOUT" ]]; then
    TIMEOUT=$(grep -E "^timeout:" "${DOMAIN_DIR}/kuttl-test.yaml" 2>/dev/null | awk '{print $2}')
    TIMEOUT=${TIMEOUT:-420}
fi

# Display header
clear
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC} ${BOLD}CNPE Exercise: ${EXERCISE_PATH}${NC}"
echo -e "${BLUE}║${NC} ${CYAN}Category: ${DOMAIN_DESC[$DOMAIN]:-Unknown}${NC}"
echo -e "${BLUE}║${NC} ${CYAN}Time Limit: $((TIMEOUT / 60)) minutes${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show task description
if [[ -f "${EXERCISE_DIR}/README.md" ]]; then
    cat "${EXERCISE_DIR}/README.md"
    echo ""
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Setup-only mode
if [[ "$SETUP_ONLY" == "true" ]]; then
    echo -e "${YELLOW}Setup mode: Creating broken state...${NC}"
    if kubectl apply -f "$SETUP_FILE" 2>&1; then
        echo ""
        echo -e "${GREEN}Setup complete.${NC}"
        echo -e "Namespace: ${CYAN}${EXERCISE_NS}${NC}"
        echo ""
        echo "When done practicing, cleanup with:"
        echo -e "  ${CYAN}kubectl delete namespace ${EXERCISE_NS}${NC}"
        echo ""
        echo "Or verify your fix with:"
        echo -e "  ${CYAN}$0 ${EXERCISE_PATH} --check-only${NC}"
    else
        echo -e "${RED}Setup failed!${NC}"
        exit 1
    fi
    exit 0
fi

# Check-only mode
if [[ "$CHECK_ONLY" == "true" ]]; then
    echo -e "${YELLOW}Verifying your solution...${NC}"
    echo ""

    KUTTL_CMD="kubectl-kuttl test ${DOMAIN_DIR} --config ${DOMAIN_DIR}/kuttl-test.yaml --test ${EXERCISE} --timeout ${TIMEOUT}"

    if $KUTTL_CMD; then
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✓ PASSED                                                     ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    else
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗ FAILED - Review the diff above                             ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi
    exit 0
fi

# Full run mode
echo ""
echo -e "${BOLD}Workflow:${NC}"
echo "  1. Press Enter -> Setup creates broken state"
echo "  2. Fix the problem using kubectl, CLI tools, or UIs"
echo "  3. KUTTL continuously checks until pass or timeout"
echo "  4. Cleanup runs automatically (pass, fail, or Ctrl+C)"
echo ""
echo -e "${YELLOW}Press Enter to start timer...${NC}"
read -r

# Enable cleanup on exit (after user confirms start)
CLEANUP_ON_EXIT=true
trap cleanup_all EXIT INT TERM

# Create broken state
echo -e "${YELLOW}Creating broken state...${NC}"
if ! kubectl apply -f "$SETUP_FILE" 2>&1; then
    echo -e "${RED}Setup failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Setup complete. Fix the problem now!${NC}"
echo ""

# Timer function
show_timer() {
    local start=$1
    local timeout=$2
    while true; do
        local elapsed=$(($(date +%s) - start))
        local remaining=$((timeout - elapsed))
        [[ $remaining -lt 0 ]] && remaining=0

        # Color based on time remaining
        local color=$GREEN
        [[ $remaining -lt 120 ]] && color=$YELLOW
        [[ $remaining -lt 60 ]] && color=$RED

        local timer_text=$(printf "%02d:%02d" $((remaining / 60)) $((remaining % 60)))
        printf "\e[s\e[1;$((${COLUMNS:-80} - 15))H${color}[${timer_text}]${NC}\e[u"
        sleep 1
    done
}

# Start timer
START_TIME=$(date +%s)
show_timer $START_TIME $TIMEOUT &
TIMER_PID=$!

# Run KUTTL with output filtering to show what was checked
KUTTL_STATUS=$(mktemp)
KUTTL_CMD="kubectl-kuttl test ${DOMAIN_DIR} --config ${DOMAIN_DIR}/kuttl-test.yaml --test ${EXERCISE} --timeout ${TIMEOUT}"

echo -e "${CYAN}KUTTL checking assertions (will pass when you fix the issue)...${NC}"
echo ""

# Run KUTTL and filter output to inject assert summaries
$KUTTL_CMD 2>&1 | while IFS= read -r line; do
    echo "$line"
    # When a test step completes, show description and what was checked
    if [[ "$line" =~ "test step completed" ]]; then
        # Extract step number from the line (e.g., "0-" from "test step completed 0-")
        step_num=$(echo "$line" | sed -n 's/.*test step completed \([0-9]*\).*/\1/p')
        if [[ -n "$step_num" ]]; then
            # Print step description from steps.txt if available
            steps_file="${EXERCISE_DIR}/steps.txt"
            if [[ -f "$steps_file" ]]; then
                step_desc=$(grep "^${step_num}:" "$steps_file" 2>/dev/null | cut -d: -f2-)
                if [[ -n "$step_desc" ]]; then
                    echo -e "${GREEN}    ✓ Step $((step_num + 1)): ${step_desc}${NC}"
                fi
            fi
            # Find and parse the assert file
            assert_file=$(find "$EXERCISE_DIR" -maxdepth 1 -name "0${step_num}-assert.yaml" -o -name "${step_num}-assert.yaml" 2>/dev/null | head -1)
            if [[ -f "$assert_file" ]]; then
                "${SCRIPT_DIR}/parse-assert.sh" "$assert_file"
            fi
        fi
    fi
done
PIPE_STATUS=${PIPESTATUS[0]}

if [[ $PIPE_STATUS -eq 0 ]]; then
    echo 0 > "$KUTTL_STATUS"
else
    echo 1 > "$KUTTL_STATUS"
fi

# Stop timer
kill $TIMER_PID 2>/dev/null || true
TIMER_PID=""

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Show result
KUTTL_EXIT=$(cat "$KUTTL_STATUS" 2>/dev/null || echo "1")

echo ""
if [[ "$KUTTL_EXIT" == "0" ]]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    printf "${GREEN}║  ✓ PASSED in %d:%02d                                            ║${NC}\n" $((ELAPSED / 60)) $((ELAPSED % 60))
    if [[ $ELAPSED -le 420 ]]; then
        echo -e "${GREEN}║  Within 7-minute exam target!                                 ║${NC}"
    else
        echo -e "${YELLOW}║  Over 7-minute target - practice more!                        ║${NC}"
    fi
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    printf "${RED}║  ✗ FAILED after %d:%02d                                         ║${NC}\n" $((ELAPSED / 60)) $((ELAPSED % 60))
    echo -e "${RED}║  Review the assertion diff above                              ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi
