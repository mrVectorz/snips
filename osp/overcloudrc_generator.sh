#!/bin/bash
# Author: Marc Methot
# Script to recreate an overcloudrc file from hiera data OSP13
# To be ran on a controller node as root user

conf="/var/lib/config-data/keystone/etc/puppet/hieradata/service_configs.json"
rc_file="$HOME/overcloudrc"

# Checking that files are available
if [ -f $rc_file ]; then
  echo "ERROR: $rc_file is already present! Either use that one or mv it"
  exit 1
elif [ ! -f $conf ]; then
  echo "ERROR: $conf file does not exist!"
else
  touch $rc_file
fi

function fecho() {
  echo $* >> $rc_file
}

fecho "# Clear any old environment that may conflict."
fecho $'for key in $( set | awk \'{FS="="}  /^OS_/ {print $1}\' ); do unset $key ; done'
fecho export OS_NO_CACHE=True
fecho export COMPUTE_API_VERSION=1.1
fecho export OS_USERNAME=admin
fecho export no_proxy=$(jq -r '.["nova::vncproxy::common::vncproxy_host"]' $conf),$(jq -r '.["keystone::endpoint::admin_url"]' $conf|cut -d: -f2 | sed 's,//,,g')
fecho export OS_USER_DOMAIN_NAME=Default
fecho export OS_VOLUME_API_VERSION=3
fecho export OS_CLOUDNAME=overcloud
fecho export OS_AUTH_URL=$(jq -r '.["heat::heat_keystone_clients_url"]' $conf)/v3
fecho export NOVA_VERSION=1.1
fecho export OS_IMAGE_API_VERSION=2
fecho export OS_PASSWORD=$(jq -r '.["keystone::admin_password"]' $conf)
fecho export OS_PROJECT_DOMAIN_NAME=Default
fecho export OS_IDENTITY_API_VERSION=3
fecho export OS_PROJECT_NAME=admin
fecho export OS_AUTH_TYPE=password
fecho export PYTHONWARNINGS="ignore:Certificate has no, ignore:A true SSLContext object is not available"

echo "$rc_file has been generated"
