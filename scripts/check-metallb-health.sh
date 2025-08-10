#!/bin/bash

# MetalLB Health Check Script
# Monitors MetalLB services and restarts components if needed

set -e

SERVICES=(
    "homepage:homepage:192.168.178.94"
    "argocd:argocd-server:192.168.178.93"
    "ingress-nginx:ingress-nginx-controller:192.168.178.90"
)

check_service() {
    local namespace=$1
    local service=$2
    local ip=$3
    
    echo "Checking $service in namespace $namespace (IP: $ip)..."
    
    # Check if IP responds
    if ! timeout 2 curl -s -o /dev/null -w "%{http_code}" "http://$ip" > /dev/null 2>&1; then
        echo "WARNING: Service $service at $ip is not responding"
        return 1
    fi
    
    echo "✓ Service $service is healthy"
    return 0
}

restart_metallb() {
    echo "Restarting MetalLB components..."
    kubectl rollout restart deployment controller -n metallb-system
    kubectl delete pod -l component=speaker -n metallb-system
    echo "Waiting for MetalLB to stabilize..."
    sleep 15
}

main() {
    local failed=0
    
    echo "=== MetalLB Health Check ==="
    echo "Time: $(date)"
    echo ""
    
    # Check if MetalLB pods are running
    if ! kubectl get pods -n metallb-system | grep -q "Running"; then
        echo "ERROR: MetalLB pods are not running"
        restart_metallb
        exit 1
    fi
    
    # Check each service
    for service_info in "${SERVICES[@]}"; do
        IFS=':' read -r namespace service ip <<< "$service_info"
        if ! check_service "$namespace" "$service" "$ip"; then
            ((failed++))
        fi
    done
    
    # If more than half of services are failing, restart MetalLB
    if [ $failed -gt $((${#SERVICES[@]} / 2)) ]; then
        echo ""
        echo "CRITICAL: Multiple services are not responding"
        restart_metallb
    elif [ $failed -gt 0 ]; then
        echo ""
        echo "WARNING: $failed service(s) not responding. Monitor closely."
    else
        echo ""
        echo "All services are healthy!"
    fi
}

main "$@"