[Presentations](https://www.openvswitch.org/support/ovscon2019/)
- ovscon.site
[akaris blog which also has a summary of ovscon](https://github.com/andreaskaris/blog/)
[blog posts to read](https://www.redhat.com/en/blog/virtio-networking-first-series-finale-and-plans-2020?source=bloglisting&f%5B0%5D=post_tags%3AVirtualization)
to do next terminal presentations use [asciinema](https://asciinema.org/)
[mapping networks with skydive](https://github.com/skydive-project/skydive)
- [openstack redhat doc](https://access.redhat.com/documentation/en-us/red_hat_openstack_platform/14/html/use_skydive_for_openstack_network_analysis/index)
  +  note that the [rpm](https://access.redhat.com/downloads/content/rhel---7/x86_64/7250/skydive/0.20.5-2.el7ost/x86_64/fd431d51/package) is not available for RHOSP 15, only for 14. This was a tech preview
  +  OSP [skydive presentation](https://www.youtube.com/watch?v=nQSdGKV8ceM)
  +  [spec](https://github.com/openstack/dragonflow/blob/master/doc/source/specs/skydive_integration.rst#id4) dragonflow making use of skydive
make sense of MPLS/VPLS

## Intro
- ovs orbit podcast
https://ovsorbit.org/


## Testing OVS at the DPDK Community Lab
- switching from C to rust language for better mem mgmt
- not part of the upstream branch for now, still in testing/beta


## Testing OVS at the DPDK Community Lab
- Physical to Virtual back to Physical topology (PVP)
- Automated Open vSwitch PVP testing (setup trex, testpmd and run the PVP scripts) 
https://github.com/chaudron/ovs_perf

## The Discrepancy of the Megaflow Cache in OVS, Part II
- Tuple space explosion, MegaFlowCache flow exploit
- generic TSE Attack impacts
- MFC Guard (MFCg)
"Mitigation technique with a cache management scheme called MFC Guard (MFCg). It dynamically monitors the number of entries in the MFC and removes less important ones to reduce the performance overhead of the TSS algorithm. It is worth noting that we have observed negligible impact on the overall packet processing performance during the monitoring process itself (i.e., executing ovs-dpctl dump-flows in, say, each second)."

## A Kubernetes Networking Implementation Using Open vSwitch
- vmware driven ovs based kubes nw plugin [antrea](https://github.com/vmware-tanzu/antrea)
- Where RH is driving [ovn-kubernetes](https://github.com/ovn-org/ovn-kubernetes) plugin instead
- [kubes network plugins](https://kubernetes.io/docs/concepts/cluster-administration/networking/)

## OVS DPDK issues in Openstack and Kubernetes and Solutions
- presenting INTEL flavour of kubes ovs plugin (does support dpdk/sriov too)
- [Multus](https://github.com/intel/multus-cni)
- it apparently already semi-works with standard kuryr integration

## OVS-DPDK life of a packet

## Utilizing DPDK Virtual Devices in OVS

## Next steps for higher performance of the software data plane in OVS
- Intel
- cpu instruction implementation (scalar and avx-512)
- suggestion of new way to compile ovs for specific cpu arch

## OVN for NFV workloads with Kubernetes
- Intel
- project to fill the gaps from ovn-kubernetes plugging, mainly for VNFs
- ovn for nfv k8s ([ovn4nfvk8s](https://github.com/opnfv/ovn4nfv-k8s-plugin))
- This project works with Multus to provide a CNI to attach multiple OVN interfaces into workloads and supports CRD controllers for dynamic networks and provider networks and for route management.
  + basically bridging ovn-kubernetes plugin with ovn4nfvk8s to use multus

## OvS-DPDK Acceleration with rte_flow: Challenges and Gaps
- Broadcom
- rte_flow_validate not used by dpdk, need to optimize capability discovery
- dynamic rebalance, apparently needed for capacity mgmt (need to read up)

## Partial offload optimization and performance on Intel Fortville NICs using rte_flow
- rte_flow on Intel nics 700 hw offload
- allows standard flow is accelerated at MF Extraction, Exact Match Cache (EMC) and DPCLS (megaflow cache) lookups 
~~~
PKT-IN --> MF-EXTRACT --> LOOKUP --> ACTION --> PKT-OUT
~~~
More to read:
- [pipeline change](https://mail.openvswitch.org/pipermail/ovs-dev/2016-December/325596.html)
- [design and implementation of the datapath classifier](https://software.intel.com/en-us/articles/ovs-dpdk-datapath-classifier)
- [ovs lookup presentation 2016](http://www.openvswitch.org/support/ovscon2016/8/1050-gobriel.pdf)
- [OvS-DPDK Datapath Classifier – Part 2](https://software.intel.com/en-us/articles/ovs-dpdk-datapath-classifier-part-2)

## Kernel Based Offloads of OVS
- Netronome presentation
- [Virtual Switch Acceleration with OVS-TC](https://www.netronome.com/m/documents/WP_OVS-TC_.pdf)
- [Multiprotocol Label Switching](https://en.wikipedia.org/wiki/Multiprotocol_Label_Switching)
- vDPA netdev is designed to support both SW and HW
- HW mode will be used to configure vDPA capable devices.
  SW acceleration is used to leverage SRIOV offloads to virtio guests by relaying packets between VF and virtio devices. Add the SW relay forwarding logic as a pre-step for adding dpdkvdpa port with no functional change.
- Packet classifier for Linux kernel traffic classification (TC) subsystem [ovs-tc](https://open-nfp.org/s/pdfs/dxdd-europe-ovs-offload-with-tc-flower.pdf)

## An Encounter with OpenvSwitch Hardware Offload on 100GbE SMART NIC
- operators view of tc-hw-offload on commodity x86
- ovs tc hw offload sucks netdev-tc-offload
- very llittle documentation
- hard to tell when the buffer gets overrun and impacts performance
- PCIv3 on an x8 lanes slot hit a PCI bottleneck (apparently there's a flag to use to avoid hitting this)

## IP Multicast in OVN - IGMP Snooping and Relay
- prb node brd will flood all the switch ports, multicast_grp sequentially executes the pipelines

## We light the OVN so that everyone may flow with it
- Ubuntu marketing presentation

## OVN issues seen in the field and how they were addressed
- ovn-openflow-probe reconnection 5 secs, can cause cpu consumption issues, resolution is to increase the probe increment
- dhcp reply time if loadedan cause snowball issue, where VIF will resend and flood
- continuous arp, update to ovn 2.12 (if lflow)run takes 10s > 100% cpu usage)
- need better debugging tools, ovn-trace and ovn-detrace arent clear enough (something like [Skydive](http://skydive.network/documentation/) would be nice)

## Multi-tenant Inter-DC tunneling with OVN
- ebay

## SmartNIC Hardware offloads past, present and future
- virtio in hardware
- virtio hw offload (in progress)
- vDPA

## [The Long Road to] Deployable OvS Hardware Offloading for 5G Telco Clouds
- nuage/mellanox/redhat

## Magma intro
- Facebook product
- goal to bring LTE everywhere cheap
