FROM ubi8
MAINTAINER mmethot<mb.methot@gmail.com>

LABEL RUN podman run -it --privileged -v /sys/bus/pci/devices:/sys/bus/pci/devices -v /sys/kernel/mm/hugepages:/sys/kernel/mm/hugepages -v /sys/devices/system/node:/sys/devices/system/node -v /dev:/dev --name dpdk-testing IMAGE

# Dependencies
RUN dnf install xz gcc-c++ python3 pciutils iproute kmod -y
RUN python3 -m pip install meson ninja pyelftools

# DPDK
RUN curl http://fast.dpdk.org/rel/dpdk-21.11.tar.xz -o /root/dpdk.tar.xz
RUN tar -xf /root/dpdk.tar.xz --one-top-level=/root/
RUN cd /root/dpdk-*/ && meson build && ninja -C build

# Trex
RUN curl -k https://trex-tgn.cisco.com/trex/release/latest -o /root/trex-latest.tar.gz
RUN tar -xzf /root/trex-latest.tar.gz --one-top-level=/root/

# Cleanup
RUN dnf clean all
RUN rm -f /root/dpdk.tar.xz /root/trex-latest.tar.gz

# Defaulting to a bash, could put a DPDK-based application here like trex or testpmd.
CMD ["/bin/bash"]
