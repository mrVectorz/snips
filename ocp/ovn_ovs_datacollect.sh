#!/bin/bash

### Change NODES variable to the desired hosts
NODES="openshift-worker-0 openshift-worker-1"

OUTDIRa=ovn_outputs
OUTDIRb=ovs_outputs
mkdir -p ${OUTDIRa}
mkdir -p ${OUTDIRb}

OVN_NB_TABLES=(
  "NB_Global"
  "Logical_Switch"
  "Logical_Switch_Port"
  "Address_Set"
  "Port_Group"
  "Load_Balancer"
  "ACL"
  "Logical_Router"
  "QoS"
  "Meter"
  "Meter_Band"
  "Logical_Router_Port"
  "Logical_Router_Static_Route"
  "NAT"
  "DHCP_Options"
  "Connection"
  "DNS"
  "SSL"
  "Gateway_Chassis"
)

PIDS=()
for NODE in ${NODES}; do
  echo ${NODE}

  ### OVN
  POD_OVNKUBE=$(2>/dev/null oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')
  NBDB=$(oc describe ds ovnkube-node -n openshift-ovn-kubernetes | awk '/nb-address/ {gsub(/"/, "", $2); print $2}')
  SBDB=$(oc describe ds ovnkube-node -n openshift-ovn-kubernetes | awk '/sb-address/ {gsub(/"/, "", $2); print $2}')
  ARGS="-p /ovn-cert/tls.key -c /ovn-cert/tls.crt -C /ovn-ca/ca-bundle.crt"

  echo "oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-sbctl --db ${SBDB} ${ARGS} show"
  sh -x &>${OUTDIRa}/${NODE}.${POD_OVNKUBE}.ovn-sbctl_show <<< "timeout 30 oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-sbctl --db ${SBDB} ${ARGS} show" & PIDS+=($!)

  echo "oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-sbctl --db ${SBDB} ${ARGS} lflow-list"
  sh -x &>${OUTDIRa}/${NODE}.${POD_OVNKUBE}.ovn-sbctl_lflow-list <<< "timeout 30 oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-sbctl --db ${SBDB} ${ARGS} lflow-list" & PIDS+=($!)

  echo "oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-nbctl --db ${NBDB} ${ARGS} show"
  sh -x &>${OUTDIRa}/${NODE}.${POD_OVNKUBE}.ovn-nbctl_show <<< "timeout 30 oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-nbctl --db ${NBDB} ${ARGS} show" & PIDS+=($!)

  for tbl in ${OVN_NB_TABLES[*]}; do
    echo "oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-nbctl --db ${NBDB} ${ARGS} list ${tbl}"
    sh -x &>${OUTDIRa}/${NODE}.${POD_OVNKUBE}.ovn-nbctl_list_${tbl} <<< "timeout 30 oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ${POD_OVNKUBE} -- ovn-nbctl --db ${NBDB} ${ARGS} list ${tbl}" & PIDS+=($!)
  done

  ### OVS
  POD_OVS_NODE=$(2>/dev/null oc -n openshift-ovn-kubernetes get pod -l app=ovs-node,component=network -o jsonpath='{range .items[?(@.spec.nodeName=="'${NODE}'")]}{.metadata.name}{end}')
  OVS_BRIDGES=$(oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-vsctl list-br 2>/dev/null)
  for OVS_BRIDGE in ${OVS_BRIDGES}; do
    echo "oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-ofctl dump-flows ${OVS_BRIDGE}"
    oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-ofctl dump-flows ${OVS_BRIDGE} > ${OUTDIRb}/${NODE}.ovs-ofctl.dump-flows.${OVS_BRIDGE}

    echo "oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-ofctl show ${OVS_BRIDGE}"
    oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-ofctl show ${OVS_BRIDGE} > ${OUTDIRb}/${NODE}.ovs-ofctl.show.${OVS_BRIDGE}

    echo "oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-appctl dpctl/dump-conntrack"
    oc -n openshift-ovn-kubernetes exec -t ${POD_OVS_NODE} -- ovs-appctl dpctl/dump-conntrack > ${OUTDIRb}/${NODE}.${POD_OVS_NODE}.ovs_appctl.dpctl.dump_conntrack
  done
done

### gathering raw ovn dbs
for OVN_KUBE_MASTER_POD in $(2>/dev/null oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-master,component=network -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
do
  echo "oc -n openshift-ovn-kubernetes exec -t -c nbdb ${OVN_KUBE_MASTER_POD} -- cat /etc/ovn/ovnnb_db.db"
  oc -n openshift-ovn-kubernetes exec -t -c nbdb ${OVN_KUBE_MASTER_POD} -- cat /etc/ovn/ovnnb_db.db > ${OUTDIRa}/${OVN_KUBE_MASTER_POD}.ovnnb_db.db

  echo "oc -n openshift-ovn-kubernetes exec -t -c nbdb ${OVN_KUBE_MASTER_POD} -- cat /etc/ovn/ovnsb_db.db"
  oc -n openshift-ovn-kubernetes exec -t -c nbdb ${OVN_KUBE_MASTER_POD} -- cat /etc/ovn/ovnsb_db.db > ${OUTDIRa}/${OVN_KUBE_MASTER_POD}.ovnsb_db.db
done

echo "Waiting for collection to complete"
wait "${PIDS[@]}"

echo "Compressing files and creating a tar archive"
tar -zcvf ovs_ovn_dumps.tar.gz ${OUTDIRa} ${OUTDIRb}

echo -e "\nCreated $(realpath ovs_ovn_dumps.tar.gz)"
