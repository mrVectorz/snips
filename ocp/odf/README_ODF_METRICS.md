# ODF/Ceph Prometheus Metrics Collector

This collection of scripts helps you gather ODF (OpenShift Data Foundation) and Ceph metrics from the OpenShift monitoring stack's Prometheus instance. This data is essential for estimating the footprint of ODF/Ceph in a non-hyperconverged environment.

## Overview

The scripts collect comprehensive metrics including:
- **Storage Capacity**: Total cluster bytes, used bytes, available bytes, pool statistics
- **Performance Metrics**: IOPS, throughput, read/write operations, latency
- **Ceph OSD Metrics**: OSD utilization, bytes, status
- **Resource Usage**: CPU and memory consumption of ODF pods
- **PVC Usage**: Volume statistics for persistent volumes
- **RBD Metrics**: Block device read/write operations

## Prerequisites

### For Bash Script (Recommended - No dependencies)
- `oc` (OpenShift CLI) configured and authenticated
- `curl` command
- `jq` (optional, for JSON parsing)

### For Python Script
- Python 3.6+
- Dependencies: `pip install -r requirements.txt`
  - requests
  - kubernetes

## Usage

### Using the Bash Script (Recommended)

The bash script is simpler and doesn't require Python dependencies:

```bash
# Basic usage (collects last 1 hour of data)
./collect_odf_metrics.sh

# Collect 6 hours of data
./collect_odf_metrics.sh --time-range 6h

# Specify output directory
./collect_odf_metrics.sh --output-dir /tmp/odf_metrics --time-range 24h

# Create a tarball of the collected metrics
./collect_odf_metrics.sh --time-range 6h --tarball

# Combine options: collect 24h of data and create tarball
./collect_odf_metrics.sh --time-range 24h --output-dir /tmp/odf_data --tarball

# Custom namespace (if Prometheus is in different namespace)
./collect_odf_metrics.sh --namespace openshift-monitoring
```

### Using the Python Script

```bash
# Install dependencies first
pip3 install -r requirements.txt

# Basic usage
python3 collect_odf_metrics.py

# With options
python3 collect_odf_metrics.py --time-range 6h --output-dir ./odf_data

# The script automatically discovers available metrics and builds queries accordingly
```

## Output Structure

The scripts create the following directory structure:

```
odf_metrics/
├── discovered_ceph_metrics.txt        # List of available Ceph metrics
├── discovered_odf_metrics.txt          # List of available ODF metrics
├── discovered_container_metrics.txt   # List of available container metrics
├── odf_metrics_summary_*.txt           # Human-readable summary
├── storage_capacity/
│   └── *.json                          # Storage capacity metrics
├── performance/
│   └── *.json                          # Performance metrics
├── ceph_osd/
│   └── *.json                          # OSD metrics
├── resource_usage/
│   └── *.json                          # Resource consumption metrics
├── pvc_usage/
│   └── *.json                          # PVC statistics
└── rbd/
    └── *.json                          # RBD metrics

# If --tarball option is used, also creates:
odf_metrics.tar.gz                      # Compressed archive of all metrics
```

## Metrics Collected

### Storage Capacity
- `ceph_cluster_total_bytes` - Total cluster storage capacity
- `ceph_cluster_total_used_bytes` - Used storage
- `ceph_cluster_total_avail_bytes` - Available storage
- `ceph_pool_available_bytes` - Per-pool available bytes
- `ceph_pool_used_bytes` - Per-pool used bytes
- `ceph_pool_objects` - Number of objects per pool

### Performance
- `ceph_pool_read_bytes` / `ceph_pool_write_bytes` - I/O throughput
- `ceph_pool_read_ops` / `ceph_pool_write_ops` - IOPS
- `rate(ceph_pool_read_bytes[5m])` - Read throughput rate
- `rate(ceph_pool_write_bytes[5m])` - Write throughput rate

### Ceph OSD
- `ceph_osd_bytes` - OSD storage capacity
- `ceph_osd_used_bytes` - OSD used storage
- `ceph_osd_utilization` - OSD utilization percentage
- `ceph_osd_up` / `ceph_osd_in` - OSD status

### Resource Usage
- CPU usage for ODF pods (summed by pod and namespace)
- Memory usage for ODF pods (summed by pod and namespace)
- Node-level resource consumption

### PVC Usage
- `kubelet_volume_stats_used_bytes` - Used PVC space
- `kubelet_volume_stats_capacity_bytes` - PVC capacity
- `kubelet_volume_stats_available_bytes` - Available PVC space

## Analyzing the Data

The collected metrics are in JSON format and require analysis tools to visualize and interpret. Several analysis options are available:

### Option 1: Python Analysis Script (Recommended)

Use the provided analysis script for comprehensive analysis:

```bash
# Install optional visualization dependencies
pip install pandas matplotlib seaborn

# Run full analysis (generates reports, CSV exports, and plots)
python3 analyze_odf_metrics.py odf_metrics --output-dir analysis_output

# Analysis without plots (if matplotlib not installed)
python3 analyze_odf_metrics.py odf_metrics --no-plots
```

**Output includes:**
- HTML summary report with key statistics
- CSV exports for spreadsheet analysis
- Time series plots (if matplotlib installed)

### Option 2: Quick Summary

Check the automatically generated summary file:
```bash
cat odf_metrics/odf_metrics_summary_*.txt
```

### Option 3: Command-Line Analysis with jq

For quick analysis without Python:
```bash
# Get latest storage capacity
jq -r '.data.result[0].values[-1][1]' odf_metrics/storage_capacity/ceph_cluster_total_bytes.json

# Get average CPU usage
jq -r '[.data.result[].values[][1] | tonumber] | add / length' \
    odf_metrics/resource_usage/odf_pods_cpu.json
```

### Option 4: Spreadsheet Analysis

The analysis script exports CSV files that can be imported into Excel, Google Sheets, or other tools:
```bash
python3 analyze_odf_metrics.py odf_metrics
# CSV files will be in analysis_output/csv_exports/
```

### Option 5: Jupyter Notebook

For interactive analysis and custom visualizations, see `ANALYSIS_GUIDE.md` for examples.

### Detailed Analysis Guide

For comprehensive analysis options, examples, and workflows, see **[ANALYSIS_GUIDE.md](ANALYSIS_GUIDE.md)**.

## Troubleshooting

### "Could not find Prometheus route"
The script requires access to Prometheus via OpenShift routes. Ensure:
- Prometheus is deployed in the `openshift-monitoring` namespace
- The route `prometheus-k8s` exists and is accessible
- You have network access to the cluster's application routes

### "Not connected to OpenShift cluster"
Verify your KUBECONFIG is set correctly:
```bash
export KUBECONFIG=/path/to/kubeconfig
oc whoami
oc get nodes
```

### "No metrics found"
- Verify ODF is installed and running: `oc get pods -n openshift-storage`
- Check if Prometheus is scraping ODF metrics: `oc get servicemonitor -n openshift-storage`
- Verify time range - some metrics may not have data for the specified period

### Authentication Issues

**Certificate-based Authentication (KUBECONFIG without token):**

If you're using certificate-based authentication (like `system:admin`), `oc whoami -t` will fail. The scripts automatically handle this by:

1. First trying `oc whoami -t` (for token-based auth)
2. If that fails, using the `prometheus-k8s` service account token directly via `oc create token`
3. If that's not accessible, creating a temporary service account with view permissions

The script uses the Prometheus route for all queries, which requires proper authentication.

**Token-based Authentication:**

If you get 401/403 errors with token-based auth:
```bash
# Get a fresh token
oc whoami -t

# Verify you have access to Prometheus
oc get route -n openshift-monitoring prometheus-k8s
```

**Authentication Methods:**

The script automatically handles authentication by:
1. First trying `oc whoami -t` (for token-based auth sessions)
2. If that fails, using the `prometheus-k8s` service account token directly
3. As a last resort, creating a temporary service account with view permissions

This ensures the script works with both certificate-based authentication (like `system:admin`) and token-based authentication.

## Time Range Formats

The `--time-range` parameter accepts:
- `1h` - 1 hour
- `6h` - 6 hours
- `24h` - 24 hours
- `7d` - 7 days
- Or any Prometheus duration format

## Notes

- The scripts collect metrics for the specified time range ending at the current time
- Metrics are collected at 30-second intervals
- Some metrics may not be available if ODF components are not fully deployed
- The script automatically discovers available metrics from your cluster before querying
- Discovered metrics are saved to `discovered_*.txt` files for reference
- The script uses Prometheus route access - ensure your cluster's routes are accessible

## Example Workflow

```bash
# 1. Connect to environment
ssh 192.168.1.11
export KUBECONFIG=/home/kubeconfig-example-ocp.yaml

# 2. Verify connection
oc get nodes

# 3. Collect metrics (last 6 hours)
./collect_odf_metrics.sh --time-range 6h

# 4. Review summary
cat odf_metrics/odf_metrics_summary_*.txt

# 5. Analyze specific metrics
jq '.' odf_metrics/storage_capacity/ceph_cluster_total_bytes.json
```

## Support

For issues or questions:
1. Check that all prerequisites are met
2. Verify ODF is properly installed and running
3. Ensure Prometheus is accessible and scraping ODF metrics
4. Review the troubleshooting section above

