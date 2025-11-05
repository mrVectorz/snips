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

### SSH to the Environment

First, connect to your environment:

```bash
# Set KUBECONFIG
export KUBECONFIG=/home/gitlab-runner/kubeconfig-bos2-ocp1.yaml

# Verify connection
oc get nodes
```

### Using the Bash Script (Recommended)

The bash script is simpler and doesn't require Python dependencies:

**Important:** The script uses **peak-focused collection**. For each metric, it:
1. Searches the specified time range to find when the peak value occurred
2. Collects data for 1 hour before and 1 hour after that peak (2-hour window total)

This means:
- `--time-range 7d` searches the last 7 days to find the peak, then collects 2 hours around it
- `--time-range 24h` searches the last 24 hours to find the peak, then collects 2 hours around it
- The actual collected data is always 2 hours (around the peak), but the time range determines how far back to search for the peak

```bash
# Basic usage (searches last 1 hour for peak, collects 2h around peak)
./collect_odf_metrics.sh

# Search last 7 days for peak, then collect 2h around peak (recommended for sizing)
./collect_odf_metrics.sh --time-range 7d

# Search last 24 hours for peak, then collect 2h around peak
./collect_odf_metrics.sh --time-range 24h

# Specify output directory
./collect_odf_metrics.sh --output-dir /tmp/odf_metrics --time-range 7d

# Create a tarball of the collected metrics
./collect_odf_metrics.sh --time-range 7d --tarball

# Increase parallelism (faster collection, default is 10 concurrent queries)
./collect_odf_metrics.sh --time-range 7d --max-jobs 20

# Combine options: search 7 days, collect 2h around peak, create tarball
./collect_odf_metrics.sh --time-range 7d --output-dir /tmp/odf_data --tarball --max-jobs 15

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
│   └── *.json                          # Storage capacity metrics (2h around peak)
├── performance/
│   └── *.json                          # Performance metrics (2h around peak)
├── ceph_osd/
│   └── *.json                          # OSD metrics (2h around peak)
├── resource_usage/
│   └── *.json                          # Resource consumption metrics (2h around peak)
├── pvc_usage/
│   └── *.json                          # PVC statistics (2h around peak)
└── rbd/
    └── *.json                          # RBD metrics (2h around peak)

# If --tarball option is used, also creates:
odf_metrics.tar.gz                      # Compressed archive of all metrics
```

**Note:** Each JSON file contains:
- Standard Prometheus query response data (2-hour window around peak)
- Metadata fields: `peak_timestamp`, `window_start`, `window_end` (added by the collection script)

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

The `--time-range` parameter defines how far back to search for peak usage:
- `1h` - Search last 1 hour for peak (default)
- `6h` - Search last 6 hours for peak
- `24h` - Search last 24 hours for peak
- `7d` - Search last 7 days for peak (recommended for sizing analysis)

**Note:** Regardless of the time range specified, the script collects **2 hours of data** (1 hour before and 1 hour after the detected peak). The time range only determines the search window for finding the peak.

The script accepts any Prometheus duration format (e.g., `1h`, `6h`, `24h`, `7d`, `30d`).

## Notes

- **Peak-Focused Collection**: The script searches the specified time range to find peak values, then collects 2 hours of data around each peak (1 hour before and 1 hour after)
- Metrics are collected at 30-second intervals within the 2-hour window
- The `--time-range` parameter determines how far back to search for peaks, not how much data to collect
- Some metrics may not be available if ODF components are not fully deployed
- The script automatically discovers available metrics from your cluster before querying
- Discovered metrics are saved to `discovered_*.txt` files for reference
- The script uses Prometheus route access - ensure your cluster's routes are accessible

## Example Workflow

```bash
# 1. Connect to environment
ss jumphost
export KUBECONFIG=/home/kni/kubeconfig-bos2-ocp1.yaml

# 2. Verify connection
oc get nodes

# 3. Collect metrics (search 7 days for peak, collect 2h around peak)
./collect_odf_metrics.sh --time-range 7d

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

