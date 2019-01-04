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
    2. [Pauch debug logs](#pauch-debug-logs)

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

On RHEL cgroups are enabled by default. This does come at a slight performance overhead due to the accounting. However if really desired we could disable this mechanism by removing the `libcgroup` package, but this isn't practical anymore as there are a lot of dependencies. Instead we can trim the overhead down a little bit by disabling specific controllers (only memory has any impact for now).

As per the [kernel documentation](https://www.kernel.org/doc/Documentation/admin-guide/kernel-parameters.txt):
~~~
	cgroup_disable=	[KNL] Disable a particular controller
			Format: {name of the controller(s) to disable}
			The effects of cgroup_disable=foo are:
			- foo isn't auto-mounted if you mount all cgroups in
			  a single hierarchy
			- foo isn't visible as an individually mountable
			  subsystem
			{Currently only "memory" controller deal with this and
			cut the overhead, others just disable the usage. So
			only cgroup_disable=memory is actually worthy}
~~~

We only have to add parameter `cgroup_disable=memory` to grub at system boot.

To manually gather information, configure or execute on cgroups we install the `libcgroup-tools` package.

Here we see the controllers and how many groups they have:
~~~
[root@controller-1 ~]# cat /proc/cgroups
#subsys_name	hierarchy	num_cgroups	enabled
cpuset	5	60	1
cpu	2	260	1
cpuacct	2	260	1
memory	3	260	1
devices	11	260	1
freezer	7	60	1
net_cls	10	60	1
blkio	6	260	1
perf_event	9	60	1
hugetlb	8	60	1
pids	4	260	1
net_prio	10	60	1
~~~

In the example output above, the hierarchy column lists IDs of the existing hierarchies on the system. Subsystems with the same hierarchy ID are attached to the same hierarchy.
The num_cgroup column lists the number of existing cgroups in the hierarchy that uses a particular subsystem.
We can then see we have over a thousand of already configured cgroups.

To see more specifically what these groups are:
~~~
[root@controller-1 ~]# lscgroup | awk 'BEGIN {FS="/"} {print $2}' | sort | uniq -c | sort -n
      5 machine.slice
      5 user.slice
     10 
   1580 system.slice
[root@controller-1 ~]# systemctl -t slice
UNIT                                                          LOAD   ACTIVE SUB    DESCRIPTION
-.slice                                                       loaded active active Root Slice
machine.slice                                                 loaded active active Virtual Machine and Container Slice
system-getty.slice                                            loaded active active system-getty.slice
system-lvm2\x2dpvscan.slice                                   loaded active active system-lvm2\x2dpvscan.slice
system-selinux\x2dpolicy\x2dmigrate\x2dlocal\x2dchanges.slice loaded active active system-selinux\x2dpolicy\x2dmigrate\x2dlocal\x2dchanges.slice
system-serial\x2dgetty.slice                                  loaded active active system-serial\x2dgetty.slice
system.slice                                                  loaded active active System Slice
user-0.slice                                                  loaded active active User Slice of root
user-1000.slice                                               loaded active active User Slice of heat-admin
user.slice                                                    loaded active active User and Session Slice

LOAD   = Reflects whether the unit definition was properly loaded.
ACTIVE = The high-level unit activation state, i.e. generalization of SUB.
SUB    = The low-level unit activation state, values depend on unit type.

10 loaded units listed. Pass --all to see loaded but inactive units, too.
To show all installed unit files use 'systemctl list-unit-files'.
~~~

We can denote that 10 slices are active. Which can be broken down:
- There are five instances of the "machine.slice"; which the default place for all virtual machines and Linux containers.
~~~
[root@controller-1 ~]# lscgroup | grep machine.slice
cpu,cpuacct:/machine.slice
memory:/machine.slice
pids:/machine.slice
blkio:/machine.slice
devices:/machine.slice
~~~

- Also 5 "user.slice"; the default place for all user sessions.
- The 10 "empty" ones are simply the controllers themselves.
- As for the 1580 "system.slice", which isthe default place for all system services, are all processes running on the system as they are child processes of the systemd init process.
  Within this slice, we will have all the mounts, services, scopes and subslices of systemd.
  Docker containers in our case will also be part of this slice, but divided in their subslice. The dash ("-") character acts as a separator of the path components.
  For example, let's see how the heat-api container is setup:
~~~
[root@controller-1 ~]# docker ps | grep heat_api$
b25aa6e03826        192.168.24.1:8787/rhosp14/openstack-heat-api:2018-11-26.1                    "kolla_start"            5 weeks ago         Up 28 hours (healthy)                             heat_api
[root@controller-1 ~]# lscgroup |grep b25aa6e03826
cpu,cpuacct:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
cpu,cpuacct:/system.slice/var-lib-docker-containers-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a-shm.mount
memory:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
memory:/system.slice/var-lib-docker-containers-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a-shm.mount
pids:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
pids:/system.slice/var-lib-docker-containers-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a-shm.mount
cpuset:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
blkio:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
blkio:/system.slice/var-lib-docker-containers-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a-shm.mount
freezer:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
hugetlb:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
perf_event:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
net_cls,net_prio:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
devices:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
devices:/system.slice/var-lib-docker-containers-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a-shm.mount
[root@controller-1 ~]# systemctl status docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
● docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope - libcontainer container b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a
   Loaded: loaded (/run/systemd/system/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope; static; vendor preset: disabled)
  Drop-In: /run/systemd/system/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope.d
           └─50-BlockIOAccounting.conf, 50-CPUAccounting.conf, 50-DefaultDependencies.conf, 50-Delegate.conf, 50-Description.conf, 50-MemoryAccounting.conf, 50-Slice.conf
   Active: active (running) since Thu 2019-01-03 15:29:45 UTC; 1 day 4h ago
    Tasks: 11
   Memory: 99.6M
   CGroup: /system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
           ├─  8102 /usr/sbin/httpd -DFOREGROUND
           ├─  9682 heat_api_wsgi   -DFOREGROUND
           ├─579839 /usr/sbin/httpd -DFOREGROUND
           ├─579961 /usr/sbin/httpd -DFOREGROUND
           ├─579962 /usr/sbin/httpd -DFOREGROUND
           ├─580574 /usr/sbin/httpd -DFOREGROUND
           ├─580788 /usr/sbin/httpd -DFOREGROUND
           └─633107 /usr/sbin/httpd -DFOREGROUND
[root@controller-1 ~]# cat /proc/8102/cgroup
11:devices:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
10:net_prio,net_cls:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
9:perf_event:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
8:hugetlb:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
7:freezer:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
6:blkio:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
5:cpuset:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
4:pids:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
3:memory:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
2:cpuacct,cpu:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
1:name=systemd:/system.slice/docker-b25aa6e03826d42d0d4ad6788365cc7e1db006f24278c57cc4160f5fd1b19d2a.scope
~~~

From this data, we can see the controllers used, what processes are within scope and their consumption.
To have a better view of of ressource consumption we can use `systemd-cgtop`.

~~~
Path                                                                                                                                                                        Tasks   %CPU   Memory  Input/s Output/s
/                                                                                                                                                                             127  167.6    10.3G        -        -
/system.slice                                                                                                                                                                   -  157.2     9.6G        -        -
/system.slice/docker-496d3166d70c00085153dbb41193037562ea514211d88f1f2bdfdf779f62be59.scope                                                                                    15   87.0   220.9M        -        -
/system.slice/docker-2792b89c98b2f73cbe269d3f15d5ad2e9dc63ea24b134176e9cfd6d4a749a154.scope                                                                                     1   22.8    34.0M        -        -
/system.slice/docker-0351e060573f32434a3cca2293a26172cc39daafeb237d3af089bb2e48220b44.scope                                                                                     5    8.2     7.0M        -        -
/user.slice                                                                                                                                                                     7    8.0   718.6M        -        -
/system.slice/docker-21c77edcc723293603ad099d03b5e55a17b39ab2dfe9b95733bbbfd60adfd032.scope                                                                                     2    2.9   115.9M        -        -
/system.slice/docker-92a0b901c3cfe86e25c6e5eadf43a05806b917b7b8f442121b761a31e9fc4f5d.scope                                                                                     2    2.5   185.7M        -        -
/system.slice/docker-550af8a36618607fc43613c87db62e1b641e7224f92f8c7ff1e4855b88d86a0b.scope                                                                                     4    2.4   167.8M        -        -
/system.slice/docker-597f92ba5d7e7f7e5d3f4602cfe7113247550f514c4b0607ae3cd1e85f326357.scope                                                                                     2    2.0    83.7M        -        -
/system.slice/docker-04474d1374e4d0694e3fe4ab6092b97382b4d403b43fd313bed1dac5aa25155c.scope                                                                                     5    2.0   347.8M        -        -
(...)
~~~

If we mount the cgroup directories, we will have a better view on what can be done with them.
Here we will make a dir and mount:
~~~
[root@localhost ~]# mkdir -p /cgroup/blkio
[root@localhost ~]# mount -t cgroup -o blkio blkio /cgroup/blkio
~~~

cgroups have special files which can be used for various reasons.
Here is what you see when you mount blkio cgroup (they all have these mechanism, just a bit different to match the controller):
~~~
[root@localhost ~]# ll /cgroup/blkio/
total 0
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_merged
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_merged_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_queued
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_queued_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_service_bytes
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_service_bytes_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_serviced
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_serviced_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_service_time
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_service_time_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_wait_time
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.io_wait_time_recursive
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.leaf_weight
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.leaf_weight_device
--w-------. 1 root root 0 Jan  3 21:19 blkio.reset_stats
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.sectors
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.sectors_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.io_service_bytes
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.io_service_bytes_recursive
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.io_serviced
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.io_serviced_recursive
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.read_bps_device
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.read_iops_device
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.write_bps_device
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.throttle.write_iops_device
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.time
-r--r--r--. 1 root root 0 Jan  3 21:19 blkio.time_recursive
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.weight
-rw-r--r--. 1 root root 0 Jan  3 21:19 blkio.weight_device
-rw-r--r--. 1 root root 0 Jan  3 21:19 cgroup.clone_children
-rw-r--r--. 1 root root 0 Jan  3 21:19 cgroup.procs
-r--r--r--. 1 root root 0 Jan  3 21:19 cgroup.sane_behavior
-rw-r--r--. 1 root root 0 Jan  3 21:19 notify_on_release
-rw-r--r--. 1 root root 0 Jan  3 21:19 release_agent
drwxr-xr-x. 2 root root 0 Jan  4 15:40 system.slice
-rw-r--r--. 1 root root 0 Jan  3 21:19 tasks
~~~

Some are more obvious like the stat/accounting files:
- merged
- queued
- serviced
- etc

There are the configuration files to do the limiting mechanics:
- blkio.throttle.*

We can see the system.slice subgroup within the parent, this directory will contain all of the same files minus the release_agent.

Lastly some control files:
- tasks: list of tasks (by PID) attached to that cgroup.  This list
  is not guaranteed to be sorted.  Writing a thread ID into this file
  moves the thread into this cgroup.
- cgroup.procs: list of thread group IDs in the cgroup.  This list is
  not guaranteed to be sorted or free of duplicate TGIDs, and userspace
  should sort/uniquify the list if this property is required.
  Writing a thread group ID into this file moves all threads in that
  group into this cgroup.
- notify_on_release flag: run the release agent on exit?
- release_agent: the path to use for release notifications (this file
  exists in the top cgroup only)

You can go the examples bellow to see more information how we can manually use these.

For further reading and information on this subject please see the following:
- [https://www.kernel.org/doc/Documentation/cgroup-v1/cgroups.txt](https://www.kernel.org/doc/Documentation/cgroup-v1/cgroups.txt)
- [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/resource_management_guide/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/resource_management_guide/)
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

The reason behind using containers is likely more involved then simply foolowing community trends and all. However, since we still use puppet, heat and bash scripts to configure the containers this isn't a clear simplicity win.

The director installs the core OpenStack Platform services as containers on the overcloud. The templates for the containerized services are located in the "/usr/share/openstack-tripleo-heat-templates/docker/services/". These templates reference their respective composable service templates. Example keystone templates will still have something like `type: ../../puppet/services/keystone.yaml` (type baiscally sources the outputs data).

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

Tasks to run on the service’s configuration container. All tasks are grouped into steps to help the director perform a staged deployment.

Step 1 - Load balancer configuration
Step 2 - Core services (Database, Redis)
Step 3 - Initial configuration of OpenStack Platform service
Step 4 - General OpenStack Platform services configuration
Step 5 - Service activation

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

#### Pauch debug logs
We can set debug logs in most of the openstack components fairly easily.

First we check if the container is already running, as if it is the task is done by simply restarting it after the modification.

Example with container running (we will do nova api):
~~~
# docker ps | grep nova-api
1adf5a0df37a        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 4 weeks (healthy)                         nova_metadata
483857212bda        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 4 weeks (healthy)                         nova_api
0156ea17dfc0        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 4 weeks                                   nova_api_cron
# docker inspect nova_api | jq -r '.[].Config.Labels.config_id'
tripleo_step4
# docker inspect nova_api | jq -r '.[].Config.Labels.container_name'
nova_api
# paunch debug --file /var/lib/tripleo-config/docker-container-startup-config-step_3.json --container nova_api --action dump-yaml
nova_api:
  environment:
  - KOLLA_CONFIG_STRATEGY=COPY_ALWAYS
  healthcheck:
    test: /openstack/healthcheck
  image: 192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1
  net: host
  privileged: true
  restart: always
  start_order: 2
  user: root
  volumes:
  - /etc/hosts:/etc/hosts:ro
  - /etc/localtime:/etc/localtime:ro
  - /etc/pki/ca-trust/extracted:/etc/pki/ca-trust/extracted:ro
  - /etc/pki/ca-trust/source/anchors:/etc/pki/ca-trust/source/anchors:ro
  - /etc/pki/tls/certs/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro
  - /etc/pki/tls/certs/ca-bundle.trust.crt:/etc/pki/tls/certs/ca-bundle.trust.crt:ro
  - /etc/pki/tls/cert.pem:/etc/pki/tls/cert.pem:ro
  - /dev/log:/dev/log
  - /etc/ssh/ssh_known_hosts:/etc/ssh/ssh_known_hosts:ro
  - /etc/puppet:/etc/puppet:ro
  - /var/log/containers/nova:/var/log/nova
  - /var/log/containers/httpd/nova-api:/var/log/httpd
  - /var/lib/kolla/config_files/nova_api.json:/var/lib/kolla/config_files/config.json:ro
  - /var/lib/config-data/puppet-generated/nova/:/var/lib/kolla/config_files/src:ro
  - ''
  - ''
# #Here we see the binded volumes where the nova.conf file would be located
# crudini --set /var/lib/config-data/puppet-generated/nova/etc/nova/nova.conf DEFAULT debug true
# crudini --get /var/lib/config-data/puppet-generated/nova/etc/nova/nova.conf DEFAULT debug
true
# docker restart nova_api
nova_api
# docker ps |grep nova_api
483857212bda        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 31 seconds (healthy)                       nova_api
0156ea17dfc0        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 4 weeks                                    nova_api_cron
~~~

If we need to start the docker manually as if it had stopped, we would use `--action run`:
~~~
# paunch debug --file /var/lib/tripleo-config/docker-container-startup-config-step_3.json --container nova_api --action run
05f24cc41c64f9379326673e77eb7c42c8849410fa8b3e6acaf21fdf42f2ca5a
# docker ps |grep nova_api
05f24cc41c64        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            48 seconds ago      Up 47 seconds (healthy)                       nova_api-vbew3x7x
0156ea17dfc0        192.168.24.1:8787/rhosp14/openstack-nova-api:2018-11-26.1                    "kolla_start"            4 weeks ago         Up 4 weeks                                    nova_api_cron
~~~

