git clone git@github.com:ovn-org/ovn.git
git clone git@github.com:openvswitch/ovs.git

podman run -v /home/mmethot/sources/ovn:/opt/ovn:Z -v ./ovs:/opt/ovs:Z -i -t --name fedora-ovn fedora /bin/bash

dnf install make findutils autoconf automake -y
