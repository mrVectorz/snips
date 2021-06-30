# Creating pods with manually set cpu-rt-period and cpu-rt-runtime in OCP

1. [Analysis](#analysis)
2. [OCP TLDR](#tldr_ocp_workaround)
3. [Other](#other)

### Analysis

Allowing 'CAP_SYS_NICE' capability for the pod allows to then set real-time scheduling policies for calling process, and set scheduling policies and priorities for arbitrary processes. Alternatively create a privileged pod.

By default on a non RT worker the error on pod creation is:
```
[root@openshift-worker-1 ~]# podman --log-level=debug run --detach --name app11 --security-opt label=disable --privileged=true --cpu-rt-period=1000000  --cpu-rt-runtime=950000  registry.access.redhat.com/ubi8 sleep infinity
(...)
DEBU[0017] ExitCode msg: "time=\"2021-06-23t20:52:05z\" level=error msg=\"container_linux.go:366: starting container process caused: process_linux.go:472: container init caused: process_linux.go:435: setting cgroup config for prochooks process caused: failed to write \\\"950000\\\" to \\\"/sys/fs/cgroup/cpu,cpuacct/machine.slice/libpod-70615b1887eedc71859a8e84d7403138f91570b73a27eff168a50ab064169c6f.scope/cpu.rt_runtime_us\\\": write /sys/fs/cgroup/cpu,cpuacct/machine.slice/libpod-70615b1887eedc71859a8e84d7403138f91570b73a27eff168a50ab064169c6f.scope/cpu.rt_runtime_us: invalid argument\": oci runtime error" 
ERRO[0017] time="2021-06-23T20:52:05Z" level=error msg="container_linux.go:366: starting container process caused: process_linux.go:472: container init caused: process_linux.go:435: setting cgroup config for procHooks process caused: failed to write \"950000\" to \"/sys/fs/cgroup/cpu,cpuacct/machine.slice/libpod-70615b1887eedc71859a8e84d7403138f91570b73a27eff168a50ab064169c6f.scope/cpu.rt_runtime_us\": write /sys/fs/cgroup/cpu,cpuacct/machine.slice/libpod-70615b1887eedc71859a8e84d7403138f91570b73a27eff168a50ab064169c6f.scope/cpu.rt_runtime_us: invalid argument": OCI runtime error
```

This is because, as we do not make use of the Docker daemon, we do not have the rt budget set by default (and systemd does not currently manage it either).
There is a closed (will not fix, as supporting this is "weird") RFE for systemd:
- [https://github.com/systemd/systemd/issues/329](https://github.com/systemd/systemd/issues/329)

We can manually allocate by setting it to the parent cgroup (example machine slice):
```
echo 950000 > /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us
```

Currently on 4.6.21 this workaround fails with perm deny:
```
[root@openshift-worker-0 ~]# cat /etc/redhat-release 
Red Hat Enterprise Linux CoreOS release 4.6
[root@openshift-worker-0 ~]# echo 950000 > /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us
-bash: /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us: Permission denied
[root@openshift-worker-0 ~]# echo 950000 > /sys/fs/cgroup/cpu,cpuacct/cpu.rt_runtime_us
-bash: /sys/fs/cgroup/cpu,cpuacct/cpu.rt_runtime_us: Permission denied
```

Even though the fs is not mounted as ro:
```
[root@openshift-worker-0 ~]# grep /sys/fs/cgroup/cpu, /proc/mounts 
cgroup /sys/fs/cgroup/cpu,cpuacct cgroup rw,seclabel,nosuid,nodev,noexec,relatime,cpu,cpuacct 0 0
```

This host is running a rt kernel and global policy is `-1` and so cannot be overwritten:
```
[root@openshift-worker-0 ~]# cat /proc/sys/kernel/sched_rt_runtime_us
-1
```

After having changed the worker to a non RT kernel:
```
[root@openshift-worker-0 ~]# uname -a
Linux openshift-worker-0 4.18.0-193.51.1.el8_2.x86_64 #1 SMP Thu Apr 8 13:59:36 EDT 2021 x86_64 x86_64 x86_64 GNU/Linux
[root@openshift-worker-0 ~]# cat /proc/cmdline 
BOOT_IMAGE=(hd0,gpt1)/ostree/rhcos-bc44efa56a1932c12e25308c05ac50176f77e332512150591b76d072375b9ba3/vmlinuz-4.18.0-193.51.1.el8_2.x86_64 rhcos.root=crypt_rootfs random.trust_cpu=on console=tty0 console=ttyS0,115200n8 rd.luks.options=discard ostree=/ostree/boot.0/rhcos/bc44efa56a1932c12e25308c05ac50176f77e332512150591b76d072375b9ba3/0 ignition.platform.id=openstack intel_iommu=on iommu=pt skew_tick=1 nohz=on rcu_nocbs=1,3,5-19,21,23,25-39 tuned.non_isolcpus=01500015 intel_pstate=disable nosoftlockup tsc=nowatchdog intel_iommu=on iommu=pt isolcpus=managed_irq,1,3,5-19,21,23,25-39 systemd.cpu_affinity=0,2,4,20,22,24 default_hugepagesz=1G hugepagesz=1G hugepages=20 +
```

**Note**: For some reason changing the performance profile of the node back to `false` still left the node with a `sched_rt_runtime_us` of `-1`.
Profile set with:
```
    realTimeKernel:
      enabled: false
# Node still has -1 even though no longer RT
[root@openshift-worker-0 ~]# cat /proc/sys/kernel/sched_rt_runtime_us
-1
```

Dismissing the above note, we can now apply the workaround and now start the pod without issue:
```
[root@openshift-worker-0 ~]# cat /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us
0
[root@openshift-worker-0 ~]# echo 950000 > /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us
[root@openshift-worker-0 ~]# cat /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us
950000
[root@openshift-worker-0 ~]# podman --log-level=debug run --detach --name app11 --security-opt label=disable --privileged=true --cpu-rt-period=1000000  --cpu-rt-runtime=950000  registry.access.redhat.com/ubi8 sleep infinity
WARN[0000] setting security options with --privileged has no effect 
DEBU[0000] Found deprecated file /usr/share/containers/libpod.conf, please remove. Use /etc/containers/containers.conf to override defaults. 
DEBU[0000] Reading configuration file "/usr/share/containers/libpod.conf" 
DEBU[0000] Ignoring lipod.conf EventsLogger setting "journald". Use containers.conf if you want to change this setting and remove libpod.conf files. 
DEBU[0000] Reading configuration file "/usr/share/containers/containers.conf" 
DEBU[0000] Merged system config "/usr/share/containers/containers.conf": &{{[] [] container-default [] host [CAP_AUDIT_WRITE CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_FSETID CAP_KILL CAP_MKNOD CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SETFCAP CAP_SETGID CAP_SETPCAP CAP_SETUID CAP_SYS_CHROOT] [] [nproc=4194304:4194304]  [] [] [] true [PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin] false false false  private k8s-file -1 bridge false 2048 private /usr/share/containers/seccomp.json 65536k private host 65536} {false systemd [PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin] [/usr/libexec/podman/conmon /usr/local/libexec/podman/conmon /usr/local/lib/podman/conmon /usr/bin/conmon /usr/sbin/conmon /usr/local/bin/conmon /usr/local/sbin/conmon /run/current-system/sw/bin/conmon] ctrl-p,ctrl-q true /var/run/libpod/events/events.log file [/usr/share/containers/oci/hooks.d] docker:// /pause k8s.gcr.io/pause:3.2 /usr/libexec/podman/catatonit shm   false 2048 runc map[crun:[/usr/bin/crun /usr/sbin/crun /usr/local/bin/crun /usr/local/sbin/crun /sbin/crun /bin/crun /run/current-system/sw/bin/crun] kata:[/usr/bin/kata-runtime /usr/sbin/kata-runtime /usr/local/bin/kata-runtime /usr/local/sbin/kata-runtime /sbin/kata-runtime /bin/kata-runtime /usr/bin/kata-qemu /usr/bin/kata-fc] kata-fc:[/usr/bin/kata-fc] kata-qemu:[/usr/bin/kata-qemu] kata-runtime:[/usr/bin/kata-runtime] runc:[/usr/bin/runc /usr/sbin/runc /usr/local/bin/runc /usr/local/sbin/runc /sbin/runc /bin/runc /usr/lib/cri-o-runc/sbin/runc /run/current-system/sw/bin/runc]] missing [] [crun runc] [crun] {false false false true true true}  false 3 /var/lib/containers/storage/libpod 10 /var/run/libpod /var/lib/containers/storage/volumes} {[/usr/libexec/cni /usr/lib/cni /usr/local/lib/cni /opt/cni/bin] podman /etc/cni/net.d/}} 
DEBU[0000] Using conmon: "/usr/bin/conmon"              
DEBU[0000] Initializing boltdb state at /var/lib/containers/storage/libpod/bolt_state.db 
DEBU[0000] Using graph driver overlay                   
DEBU[0000] Using graph root /var/lib/containers/storage 
DEBU[0000] Using run root /var/run/containers/storage   
DEBU[0000] Using static dir /var/lib/containers/storage/libpod 
DEBU[0000] Using tmp dir /var/run/libpod                
DEBU[0000] Using volume path /var/lib/containers/storage/volumes 
DEBU[0000] Set libpod namespace to ""                   
DEBU[0000] [graphdriver] trying provided driver "overlay" 
DEBU[0000] cached value indicated that overlay is supported 
DEBU[0000] cached value indicated that metacopy is not being used 
DEBU[0000] NewControl(/var/lib/containers/storage/overlay): nextProjectID = 2 
DEBU[0000] cached value indicated that native-diff is usable 
DEBU[0000] backingFs=xfs, projectQuotaSupported=true, useNativeDiff=true, usingMetacopy=false 
DEBU[0000] Initializing event backend file              
DEBU[0000] using runtime "/usr/bin/runc"                
WARN[0000] Error initializing configured OCI runtime crun: no valid executable found for OCI runtime crun: invalid argument 
WARN[0000] Error initializing configured OCI runtime kata: no valid executable found for OCI runtime kata: invalid argument 
WARN[0000] Error initializing configured OCI runtime kata-runtime: no valid executable found for OCI runtime kata-runtime: invalid argument 
WARN[0000] Error initializing configured OCI runtime kata-qemu: no valid executable found for OCI runtime kata-qemu: invalid argument 
WARN[0000] Error initializing configured OCI runtime kata-fc: no valid executable found for OCI runtime kata-fc: invalid argument 
INFO[0000] Found CNI network crio (type=bridge) at /etc/cni/net.d/100-crio-bridge.conf 
INFO[0000] Found CNI network 200-loopback.conf (type=loopback) at /etc/cni/net.d/200-loopback.conf 
INFO[0000] Found CNI network podman (type=bridge) at /etc/cni/net.d/87-podman-bridge.conflist 
WARN[0000] Default CNI network name podman is unchangeable 
DEBU[0000] parsed reference into "[overlay@/var/lib/containers/storage+/var/run/containers/storage]registry.access.redhat.com/ubi8:latest" 
DEBU[0000] parsed reference into "[overlay@/var/lib/containers/storage+/var/run/containers/storage]@272209ff0ae5fe54c119b9c32a25887e13625c9035a1599feba654aa7638262d" 
DEBU[0000] exporting opaque data as blob "sha256:272209ff0ae5fe54c119b9c32a25887e13625c9035a1599feba654aa7638262d" 
DEBU[0000] Using bridge netmode                         
DEBU[0000] No hostname set; container's hostname will default to runtime default 
DEBU[0000] Loading seccomp profile from "/usr/share/containers/seccomp.json" 
DEBU[0000] setting container name app11                 
DEBU[0000] created OCI spec and options for new container 
DEBU[0000] Allocated lock 0 for container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 
DEBU[0000] parsed reference into "[overlay@/var/lib/containers/storage+/var/run/containers/storage]@272209ff0ae5fe54c119b9c32a25887e13625c9035a1599feba654aa7638262d" 
DEBU[0000] exporting opaque data as blob "sha256:272209ff0ae5fe54c119b9c32a25887e13625c9035a1599feba654aa7638262d" 
DEBU[0000] created container "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" 
DEBU[0000] container "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" has work directory "/var/lib/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata" 
DEBU[0000] container "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" has run directory "/var/run/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata" 
DEBU[0000] New container created "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" 
DEBU[0000] container "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" has CgroupParent "machine.slice/libpod-6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394.scope" 
DEBU[0000] Made network namespace at /var/run/netns/cni-6437131d-2be5-b55c-1685-b799b21fd63f for container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 
INFO[0000] About to add CNI network lo (type=loopback)  
DEBU[0000] overlay: mount_data=lowerdir=/var/lib/containers/storage/overlay/l/PFJQ63Q2UGHLP7OIC5USQTDIPM:/var/lib/containers/storage/overlay/l/ANSY2EVZNPSZFWEP3OIVPRENKU,upperdir=/var/lib/containers/storage/overlay/7c375cb3ccfcf3d7cf12d1a4194c38484fe8658d17e80f903e4a34691a736110/diff,workdir=/var/lib/containers/storage/overlay/7c375cb3ccfcf3d7cf12d1a4194c38484fe8658d17e80f903e4a34691a736110/work,context="system_u:object_r:container_file_t:s0:c61,c249" 
INFO[0000] Got pod network &{Name:app11 Namespace:app11 ID:6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 NetNS:/var/run/netns/cni-6437131d-2be5-b55c-1685-b799b21fd63f Networks:[] RuntimeConfig:map[podman:{IP: MAC: PortMappings:[] Bandwidth:<nil> IpRanges:[]}]} 
INFO[0000] About to add CNI network podman (type=bridge) 
DEBU[0000] mounted container "6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394" at "/var/lib/containers/storage/overlay/7c375cb3ccfcf3d7cf12d1a4194c38484fe8658d17e80f903e4a34691a736110/merged" 
DEBU[0000] Created root filesystem for container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 at /var/lib/containers/storage/overlay/7c375cb3ccfcf3d7cf12d1a4194c38484fe8658d17e80f903e4a34691a736110/merged 
DEBU[0000] [0] CNI result: &{0.4.0 [{Name:cni-podman0 Mac:6e:6f:a1:11:1d:1a Sandbox:} {Name:vethc7b0908a Mac:22:24:70:a2:59:61 Sandbox:} {Name:eth0 Mac:2e:e4:86:11:b0:f6 Sandbox:/var/run/netns/cni-6437131d-2be5-b55c-1685-b799b21fd63f}] [{Version:4 Interface:0xc000119468 Address:{IP:10.88.0.4 Mask:ffff0000} Gateway:10.88.0.1}] [{Dst:{IP:0.0.0.0 Mask:00000000} GW:<nil>}] {[]  [] []}} 
DEBU[0000] /etc/system-fips does not exist on host, not mounting FIPS mode secret 
DEBU[0000] Setting CGroups for container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 to machine.slice:libpod:6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 
DEBU[0000] reading hooks from /usr/share/containers/oci/hooks.d 
DEBU[0000] Created OCI spec for container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 at /var/lib/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata/config.json 
DEBU[0000] /usr/bin/conmon messages will be logged to syslog 
DEBU[0000] running conmon: /usr/bin/conmon               args="[--api-version 1 -s -c 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 -u 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 -r /usr/bin/runc -b /var/lib/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata -p /var/run/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata/pidfile -l k8s-file:/var/lib/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata/ctr.log --exit-dir /var/run/libpod/exits --socket-dir-path /var/run/libpod/socket --log-level debug --syslog --conmon-pidfile /var/run/containers/storage/overlay-containers/6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394/userdata/conmon.pid --exit-command /usr/bin/podman --exit-command-arg --root --exit-command-arg /var/lib/containers/storage --exit-command-arg --runroot --exit-command-arg /var/run/containers/storage --exit-command-arg --log-level --exit-command-arg debug --exit-command-arg --cgroup-manager --exit-command-arg systemd --exit-command-arg --tmpdir --exit-command-arg /var/run/libpod --exit-command-arg --runtime --exit-command-arg runc --exit-command-arg --storage-driver --exit-command-arg overlay --exit-command-arg --events-backend --exit-command-arg file --exit-command-arg container --exit-command-arg cleanup --exit-command-arg 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394]"
INFO[0000] Running conmon under slice machine.slice and unitName libpod-conmon-6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394.scope 
DEBU[0000] Received: 2139722                            
INFO[0000] Got Conmon PID as 2139710                    
DEBU[0000] Created container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 in OCI runtime 
DEBU[0000] Starting container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 with command [sleep infinity] 
DEBU[0000] Started container 6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394 
6dd05e91f00f99281f70b1fd90a29e5cc30b0dab243cb7cfb6153d8017872394
[root@openshift-worker-0 ~]# podman ps
CONTAINER ID  IMAGE                                   COMMAND         CREATED        STATUS            PORTS  NAMES
6dd05e91f00f  registry.access.redhat.com/ubi8:latest  sleep infinity  8 seconds ago  Up 7 seconds ago         app11
```

### TLDR OCP Workaround

We will apply the workaround via MC.

1. get the base64 string as follows
```
echo $(cat << EOF | base64 -w0
[Unit]
Description=Apply OCP cpu-rt workaround
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash /usr/local/bin/ocp_cpu_rt_workaround.sh
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF
)
W1VuaXRdCkRlc2NyaXB0aW9uPUFwcGx5IE9DUCBjcHUtcnQgd29ya2Fyb3VuZApBZnRlcj1uZXR3b3JrLW9ubGluZS50YXJnZXQKV2FudHM9bmV0d29yay1vbmxpbmUudGFyZ2V0CgpbU2VydmljZV0KRXhlY1N0YXJ0PS9iaW4vYmFzaCAvdXNyL2xvY2FsL2Jpbi9vY3BfY3B1X3J0X3dvcmthcm91bmQuc2gKVHlwZT1vbmVzaG90CgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQK
```

2. We create a file named `ocp_cpu_rt_workaround.sh` with the following bash commands for our workaround bash script
```
function log()
{
  echo "$(TZ=Z date +%FT%TZ) $@"
}

function validate_setup()
{
  grep -q 950000 /sys/fs/cgroup/cpu,cpuacct/machine.slice/cpu.rt_runtime_us 2> /dev/null
  return $?
}

if ! validate_setup; then
  log "INFO: Applying the workaround"
  echo 950000 > /sys/fs/cgroup/cpu,cpuacct/cpu.rt_runtime_us
  if [ $? -ne 0 ]; then
    log "ERROR: Could not set the workaround"
  else
    log "Success: Applied the workaround"
  fi
else
  log "INFO: Workaround already in place"
fi
```

3. We create our MachineConfig yaml file (change the role to apply to the correct MCP)
```
cat << EOF > ./ocp_cpu_rt_workaround.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: cpu-rt-workaround
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - contents:
          source: data:text/plain;base64,W1VuaXRdCkRlc2NyaXB0aW9uPUFwcGx5IE9DUCBjcHUtcnQgd29ya2Fyb3VuZApBZnRlcj1uZXR3b3JrLW9ubGluZS50YXJnZXQKV2FudHM9bmV0d29yay1vbmxpbmUudGFyZ2V0CgpbU2VydmljZV0KRXhlY1N0YXJ0PS9iaW4vYmFzaCAvdXNyL2xvY2FsL2Jpbi9vY3BfY3B1X3J0X3dvcmthcm91bmQuc2gKVHlwZT1vbmVzaG90CgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQK
        filesystem: root
        mode: 0660
        path: /etc/systemd/system/ocp_cpu_rt_workaround.unit
      - contents:
          source: data:text/plain;base64,ZnVuY3Rpb24gbG9nKCkKeyAKICBlY2hvICIkKFRaPVogZGF0ZSArJUZUJVRaKSAkQCIKfQoKZnVuY3Rpb24gdmFsaWRhdGVfc2V0dXAoKQp7CiAgZ3JlcCAtcSA5NTAwMDAgL3N5cy9mcy9jZ3JvdXAvY3B1LGNwdWFjY3QvbWFjaGluZS5zbGljZS9jcHUucnRfcnVudGltZV91cyAyPiAvZGV2L251bGwKICByZXR1cm4gJD8KfQoKaWYgISB2YWxpZGF0ZV9zZXR1cDsgdGhlbgogIGxvZyAiSU5GTzogQXBwbHlpbmcgdGhlIHdvcmthcm91bmQiCiAgZWNobyA5NTAwMDAgPiAvc3lzL2ZzL2Nncm91cC9jcHUsY3B1YWNjdC9jcHUucnRfcnVudGltZV91cyAKICBpZiBbICQ/IC1uZSAwIF07IHRoZW4KICAgIGxvZyAiRVJST1I6IENvdWxkIG5vdCBzZXQgdGhlIHdvcmthcm91bmQiCiAgZWxzZQogICAgbG9nICJTVUNDRVNTOiBBcHBsaWVkIHRoZSB3b3JrYXJvdW5kIgogIGZpCmVsc2UKICBsb2cgIklORk86IFdvcmthcm91bmQgYWxyZWFkeSBpbiBwbGFjZSIKZmkK
        filesystem: root
        mode: 0660
        path: /usr/local/bin/ocp_cpu_rt_workaround.sh
EOF
```

4. Lastly we apply this workaround to the environment
```
oc apply -f ./ocp_cpu_rt_workaround.yaml
```

### Other
Example script to automate desired runtime policy per cgroup ([source](https://lists.freedesktop.org/archives/systemd-devel/2017-July/039353.html)):
```
#!/bin/bash

desired_rt_runtime_us=$1
mygroup=${2:-$(awk -F: '$2 == "cpuacct,cpu" {print $3}' /proc/self/cgroup)}

[[ $desired_rt_runtime_us -gt 0 ]] || exit
[[ $mygroup ]] || exit
[[ $mygroup = / ]] && exit

echo "${0##*/}: setting cpu.rt_runtime_us for $mygroup" >&2

cgpath=
IFS=/ read -ra cgroups <<< "${mygroup:1}"
for cg in "${cgroups[@]}"; do
cgpath="${cgpath}/${cg}"
echo "${0##*/}: $desired_rt_runtime_us ->
/sys/fs/cgroup/cpu,cpuacct${cgpath}" >&2
echo "$desired_rt_runtime_us" >
/sys/fs/cgroup/cpu,cpuacct${cgpath}/cpu.rt_runtime_us
done
```

Updated KCS: [https://access.redhat.com/solutions/6099871](https://access.redhat.com/solutions/6099871)
