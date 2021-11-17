# Debugging Performance Addon Operator for low latency pods (guaranteed QoS and IRQ balancing) 

## Issue
- Other threads scheduled on cores that are meant to be isolated.
- DPDK lost packets due to unwanted interrupts.
- pods not in the "guaranteed" QOS class.

## Environment
Redhat Openshift Container Platform 4.x

# Resolution
If the **Diagnostic Steps** have been followed and therefor the operator confirms the following:
- Nodes where the pods have been scheduled are:
  * Properly labeled
  * `cpuManagerPolicy` is set to `static`
- Pods that require best performance are:
  * Configured to have `guaranteed` QoS containers (reserved the correct amount of resources)
  * Have both annotations in their configuration
  * Are scheduled to the correct labeled nodes

If the pods are still not isolated from disrupting IRQs/threads, we then suggest that a case for Red Hat support be open with the following data sets:
- All outputs from the **Diagnostic Steps** verification section
- Pod name(s) and their configuration yaml files
- [General must-gather of the environment](https://docs.openshift.com/container-platform/4.9/cli_reference/openshift_cli/administrator-cli-commands.html#must-gather)
- [Performance Addon Operator specific must-gather](https://docs.openshift.com/container-platform/4.8/scalability_and_performance/cnf-performance-addon-operator-for-low-latency-nodes.html#cnf-about-gathering-data_cnf-master)
- [sosreport of the node](https://access.redhat.com/solutions/3820762) where the pods are deployed

## Diagnostic Steps
### Cluster Configuration Verification
Based on the [official Openshift documentation](https://docs.openshift.com/container-platform/4.9/scalability_and_performance/using-cpu-manager.html) the cluster needs to utilize CPU Manager in order to "isolate" `guaranteed` QoS pods' CPUs.

The scheduled nodes will require a custom KubeletConfig with `cpuManagerPolicy: static` configured, [this can be configured via the use of a `Performanceprofile`](https://docs.openshift.com/container-platform/4.9/scalability_and_performance/cnf-performance-addon-operator-for-low-latency-nodes.html#cnf-tuning-nodes-for-low-latency-via-performanceprofile_cnf-master).

Example:
```
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpumanager-enabled
spec:
  machineConfigPoolSelector:
    matchLabels:
      custom-kubelet: cpumanager-enabled
  kubeletConfig:
     cpuManagerPolicy: static
     cpuManagerReconcilePeriod: 5s
```

With Openshift Container Platform 4, "isolated" really means "available for isolation":
 - Interrupts, kernel processes, OS/systemd processes will always run on reserved CPUs as configured in CPU Manager (reservedSystemCPUs).
 - Burstable pods will run on reserved CPUs and isolated CPUs **NOT** used by a `guaranteed` QoS pod. This is how [Kubernetes implemented CPU Manager](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/#static-policy-options).
 - Guaranteed pods’ containers will be pinned to a specific set of CPUs from the isolated pool (in other words, available for isolation).

**Note** that for OCP 4:
 - Reserved + isolated CPUs must equal all the CPUs on the server.
 - Reserved CPUs should be large enough to accommodate the kernel and its OS.
 - Guaranteed pod will have the CPUs dedicated to itself after 5 to 10 seconds (configurable) but setting it too low will put higher load on the node.
- Total of allocatable CPUs of a node = capacity - reserved.

### Pod Configuration Verification
Here are the steps to ensure the system is configured correctly for IRQ dynamic load balancing.

Consider a node with 6 CPUs targeted by a 'v2' [Performance Profile](https://github.com/openshift-kni/performance-addon-operators/blob/master/docs/performance_profile.md):
Let's assume the node name is `cnf-worker.demo.lab`.

A profile reserving 2 CPUs for housekeeping can look like this:
```
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: dynamic-irq-profile
spec:
  cpu:
    isolated: 2-5
    reserved: 0-1
  ...
```
1. Ensure you are using a `v2` profile in the apiVersion.
2. Ensure `GloballyDisableIrqLoadBalancing` field is missing or has the value `false`.

The pod below is `guaranteed` QoS and requires 2 exclusive CPUs out of the 6 available CPUs in the node.
```
apiVersion: v1
kind: Pod
metadata:
  name: dynamic-irq-pod
  annotations:
     irq-load-balancing.crio.io: "disable"
     cpu-quota.crio.io: "disable"
spec:
  containers:
  - name: dynamic-irq-pod
    image: "quay.io/openshift-kni/cnf-tests:4.6"
    command: ["sleep", "10h"]
    resources:
      requests:
        cpu: 2
        memory: "200M"
      limits:
        cpu: 2
        memory: "200M"
  nodeSelector:
    node-role.kubernetes.io/worker-cnf: ""
  runtimeClassName: dynamic-irq-profile
```
**Note**: Only disable CPU load balancing when the CPU manager static policy is enabled and for pods with guaranteed QoS that use whole CPUs. Otherwise, disabling CPU load balancing can affect the performance of other containers in the cluster. See above section **Cluster Configuration Verification**.

1. Ensure both annotations exist (`irq-load-balancing.crio.io` and `cpu-quota.crio.io`).
2. Ensure the pod has its `runtimeClassName` as the respective profile name, in this example `dynamic-irq-profile`.
3. Ensure the node selector targets a cnf-worker.

Ensure the pod is running correctly.
```
oc get pod -o wide
NAME              READY   STATUS    RESTARTS   AGE     IP             NODE                  NOMINATED NODE   READINESS GATES
dynamic-irq-pod   1/1     Running   0          5h33m   10.135.1.140   cnf-worker.demo.lab   <none>           <none>
```

1. Ensure status is `Running`.
2. Ensure the pod is scheduled on a cnf-worker node, in our case on the `cnf-worker.demo.lab` node.

Find out the CPUs dynamic-irq-pod runs on.
```
oc exec -it dynamic-irq-pod -- /bin/bash -c "grep Cpus_allowed_list /proc/self/status | awk '{print $2}'"
Cpus_allowed_list:    2-3
```

Ensure the node configuration is applied correctly.
Connect to the `cnf-worker.demo.lab`  node to verify the configuration.
```
oc debug node/ocp47-worker-0.demo.lab
Starting pod/ocp47-worker-0demolab-debug ...
To use host binaries, run `chroot /host`

Pod IP: 192.168.122.99
If you don't see a command prompt, try pressing enter.

sh-4.4#
```

Use the node file system:
```
sh-4.4# chroot /host
sh-4.4#
```

1. Ensure the default system CPU affinity mask does not include the dynamic-irq-pod CPUs, in our case 2,3.
```  
cat /proc/irq/default_smp_affinity
33
```

2. Ensure the system IRQs are not configured to run on the dynamic-irq-pod CPUs
```
find /proc/irq/ -name smp_affinity_list -exec sh -c 'i="$1"; mask=$(cat $i); file=$(echo $i); echo $file: $mask' _ {} \;
/proc/irq/0/smp_affinity_list: 0-5
/proc/irq/1/smp_affinity_list: 5
/proc/irq/2/smp_affinity_list: 0-5
/proc/irq/3/smp_affinity_list: 0-5
/proc/irq/4/smp_affinity_list: 0
/proc/irq/5/smp_affinity_list: 0-5
/proc/irq/6/smp_affinity_list: 0-5
/proc/irq/7/smp_affinity_list: 0-5
/proc/irq/8/smp_affinity_list: 4
/proc/irq/9/smp_affinity_list: 4
/proc/irq/10/smp_affinity_list: 0-5
/proc/irq/11/smp_affinity_list: 0
/proc/irq/12/smp_affinity_list: 1
/proc/irq/13/smp_affinity_list: 0-5
/proc/irq/14/smp_affinity_list: 1
/proc/irq/15/smp_affinity_list: 0
/proc/irq/24/smp_affinity_list: 1
/proc/irq/25/smp_affinity_list: 1
/proc/irq/26/smp_affinity_list: 1
/proc/irq/27/smp_affinity_list: 5
/proc/irq/28/smp_affinity_list: 1
/proc/irq/29/smp_affinity_list: 0
/proc/irq/30/smp_affinity_list: 0-5
```

**Note**: Some IRQ controllers do not support IRQ re-balancing and will always expose all online CPUs as the IRQ mask.
Usually they will effectively run on CPU 0, a hint can be received with:
```
for i in {0,2,3,5,6,7,10,13,30}; do cat /proc/irq/$i/effective_affinity_list; done
0

0
0
0
0
0
0
1
```

More information on [Best practices for avoiding noisy neighbor issues using CPU manager behaves with regards to hyper-threading](https://access.redhat.com/articles/6407791)(SMTAlignment).
