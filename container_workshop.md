## Container Training

Presenter: Marc Methot

Date: Jan-2019

### Index
1. [Introduction to containers](#introduction-to-containers)
2. [Namespaces](#namespaces)
3. [Control Groups](#control-groups)
4. [Capabilities](#capabilities)
5. [Copy-on-Write](#copy-on-write)
6. [Full blown containers](#full-blown-containers)
    1. [Runtimes](#runtimes)
    2. [API](#api)
    3. [Registry](#registry)
7. [Tripleo](#tripleo)
    1. [Kolla Containers](#kolla-containers)
    2. [Paunch](#paunch)
    3. [Configuration Steps](#configuration-steps)
    4. [Kuryr](#kuryr)
    5. [Magnum](#magnum)
8. [Examples](#examples)
    1. [Making a manual container](#making-a-manual-container)

### Introduction to containers
Containers are just an agglomerate of kernel features made easy.
They principally rely on the following key features:
- namespaces
- cgroups
- capabilities
- security (selinux)

After these kernel based features, we have what makes it all usuable.
- container runtimes (lxc, runC, libcontainer)
- APIs/Engines
- builders
- registries

Lastly we will cover how Tripleo makes use of containers.

### Namespaces
I don't feel like reiterating, please go check out:
- [Andreas Karis' blog post / presentation](https://github.com/andreaskaris/blog/blob/master/namespaces.md)

### Control Groups
Control groups (cgroups), simply put, provide a way to limit and control the amount of resources (CPU, memory, network, etc) that each collection of processes can use.
These aren't specific to containers, it is setup for all processes right at boot. We can create different groups and subgroups from there.
You could manage allowed system resources with `systemctl` (or in the unit file with "ControlGroupAttribute") for each service.

We (Red Hat) have a decent [guide on the matter](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/resource_management_guide/chap-introduction_to_control_groups).

### Capabilities

### Copy-on-Write

### Full Blown Containers
Here we will mostly focus on Docker specific tooling as this is what is currently used in Tripleo deployments.

#### Runtimes

#### API

#### Registry

### Tripleo
Since the Openstack 12 realease, we have been shipping Tripleo (OoO) with containers on the overcloud nodes (14 will also have these on the undercloud).
As previously mentionned we currently use Docker, however we use a fancy wrapper called Paunch so we can be independant.

#### Kolla Containers

#### Paunch

#### Configuration steps

#### Kuryr

#### Magnum

### Examples
In this section we will have a few types of examples, ranging from debugging a failed container to setting up one mnually.

#### Making a manual container
This example is just to show a simple breakdown of how namespaces with cgroups can achieve a container-ish.

We first setup the btrfs volume where we will work from:
~~~
# mkfs.btrfs /dev/sdb
# mount /dev/sdb /btrfs
# cd /btrfs
# mount --make-private /
~~~

Then we create the structures we will need:
~~~
# mkdir -p images containers
# btrfs subvol create images/alpine
Create subvolume 'images/alpine'
~~~

Here we can see how useful a registry can be, we download and then unpackage the image:
~~~
# CID=$(docker run -d alpine true)
Unable to find image 'alpine:latest' locally
Trying to pull repository docker.io/library/alpine ... 
sha256:46e71df1e5191ab8b8034c5189e325258ec44ea739bba1e5645cff83c9048ff1: Pulling from docker.io/library/alpine
cd784148e348: Pulling fs layer
cd784148e348: Verifying Checksum
cd784148e348: Download complete
cd784148e348: Pull complete
Digest: sha256:46e71df1e5191ab8b8034c5189e325258ec44ea739bba1e5645cff83c9048ff1
Status: Downloaded newer image for docker.io/alpine:latest
# docker export $CID | tar -C images/alpine/ -xf-
# ls images/alpine/
bin  dev  etc  home  lib  media  mnt  proc  root  run  sbin  srv  sys  tmp  usr  var
~~~

As we don't want to edit the image directly we setup a snapshot (good example of how useful/important CoW is):
~~~
# btrfs subvol snapshot images/alpine/ containers/test_container
Create a snapshot of 'images/alpine/' in 'containers/test_container'
# touch containers/test_container/THIS_IS_TEST_CONTAINER
~~~

We can now already see that we have an almost container like feel with just a few namespaces:
~~~
# unshare --mount --uts --ipc --net --pid --fork bash
# ps
  PID TTY          TIME CMD
24951 pts/2    00:00:00 sudo
24953 pts/2    00:00:00 bash
25201 pts/2    00:00:00 unshare
25202 pts/2    00:00:00 bash
25233 pts/2    00:00:00 ps
# kill $(pidof unshare)
bash: kill: (25201) - No such process
# exit
~~~
Can't kill it because we are in our own namespace, and this PID does not exist in here.
Thus we still have the view of the host, and so have to mount our own root:
~~~
# cd /
# mount --bind /btrfs/containers/test_container/ /btrfs/containers/test_container/
# mount --move /btrfs/containers/test_container/ /btrfs/
# cd /btrfs/
# ls
bin  dev  etc  home  lib  media  mnt  proc  root  run  sbin  srv  sys  THIS_IS_TEST_CONTAINER  tmp  usr  var
# mkdir oldroot
# pivot_root . oldroot/
# cd /
# mount -t proc none /proc
# ps faux
PID   USER     TIME  COMMAND
    1 root      0:00 bash
   54 root      0:00 ps faux
~~~

At this point we still have all the host's mounts, so we have to remove these:
~~~
# umount -a
# mount -t proc none /proc
# umount -l /oldroot/
# mount
/dev/sdb on / type btrfs (ro,seclabel,relatime,space_cache,subvolid=258,subvol=/containers/test_container)
none on /proc type proc (rw,relatime)
# ip a
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
~~~

We now basically only covered mount_namespaces, pid_namespaces, which is just scratching the surface of what containers need now a days.
Here we can quickly setup networking, on the host we do the following to create a pair of virtual interfaces:
~~~
# CPID=$(pidof unshare)
# ip link add name h$CPID type veth peer name c$CPID
# ip link set c$CPID netns $CPID
# ip link set h$CPID master docker0 up
~~~

At this point the "container" now has the paired veth and it's pair is setup on the precreated docker bridge.
We now move onto the config of the network config within our namespace:
~~~
# ip a
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
10: c25568@if11: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop state DOWN qlen 1000
    link/ether b2:25:40:05:07:a4 brd ff:ff:ff:ff:ff:ff
# ip link set lo up
# ip link set c25568 name eth0 up
# ip a add 172.17.0.200/16 dev eth0
# ip route add default via 172.17.0.1
# ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=41 time=28.029 ms
64 bytes from 8.8.8.8: seq=1 ttl=41 time=27.868 ms
64 bytes from 8.8.8.8: seq=2 ttl=41 time=30.308 ms
~~~

Last step will be getting into the "container's" runtime. As of yet we've always been running with bash and the container itself does not have bash.
We then need to do this "handoff" within the container:
~~~
# exec chroot / sh
~~~

Things to add into this example:
- cgroups
- device ns
- capabilities
- selinux


