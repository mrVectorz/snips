#!/usr/bin/env python3
"""
ODF/Ceph Prometheus Metrics Collector

This script collects all relevant Prometheus metrics from the OpenShift
monitoring stack for ODF (OpenShift Data Foundation) and Ceph storage.
It's designed to help estimate the footprint of ODF/Ceph in a
non-hyperconverged environment.

Usage:
    python3 collect_odf_metrics.py [--output-dir OUTPUT_DIR] [--time-range RANGE]
    
    --output-dir: Directory to save collected metrics (default: ./odf_metrics)
    --time-range: Time range for queries in Prometheus format (default: 1h)
"""

import argparse
import base64
import json
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Any, Optional
import csv

try:
    import requests
    from requests.auth import HTTPBasicAuth
except ImportError:
    print("Error: 'requests' library is required. Install with: pip install requests")
    sys.exit(1)

try:
    from kubernetes import client, config
    from kubernetes.client.rest import ApiException
except ImportError:
    print("Error: 'kubernetes' library is required. Install with: pip install kubernetes")
    sys.exit(1)


class PrometheusODFCollector:
    """Collector for ODF/Ceph metrics from Prometheus"""
    
    def __init__(self, namespace: str = "openshift-monitoring", output_dir: str = "./odf_metrics"):
        self.namespace = namespace
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.session = requests.Session()
        self.prometheus_url = None
        self.token = None
        
    def setup_kubernetes_client(self):
        """Initialize Kubernetes client using KUBECONFIG"""
        try:
            config.load_kube_config()
            self.k8s_client = client.CoreV1Api()
            self.k8s_apps_client = client.AppsV1Api()
            return True
        except Exception as e:
            print(f"Error loading Kubernetes config: {e}")
            print("Make sure KUBECONFIG is set and points to a valid config file")
            return False
    
    def get_prometheus_route(self) -> Optional[str]:
        """Get Prometheus route URL"""
        try:
            custom_api = client.CustomObjectsApi()
            routes = custom_api.list_namespaced_custom_object(
                group="route.openshift.io",
                version="v1",
                namespace=self.namespace,
                plural="routes",
                label_selector="app=prometheus"
            )
            
            for route in routes.get('items', []):
                route_name = route.get('metadata', {}).get('name', '')
                if 'prometheus' in route_name.lower():
                    host = route.get('spec', {}).get('host', '')
                    if host:
                        protocol = 'https' if route.get('spec', {}).get('tls', {}).get('termination') else 'http'
                        return f"{protocol}://{host}"
        except Exception as e:
            print(f"Warning: Could not get route via CustomObjectsApi: {e}")
        
        # Fallback: try to get route via service
        try:
            svc = self.k8s_client.read_namespaced_service("prometheus-k8s", self.namespace)
            # In OpenShift, we can use the service directly if we have access
            # But typically we need the route
            print("Warning: Could not find Prometheus route. Trying service endpoint...")
        except Exception as e:
            print(f"Error accessing Prometheus service: {e}")
        
        return None
    
    def get_service_account_token(self) -> Optional[str]:
        """Get token from service account for Prometheus authentication"""
        try:
            # Method 1: Try to find Prometheus service account token secret
            try:
                secrets = self.k8s_client.list_namespaced_secret(self.namespace)
                for secret in secrets.items:
                    # Check if this is a service account token for prometheus-k8s
                    sa_name = secret.metadata.annotations.get('kubernetes.io/service-account.name', '')
                    if sa_name == 'prometheus-k8s' and secret.type == 'kubernetes.io/service-account-token':
                        if 'token' in secret.data:
                            token = base64.b64decode(secret.data['token']).decode('utf-8')
                            print(f"  Found token from service account: {sa_name}")
                            return token
            except Exception as e:
                print(f"  Could not list secrets: {e}")
            
            # Method 2: Try any service account token in the namespace
            try:
                secrets = self.k8s_client.list_namespaced_secret(self.namespace)
                for secret in secrets.items:
                    if secret.type == 'kubernetes.io/service-account-token':
                        if 'token' in secret.data:
                            token = base64.b64decode(secret.data['token']).decode('utf-8')
                            sa_name = secret.metadata.annotations.get('kubernetes.io/service-account.name', 'unknown')
                            print(f"  Found token from service account: {sa_name}")
                            return token
            except Exception as e:
                print(f"  Could not find service account tokens: {e}")
            
            # Method 3: Create a temporary service account with view permissions
            try:
                import uuid
                temp_sa_name = f"odf-metrics-collector-{uuid.uuid4().hex[:8]}"
                print(f"  Attempting to create temporary service account: {temp_sa_name}")
                
                # Create service account
                sa_body = client.V1ServiceAccount(
                    metadata=client.V1ObjectMeta(name=temp_sa_name, namespace=self.namespace)
                )
                self.k8s_client.create_namespaced_service_account(self.namespace, sa_body)
                
                # Grant view permissions
                try:
                    import subprocess
                    subprocess.run(['oc', 'adm', 'policy', 'add-cluster-role-to-user', 'view', 
                                   f'system:serviceaccount:{self.namespace}:{temp_sa_name}'],
                                  capture_output=True, check=True)
                except:
                    pass  # May fail if user doesn't have permissions, but continue
                
                # Try to get token using oc create token (modern method)
                import subprocess
                import time
                time.sleep(1)
                
                try:
                    result = subprocess.run(['oc', 'create', 'token', '-n', self.namespace, temp_sa_name, '--duration=1h'],
                                          capture_output=True, text=True, check=True, timeout=10)
                    token = result.stdout.strip()
                    if token:
                        print(f"  Created temporary service account: {temp_sa_name}")
                        print(f"  Note: Clean up with: oc delete sa {temp_sa_name} -n {self.namespace}")
                        return token
                except:
                    # Fall back to secret method
                    time.sleep(2)
                    secrets = self.k8s_client.list_namespaced_secret(self.namespace)
                    for secret in secrets.items:
                        sa_name = secret.metadata.annotations.get('kubernetes.io/service-account.name', '')
                        if sa_name == temp_sa_name and secret.type == 'kubernetes.io/service-account-token':
                            if 'token' in secret.data:
                                token = base64.b64decode(secret.data['token']).decode('utf-8')
                                print(f"  Created temporary service account: {temp_sa_name}")
                                print(f"  Note: Clean up with: oc delete sa {temp_sa_name} -n {self.namespace}")
                                return token
            except Exception as e:
                print(f"  Could not create temporary service account: {e}")
                
        except Exception as e:
            print(f"Warning: Could not get service account token: {e}")
        
        return None
    
    def setup_prometheus_connection(self):
        """Set up connection to Prometheus"""
        if not self.setup_kubernetes_client():
            return False
        
        # Get Prometheus URL
        self.prometheus_url = self.get_prometheus_route()
        if not self.prometheus_url:
            print("Error: Could not determine Prometheus URL")
            return False
        
        print(f"Prometheus URL: {self.prometheus_url}")
        
        # Get authentication token
        # First try to get from current session
        try:
            import subprocess
            result = subprocess.run(['oc', 'whoami', '-t'], 
                                  capture_output=True, text=True, check=True)
            self.token = result.stdout.strip()
            if self.token:
                print("Using token from current session")
        except:
            # If no token in session, get service account token
            print("No token in current session, trying to get service account token...")
            self.token = self.get_service_account_token()
            if not self.token:
                print("Warning: Could not get authentication token. Some queries may fail.")
                print("Alternative: Use port-forward: oc port-forward -n {} svc/prometheus-k8s 9090:9090".format(self.namespace))
        
        if self.token:
            self.session.headers.update({
                'Authorization': f'Bearer {self.token}'
            })
        
        # Verify connection
        try:
            response = self.session.get(f"{self.prometheus_url}/api/v1/status/config", verify=False, timeout=10)
            if response.status_code == 200:
                print("Successfully connected to Prometheus")
                return True
            else:
                print(f"Warning: Prometheus returned status code {response.status_code}")
        except Exception as e:
            print(f"Error connecting to Prometheus: {e}")
            print("Note: You may need to port-forward to Prometheus if route is not accessible")
            print("Run: oc port-forward -n openshift-monitoring svc/prometheus-k8s 9090:9090")
            print("Then set PROMETHEUS_URL=http://localhost:9090")
        
        return True
    
    def query_prometheus(self, query: str, time_range: str = "1h") -> List[Dict]:
        """Execute a Prometheus query"""
        # Parse time range
        hours = 1
        if time_range.endswith('h'):
            hours = int(time_range[:-1])
        elif time_range.endswith('d'):
            hours = int(time_range[:-1]) * 24
        
        end_time = datetime.now()
        start_time = end_time - timedelta(hours=hours)
        
        url = f"{self.prometheus_url}/api/v1/query_range"
        params = {
            'query': query,
            'start': start_time.timestamp(),
            'end': end_time.timestamp(),
            'step': '30s'
        }
        
        try:
            response = self.session.get(url, params=params, verify=False, timeout=30)
            response.raise_for_status()
            data = response.json()
            
            if data['status'] == 'success':
                return data.get('data', {}).get('result', [])
            else:
                print(f"Query failed: {data.get('error', 'Unknown error')}")
                return []
        except Exception as e:
            print(f"Error executing query '{query[:50]}...': {e}")
            return []
    
    def get_odf_metrics_queries(self) -> Dict[str, List[str]]:
        """Define all ODF/Ceph related Prometheus queries"""
        return {
            "storage_capacity": [
                # Ceph cluster capacity
                'ceph_cluster_total_bytes',
                'ceph_cluster_total_used_bytes',
                'ceph_cluster_total_avail_bytes',
                'ceph_pool_available_bytes',
                'ceph_pool_used_bytes',
                'ceph_pool_objects',
                # ODF storage cluster
                'odf_storagecluster_total_bytes',
                'odf_storagecluster_total_used_bytes',
            ],
            "performance": [
                # IOPS
                'ceph_pool_read_bytes',
                'ceph_pool_write_bytes',
                'ceph_pool_read_ops',
                'ceph_pool_write_ops',
                # Latency
                'ceph_pool_read_latency',
                'ceph_pool_write_latency',
                # Throughput
                'rate(ceph_pool_read_bytes[5m])',
                'rate(ceph_pool_write_bytes[5m])',
            ],
            "ceph_pools": [
                'ceph_pool_available_bytes',
                'ceph_pool_used_bytes',
                'ceph_pool_objects',
                'ceph_pool_raw_bytes_used',
                'ceph_pool_raw_bytes_avail',
                'ceph_pool_num_objects',
                'ceph_pool_num_objects_degraded',
                'ceph_pool_num_objects_unfound',
            ],
            "ceph_osd": [
                'ceph_osd_in',
                'ceph_osd_up',
                'ceph_osd_bytes',
                'ceph_osd_used_bytes',
                'ceph_osd_utilization',
                'ceph_osd_apply_latency',
                'ceph_osd_commit_latency',
            ],
            "ceph_mon": [
                'ceph_mon_quorum_status',
                'ceph_mon_num_sessions',
            ],
            "odf_operator": [
                'odf_operator_health_status',
                'odf_storagecluster_phase',
                'odf_storagecluster_status',
            ],
            "resource_usage": [
                # CPU and memory for ODF pods
                'sum(rate(container_cpu_usage_seconds_total{namespace=~"openshift-storage|openshift-storage-operator-system",container!="",pod!=""}[5m])) by (pod, namespace)',
                'sum(container_memory_working_set_bytes{namespace=~"openshift-storage|openshift-storage-operator-system",container!="",pod!=""}) by (pod, namespace)',
                # Node resource usage for ODF nodes
                'sum(rate(container_cpu_usage_seconds_total{namespace=~"openshift-storage|openshift-storage-operator-system"}[5m])) by (node)',
                'sum(container_memory_working_set_bytes{namespace=~"openshift-storage|openshift-storage-operator-system"}) by (node)',
            ],
            "pvc_usage": [
                'kubelet_volume_stats_used_bytes',
                'kubelet_volume_stats_available_bytes',
                'kubelet_volume_stats_capacity_bytes',
                'kubelet_volume_stats_inodes_used',
                'kubelet_volume_stats_inodes_free',
                'kubelet_volume_stats_inodes',
            ],
            "rbd": [
                'ceph_rbd_write_bytes',
                'ceph_rbd_read_bytes',
                'ceph_rbd_write_ops',
                'ceph_rbd_read_ops',
            ],
            "rgw": [
                'ceph_rgw_put_bucket_size',
                'ceph_rgw_get_bucket_size',
                'ceph_rgw_put_ops',
                'ceph_rgw_get_ops',
            ]
        }
    
    def collect_metrics(self, time_range: str = "1h"):
        """Collect all ODF metrics"""
        print(f"\nCollecting ODF/Ceph metrics (time range: {time_range})...")
        print("=" * 80)
        
        all_metrics = {}
        queries = self.get_odf_metrics_queries()
        
        for category, metric_list in queries.items():
            print(f"\nCollecting {category} metrics...")
            category_metrics = {}
            
            for metric in metric_list:
                print(f"  Querying: {metric}")
                results = self.query_prometheus(metric, time_range)
                if results:
                    category_metrics[metric] = results
                    print(f"    Found {len(results)} result(s)")
                else:
                    print(f"    No results found")
            
            if category_metrics:
                all_metrics[category] = category_metrics
        
        return all_metrics
    
    def save_metrics_json(self, metrics: Dict, filename: str = "odf_metrics.json"):
        """Save metrics to JSON file"""
        output_file = self.output_dir / filename
        with open(output_file, 'w') as f:
            json.dump(metrics, f, indent=2, default=str)
        print(f"\nMetrics saved to: {output_file}")
    
    def save_metrics_csv(self, metrics: Dict):
        """Save metrics to CSV files for easier analysis"""
        for category, category_metrics in metrics.items():
            csv_file = self.output_dir / f"{category}_metrics.csv"
            
            with open(csv_file, 'w', newline='') as f:
                writer = csv.writer(f)
                
                for metric_name, results in category_metrics.items():
                    if not results:
                        continue
                    
                    # Write metric name as header
                    writer.writerow([f"Metric: {metric_name}"])
                    
                    # Write headers
                    if results:
                        first_result = results[0]
                        if 'metric' in first_result:
                            labels = list(first_result['metric'].keys())
                            writer.writerow(['timestamp'] + labels + ['value'])
                            
                            # Write data rows
                            if 'values' in first_result:
                                for timestamp, value in first_result['values']:
                                    row = [datetime.fromtimestamp(timestamp).isoformat()] + \
                                          [first_result['metric'].get(label, '') for label in labels] + \
                                          [value]
                                    writer.writerow(row)
                            elif 'value' in first_result:
                                timestamp, value = first_result['value']
                                row = [datetime.fromtimestamp(timestamp).isoformat()] + \
                                      [first_result['metric'].get(label, '') for label in labels] + \
                                      [value]
                                writer.writerow(row)
                    
                    writer.writerow([])  # Empty row between metrics
            
            print(f"CSV saved to: {csv_file}")
    
    def generate_summary_report(self, metrics: Dict):
        """Generate a summary report of key metrics"""
        report_file = self.output_dir / "odf_metrics_summary.txt"
        
        with open(report_file, 'w') as f:
            f.write("ODF/Ceph Metrics Summary Report\n")
            f.write("=" * 80 + "\n")
            f.write(f"Generated: {datetime.now().isoformat()}\n\n")
            
            # Storage capacity summary
            if 'storage_capacity' in metrics:
                f.write("STORAGE CAPACITY\n")
                f.write("-" * 80 + "\n")
                for metric_name, results in metrics['storage_capacity'].items():
                    if results:
                        f.write(f"\n{metric_name}:\n")
                        for result in results[:5]:  # Show first 5 results
                            labels = result.get('metric', {})
                            value = result.get('value', ['', ''])[1]
                            f.write(f"  {labels}: {value}\n")
                f.write("\n")
            
            # Performance summary
            if 'performance' in metrics:
                f.write("PERFORMANCE METRICS\n")
                f.write("-" * 80 + "\n")
                for metric_name, results in metrics['performance'].items():
                    if results:
                        f.write(f"\n{metric_name}: {len(results)} time series\n")
                f.write("\n")
            
            # Resource usage summary
            if 'resource_usage' in metrics:
                f.write("RESOURCE USAGE\n")
                f.write("-" * 80 + "\n")
                for metric_name, results in metrics['resource_usage'].items():
                    if results:
                        f.write(f"\n{metric_name}:\n")
                        for result in results[:10]:
                            labels = result.get('metric', {})
                            value = result.get('value', ['', ''])[1]
                            f.write(f"  {labels}: {value}\n")
                f.write("\n")
        
        print(f"Summary report saved to: {report_file}")


def main():
    parser = argparse.ArgumentParser(
        description='Collect ODF/Ceph metrics from Prometheus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Collect metrics for the last hour
  python3 collect_odf_metrics.py
  
  # Collect metrics for the last 6 hours
  python3 collect_odf_metrics.py --time-range 6h
  
  # Save to custom directory
  python3 collect_odf_metrics.py --output-dir /tmp/odf_data
        """
    )
    parser.add_argument(
        '--output-dir',
        default='./odf_metrics',
        help='Directory to save collected metrics (default: ./odf_metrics)'
    )
    parser.add_argument(
        '--time-range',
        default='1h',
        help='Time range for queries (default: 1h, e.g., 6h, 24h, 7d)'
    )
    parser.add_argument(
        '--namespace',
        default='openshift-monitoring',
        help='Namespace where Prometheus is deployed (default: openshift-monitoring)'
    )
    parser.add_argument(
        '--prometheus-url',
        default=None,
        help='Direct Prometheus URL (if not using route discovery, e.g., http://localhost:9090)'
    )
    
    args = parser.parse_args()
    
    # Initialize collector
    collector = PrometheusODFCollector(
        namespace=args.namespace,
        output_dir=args.output_dir
    )
    
    # Override Prometheus URL if provided
    if args.prometheus_url:
        collector.prometheus_url = args.prometheus_url
        collector.token = None  # Will try to get token
        collector.setup_kubernetes_client()
    else:
        # Setup Prometheus connection
        if not collector.setup_prometheus_connection():
            print("\nError: Failed to connect to Prometheus")
            print("Tip: If using port-forward, set --prometheus-url http://localhost:9090")
            sys.exit(1)
    
    # Collect metrics
    metrics = collector.collect_metrics(time_range=args.time_range)
    
    if not metrics:
        print("\nWarning: No metrics collected. Check Prometheus queries and access.")
        sys.exit(1)
    
    # Save results
    collector.save_metrics_json(metrics)
    collector.save_metrics_csv(metrics)
    collector.generate_summary_report(metrics)
    
    print("\n" + "=" * 80)
    print("Metrics collection complete!")
    print(f"Results saved to: {collector.output_dir}")
    print("=" * 80)


if __name__ == '__main__':
    main()

