# Marc Methot (mmethot)
# Built upon k8s_auth.py anisble module
# 

import requests
from urllib3.util import make_headers
from requests_oauthlib import OAuth2Session
from six.moves.urllib_parse import urlparse, parse_qs, urlencode
from pprint import pprint
import json

#HOST = 'https://master.example.org:8443'
HOST = 'https://openshift-master-0.example.com:6443'
#HOST = 'https://oauth-openshift.apps.cluster.example.com:6443'
USERNAME = 'kubeadmin'
# Can get the password from the oc install log
PASSWORD = 'PASSWORD'

# Gather authorization APIs info
oauth_server_info = requests.get('{}/.well-known/oauth-authorization-server'.format(HOST), verify=False).json()
#print(oauth_server_info)

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

#print(challenge_response)

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
    print("ERROR: {2} {1} {0}".format(
        self.openshift_token_endpoint,
        reason=auth.reason, status_code=auth.status_code))
    exit()

#print(auth)

# We now have the Bearer token and can interact with the API
token_type = auth.json()['token_type']
access_token = auth.json()['access_token']
print("Type: {}\nToken: {}".format(token_type, access_token))

# Example get all pods (omitted due to having too much ouput)
print('Example 0: basically `oc get pods -A -o json`')
pprint(requests.get('{}/api/v1/pods'.format(HOST), verify=False, headers={'authorization': '{} {}'.format(token_type, access_token)}).json())

# Example get from namespace "openshift-kube-apiserver"
# https://docs.openshift.com/container-platform/4.6/rest_api/workloads_apis/pod-core-v1.html
print('Example 1: basically `oc get pods -n openshift-kube-apiserver -o json`')
pprint(requests.get('{}/api/v1/namespaces/openshift-kube-apiserver/pods'.format(HOST), verify=False, headers={'authorization': '{} {}'.format(token_type, access_token)}).json())

# Example get routes
print('Example 2: basically `oc get routes -A -o json`')
routes = requests.get('{}/apis/route.openshift.io/v1/routes'.format(HOST), verify=False, headers={'authorization': '{} {}'.format(token_type, access_token)}).json()
promo_route = ""

for r in routes['items']:
    try:
        ingress = r['status']['ingress'][0]['host']
        print(ingress)
        if ingress[0:10] == "prometheus":
            promo_route = ingress
    except:
        continue

# Example metric test
# curl -vk -H 'authorization: token_type access_token' -G https://prometheus-k8s-openshift-monitoring.apps.cluster.example.com/api/v1/label/source_id/values
print('Example 3: list all available Promotheus labels')
if promo_route != "":
    pprint(requests.get('https://{}/api/v1/labels'.format(promo_route), verify=False, headers={'authorization': '{} {}'.format(token_type, access_token)}).json())
