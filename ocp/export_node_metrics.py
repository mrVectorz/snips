# Marc Methot (mmethot)
# Built upon k8s_auth.py anisble module for oauth
# Exports data from oc promo for a specific node in csv type
# `python export_node_metrics.py | gzip -c > node_metrics_$(date +"%Y_%m_%d_%I_%M_%p").gz`

import requests
import urllib3
import sys
from urllib3.util import make_headers
from requests_oauthlib import OAuth2Session
from six.moves.urllib_parse import urlparse, parse_qs, urlencode
from pprint import pprint
import json
import csv

# Self signed certs used, disabling warning spam
urllib3.disable_warnings()

#HOST = 'https://master.example.org:8443'
HOST = 'https://openshift-master-0.example.com:6443'
#HOST = 'https://oauth-openshift.apps.cluster.example.com:6443'
USERNAME = 'kubeadmin'
PASSWORD = 'xSAho-fjU4y-srLg4-WFXXV'

# host to have its metrics exported, change to desired node
select_host= "openshift-worker-1.example.com"

# Gather authorization APIs info
oauth_server_info = requests.get('{}/.well-known/oauth-authorization-server'.format(HOST), verify=False).json()
openshift_oauth = OAuth2Session(client_id='openshift-challenging-client')
authorization_url, state = openshift_oauth.authorization_url(oauth_server_info['authorization_endpoint'], state="1", code_challenge_method='S256')
basic_auth_header = make_headers(basic_auth='{}:{}'.format(USERNAME, PASSWORD))

# Request auth using simple credentials
challenge_response = openshift_oauth.get(
    authorization_url,
    headers={'X-Csrf-Token': state, 'authorization': basic_auth_header.get('authorization')},
    verify=False,
    allow_redirects=False
)

if challenge_response.status_code != 200 and challenge_response.status_code != 302:
    print("ERROR Challenge: {2} {1} {0}".format(
        authorization_url,
        challenge_response.reason,
        challenge_response.status_code))
    exit()

qwargs = {k: v[0] for k, v in parse_qs(urlparse(challenge_response.headers['Location']).query).items()}
qwargs['grant_type'] = 'authorization_code'

# Using authorization code provided in the Location header we now request a token
auth = openshift_oauth.post(
    oauth_server_info['token_endpoint'],
    headers={
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
        # This is just base64 encoded 'openshift-challenging-client:'
        'Authorization': 'Basic b3BlbnNoaWZ0LWNoYWxsZW5naW5nLWNsaWVudDo='
    },
    data=urlencode(qwargs),
    verify=False
)

# Fails if we get anything but a 200 at this point
if auth.status_code != 200:
    print("ERROR Auth POST: {2} {1} {0}".format(
        oauth_server_info['token_endpoint'],
        auth.reason, auth.status_code))
    exit()

# We now have the Bearer token and can interact with the API
token_type = auth.json()['token_type']
access_token = auth.json()['access_token']

# Get prmotheus route
routes = requests.get('{}/apis/route.openshift.io/v1/routes'.format(HOST), verify=False, headers={'authorization': '{} {}'.format(token_type, access_token)}).json()
promo_route = ""

for r in routes['items']:
    try:
        ingress = r['status']['ingress'][0]['host']
        if ingress[0:10] == "prometheus":
            promo_route = ingress
    except:
        continue

def GetMetrixNames(url, HEADERS):
    response = requests.get('{0}/api/v1/label/__name__/values'.format(url), verify=False, headers=HEADERS)
    names = response.json()['data']
    return names
"""
Prometheus hourly data as csv.
"""

url = "https://{}".format(promo_route)
HEADERS = {'authorization': '{} {}'.format(token_type, access_token)}
writer = csv.writer(sys.stdout)

metricsNames=GetMetrixNames(url, HEADERS)
writeHeader=True
for metricsName in metricsNames:
     if metricsName[0:4] != 'node':
         continue
     # note(mmethot): the double curly brackets is to escape those otherwise format tries to interpret
     response = requests.get('{0}/api/v1/query'.format(url), verify=False, headers=HEADERS,
             params={'query': '{metric}{{instance="{host}"}}[5m]'.format(metric=metricsName, host=select_host)})

     if response.status_code  != 200:
         print("ERROR: Did not get 200 return code on promo query -- {}".format(response))
         continue
     results = response.json()['data']['result']

     # Example return
     """
     [{'metric': {'__name__': 'node_nf_conntrack_entries_limit', 'endpoint': 'https', 'instance': 'openshift-worker-1.example.com', 'job': 'node-exporter', 'namespace': 'openshift-monitoring', 'pod': 'node-exporter-qsm25', 'service': 'node-exporter'}, 'values': [[1611597496.32, '262144'], [1611597511.32, '262144'], [1611597526.32, '262144'], [1611597541.32, '262144'], [1611597556.32, '262144'], [1611597571.32, '262144'], [1611597586.32, '262144'], [1611597601.32, '262144'], [1611597616.32, '262144'], [1611597631.32, '262144'], [1611597646.32, '262144'], [1611597661.32, '262144'], [1611597676.32, '262144'], [1611597691.32, '262144'], [1611597706.32, '262144'], [1611597721.32, '262144'], [1611597736.32, '262144'], [1611597751.32, '262144'], [1611597766.32, '262144'], [1611597781.32, '262144']]}]
     """

     # Build a list of all labelnames used.
     # gets all keys and discard __name__
     labelnames = set()
     for result in results:
          labelnames.update(result['metric'].keys())
     # Canonicalize
     labelnames.discard('__name__')
     labelnames = sorted(labelnames)
     # Write the samples.
     if writeHeader:
          writer.writerow(['name', 'timestamp', 'value'] + labelnames)
          writeHeader=False

     for result in results:
          l = [result['metric'].get('__name__', '')] + result['values']
          for label in labelnames:
              l.append(result['metric'].get(label, ''))
              writer.writerow(l)
