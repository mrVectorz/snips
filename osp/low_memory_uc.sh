#!/bin/bash
# Author: Marc Methot
# Script to lower the memory usage on the undercloud
# lowers all worker or wsgi process counts to 1

services=(
 'httpd.service'
 'openstack-heat-api.service'
 'openstack-swift-proxy.service'
 'openstack-nova-api.service'
 'openstack-mistral-api.service'
 'neutron-server.service'
 'openstack-ironic-api.service'
 'openstack-glance-api.service'
)

files=(
 '/etc/heat/heat.conf'
 '/etc/swift/proxy-server.conf'
 '/etc/nova/nova.conf'
 '/etc/mistral/mistral.conf'
 '/etc/neutron/neutron.conf'
 '/etc/ironic/ironic.conf'
 '/etc/keystone/keystone.conf'
 '/etc/glance/glance-api.conf'
)

# old style conf files
for file in ${files[@]}; do
  awk '{if($0 ~ /^\w+orkers *= */) print gensub(/(\w* *= *)[0-9]+$/, "\\11", "g", $0); else print}' < $file > ${file}.bak && cp -f ${file}.bak $file
done

# wsgi files
for file in $(grep -l -r WSGIDaemonProcess /etc/httpd/conf.d/); do
  awk '{if ($0 ~ /WSGIDaemonProcess/) print gensub(/(.*processes=)[0-9]+(.*)/, "\\11\\2", "g", $0); else print}' < $file > ${file}.bak && mv -f ${file}.bak $file
done

# restarting services to apply the changes
for service in ${services[@]}; do
  if $(systemctl is-enabled $service >/dev/null) ; then
    echo "Restarting service: $service"
    systemctl restart $service
  fi
done

# validations
echo "Everything should set to have 1 worker/process"
for file in ${files[@]}; do
  echo $file
  egrep '^\w+orkers *= *' $file
done
grep -r WSGIDaemonProcess /etc/httpd/conf.d/
