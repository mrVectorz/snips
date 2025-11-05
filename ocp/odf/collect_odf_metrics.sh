#!/bin/bash
#
# ODF/Ceph Prometheus Metrics Collector (Bash version)
#
# This script collects ODF/Ceph metrics from Prometheus using curl and oc commands.
# It's a simpler alternative to the Python script that doesn't require additional dependencies.
#
# The script automatically discovers available metrics from Prometheus and filters them
# to only collect sizing-relevant metrics (storage capacity, IOPS, throughput, latency,
# CPU/memory usage, disk IO, network bandwidth, etc.) for capacity planning.
#
# Usage:
#   ./collect_odf_metrics.sh [--time-range 1h] [--output-dir ./odf_metrics] [--tarball]
#

set -uo pipefail
# Note: We don't use 'set -e' so query failures don't stop the script

# Default values
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_DIR="${OUTPUT_DIR:-./odf_metrics}"
NAMESPACE="${NAMESPACE:-openshift-monitoring}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CREATE_TARBALL="${CREATE_TARBALL:-false}"
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-10}"  # Maximum concurrent Prometheus queries

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
    local quiet="${4:-false}"  # Optional: suppress output for parallel execution
    
    if [ "$quiet" != "true" ]; then
        echo "  Querying: $metric_name"
    fi
    
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

# Calculate appropriate step size to stay under Prometheus 11,000 point limit
calculate_step_size() {
    local start_time="$1"
    local end_time="$2"
    
    local duration=$(($end_time - $start_time))
    # Maximum 11,000 points, so step = duration / 11000, rounded up to nearest reasonable value
    local min_step=$(($duration / 11000))
    
    # Round up to nearest reasonable step size (in seconds)
    # Use steps: 30s, 1m, 2m, 5m, 10m, 15m, 30m, 1h, etc.
    if [ $min_step -le 30 ]; then
        echo "30s"
    elif [ $min_step -le 60 ]; then
        echo "1m"
    elif [ $min_step -le 120 ]; then
        echo "2m"
    elif [ $min_step -le 300 ]; then
        echo "5m"
    elif [ $min_step -le 600 ]; then
        echo "10m"
    elif [ $min_step -le 900 ]; then
        echo "15m"
    elif [ $min_step -le 1800 ]; then
        echo "30m"
    elif [ $min_step -le 3600 ]; then
        echo "1h"
    else
        # For very long ranges, use 2h or more
        local hours=$((($min_step + 3600 - 1) / 3600))
        echo "${hours}h"
    fi
}

# Find peak value and timestamp for a metric
find_peak_timestamp() {
    local query="$1"
    local quiet="${2:-false}"
    
    # Calculate time range for peak detection
    local end_time=$(date +%s)
    local start_time
    case "$TIME_RANGE" in
        *h) start_time=$(($end_time - ${TIME_RANGE%h} * 3600)) ;;
        *d) start_time=$(($end_time - ${TIME_RANGE%d} * 86400)) ;;
        *) start_time=$(($end_time - 3600)) ;;
    esac
    
    # Calculate appropriate step size to avoid exceeding 11,000 point limit
    local step_size=$(calculate_step_size "$start_time" "$end_time")
    
    # Query to find peak value and timestamp
    # We'll use a subquery to get the max value, then find when it occurred
    local url="${PROMETHEUS_URL}/api/v1/query_range"
    
    # First, get the full range to find peak
    local response
    response=$(curl -s -k -G \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${start_time}" \
        --data-urlencode "end=${end_time}" \
        --data-urlencode "step=${step_size}" \
        "${url}" \
        -w "\n%{http_code}" || echo "")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        # If still failing, try with even larger step or split query
        if [ "$http_code" = "400" ]; then
            local error_msg=$(echo "$body" | grep -i "exceeded maximum resolution" || echo "")
            if [ -n "$error_msg" ]; then
                # Try with a much larger step as fallback
                local duration=$(($end_time - $start_time))
                if [ $duration -gt 86400 ]; then
                    # For ranges > 1 day, try 1h step
                    step_size="1h"
                    response=$(curl -s -k -G \
                        -H "Authorization: Bearer $TOKEN" \
                        --data-urlencode "query=${query}" \
                        --data-urlencode "start=${start_time}" \
                        --data-urlencode "end=${end_time}" \
                        --data-urlencode "step=${step_size}" \
                        "${url}" \
                        -w "\n%{http_code}" || echo "")
                    http_code=$(echo "$response" | tail -n1)
                    body=$(echo "$response" | sed '$d')
                    
                    # If still failing, try splitting into chunks
                    if [ "$http_code" != "200" ]; then
                        # Split into 6-hour chunks and find peak across all chunks
                        local chunk_size=21600  # 6 hours in seconds
                        local chunk_start=$start_time
                        local all_results=""
                        local peak_timestamp=""
                        local peak_value=""
                        
                        while [ $chunk_start -lt $end_time ]; do
                            local chunk_end=$(($chunk_start + $chunk_size))
                            if [ $chunk_end -gt $end_time ]; then
                                chunk_end=$end_time
                            fi
                            
                            local chunk_response
                            chunk_response=$(curl -s -k -G \
                                -H "Authorization: Bearer $TOKEN" \
                                --data-urlencode "query=${query}" \
                                --data-urlencode "start=${chunk_start}" \
                                --data-urlencode "end=${chunk_end}" \
                                --data-urlencode "step=5m" \
                                "${url}" \
                                -w "\n%{http_code}" || echo "")
                            
                            local chunk_http_code=$(echo "$chunk_response" | tail -n1)
                            local chunk_body=$(echo "$chunk_response" | sed '$d')
                            
                            if [ "$chunk_http_code" = "200" ]; then
                                # Find peak in this chunk
                                if command -v jq &> /dev/null; then
                                    local chunk_peak=$(echo "$chunk_body" | jq -r '
                                        [.data.result[]?.values[]? | select(.[1] != null and .[1] != "NaN") | .] 
                                        | sort_by(.[1] | tonumber) 
                                        | reverse 
                                        | if length > 0 then .[0] else empty end' 2>/dev/null || echo "")
                                    
                                    if [ -n "$chunk_peak" ] && [ "$chunk_peak" != "null" ]; then
                                        local chunk_peak_ts=$(echo "$chunk_peak" | jq -r '.[0] | tonumber' 2>/dev/null || echo "")
                                        local chunk_peak_val=$(echo "$chunk_peak" | jq -r '.[1] | tonumber' 2>/dev/null || echo "")
                                        
                                        if [ -n "$chunk_peak_ts" ] && [ -n "$chunk_peak_val" ]; then
                                            # Use bash arithmetic for comparison (avoiding bc dependency)
                                            local should_update=0
                                            if [ -z "$peak_value" ]; then
                                                should_update=1
                                            else
                                                # Compare using awk for floating point comparison
                                                if command -v awk &> /dev/null; then
                                                    should_update=$(awk "BEGIN {print ($chunk_peak_val > $peak_value) ? 1 : 0}")
                                                else
                                                    # Fallback: simple integer comparison
                                                    local chunk_int=${chunk_peak_val%.*}
                                                    local peak_int=${peak_value%.*}
                                                    if [ $chunk_int -gt $peak_int ]; then
                                                        should_update=1
                                                    fi
                                                fi
                                            fi
                                            
                                            if [ "$should_update" = "1" ]; then
                                                peak_timestamp=$chunk_peak_ts
                                                peak_value=$chunk_peak_val
                                            fi
                                        fi
                                    fi
                                fi
                            fi
                            
                            chunk_start=$chunk_end
                        done
                        
                        if [ -n "$peak_timestamp" ]; then
                            echo "$peak_timestamp"
                            return 0
                        fi
                    fi
                fi
            fi
        fi
        if [ "$http_code" != "200" ]; then
            return 1
        fi
    fi
    
    # Use jq to find the peak value and its timestamp
    if ! command -v jq &> /dev/null; then
        # Fallback: return middle of time range if jq not available
        echo $((start_time + (end_time - start_time) / 2))
        return 0
    fi
    
    # Find the peak value across all time series and get its timestamp
    # Flatten all values from all series, sort by value (descending), get first timestamp
    local peak_timestamp=$(echo "$body" | jq -r '
        [.data.result[]?.values[]? | select(.[1] != null and .[1] != "NaN") | .] 
        | sort_by(.[1] | tonumber) 
        | reverse 
        | if length > 0 then .[0][0] | tonumber else empty end' 2>/dev/null || echo "")
    
    # If no peak found, use middle of range
    if [ -z "$peak_timestamp" ] || [ "$peak_timestamp" = "null" ]; then
        peak_timestamp=$((start_time + (end_time - start_time) / 2))
    fi
    
    echo "$peak_timestamp"
    return 0
}

# Query Prometheus around peak time (1h before to 1h after peak)
query_prometheus_around_peak() {
    local query="$1"
    local metric_name="$2"
    local output_file="$3"
    local quiet="${4:-false}"
    
    if [ "$quiet" != "true" ]; then
        echo "  Querying: $metric_name (peak-focused)"
    fi
    
    # Find peak timestamp
    local peak_timestamp
    peak_timestamp=$(find_peak_timestamp "$query" "$quiet")
    
    if [ -z "$peak_timestamp" ]; then
        if [ "$quiet" != "true" ]; then
            echo -e "    ${YELLOW}Could not determine peak time, using full range${NC}"
        fi
        # Fallback to regular query
        query_prometheus "$query" "$metric_name" "$output_file" "$quiet"
        return $?
    fi
    
    # Calculate window: 1 hour before to 1 hour after peak
    local window_start=$(($peak_timestamp - 3600))
    local window_end=$(($peak_timestamp + 3600))
    local end_time=$(date +%s)
    
    # Ensure window doesn't go beyond current time
    if [ "$window_end" -gt "$end_time" ]; then
        window_end=$end_time
    fi
    
    # Ensure window doesn't go before start of time range
    local full_start_time
    case "$TIME_RANGE" in
        *h) full_start_time=$(($end_time - ${TIME_RANGE%h} * 3600)) ;;
        *d) full_start_time=$(($end_time - ${TIME_RANGE%d} * 86400)) ;;
        *) full_start_time=$(($end_time - 3600)) ;;
    esac
    if [ "$window_start" -lt "$full_start_time" ]; then
        window_start=$full_start_time
    fi
    
    local url="${PROMETHEUS_URL}/api/v1/query_range"
    
    # For 2-hour window, 30s step = 240 points, well under 11,000 limit
    # But if query fails, we'll try with larger step
    local step_size="30s"
    local response
    response=$(curl -s -k -G \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=${query}" \
        --data-urlencode "start=${window_start}" \
        --data-urlencode "end=${window_end}" \
        --data-urlencode "step=${step_size}" \
        "${url}" \
        -w "\n%{http_code}" || echo "")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    # If query fails due to resolution limit, try with larger step
    if [ "$http_code" = "400" ]; then
        local error_msg=$(echo "$body" | grep -i "exceeded maximum resolution" || echo "")
        if [ -n "$error_msg" ]; then
            # Try with 1m step (120 points for 2h)
            step_size="1m"
            response=$(curl -s -k -G \
                -H "Authorization: Bearer $TOKEN" \
                --data-urlencode "query=${query}" \
                --data-urlencode "start=${window_start}" \
                --data-urlencode "end=${window_end}" \
                --data-urlencode "step=${step_size}" \
                "${url}" \
                -w "\n%{http_code}" || echo "")
            http_code=$(echo "$response" | tail -n1)
            body=$(echo "$response" | sed '$d')
        fi
    fi
    
    if [ "$http_code" = "200" ]; then
        # Add metadata about peak time to the JSON
        if command -v jq &> /dev/null; then
            echo "$body" | jq --arg peak_time "$peak_timestamp" '
                . + {
                    peak_timestamp: ($peak_time | tonumber),
                    window_start: ('"$window_start"'),
                    window_end: ('"$window_end"')
                }' > "$output_file" 2>/dev/null || echo "$body" > "$output_file"
        else
            echo "$body" > "$output_file"
        fi
        
        if [ "$quiet" != "true" ]; then
            if command -v jq &> /dev/null; then
                local count=$(echo "$body" | jq '.data.result | length' 2>/dev/null || echo "0")
                local peak_time_str=$(date -d "@$peak_timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "@$peak_timestamp")
                echo "    Found $count time series (peak: $peak_time_str, window: 2h)"
            else
                echo "    Query successful (peak-focused, 2h window)"
            fi
        fi
        return 0
    elif [ "$http_code" = "403" ]; then
        if [ "$quiet" != "true" ]; then
            echo -e "    ${RED}Query failed (HTTP 403 - Forbidden)${NC}"
            echo -e "    ${YELLOW}Service account lacks Prometheus access permissions${NC}"
        fi
        return 0
    elif [ "$http_code" = "400" ]; then
        if [ "$quiet" != "true" ]; then
            echo -e "    ${YELLOW}Query failed (HTTP 400 - Bad Request)${NC}"
            echo -e "    ${YELLOW}This may indicate an invalid query or no data available${NC}"
        fi
        return 0
    else
        if [ "$quiet" != "true" ]; then
            echo -e "    ${YELLOW}Query failed (HTTP $http_code) - continuing${NC}"
        fi
        return 0
    fi
}

# Filter discovered metrics for sizing-relevant metrics
filter_sizing_metrics() {
    local metrics_list="$1"
    local category="$2"
    
    # Define patterns for sizing-relevant metrics
    case "$category" in
        "storage")
            # Storage capacity metrics - cluster, pool, OSD, bluestore
            # Match: cluster total/used, pool bytes/objects/stored, OSD stat bytes, bluestore allocated/stored
            echo "$metrics_list" | grep -E "^ceph_(cluster_(total_bytes|total_used_bytes|total_used_raw_bytes|by_class_total_bytes|by_class_total_used_bytes|by_class_total_used_raw_bytes)|pool_(avail_raw|bytes_used|objects|stored|stored_raw|max_avail|percent_used|quota_bytes|quota_objects|compress_bytes_used|compress_under_bytes|dirty|num_bytes_recovered|num_objects_recovered|objects_repaired)|osd_stat_(bytes|bytes_used)|osd_(weight|numpg|numpg_removing)|bluestore_(allocated|stored|compressed|compressed_allocated|compressed_original)|disk_occupation)$"
            ;;
        "performance")
            # IOPS, throughput, latency metrics - pool, RBD, OSD operations
            # Match: pool rd/wr ops/bytes, RBD ops/bytes/latency, OSD op metrics
            echo "$metrics_list" | grep -E "^ceph_(pool_(rd|wr|rd_bytes|wr_bytes|recovering_bytes_per_sec|recovering_objects_per_sec|recovering_keys_per_sec)|rbd_(read_bytes|write_bytes|read_ops|write_ops|read_latency_count|read_latency_sum|write_latency_count|write_latency_sum)|osd_op_(r|w|rw|in_bytes|out_bytes|r_in_bytes|r_out_bytes|rw_in_bytes|rw_out_bytes|w_in_bytes|latency_count|latency_sum|r_latency_count|r_latency_sum|w_latency_count|w_latency_sum|rw_latency_count|rw_latency_sum|r_prepare_latency_count|r_prepare_latency_sum|r_process_latency_count|r_process_latency_sum|w_prepare_latency_count|w_prepare_latency_sum|w_process_latency_count|w_process_latency_sum|rw_prepare_latency_count|rw_prepare_latency_sum|rw_process_latency_count|rw_process_latency_sum|before_queue_op_lat_count|before_queue_op_lat_sum|prepare_latency_count|prepare_latency_sum|process_latency_count|process_latency_sum)|osd_(recovery_bytes|recovery_ops|apply_latency_ms|commit_latency_ms)|pool_num_(bytes_recovered|objects_recovered))$"
            ;;
        "osd")
            # OSD status, utilization, and operational metrics
            # Match: OSD up/in/weight/pg counts, op counts, flags
            echo "$metrics_list" | grep -E "^ceph_(osd_(up|in|stat_bytes|stat_bytes_used|weight|numpg|numpg_removing|apply_latency_ms|commit_latency_ms|op_active|op_r|op_w|op_rw|op_wip|op_delayed_degraded|op_delayed_unreadable|flag_(nobackfill|nodeep_scrub|nodown|noin|noout|norebalance|norecover|noscrub|noup))|disk_occupation)$"
            ;;
        "rbd")
            # RBD specific metrics - read/write operations and latency
            echo "$metrics_list" | grep -E "^ceph_rbd_(read_bytes|write_bytes|read_ops|write_ops|read_latency_count|read_latency_sum|write_latency_count|write_latency_sum)$"
            ;;
        "latency")
            # Latency metrics for sizing performance requirements
            echo "$metrics_list" | grep -E "(latency|lat_count|lat_sum|apply_latency|commit_latency)" | grep -E "^ceph_(pool_|rbd_|osd_op_|osd_)"
            ;;
        *)
            echo "$metrics_list"
            ;;
    esac
}

# Query Prometheus in background (for parallel execution)
query_prometheus_background() {
    local query="$1"
    local metric_name="$2"
    local output_file="$3"
    
    # Run query in background, redirect output to temp file for logging
    local log_file=$(mktemp)
    (
        query_prometheus "$query" "$metric_name" "$output_file" > "$log_file" 2>&1
        echo "$log_file"  # Signal completion
    ) &
}

# Collect metrics from discovered list (parallel version)
collect_metrics_from_list() {
    local metrics_list="$1"
    local category="$2"
    local output_subdir="$3"
    local query_pattern="${4:-}"  # Optional: additional query pattern (e.g., rate, sum), default to empty
    local max_jobs="${5:-10}"  # Maximum parallel jobs (default: 10)
    
    if [ -z "$metrics_list" ]; then
        return 0
    fi
    
    # Build list of queries to execute
    local queries=()
    local metric_names=()
    local output_files=()
    
    while IFS= read -r metric; do
        [ -z "$metric" ] && continue
        
        local query="$metric"
        # Apply query pattern if provided
        if [ -n "$query_pattern" ]; then
            case "$query_pattern" in
                "rate")
                    query="rate(${metric}[5m])"
                    ;;
                "sum_rate")
                    query="sum(rate(${metric}[5m]))"
                    ;;
                "sum")
                    query="sum(${metric})"
                    ;;
            esac
        fi
        
        local safe_name=$(echo "$metric" | sed 's/[^a-zA-Z0-9_]/_/g')
        queries+=("$query")
        metric_names+=("$safe_name")
        output_files+=("$OUTPUT_DIR/$output_subdir/${safe_name}.json")
    done <<< "$metrics_list"
    
    local total=${#queries[@]}
    if [ "$total" -eq 0 ]; then
        return 0
    fi
    
    echo "  Collecting $total metrics (peak-focused: 1h before/after peak, parallel, max $max_jobs concurrent)..."
    
    # Execute queries in parallel with job limit
    local active_jobs=0
    local completed=0
    local log_files=()
    
    for i in "${!queries[@]}"; do
        # Wait if we've reached max concurrent jobs
        while [ "$active_jobs" -ge "$max_jobs" ]; do
            # Wait for any job to complete
            wait -n 2>/dev/null || true
            active_jobs=$((active_jobs - 1))
            completed=$((completed + 1))
            
            # Print progress every 10 completed queries
            if [ $((completed % 10)) -eq 0 ] && [ "$completed" -gt 0 ]; then
                echo "    Progress: $completed/$total metrics collected..."
            fi
        done
        
        # Start new query in background (peak-focused collection)
        local log_file=$(mktemp)
        log_files+=("$log_file")
        (
            query_prometheus_around_peak "${queries[$i]}" "${metric_names[$i]}" "${output_files[$i]}" "true" > "$log_file" 2>&1
        ) &
        
        active_jobs=$((active_jobs + 1))
    done
    
    # Wait for all remaining jobs to complete
    while [ "$active_jobs" -gt 0 ]; do
        wait -n 2>/dev/null || true
        active_jobs=$((active_jobs - 1))
        completed=$((completed + 1))
        
        if [ $((completed % 10)) -eq 0 ] && [ "$completed" -gt 0 ]; then
            echo "    Progress: $completed/$total metrics collected..."
        fi
    done
    
    # Print any errors from background jobs
    for log_file in "${log_files[@]}"; do
        if [ -f "$log_file" ]; then
            local error_content=$(cat "$log_file" 2>/dev/null | grep -i "error\|failed" || true)
            if [ -n "$error_content" ]; then
                echo "$error_content" | while IFS= read -r line; do
                    echo "    $line" >&2
                done
            fi
            rm -f "$log_file"
        fi
    done
    
    echo "    Completed: $total metrics"
    return $total
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
    
    # Filter for sizing-relevant metrics
    echo ""
    echo "Filtering sizing-relevant metrics..."
    
    # Storage capacity metrics
    echo ""
    echo "Storage Capacity Metrics:"
    mkdir -p "$OUTPUT_DIR/storage_capacity"
    STORAGE_METRICS=$(filter_sizing_metrics "$CEPH_METRICS" "storage")
    if [ -n "$STORAGE_METRICS" ]; then
        echo "$STORAGE_METRICS" > "$OUTPUT_DIR/discovered_storage_metrics.txt"
        echo "  Found $(echo "$STORAGE_METRICS" | wc -l) storage metrics"
        collect_metrics_from_list "$STORAGE_METRICS" "storage" "storage_capacity" "" "$MAX_PARALLEL_JOBS"
    else
        echo "  No storage metrics found"
    fi
    
    # Performance metrics (IOPS, throughput)
    echo ""
    echo "Performance Metrics:"
    mkdir -p "$OUTPUT_DIR/performance"
    PERF_METRICS=$(filter_sizing_metrics "$CEPH_METRICS" "performance")
    if [ -n "$PERF_METRICS" ]; then
        echo "$PERF_METRICS" > "$OUTPUT_DIR/discovered_performance_metrics.txt"
        echo "  Found $(echo "$PERF_METRICS" | wc -l) performance metrics"
        collect_metrics_from_list "$PERF_METRICS" "performance" "performance" "" "$MAX_PARALLEL_JOBS"
        
        # Also collect rate-based metrics for throughput
        PERF_RATE_METRICS=$(echo "$PERF_METRICS" | grep -E "(bytes|ops)$" | head -10)
        if [ -n "$PERF_RATE_METRICS" ]; then
            echo "  Collecting rate-based performance metrics..."
            collect_metrics_from_list "$PERF_RATE_METRICS" "performance" "performance" "rate" "$MAX_PARALLEL_JOBS"
        fi
        
        # Peak throughput metrics for sizing calculator (peak value + 1h window)
        echo "  Collecting peak throughput metrics for sizing..."
        query_prometheus_around_peak 'sum(rate(ceph_pool_rd_bytes[5m]))' \
            "peak_read_throughput" "$OUTPUT_DIR/performance/peak_read_throughput.json"
        query_prometheus_around_peak 'sum(rate(ceph_pool_wr_bytes[5m]))' \
            "peak_write_throughput" "$OUTPUT_DIR/performance/peak_write_throughput.json"
    else
        echo "  No performance metrics found"
    fi
    
    # Ceph OSD metrics
    echo ""
    echo "Ceph OSD Metrics:"
    mkdir -p "$OUTPUT_DIR/ceph_osd"
    OSD_METRICS=$(filter_sizing_metrics "$CEPH_METRICS" "osd")
    if [ -n "$OSD_METRICS" ]; then
        echo "$OSD_METRICS" > "$OUTPUT_DIR/discovered_osd_metrics.txt"
        echo "  Found $(echo "$OSD_METRICS" | wc -l) OSD metrics"
        collect_metrics_from_list "$OSD_METRICS" "osd" "ceph_osd" "" "$MAX_PARALLEL_JOBS"
    else
        echo "  No OSD metrics found"
    fi
    
    # Resource usage metrics - filter container metrics for CPU/memory
    echo ""
    echo "Resource Usage Metrics:"
    mkdir -p "$OUTPUT_DIR/resource_usage"
    
    # Filter container metrics for CPU and memory
    CPU_METRICS=$(echo "$CONTAINER_METRICS" | grep -E "^(container_cpu_usage_seconds_total|container_cpu_system_seconds_total|container_cpu_user_seconds_total)$")
    MEM_METRICS=$(echo "$CONTAINER_METRICS" | grep -E "^(container_memory_working_set_bytes|container_memory_rss|container_memory_cache|container_memory_usage_bytes)$")
    
    # CPU usage by pod
    if echo "$CPU_METRICS" | grep -q "container_cpu_usage_seconds_total"; then
        echo "  Collecting CPU usage metrics (peak-focused)..."
        query_prometheus_around_peak 'container_cpu_usage_seconds_total{namespace="openshift-storage"}' \
            "odf_pods_cpu_raw" "$OUTPUT_DIR/resource_usage/odf_pods_cpu_raw.json"
        query_prometheus_around_peak 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage",container!="POD",container!=""}[5m])) by (pod,namespace)' \
            "odf_pods_cpu" "$OUTPUT_DIR/resource_usage/odf_pods_cpu.json"
        query_prometheus_around_peak 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage-operator-system",container!="POD",container!=""}[5m])) by (pod,namespace)' \
            "odf_operator_pods_cpu" "$OUTPUT_DIR/resource_usage/odf_operator_pods_cpu.json"
        query_prometheus_around_peak 'sum(rate(container_cpu_usage_seconds_total{namespace="openshift-storage"}[5m])) by (node)' \
            "odf_nodes_cpu" "$OUTPUT_DIR/resource_usage/odf_nodes_cpu.json"
        
        # Peak metrics for sizing calculator (peak value + 1h window)
        echo "  Collecting peak CPU metrics for sizing..."
        query_prometheus_around_peak 'rate(container_cpu_usage_seconds_total{pod=~"rook-ceph-osd.*",namespace="openshift-storage"}[5m])' \
            "peak_osd_cpu" "$OUTPUT_DIR/resource_usage/peak_osd_cpu.json"
        query_prometheus_around_peak 'rate(container_cpu_usage_seconds_total{pod=~"rook-ceph-mon.*",namespace="openshift-storage"}[5m])' \
            "peak_mon_cpu" "$OUTPUT_DIR/resource_usage/peak_mon_cpu.json"
    fi
    
    # Memory usage by pod
    if echo "$MEM_METRICS" | grep -q "container_memory_working_set_bytes"; then
        echo "  Collecting memory usage metrics (peak-focused)..."
        query_prometheus_around_peak 'container_memory_working_set_bytes{namespace="openshift-storage"}' \
            "odf_pods_memory_raw" "$OUTPUT_DIR/resource_usage/odf_pods_memory_raw.json"
        query_prometheus_around_peak 'sum(container_memory_working_set_bytes{namespace="openshift-storage",container!="POD",container!=""}) by (pod,namespace)' \
            "odf_pods_memory" "$OUTPUT_DIR/resource_usage/odf_pods_memory.json"
        query_prometheus_around_peak 'sum(container_memory_working_set_bytes{namespace="openshift-storage-operator-system",container!="POD",container!=""}) by (pod,namespace)' \
            "odf_operator_pods_memory" "$OUTPUT_DIR/resource_usage/odf_operator_pods_memory.json"
        query_prometheus_around_peak 'sum(container_memory_working_set_bytes{namespace="openshift-storage"}) by (node)' \
            "odf_nodes_memory" "$OUTPUT_DIR/resource_usage/odf_nodes_memory.json"
        
        # Peak metrics for sizing calculator (peak value + 1h window)
        echo "  Collecting peak memory metrics for sizing..."
        query_prometheus_around_peak 'container_memory_working_set_bytes{pod=~"rook-ceph-osd.*",namespace="openshift-storage"}' \
            "peak_osd_memory" "$OUTPUT_DIR/resource_usage/peak_osd_memory.json"
        query_prometheus_around_peak 'container_memory_working_set_bytes{pod=~"rook-ceph-mon.*",namespace="openshift-storage"}' \
            "peak_mon_memory" "$OUTPUT_DIR/resource_usage/peak_mon_memory.json"
    fi
    
    # Disk IO metrics (if available)
    DISK_IO_METRICS=$(echo "$CONTAINER_METRICS" | grep -E "^(container_fs_(reads_bytes_total|writes_bytes_total|reads_total|writes_total|io_time_seconds_total))$")
    if [ -n "$DISK_IO_METRICS" ]; then
        echo "  Collecting disk IO metrics..."
        mkdir -p "$OUTPUT_DIR/resource_usage/disk_io"
        collect_metrics_from_list "$DISK_IO_METRICS" "disk_io" "resource_usage/disk_io" "" "$MAX_PARALLEL_JOBS"
    fi
    
    # PVC usage metrics
    echo ""
    echo "PVC Usage Metrics:"
    mkdir -p "$OUTPUT_DIR/pvc_usage"
    # Discover kubelet metrics
    KUBELET_METRICS=$(discover_metrics "kubelet_volume_stats")
    if [ -n "$KUBELET_METRICS" ]; then
        PVC_METRICS=$(echo "$KUBELET_METRICS" | grep -E "(used_bytes|capacity_bytes|available_bytes|inodes)")
        echo "  Found $(echo "$PVC_METRICS" | wc -l) PVC metrics"
        collect_metrics_from_list "$PVC_METRICS" "pvc" "pvc_usage" "" "$MAX_PARALLEL_JOBS"
    else
        echo "  No PVC metrics found"
    fi
    
    # RBD metrics
    echo ""
    echo "RBD Metrics:"
    mkdir -p "$OUTPUT_DIR/rbd"
    RBD_METRICS=$(filter_sizing_metrics "$CEPH_METRICS" "rbd")
    if [ -n "$RBD_METRICS" ]; then
        echo "$RBD_METRICS" > "$OUTPUT_DIR/discovered_rbd_metrics.txt"
        echo "  Found $(echo "$RBD_METRICS" | wc -l) RBD metrics"
        collect_metrics_from_list "$RBD_METRICS" "rbd" "rbd" "" "$MAX_PARALLEL_JOBS"
    else
        echo "  No RBD metrics found"
    fi
    
    # ODF system metrics (if available)
    if [ -n "$ODF_METRICS" ]; then
        echo ""
        echo "ODF System Metrics:"
        mkdir -p "$OUTPUT_DIR/odf_system"
        # Filter ODF metrics for sizing-relevant ones
        ODF_SIZING=$(echo "$ODF_METRICS" | grep -E "(iops|throughput|latency|capacity|objects|bytes)")
        if [ -n "$ODF_SIZING" ]; then
            echo "  Found $(echo "$ODF_SIZING" | wc -l) ODF sizing metrics"
            collect_metrics_from_list "$ODF_SIZING" "odf_system" "odf_system" "" "$MAX_PARALLEL_JOBS"
        fi
    fi
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
        --max-jobs)
            MAX_PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --time-range RANGE    Time range for queries (default: 1h, e.g., 6h, 24h, 7d)"
            echo "  --output-dir DIR       Directory to save metrics (default: ./odf_metrics)"
            echo "  --namespace NAMESPACE  Namespace where Prometheus is deployed (default: openshift-monitoring)"
            echo "  --tarball              Create a gzip tarball of the output directory"
            echo "  --max-jobs N           Maximum concurrent Prometheus queries (default: 10)"
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

