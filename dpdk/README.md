# DPDK
Quick subdir with info/stuff relating to DPDK.

## Container
I have created a *large* container that builds DPDK and includes the benchmarking tool trex.
To start using it on Kubernetes/OCP the CMD needs to be changed to start a DPDK application.
For example running testpmd requires additionnal setup:
```
NICADDRESS1=’0000:00:05.0′
modprobe vfio-pci
dpdk-devbind –bind=vfio-pci $NICADDRESS1
/root/dpdk-*/build/app/dpdk-testpmd –log-level 8 –huge-dir=/mnt/huge -l 0,1,2,3 -n 4 –proc-type auto –file-prefix pg -w $NICADDRESS1 — –disable-rss –nb-cores=2 –portmask=1 –rxq=2 –txq=2 –rxd=256 –txd=256 –port-topology=chained –forward-mode=mac –eth-peer=0,00:10:94:00:00:06 –mbuf-size=10240 –total-num-mbufs=32768 –max-pkt-len=9200 -i –auto-start
```

- Building it locally with buildah:
```
buildah build --tag dpdk-test .
```
- Running it with podman:
```
podman run -ti dpdk-test --name dpdk-test
```

## References
- http://core.dpdk.org/doc/quick-start/
- http://doc.dpdk.org/guides/linux_gsg/index.html
- https://core.dpdk.org/supported/
- https://trex-tgn.cisco.com/trex/doc/trex_manual.html#_running_examples
