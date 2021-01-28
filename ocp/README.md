## Exporting Promotheus Data
The following python scripts work in pair to export data from your Openshift Promotheus and then stream it to graphite.

If you do not have a graphite instance already running, this is how you can get setup quickly:
```
# sudo as port 80 is a protected port
sudo podman run -d  --name graphite \
 --restart=always \
 -v ./storage-schemas.conf \
 -p 80:80 \
 -p 2003-2004:2003-2004 \
 -p 2023-2024:2023-2024 \
 -p 8125:8125/udp \
 -p 8126:8126 \
 graphiteapp/graphite-statsd
```

The `./storage-schemas.conf` should either match your exported metrics as you want, or simply something like:
```
[metrics]
priority = 1
pattern = .*
retentions = 5s:7d,1m:90d
```

#### Exporting
The `export_node_metrics.py` script will use oauth to scrape 'node' metrics, for a specifed node.
It will then create compressed json files that it put in a directory that it creates based off the node of interest.
You can then create a tarball and move it to some more appropriate (or attach to a support case).

In the export script change the following values to match your requirements and environment:
```
# Auth server and credentials
HOST = 'https://oauth-openshift.apps.cluster.example.com:6443'
USERNAME = 'kubeadmin'
PASSWORD = 'ExamplePassword'

# Host to have its metrics exported, change to desired node
select_host = "openshift-worker-1.example.com"

# From how long ago are we pulling data for, example 5 minutes prior when this is executed
timeRange = "[5m]"
```

#### Importing
Using the `import_metrics_to_graphite.py` script we can stream the data from the json files into graphite.

Example: `python ocp_metrics_to_graphite.py ./metrics_openshift-worker-1.example.com_2021-01-26`

In the script change the following values to match your graphite server information:
```
CARBON_SERVER = '127.0.0.1'
CARBON_PORT = 2003
DELAY = 0.01
```
