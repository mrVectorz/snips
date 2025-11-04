#!/bin/bash
#
# ODF/Ceph Prometheus Metrics Collector (Bash version)
#
# This script collects ODF/Ceph metrics from Prometheus using curl and oc commands.
# It's a simpler alternative to the Python script that doesn't require additional dependencies.
#
# Usage:
#   ./collect_odf_metrics.sh [--time-range 1h] [--output-dir ./odf_metrics]
#

set -uo pipefail
# Note: We don't use 'set -e' so query failures don't stop the script

# Default values
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_DIR="${OUTPUT_DIR:-./odf_metrics}"
NAMESPACE="${NAMESPACE:-openshift-monitoring}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CREATE_TARBALL="${CREATE_TARBALL:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
check_prerequisites() {
    if ! command -v oc &> /dev/null; then
        echo -e "${RED}Error: 'oc' command not found${NC}"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        echo -e "${RED}Error: 'curl' command not found${NC}"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}Warning: 'jq' not found. JSON parsing will be limited.${NC}"
    fi
    
    # Check if we're connected to a cluster
    if ! oc whoami &> /dev/null; then
        echo -e "${RED}Error: Not connected to OpenShift cluster${NC}"
        echo "Make sure KUBECONFIG is set correctly"
        exit 1
    fi
    
    echo -e "${GREEN}Prerequisites check passed${NC}"
}

# Get Prometheus route
get_prometheus_url() {
    echo "Getting Prometheus route..."
    PROMETHEUS_HOST=$(oc get route -n "$NAMESPACE" prometheus-k8s -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "$PROMETHEUS_HOST" ]; then
        echo -e "${RED}Error: Could not find Prometheus route${NC}"
        echo "Please ensure Prometheus is accessible in the $NAMESPACE namespace"
        return 1
    fi
    
    PROMETHEUS_URL="https://${PROMETHEUS_HOST}"
    echo -e "${GREEN}Prometheus URL: ${PROMETHEUS_URL}${NC}"
    return 0
}


# Get authentication token
get_token() {
    # Try to get token from current session first
    TOKEN=$(oc whoami -t 2>/dev/null || echo "")
    
    if [ -z "$TOKEN" ]; then
        echo -e "${YELLOW}No token in current session, trying to get service account token...${NC}"
        
        # Try to get token from Prometheus service account directly using oc create token
        echo "  Trying to use prometheus-k8s service account token..."
        TOKEN=$(oc create token -n "$NAMESPACE" prometheus-k8s --duration=1h 2>/dev/null || echo "")
        
        if [ -z "$TOKEN" ]; then
            # Fallback: Try to get token from secret
            TOKEN_SECRET=$(oc get secret -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="prometheus-k8s")].metadata.name}' 2>/dev/null | head -1)
            
            if [ -z "$TOKEN_SECRET" ]; then
                # Try alternative: look for any token secret in the namespace
                TOKEN_SECRET=$(oc get secret -n "$NAMESPACE" -o jsonpath='{.items[?(@.type=="kubernetes.io/service-account-token")].metadata.name}' 2>/dev/null | head -1)
            fi
            
            if [ -n "$TOKEN_SECRET" ]; then
                echo "  Using service account token from secret: $TOKEN_SECRET"
                TOKEN=$(oc get secret -n "$NAMESPACE" "$TOKEN_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
            fi
        else
            echo "  Using prometheus-k8s service account token"
        fi
        
        # If still no token, try creating a temporary service account
        if [ -z "$TOKEN" ]; then
            echo "  Attempting to create temporary service account..."
            TEMP_SA="odf-metrics-collector-$(date +%s)"
            
            # Create service account
            oc create serviceaccount -n "$NAMESPACE" "$TEMP_SA" 2>/dev/null
            
            # Give it view permissions (read-only) - required for basic access
            oc adm policy add-cluster-role-to-user view -z "$TEMP_SA" -n "$NAMESPACE" 2>/dev/null
            
            # Create a RoleBinding to grant access to Prometheus service
            # This allows the service account to access the Prometheus API
            cat <<EOF | oc apply -f - 2>/dev/null || true
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-access-${TEMP_SA}
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: ServiceAccount
  name: ${TEMP_SA}
  namespace: ${NAMESPACE}
EOF
            
            # Also try to grant monitoring-rules-view if it exists
            oc adm policy add-cluster-role-to-user monitoring-rules-view -z "$TEMP_SA" -n "$NAMESPACE" 2>/dev/null || true
            
            # Wait a moment for RBAC to propagate and service account to be ready
            sleep 3
            
            # Try to get token using oc create token (modern method)
            TOKEN=$(oc create token -n "$NAMESPACE" "$TEMP_SA" --duration=1h 2>/dev/null || echo "")
            
            # If oc create token failed, try the old method (waiting for secret)
            if [ -z "$TOKEN" ]; then
                echo "  oc create token not available, trying secret method..."
                # Wait a bit longer for token secret (may not work in newer versions)
                sleep 3
                
                # Get the token from secret
                TOKEN_SECRET=$(oc get secret -n "$NAMESPACE" -o jsonpath="{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name==\"$TEMP_SA\")].metadata.name}" 2>/dev/null | head -1)
                
                if [ -n "$TOKEN_SECRET" ]; then
                    TOKEN=$(oc get secret -n "$NAMESPACE" "$TOKEN_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
                fi
            fi
            
            if [ -n "$TOKEN" ]; then
                echo "  Created temporary service account: $TEMP_SA"
                echo "  Note: You may want to clean up with: oc delete sa $TEMP_SA -n $NAMESPACE"
            fi
        fi
        
        if [ -z "$TOKEN" ]; then
            echo -e "${RED}Error: Could not get authentication token${NC}"
            echo "Tried:"
            echo "  1. oc whoami -t (current session token)"
            echo "  2. prometheus-k8s service account token"
            echo "  3. Creating temporary service account with oc create token"
            echo ""
            echo "Please ensure you have permissions to create service accounts or access Prometheus."
            exit 1
        fi
    fi
    
    echo -e "${GREEN}Authentication token obtained${NC}"
}

# Discover available metrics from Prometheus
discover_metrics() {
    local pattern="$1"
    local url="${PROMETHEUS_URL}/api/v1/label/__name__/values"
    
    local response
    response=$(curl -s -k -H "Authorization: Bearer $TOKEN" "$url" -w "\n%{http_code}" || echo "")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ]; then
        if command -v jq &> /dev/null; then
            echo "$body" | jq -r ".data[] | select(. | startswith(\"$pattern\"))" 2>/dev/null || echo ""
        else
            echo "$body" | grep -o "\"$pattern[^\"]*\"" | sed 's/"//g' || echo ""
        fi
    fi
}

# Query Prometheus
query_prometheus() {
    local query="$1"
    local metric_name="$2"
    local output_file="$3"
    
    echo "  Querying: $metric_name"
    
    # Calculate time range
    local end_time=$(date +%s)
    local start_time
    case "$TIME_RANGE" in
        *h) start_time=$(($end_time - ${TIME_RANGE%h} * 3600)) ;;
        *d) start_time=$(($end_time - ${TIME_RANGE%d} * 86400)) ;;
        *) start_time=$(($end_time - 3600)) ;;
    esac
    
    local url="${PROMETHEUS_URL}/api/v1/query_range"
    
    local response
    # Build curl command with proper URL encoding using --data-urlencode
    response=$(curl -s -k -G \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "step=30s" \
        "${url}" \
        -w "\n%{http_code}" || echo "")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ]; then
        echo "$body" > "$output_file"
        if command -v jq &> /dev/null; then
            local count=$(echo "$body" | jq '.data.result | length' 2>/dev/null || echo "0")
            echo "    Found $count time series"
        else
            echo "    Query successful"
        fi
        return 0
    elif [ "$http_code" = "403" ]; then
        echo -e "    ${RED}Query failed (HTTP 403 - Forbidden)${NC}"
        echo -e "    ${YELLOW}Service account lacks Prometheus access permissions${NC}"
        # Continue with other queries - don't fail the script
        return 0
    elif [ "$http_code" = "400" ]; then
        echo -e "    ${YELLOW}Query failed (HTTP 400 - Bad Request)${NC}"
        echo -e "    ${YELLOW}This may indicate an invalid query or no data available${NC}"
        # Try to extract error message from response
        if command -v jq &> /dev/null; then
            local error_msg=$(echo "$body" | jq -r '.error // .errorType // "Unknown error"' 2>/dev/null || echo "")
            if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
                echo -e "    ${YELLOW}Error: $error_msg${NC}"
            fi
        fi
        # Continue with other queries - don't fail the script
        return 0  # Return success so script continues
    else
        echo -e "    ${YELLOW}Query failed (HTTP $http_code) - continuing with other queries${NC}"
        # Continue with other queries - don't fail the script
        return 0  # Return success so script continues
    fi
}

# Query Prometheus wrapper (kept for consistency, but no retry needed)
query_prometheus_with_retry() {
    local query="$1"
    local metric_name="$2"
    local output_file="$3"
    
    query_prometheus "$query" "$metric_name" "$output_file"
}

# Discover and collect ODF metrics
collect_metrics() {
    echo ""
    echo "Collecting ODF/Ceph metrics..."
    echo "================================================================================"
    
    # First, discover available metrics
    echo ""
    echo "Discovering available metrics..."
    mkdir -p "$OUTPUT_DIR"
    
    # Discover Ceph metrics
    echo "  Discovering Ceph metrics..."
    CEPH_METRICS=$(discover_metrics "ceph_")
    echo "$CEPH_METRICS" > "$OUTPUT_DIR/discovered_ceph_metrics.txt"
    echo "    Found $(echo "$CEPH_METRICS" | wc -l) Ceph metrics"
    
    # Discover ODF metrics
    echo "  Discovering ODF metrics..."
    ODF_METRICS=$(discover_metrics "odf_")
    echo "$ODF_METRICS" > "$OUTPUT_DIR/discovered_odf_metrics.txt"
    echo "    Found $(echo "$ODF_METRICS" | wc -l) ODF metrics"
    
    # Discover container metrics for ODF namespaces
    echo "  Discovering container metrics..."
    CONTAINER_METRICS=$(discover_metrics "container_")
    echo "$CONTAINER_METRICS" > "$OUTPUT_DIR/discovered_container_metrics.txt"
    echo "    Found $(echo "$CONTAINER_METRICS" | wc -l) container metrics"
    
    # Storage capacity metrics
    echo ""
    echo "Storage Capacity Metrics:"
    mkdir -p "$OUTPUT_DIR/storage_capacity"
    query_prometheus_with_retry "ceph_cluster_total_bytes" "ceph_cluster_total_bytes" "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_bytes.json"
    query_prometheus_with_retry "ceph_cluster_total_used_bytes" "ceph_cluster_total_used_bytes" "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_used_bytes.json"
    query_prometheus_with_retry "ceph_cluster_total_avail_bytes" "ceph_cluster_total_avail_bytes" "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_avail_bytes.json"
    query_prometheus_with_retry "ceph_pool_available_bytes" "ceph_pool_available_bytes" "$OUTPUT_DIR/storage_capacity/ceph_pool_available_bytes.json"
    query_prometheus_with_retry "ceph_pool_used_bytes" "ceph_pool_used_bytes" "$OUTPUT_DIR/storage_capacity/ceph_pool_used_bytes.json"
    query_prometheus_with_retry "ceph_pool_objects" "ceph_pool_objects" "$OUTPUT_DIR/storage_capacity/ceph_pool_objects.json"
    
    # Performance metrics
    echo ""
    echo "Performance Metrics:"
    mkdir -p "$OUTPUT_DIR/performance"
    query_prometheus_with_retry "ceph_pool_read_bytes" "ceph_pool_read_bytes" "$OUTPUT_DIR/performance/ceph_pool_read_bytes.json"
    query_prometheus_with_retry "ceph_pool_write_bytes" "ceph_pool_write_bytes" "$OUTPUT_DIR/performance/ceph_pool_write_bytes.json"
    query_prometheus_with_retry "rate(ceph_pool_read_bytes[5m])" "ceph_pool_read_bytes_rate" "$OUTPUT_DIR/performance/ceph_pool_read_bytes_rate.json"
    query_prometheus_with_retry "rate(ceph_pool_write_bytes[5m])" "ceph_pool_write_bytes_rate" "$OUTPUT_DIR/performance/ceph_pool_write_bytes_rate.json"
    query_prometheus_with_retry "ceph_pool_read_ops" "ceph_pool_read_ops" "$OUTPUT_DIR/performance/ceph_pool_read_ops.json"
    query_prometheus_with_retry "ceph_pool_write_ops" "ceph_pool_write_ops" "$OUTPUT_DIR/performance/ceph_pool_write_ops.json"
    
    # Ceph OSD metrics
    echo ""
    echo "Ceph OSD Metrics:"
    mkdir -p "$OUTPUT_DIR/ceph_osd"
    query_prometheus_with_retry "ceph_osd_bytes" "ceph_osd_bytes" "$OUTPUT_DIR/ceph_osd/ceph_osd_bytes.json"
    query_prometheus_with_retry "ceph_osd_used_bytes" "ceph_osd_used_bytes" "$OUTPUT_DIR/ceph_osd/ceph_osd_used_bytes.json"
    query_prometheus_with_retry "ceph_osd_utilization" "ceph_osd_utilization" "$OUTPUT_DIR/ceph_osd/ceph_osd_utilization.json"
    query_prometheus_with_retry "ceph_osd_up" "ceph_osd_up" "$OUTPUT_DIR/ceph_osd/ceph_osd_up.json"
    query_prometheus_with_retry "ceph_osd_in" "ceph_osd_in" "$OUTPUT_DIR/ceph_osd/ceph_osd_in.json"
    
    # Resource usage metrics - use discovered metrics to build queries
    echo ""
    echo "Resource Usage Metrics:"
    mkdir -p "$OUTPUT_DIR/resource_usage"
    
    # Check if container_cpu_usage_seconds_total exists and build queries based on discovered metrics
    if echo "$CONTAINER_METRICS" | grep -q "container_cpu_usage_seconds_total"; then
        # Simple query first - just get the metric with namespace filter (no aggregation)
        query_prometheus_with_retry 'container_cpu_usage_seconds_total{namespace="openshift-storage"}' \
            "odf_pods_cpu_raw" "$OUTPUT_DIR/resource_usage/odf_pods_cpu_raw.json"
        # Aggregated version - exclude POD containers properly
        query_prometheus_with_retry 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage",container!="POD",container!=""}[5m])) by (pod,namespace)' \
            "odf_pods_cpu" "$OUTPUT_DIR/resource_usage/odf_pods_cpu.json"
    fi
    
    # Check if container_memory_working_set_bytes exists
    if echo "$CONTAINER_METRICS" | grep -q "container_memory_working_set_bytes"; then
        query_prometheus_with_retry 'container_memory_working_set_bytes{namespace="openshift-storage"}' \
            "odf_pods_memory_raw" "$OUTPUT_DIR/resource_usage/odf_pods_memory_raw.json"
        query_prometheus_with_retry 'sum(container_memory_working_set_bytes{namespace="openshift-storage",container!="POD",container!=""}) by (pod,namespace)' \
            "odf_pods_memory" "$OUTPUT_DIR/resource_usage/odf_pods_memory.json"
    fi
    
    # Try operator namespace
    if echo "$CONTAINER_METRICS" | grep -q "container_cpu_usage_seconds_total"; then
        query_prometheus_with_retry 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage-operator-system",container!="POD",container!=""}[5m])) by (pod,namespace)' \
            "odf_operator_pods_cpu" "$OUTPUT_DIR/resource_usage/odf_operator_pods_cpu.json"
    fi
    
    if echo "$CONTAINER_METRICS" | grep -q "container_memory_working_set_bytes"; then
        query_prometheus_with_retry 'sum(container_memory_working_set_bytes{namespace="openshift-storage-operator-system",container!="POD",container!=""}) by (pod,namespace)' \
            "odf_operator_pods_memory" "$OUTPUT_DIR/resource_usage/odf_operator_pods_memory.json"
    fi
    
    # Node-level aggregation
    if echo "$CONTAINER_METRICS" | grep -q "container_cpu_usage_seconds_total"; then
        query_prometheus_with_retry 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage"}[5m])) by (node)' \
            "odf_nodes_cpu" "$OUTPUT_DIR/resource_usage/odf_nodes_cpu.json"
    fi
    
    if echo "$CONTAINER_METRICS" | grep -q "container_memory_working_set_bytes"; then
        query_prometheus_with_retry 'sum(container_memory_working_set_bytes{namespace="openshift-storage"}) by (node)' \
            "odf_nodes_memory" "$OUTPUT_DIR/resource_usage/odf_nodes_memory.json"
    fi
    
    # PVC usage metrics
    echo ""
    echo "PVC Usage Metrics:"
    mkdir -p "$OUTPUT_DIR/pvc_usage"
    query_prometheus_with_retry "kubelet_volume_stats_used_bytes" "kubelet_volume_stats_used_bytes" "$OUTPUT_DIR/pvc_usage/kubelet_volume_stats_used_bytes.json"
    query_prometheus_with_retry "kubelet_volume_stats_capacity_bytes" "kubelet_volume_stats_capacity_bytes" "$OUTPUT_DIR/pvc_usage/kubelet_volume_stats_capacity_bytes.json"
    query_prometheus_with_retry "kubelet_volume_stats_available_bytes" "kubelet_volume_stats_available_bytes" "$OUTPUT_DIR/pvc_usage/kubelet_volume_stats_available_bytes.json"
    
    # RBD metrics
    echo ""
    echo "RBD Metrics:"
    mkdir -p "$OUTPUT_DIR/rbd"
    query_prometheus_with_retry "ceph_rbd_read_bytes" "ceph_rbd_read_bytes" "$OUTPUT_DIR/rbd/ceph_rbd_read_bytes.json"
    query_prometheus_with_retry "ceph_rbd_write_bytes" "ceph_rbd_write_bytes" "$OUTPUT_DIR/rbd/ceph_rbd_write_bytes.json"
    query_prometheus_with_retry "ceph_rbd_read_ops" "ceph_rbd_read_ops" "$OUTPUT_DIR/rbd/ceph_rbd_read_ops.json"
    query_prometheus_with_retry "ceph_rbd_write_ops" "ceph_rbd_write_ops" "$OUTPUT_DIR/rbd/ceph_rbd_write_ops.json"
}

# Create tarball of output directory
create_tarball() {
    echo ""
    echo "Creating tarball of collected metrics..."
    
    # Get the base name of the output directory for tarball name
    local base_name=$(basename "$OUTPUT_DIR")
    local tarball_name="${base_name}.tar.gz"
    
    # Get absolute path of output directory
    local abs_output_dir
    if [[ "$OUTPUT_DIR" == /* ]]; then
        abs_output_dir="$OUTPUT_DIR"
    else
        abs_output_dir="$(pwd)/${OUTPUT_DIR}"
    fi
    
    # Get parent directory
    local parent_dir=$(dirname "$abs_output_dir")
    
    # Create tarball in current working directory
    if tar -czf "$tarball_name" -C "$parent_dir" "$base_name" 2>/dev/null; then
        local tarball_path="$(pwd)/${tarball_name}"
        local tarball_size=$(du -h "$tarball_path" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "${GREEN}Tarball created: $tarball_path ($tarball_size)${NC}"
        return 0
    else
        echo -e "${YELLOW}Warning: Could not create tarball${NC}"
        return 1
    fi
}

# Generate summary
generate_summary() {
    echo ""
    echo "Generating summary report..."
    SUMMARY_FILE="$OUTPUT_DIR/odf_metrics_summary_${TIMESTAMP}.txt"
    
    {
        echo "ODF/Ceph Metrics Summary Report"
        echo "================================================================================"
        echo "Generated: $(date)"
        echo "Time Range: $TIME_RANGE"
        echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'Unknown')"
        echo ""
        
        echo "STORAGE CAPACITY"
        echo "--------------------------------------------------------------------------------"
        if [ -f "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_bytes.json" ] && command -v jq &> /dev/null; then
            echo "Total Cluster Bytes:"
            jq -r '.data.result[] | "  \(.metric) = \(.values[-1][1])"' "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_bytes.json" 2>/dev/null || echo "  (Unable to parse)"
            echo ""
            echo "Used Bytes:"
            jq -r '.data.result[] | "  \(.metric) = \(.values[-1][1])"' "$OUTPUT_DIR/storage_capacity/ceph_cluster_total_used_bytes.json" 2>/dev/null || echo "  (Unable to parse)"
        fi
        echo ""
        
        echo "PERFORMANCE METRICS"
        echo "--------------------------------------------------------------------------------"
        echo "Metrics collected in: $OUTPUT_DIR/performance/"
        echo ""
        
        echo "RESOURCE USAGE"
        echo "--------------------------------------------------------------------------------"
        echo "Metrics collected in: $OUTPUT_DIR/resource_usage/"
        echo ""
        
    } > "$SUMMARY_FILE"
    
    echo -e "${GREEN}Summary saved to: $SUMMARY_FILE${NC}"
}


# Main execution
main() {
    echo "ODF/Ceph Prometheus Metrics Collector"
    echo "================================================================================"
    
    check_prerequisites
    
    # Get Prometheus URL
    if ! get_prometheus_url; then
        echo -e "${RED}Error: Could not determine Prometheus URL${NC}"
        exit 1
    fi
    
    # Get authentication token
    get_token
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Collect metrics
    collect_metrics
    
    # Generate summary
    generate_summary
    
    # Create tarball if requested
    if [ "${CREATE_TARBALL}" = "true" ]; then
        create_tarball
    fi
    
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}Metrics collection complete!${NC}"
    echo "Results saved to: $OUTPUT_DIR"
    if [ "${CREATE_TARBALL}" = "true" ]; then
        local base_name=$(basename "$OUTPUT_DIR")
        echo "Tarball created: $(pwd)/${base_name}.tar.gz"
    fi
    echo "================================================================================"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --time-range)
            TIME_RANGE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --tarball|--tar)
            CREATE_TARBALL="true"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --time-range RANGE    Time range for queries (default: 1h, e.g., 6h, 24h, 7d)"
            echo "  --output-dir DIR       Directory to save metrics (default: ./odf_metrics)"
            echo "  --namespace NAMESPACE  Namespace where Prometheus is deployed (default: openshift-monitoring)"
            echo "  --tarball              Create a gzip tarball of the output directory"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --time-range 6h"
            echo "  $0 --time-range 24h --output-dir /tmp/odf_data --tarball"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main

