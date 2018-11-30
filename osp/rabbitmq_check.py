# Script to write and consume a msg for rabbit
# Author:  Marc Methot

import pika
import re
import sys, os, errno, signal
from functools import wraps
from oslo_config import cfg

# Default values that require manual change if it can't read conf file
password=""
host=""
port=5672
user="guest"
queue="redhat"
config_file="/etc/neutron/neutron.conf"
# Setting up a way to timeout the rpc call if it can't consume a message
class TimeoutError(Exception):
    pass

def timeout(seconds=10, error_message=os.strerror(errno.ETIME)):
    def decorator(func):
        def _handle_timeout(signum, frame):
            raise TimeoutError(error_message)

        def wrapper(*args, **kwargs):
            signal.signal(signal.SIGALRM, _handle_timeout)
            signal.alarm(seconds)
            try:
                result = func(*args, **kwargs)
            finally:
                signal.alarm(0)
            return result

        return wraps(func)(wrapper)

    return decorator

@timeout(30, os.strerror(errno.ETIMEDOUT))
def callback(ch, method, properties, body):
  print("Received %r" % body)
  #channel.basic_ack(delivery_tag=method.delivery_tag)
  connection.close()


# NOTE: Decided to check if I can get the data from neutron.conf
# We however decided to change from rabbit_hosts param to transport_url in 12
# TODO: Have this test all controllers in case of HA
if os.path.isfile(config_file):
  print("Using Neutron's creds")
  msg_group = cfg.OptGroup(name='oslo_messaging_notifications')
  transport_opt = [
      cfg.StrOpt('transport_url')]
  rabbit_group = cfg.OptGroup(name='oslo_messaging_rabbit')
  rabbit_opts = [
      cfg.StrOpt('rabbit_hosts'),
      cfg.StrOpt('rabbit_userid'),
      cfg.StrOpt('rabbit_password')
  ]

  CONF = cfg.CONF
  CONF.register_group(msg_group)
  CONF.register_group(rabbit_group)
  CONF.register_opts(transport_opt, msg_group)
  CONF.register_opts(rabbit_opts, rabbit_group)
  CONF(default_config_files=[config_file])

  if CONF.oslo_messaging_notifications.transport_url != None:
    transport_url = re.sub("^rabbit", "amqp",
                           CONF.oslo_messaging_notifications.transport_url.split(",")[0])
    parameters = pika.URLParameters(transport_url)
  else:
    user = CONF.oslo_messaging_rabbit.rabbit_userid
    password = CONF.oslo_messaging_rabbit.rabbit_password
    host = re.split("[,:]", CONF.oslo_messaging_rabbit.rabbit_hosts)[0]
    # The split will cause us to drop the port and use the default
    credentials = pika.PlainCredentials(user, password)
    parameters = pika.ConnectionParameters(host, port, '/', credentials)

else:
  print("Using hardcoded values")
  credentials = pika.PlainCredentials(user, password)
  parameters = pika.ConnectionParameters(host,
                                       port,
                                       '/',
                                       credentials)
connection = pika.BlockingConnection(parameters)
channel = connection.channel()
channel.queue_declare(queue=queue)

channel.basic_publish(exchange='',
                      routing_key='redhat',
                      body='Redhat Message Test')

print("Sent 'Redhat msg'")

channel.basic_consume(callback,
  queue=queue,
  no_ack=True)

try:
  channel.start_consuming()
except KeyboardInterrupt:
  print("CTR+C - took too long?")
  channle.stop_consuming()

