# Quick OVN break down
High level view of OVN, its components and its integration in Kubernetes.

### Table of Contents
1. [Overview of ovn-kubernetes deployment](#Overview)

## Overview of ovn-kubernetes deployment {#Overview}

There are three pod types for this deployment:
```
[root@ocp-ipimetal-45-lab ~]# oc get pods -n openshift-ovn-kubernetes -o go-template='{{ range .items}}{{ if (eq .spec.nodeName "openshift-master-0.example.com") }}{{printf "%s\n" .metadata.name}}{{end}}{{end}}'
ovnkube-master-2wltp
ovnkube-node-wrtnh
ovs-node-4qmgn
[root@ocp-ipimetal-45-lab ~]# oc get pods -n openshift-ovn-kubernetes -o go-template='{{ range .items}}{{ if (eq .spec.nodeName "openshift-worker-0.example.com") }}{{printf "%s\n" .metadata.name}}{{end}}{{end}}'
ovnkube-node-5l7dc
ovs-node-r5r84
```

Information flow for OpenFlow rule creation:
ApiServer -> ovn-kubernetes master -> nbdb -> northd -> sbdb -> ovn-controller -> openvswitch

ovn-kubernetes master components:
- ovn-k8s master
- nbdb
- ovn-northd
- sbdb

ovn-kubernetes node components:
- ovn-ks8 node
- ovn-controller
- OpenVswitch


Diagram of the OVN architecture taken from the man page. CMS explained bellow, and HV is hypervisor (in our case we can refer to it as worker).

```
                                         CMS
                                          |
                                          |
                              +-----------|-----------+
                              |           |           |
                              |     OVN/CMS Plugin    |
                              |           |           |
                              |           |           |
                              |   OVN Northbound DB   |
                              |           |           |
                              |           |           |
                              |       ovn-northd      |
                              |           |           |
                              +-----------|-----------+
                                          |
                                          |
                                +-------------------+
                                | OVN Southbound DB |
                                +-------------------+
                                          |
                                          |
                       +------------------+------------------+
                       |                  |                  |
         HV 1          |                  |    HV n          |
       +---------------|---------------+  .  +---------------|---------------+
       |               |               |  .  |               |               |
       |        ovn-controller         |  .  |        ovn-controller         |
       |         |          |          |  .  |         |          |          |
       |         |          |          |     |         |          |          |
       |  ovs-vswitchd   ovsdb-server  |     |  ovs-vswitchd   ovsdb-server  |
       |                               |     |                               |
       +-------------------------------+     +-------------------------------+
```

## Step by Step Pod Creation
As an example we go over the steps that are taken by creating a simple pod using kube-ovn.

Pod creation steps:
1. Pod Object is created.
2. Scheduler reacts to pod creation, sets v1.Pod.spec.NodeName property.
3. Kubelet notices the pod (if it's nodename matches).
4. Kubelet creates a sandbox (the actual container, cgroups, linux ns, selinux) via CRI (Container Runtime Interface) to CRI-O (which then uses runc and so on). ([Creating Sandbox](https://github.com/cri-o/cri-o/blob/master/server/sandbox_run_linux.go#L289))
5. CRIO executes CNI plugin binary (That binary is also called ovn-kubernetes). This can be refered to as Kubernetes Cloud Management System (CMS) plugin.
6. CNI plugin sends an http POST request to ovn-kubernetes-node over internal socket.
7. OVN-k node creates veth pair (connected to the ovn bridge - [mapping ref](https://github.com/ovn-org/ovn-kubernetes/blob/master/docs/switch-per-node.pdf)), then waits[0] for annotations **and** OpenFlows in openvswitchd. ([WatchServices control loop](https://github.com/ovn-org/ovn-kubernetes/blob/master/go-controller/pkg/ovn/ovn.go#L594))
  1. ovn-k master notices the pod, executes addLogicalPort.
  2. addLogicalPort creates a pod object in nbdb.
    1. ovn-northd which watches for changes in nbdb generates logicalFlows in sbdb. Assigns IP addresses at the same time (OCP 4.5+).
    2. ovn-controller observes changes in sbdb programs openvswitch.
  3. ovn-k master watches for changes on the objects it created then sets annotations (IP, MAC, status).
8. ovn-k node observes that annotations and flows are present, returns response to CNI request
9. CNI binary exits
10. CRI-O returns response
11. Kubelet continues setting up pod

All steps are done via polling (minus the crio executing the binary), there is no direct communication between services.
Most of the steps where it states X is watching for changes, this is non blocking and assyncronous. Multiple pods can be created at once.

[0] - ovn-kubernetes node waits for two minutes and then timesout. If it does time out, kubelet will retry.

## Cloud Management System
OVN CMS plugin is the component of the CMS that interfaces with OVN. Our CMS being Openshift/Kubernetes or Openstack.

OVN initially targeted Openstack as CMS, and the interface was done via a Neutron plugin. With Kubernetes we have the ovn-kubernetes CNI plugin, this binary is executed by CRIO in the sandbox creation.
The plugin’s main purpose is to translate kubernetes notion of network configurations, stored in etcd, into an intermediate representation understood by OVN.

## OVN Northbound  Database (NBDB)
This  database  is  the  interface between OVN and the CMS running above  it. The CMS is the main (if not all) creator the contents of the database. This data will represent notions of logical switches, routers, ACLs, loadbalancers and so forth.
The **ovn-northd** program monitors the database contents, translates it to LogicalFlows, and stores it into the OVN Southbound database (SBDB).

NorthBound database is replicated accross the cluster via Raft (the same protocol as etcd, but it's own implementation for some reason).

### NBDB structure
Quick overview of the contents/schema of the NBDB.

Each of the 24 tables in this database contain a special column, named `external_ids`. These can be used to match, for example, a pod to which logical switch port it's using.
```
external_ids: map of string-string pairs
	Key-value pairs for use by the CMS.  The  CMS  might  use
	certain  pairs,  for example, to identify entities in its
	own configuration that correspond to those in this  data‐
	base.
```

Table list with brief descriptions, for more information consult the [man page](https://www.ovn.org/support/dist-docs/ovn-nb.5.html).

| Table | Purpose |
| ----- |:-------:|
| NB_Global      | Northbound configuration |
| Logical_Switch | L2 logical switch        |
| Logical_Switch_Port | L2 logical switch port |
| Forwarding_Group | forwarding group |
| Address_Set | Address Sets |
| Port_Group | Port Groups |
| Load_Balancer | load balancer |
| Load_Balancer_Health_Check | load balancer |
| ACL | Access Control List (ACL) rule |
| Logical_Router | L3 logical router |
| QoS | QoS rule |
| Meter | Meter entry |
| Meter_Band | Band for meter entries |
| Logical_Router_Port | L3 logical router port |
| Logical_Router_Static_Route | Logical router static routes |
| Logical_Router_Policy | Logical router policies |
| NAT | NAT rules |
| DHCP_Options | DHCP options |
| Connection | OVSDB client connections |
| DNS | Native DNS resolution |
| SSL | SSL configuration |
| Gateway_Chassis | Gateway_Chassis configuration |
| HA_Chassis_Group | HA_Chassis_Group configuration |
| HA_Chassis |  HA_Chassis configuration |



## ovn-northd
This is technically the second OVN Northbound Database client (CMS plugin being the other).
The ovn-northd program connects to the NBDB and the Southbound Database. Then monitors the NDBD database contents, if any changes applied it translates them from conventional network concepts to LogicalFlows, and lastly stores them into the SBDB.

An operator can send commands to this centralized daemon using `ovn-appctl`. (use to be `ovs-appctl`)

Some status examples:
```
[root@ocp-ipimetal-45-lab ~]# oc -n openshift-ovn-kubernetes describe pod/ovnkube-master-2wltp | grep -B 1 "Container ID"
  northd:
    Container ID:  cri-o://70442ac01816655e43492848cfefe9ed02f061646eea74996e027e9b83306d26
--
  nbdb:
    Container ID:  cri-o://ee5785abcce83fb069a54ca2d2abdcbe3ef29e147a166407ce58f1b56fcb1d1e
--
  sbdb:
    Container ID:  cri-o://b9cd3651c62577d5cf45a454323bda00892c1197f08155c393a86a64c83824d5
--
  ovnkube-master:
    Container ID:  cri-o://649dfdfaae7b1c68696efb4c2032a5655dd5d90279cd0b50a708c6065c50a0b4
[root@ocp-ipimetal-45-lab ~]# oc -n openshift-ovn-kubernetes exec -t -c northd ovnkube-master-2wltp -- ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound
f34d
Name: OVN_Northbound
Cluster ID: 2332 (2332a49d-276f-4407-93bb-13cef0ce80e5)
Server ID: f34d (f34deaa3-2307-4c10-b9ec-9e04f16c2f81)
Address: ssl:192.168.123.200:9643
Status: cluster member
Role: leader
Term: 1
Leader: self
Vote: self

Election timer: 5000
Log: [55164, 55950]
Entries not yet committed: 0
Entries not yet applied: 0
Connections: <-98c6 ->98c6 <-b792 ->b792
Servers:
    98c6 (98c6 at ssl:192.168.123.201:9643) next_index=55950 match_index=55949
    b792 (b792 at ssl:192.168.123.202:9643) next_index=55950 match_index=55949
    f34d (f34d at ssl:192.168.123.200:9643) (self) next_index=2 match_index=55949
[root@ocp-ipimetal-45-lab ~]# oc -n openshift-ovn-kubernetes exec -t ovnkube-master-2wltp -c northd -- ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound
2d71
Name: OVN_Southbound
Cluster ID: b217 (b217c1f6-0e29-440e-9f07-2d891cd12e89)
Server ID: 2d71 (2d71a8b6-4a76-48ee-8dc4-b1944b1d0cec)
Address: ssl:192.168.123.200:9644
Status: cluster member
Role: leader
Term: 1
Leader: self
Vote: self

Election timer: 5000
Log: [54105, 54991]
Entries not yet committed: 0
Entries not yet applied: 0
Connections: <-2156 ->2156 <-15df ->15df
Servers:
    2156 (2156 at ssl:192.168.123.201:9644) next_index=54991 match_index=54990
    2d71 (2d71 at ssl:192.168.123.200:9644) (self) next_index=2 match_index=54990
    15df (15df at ssl:192.168.123.202:9644) next_index=54991 match_index=54990
```

## OVN Southbound Database
The OVN Southbound Database contains three clases of data:
- Physical Network (PN) tables that specify how to reach hypervisior and other nodes.  
  This contains all the information necessary to wire the overlay, such as IP addresses, supported tunnel types, and security keys.
- Logical Network (LN) tables that describe the logical network in terms of ``logical datapath flows``.  
  These contain the topology of logical switches and routers, ACLs, firewall rules, and everything needed to describe how packets traverse a logical network, represented as logical datapath flows.
- Binding tables that link logical network components’ locations to the physical network.  
  The types tables link the other two components together. They show the current placement of logical components (such as VMs/pods and VIFs) onto chassis, and map logical entities to the values that represent them in tunnel encapsulations.

### SBDB Structure
Table of tables with a short description and their data class.

| Table | Purpose |
| ----- |:-------:|
| SB_Global | Southbound configuration |
| Chassis | Physical Network Hypervisor and Gateway Information |
| Encap | Encapsulation Types |
| Address_Set | Address Sets |
| Port_Group | Port Groups |
| Logical_Flow | Logical Network Flows |
| Multicast_Group | Logical Port Multicast Groups |
| Meter | Meter entry |
| Meter_Band | Band for meter entries |
| Datapath_Binding | Physical-Logical Datapath Bindings |
| Port_Binding | Physical-Logical Port Bindings |
| MAC_Binding | IP to MAC bindings |
| DHCP_Options | DHCP Options supported by native OVN DHCP |
| DHCPv6_Options | DHCPv6 Options supported by native OVN DHCPv6 |
| Connection | OVSDB client connections. |
| SSL | SSL configuration. |
| DNS | Native DNS resolution |
| RBAC_Role | RBAC_Role configuration. |
| RBAC_Permission | RBAC_Permission configuration. |
| Gateway_Chassis | Gateway_Chassis configuration. |
| HA_Chassis | HA_Chassis configuration. |
| HA_Chassis_Group | HA_Chassis_Group configuration. |
| Controller_Event | Controller Event table |
| IP_Multicast | IP_Multicast configuration. |
| IGMP_Group | IGMP_Group configuration. |
| Service_Monitor | Service_Monitor configuration. |

`ovn-sbctl` program configures SBDB amd can querry the DB.

Example of a show output:
```
[root@ocp-ipimetal-45-lab ~]# oc -n openshift-ovn-kubernetes exec -t -c ovn-controller ovnkube-node-wrtnh -- ovn-sbctl --db ssl:192.168.123.200:9642,ssl:192.168.123.201:9642,ssl:192.168.123.202:9642 -p /ovn-cert/tls.key -c /ovn-cert/tls.crt -C /ovn-ca/ca-bundle.crt show
Chassis "3e4ff38c-918d-417d-8f88-8e7cd24b4a42"
    hostname: openshift-master-1.example.com
    Encap geneve
        ip: "192.168.123.201"
        options: {csum="true"}
    Port_Binding openshift-console_console-7bf6c576d7-5x6rg
    Port_Binding rtoj-GR_openshift-master-1.example.com
    Port_Binding openshift-apiserver_apiserver-6f657f94f7-qfmpw
(...)
```
This output can be quite large depending on how many chasis, pods and so on are in the cluster.

## ovn-controller
The `ovn-controller` is OVN’s agent on each hypervisor and software gateway.
- Northbound, it connects to the OVN Southbound Database to learn about OVN configuration and status and to populate the PN table and the Chassis column in Binding table with the hypervisor’s status.
- Southbound, it connects to `ovs-vswitchd` as an OpenFlow controller, for control over network traffic, and to the local `ovsdb-server` to allow it to monitor and control OpenvSwitch configuration.

