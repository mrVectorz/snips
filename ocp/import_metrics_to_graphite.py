# Script to read json files that were exported metrics from promotheus
# Author: Marc Methot

import json
import gzip
import os
import socket
from sys import argv
from time import sleep

# TODO: Have it check for more options
if len(argv) != 2:
    print("ERROR: Pass only the desired directory containing the compressed json files")
    exit(2)
elif not os.path.isdir(argv[1]):
    print('ERROR: "{}" is not a directory or not the full path to it'.format(argv[1]))
    exit(2)
else:
    dataDir = argv[1]


# Your graphite configurations
CARBON_SERVER = '127.0.0.1'
CARBON_PORT = 2003
DELAY = 0.01

# TODO: Currently using plain text protocol, would be ideal to move to pickle
#       for better performance with large datasets
def sendMsg(message):
    print('Sending message: %s' % message)
    sock = socket.socket()
    sock.connect((CARBON_SERVER, CARBON_PORT))
    sock.sendall(bytearray(message, 'utf-8'))
    sock.close()

for f in os.listdir(dataDir):
    if f[len(f)-8:] != '.json.gz':
        continue
    else:
        lines = gzip.open('{rootDir}/{jsonFile}'.format(rootDir=dataDir, jsonFile=f), 'r').readlines()
        # Note(mmethot): Assuming there will always only one line
        data = json.loads(lines[0])


# For graphite dot entries we'll want something unique
uniques = []
for d in data['data']['result']:
    for i in d['metric']:
        uniques.append((i, d['metric'][i].replace('/', '_')))

entries = set(uniques)

for e in entries:
    counter = uniques.count(e)
    if counter > 1:
        for i in range(counter):
            uniques.remove(e)

serverName = dataDir[dataDir.find('_')+1:dataDir.rfind('_')].replace('.', '_')
# TODO: Multithread this step otherwise it takes very long on large sets
for d in data['data']['result']:
    for v in d['values']:
        sendMsg('{}.{}.{} {} {}\n'.format(serverName, uniques[0][0], d['metric'][uniques[0][0]], v[1], int(v[0])))
        sleep(DELAY)
