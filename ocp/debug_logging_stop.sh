#!/bin/bash

# Specify the worker nodes that your application is seeing issue on
NODES="openshift-worker-0"

# Adding master nodes to the list of NODES regradless to help detect potential replication issues
for NODE in $(echo $NODES $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') | sort -u); do
  OVN_POD=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')
  OVS_POD=$(oc -n openshift-ovn-kubernetes get pod -l app=ovs-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')

  echo "oc -n openshift-ovn-kubernetes exec -t ${OVS_POD} -- ovs-appctl vlog/set info"
  oc -n openshift-ovn-kubernetes exec -t ${OVS_POD} -- ovs-appctl vlog/set info

  echo "oc -n openshift-ovn-kubernetes exec -t ${OVN_POD} -- ovn-appctl -t ovn-controller vlog/set info"
  oc -n openshift-ovn-kubernetes exec -t ${OVN_POD} -c ovn-controller -- ovn-appctl -t ovn-controller vlog/set info
done
