# Script to set, read, and delete a key in redis
# This is to test redis service health
# Author:  Marc Methot

import redis
import re
import os

# Default values that require manual change if it can't read conf file
password=""
host="127.0.0.1"
port=6379
config_file="/etc/redis.conf"

# Reading the config file
if os.path.isfile(config_file):
  print("Using the {} settings instead of default.".format(config_file))
  conf = open(config_file, "r")

  for line in conf:
    if re.match("^bind", line):
      host=line.split()[1]   
    if re.match("^port", line):
      port=line.split()[1]
    if re.match("^masterauth", line):
      password=line.split()[1]

  conf.close()
else:
  print("Using the Default parameters")

print("Using the following connection parameters:")
print("redis-cli -h {} -p {} -a {}\n".format(host, port, password))
# instantiating the connection pool and connect
conn = redis.Redis(
    host=host,
    port=port, 
    password=password)

# SET operation
conn.set('redhat', 'test')
# GET operation
value = conn.get('redhat')
if value != b"test":
  raise ValueError('Did not get the correct return value.')
else:
  print('Fetched the "redhat" key value: {}'.format(value.decode()))
# DEL operation
if conn.delete('redhat') <= 0:
  raise ValueError('The "redhat" key has not been deleted')
else:
  print('Deleted the "redhat" key')

print("\nTest completed SUCCESSFULLY")

