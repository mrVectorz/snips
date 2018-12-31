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
        - [Setup](#setup)
        - [Namespaces](#namespaces-1)
        - [cgroups](#cgroups)

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

cgroup subsystems represent a since resource each. These are mounted automatically by systemd at boot. You can view the currently mounted ones in `/proc/cgroups`.
The following are the default mounted in RHEL (source [0]):
- blkio: sets limits on i/o access to and from block devices
- cpu: uses the CPU scheduler to provide cgroup tasks access to the CPU. It is mounted together with the cpuacct controller on the same mount;
- cpuacct: creates automatic reports on CPU resources used by tasks in a cgroup. It is mounted together with the cpu controller on the same mount;
- cpuset: assigns individual CPUs (on a multicore system) and memory nodes to tasks in a cgroup;
- devices: allows or denies access to devices for tasks in a cgroup;
- freezer: suspends or resumes tasks in a cgroup;
- memory: sets limits on memory use by tasks in a cgroup and generates automatic reports on memory resources used by those tasks;
- net_cls: tags network packets with a class identifier (classid) that allows the Linux traffic controller (the tc command) to identify packets originating from a particular cgroup task. A subsystem of net_cls, the net_filter (iptables) can also use this tag to perform actions on such packets. The net_filter tags network sockets with a firewall identifier (fwid) that allows the Linux firewall (the iptables command) to identify packets (skb->sk) originating from a particular cgroup task;
- perf_event: enables monitoring cgroups with the perf tool;
- hugetlb: allows to use virtual memory pages of large sizes and to enforce resource limits on these pages.

[0] - Red Hat's [guide on the matter](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/resource_management_guide/chap-introduction_to_control_groups).



### Capabilities

### Copy-on-Write

### Full Blown Containers
Here we will mostly focus on Docker specific tooling as this is what is currently used in Tripleo deployments.

#### Runtimes

#### API

#### Registry

### Tripleo
Since the Openstack 12 realease, we have been shipping Tripleo (OoO) with containers on the overcloud nodes (14 will also have these on the undercloud).
The container runtime currently used by OoO is containerd (dockerd), however we use a wrapper called Paunch to manage the containers.

#### Kolla Containers

#### Paunch
Pauch is the utility used to launch, manage and configure containers. Only containers created by paunch will be modified by paunch.
This utility only keeps track of are labels, whether a certain container should be running or not is of no matter.

Paunch is idempotent, as in making multiple identical requests has the same effect as making a single request. The aim of the idempotency behaviour is to leave containers running when their config has not changed, but replace containers which have modified config.

As OoO does all the configuration parts in the deployment, we will only focus on the debugging aspect.

Labels on the containers are the only thing that paunch relies on and the `pauch debug` command (which is the only useful one for debugging) requires to know some information to even use it.

To list all labels on a container (using keystone for example):
~~~
# docker inspect keystone | jq -r '.[].Config.Labels'
{
  "version": "14.0",
  "vendor": "Red Hat, Inc.",
  "vcs-type": "git",
  "vcs-ref": "6635d448f90bf706adcb39272d1cfc8ee22036ec",
  "url": "https://access.redhat.com/containers/#/registry.access.redhat.com/rhosp14/openstack-keystone/images/14.0-81",
  "summary": "Red Hat OpenStack Platform 14.0 keystone",
  "release": "81",
  "config_id": "tripleo_step3",
  "config_data": "{\"start_order\": 2, \"healthcheck\": {\"test\": \"/openstack/healthcheck\"}, \"image\": \"192.168.24.1:8787/rhosp14/openstack-keystone:2018-11-26.1\", \"environment\": [\"KOLLA_CONFIG_STRATEGY=COPY_ALWAYS\", \"TRIPLEO_CONFIG_HASH=da5a48a8a5cb6c5469a5db334d36a69a\"], \"volumes\": [\"/etc/hosts:/etc/hosts:ro\", \"/etc/localtime:/etc/localtime:ro\", \"/etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro\", \"/etc/pki/ca-trust/source/anchors:/etc/pki/ca-trust/source/anchors:ro\", \"/etc/pki/tls/certs/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro\", \"/etc/pki/tls/certs/ca-bundle.trust.crt:/etc/pki/tls/certs/ca-bundle.trust.crt:ro\", \"/etc/pki/tls/cert.pem:/etc/pki/tls/cert.pem:ro\", \"/dev/log:/dev/log\", \"/etc/ssh/ssh_known_hosts:/etc/ssh/ssh_known_hosts:ro\", \"/etc/puppet:/etc/puppet:ro\", \"/var/log/containers/keystone:/var/log/keystone\", \"/var/log/containers/httpd/keystone:/var/log/httpd\", \"/var/lib/kolla/config_files/keystone.json:/var/lib/kolla/config_files/config.json:ro\", \"/var/lib/config-data/puppet-generated/keystone/:/var/lib/kolla/config_files/src:ro\", \"\", \"\"], \"net\": \"host\", \"privileged\": false, \"restart\": \"always\"}",
  "com.redhat.component": "openstack-keystone-container",
  "com.redhat.build-host": "cpt-0004.osbs.prod.upshift.rdu2.redhat.com",
  "build-date": "2018-11-26T19:32:31.327477",
  "batch": "20181126.1",
  "authoritative-source-url": "registry.access.redhat.com",
  "architecture": "x86_64",
  "container_name": "keystone",
  "description": "Red Hat OpenStack Platform 14.0 keystone",
  "distribution-scope": "public",
  "io.k8s.description": "Red Hat OpenStack Platform 14.0 keystone",
  "io.k8s.display-name": "Red Hat OpenStack Platform 14.0 keystone",
  "io.openshift.tags": "rhosp osp openstack osp-14.0",
  "managed_by": "paunch",
  "name": "rhosp14/openstack-keystone"
}
~~~

The relevant data that the `debug` command requires are "container_name" and "config_id".
"config_id" will only serve to tell us which config file to check for more information on this container ("print-cmd", "dump-yaml").
The config files used by OoO are all in dir "/var/lib/tripleo-config/" and the files to look into are "docker-container-startup-config-step*.json"

Looking at the help output:
~~~
# paunch debug --help
usage: paunch debug [-h] --file <file> [--label <label=value>]
                    [--managed-by <name>] [--action <name>] --container <name>
                    [--interactive] [--shell] [--user <name>]
                    [--overrides <name>] [--config-id <name>]

optional arguments:
  -h, --help            show this help message and exit
  --file <file>         YAML or JSON file containing configuration data
  --label <label=value>
                        Extra labels to apply to containers in this config, in
                        the form --label label=value --label label2=value2.
  --managed-by <name>   Override the name of the tool managing the containers
  --action <name>       Action can be one of: "dump-json", "dump-yaml",
                        "print-cmd", or "run"
  --container <name>    Name of the container you wish to manipulate
  --interactive         Run container in interactive mode - modifies config
                        and execution of container
  --shell               Similar to interactive but drops you into a shell
  --user <name>         Start container as the specified user
  --overrides <name>    JSON configuration information used to override
                        default config values
  --config-id <name>    ID to assign to containers
~~~

`--file` for our above example (keystone container) will be "/var/lib/tripleo-config/docker-container-startup-config-step_3.json"
`--container` is required to identify which container you want to manipulate out of all the ones in the specified file.

From here, we can dump the container's configuration in three formats (json, yaml and a docker run command string) or execute/run the container in either of two modes (interactive or detached)

To conclude this overview of Paunch, we will dump the command used to start the `keystone` container. This could be useful if for example it failed to start or was killed/destroyed.
~~~
# file="/var/lib/tripleo-config/docker-container-startup-config-step"
# step=$(docker inspect keystone | jq -r '.[].Config.Labels.config_id' | egrep -o "[0-9]*")
# name=$(docker inspect keystone | jq -r '.[].Config.Labels.container_name')
# paunch debug --file ${file}_${step}.json --container $name --action print-cmd
docker run --name keystone-uvb40g2t --detach=true --env=KOLLA_CONFIG_STRATEGY=COPY_ALWAYS --net=host --health-cmd=/openstack/healthcheck --privileged=false --restart=always --volume=/etc/hosts:/etc/hosts:ro --volume=/etc/localtime:/etc/localtime:ro --volume=/etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro --volume=/etc/pki/ca-trust/source/anchors:/etc/pki/ca-trust/source/anchors:ro --volume=/etc/pki/tls/certs/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro --volume=/etc/pki/tls/certs/ca-bundle.trust.crt:/etc/pki/tls/certs/ca-bundle.trust.crt:ro --volume=/etc/pki/tls/cert.pem:/etc/pki/tls/cert.pem:ro --volume=/dev/log:/dev/log --volume=/etc/ssh/ssh_known_hosts:/etc/ssh/ssh_known_hosts:ro --volume=/etc/puppet:/etc/puppet:ro --volume=/var/log/containers/keystone:/var/log/keystone --volume=/var/log/containers/httpd/keystone:/var/log/httpd --volume=/var/lib/kolla/config_files/keystone.json:/var/lib/kolla/config_files/config.json:ro --volume=/var/lib/config-data/puppet-generated/keystone/:/var/lib/kolla/config_files/src:ro 192.168.24.1:8787/rhosp14/openstack-keystone:2018-11-26.1
~~~

#### Configuration steps

#### Kuryr

#### Magnum

### Examples
In this section we will have a few types of examples, ranging from debugging a failed container to setting up one manually.

#### Making a manual container
This example is just to show a simple breakdown of how namespaces with cgroups can achieve a container-ish.
To be used as a guide only, do not attempt in any sorts of prod-like environment.

##### Setup
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

Here we can see how useful an image registry can be, we download and then unpackage the already made tiny image:
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

##### Namespaces
In this section of the example we're going to start unsharing namespaces, we can quicly to something that feels like a normal container.

We can now already see that we have an almost container like feel:
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
- device ns
- capabilities
- selinux

##### cgroups

