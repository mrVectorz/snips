# Marc Methot (mmethot)
# Built upon k8s_auth.py anisble module for oauth
# Exports data from oc promo for a specific node in json format
# 

import requests
import urllib3
import json
import os
import gzip
import datetime
from urllib3.util import make_headers
from requests_oauthlib import OAuth2Session
from six.moves.urllib_parse import urlparse, parse_qs, urlencode

# Self signed certs used, disabling warning spam
urllib3.disable_warnings()

# Auth server and credentials
HOST = 'https://openshift-master-0.example.com:6443'
#HOST = 'https://oauth-openshift.apps.cluster.example.com:6443'
USERNAME = 'kubeadmin'
PASSWORD = 'ExamplePassword'

# Host to have its metrics exported, change to desired node
select_host = "openshift-worker-1.example.com"
# From how long ago are we pulling data for, example 5 minutes prior when this is executed
timeRange = "[5m]"

# Gather authorization APIs info
oauth_server_info = requests.get('{}/.well-known/oauth-authorization-server'.format(HOST), verify=False).json()
openshift_oauth = OAuth2Session(client_id='openshift-challenging-client')
authorization_url, state = openshift_oauth.authorization_url(oauth_server_info['authorization_endpoint'], state="1", code_challenge_method='S256')
basic_auth_header = make_headers(basic_auth='{}:{}'.format(USERNAME, PASSWORD))

# Creating the directory
# TODO: try catch exceptions
dataDir = "metrics_{}_{}".format(select_host, datetime.date.today())
os.mkdir(dataDir)

# Creating the graphite config for later ingest: storage-schemas.conf
graphiteConfig = [
        '[commuting]',
        'priority = 100',
        'pattern = ^{}\..*'.format(select_host),
        'retentions = 10s:7d,1m:90d']
with open('./{}/storage-schemas.conf'.format(dataDir), 'w') as c:
    for line in graphiteConfig:
        c.write(line + '\n')


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

def GetMetricsNames(url, HEADERS):
    response = requests.get('{0}/api/v1/label/__name__/values'.format(url), verify=False, headers=HEADERS)
    names = response.json()['data']
    return names

url = "https://{}".format(promo_route)
HEADERS = {'authorization': '{} {}'.format(token_type, access_token)}

metricNames = GetMetricsNames(url, HEADERS)

for metricName in metricNames:
    if metricName[0:4] != 'node':
        continue
    # note(mmethot): the double curly brackets is to escape those otherwise format tries to interpret
    print("INFO: Qerying - {}".format('{metric}{{instance="{host}"}}{t}'.format(metric=metricName, host=select_host, t=timeRange)))
    response = requests.get('{0}/api/v1/query'.format(url), verify=False, headers=HEADERS,
            params={'query': '{metric}{{instance="{host}"}}{t}'.format(metric=metricName, host=select_host, t=timeRange)})

    if response.status_code  != 200:
        print("ERROR: Did not get 200 return code on promo query -- {}".format(response))
        continue
    
    data = response.json()
    json_str = json.dumps(data)+"\n"
    if len(data['data']['result']) > 1:
        with gzip.open('./{}/{}.json.gz'.format(dataDir, metricName), 'w') as f:
            f.write(json_str.encode('utf-8'))

print("INFO: Completed dump of promotheus metrics for host {} over the past {}".format(select_host, timeRange))
print("INFO: Suggesting creating a tarball of the {} directory".format(dataDir))
