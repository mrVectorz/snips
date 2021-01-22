#!/bin/bash

# Specify the worker nodes that your application is seeing issue on
NODES="openshift-worker-0"

LOG_LOCAL=true
# This scriptuses "oc logs ... -f" and sends it to bg.
# You have to manually stop it when you're done:
# ps f | awk '$0 ~ /oc.*logs/ {print $0}'

OUTDIRa=ovn_outputs
OUTDIRb=ovs_outputs
mkdir -p ${OUTDIRa}
mkdir -p ${OUTDIRb}

# Adding master nodes to the list of NODES regradless to help detect potential replication issues
for NODE in $(echo $NODES $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') | sort -u); do
  echo "Working on $NODE"
  OVN_POD=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')
  OVS_POD=$(oc -n openshift-ovn-kubernetes get pod -l app=ovs-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')

  echo oc -n openshift-ovn-kubernetes exec -t ${OVS_POD} -- ovs-appctl vlog/set dbg
  oc -n openshift-ovn-kubernetes exec -t ${OVS_POD} -- ovs-appctl vlog/set dbg

  echo oc -n openshift-ovn-kubernetes exec -t ${OVN_POD} -- ovn-appctl -t ovn-controller vlog/set dbg
  oc -n openshift-ovn-kubernetes exec -t ${OVN_POD} -c ovn-controller -- ovn-appctl -t ovn-controller vlog/set dbg

  if ! $LOG_LOCAL; then
    # if LOG_LOCAL variable is set to false the loop stops here and will not log locally
    continue
  fi

  echo "Sending to Background: oc -n openshift-ovn-kubernetes logs ${OVS_NODE_POD} --timestamps -f"
  (oc -n openshift-ovn-kubernetes logs ${OVS_POD} --timestamps -f > ${OUTDIRb}/ovs-node-${NODE}.log) &

  echo "Sending to Background: oc -n openshift-ovn-kubernetes logs ${OVNKUBE_NODE_POD} --all-containers --timestamps -f"
  (oc -n openshift-ovn-kubernetes logs ${OVN_POD} --all-containers --timestamps -f > ${OUTDIRa}/ovnkube-node-${NODE}.log) &
done
