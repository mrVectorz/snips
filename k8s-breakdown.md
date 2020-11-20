# Kubernetes Breakdown
Overview (TLDR) of [k8s official concept documentation](https://kubernetes.io/docs/concepts/).

### Index
1. [Kubernetes API](#kubernetes-api)
2. [Nodes](#nodes)
3. [Controllers](#controllers)
4. [Etcd](#etcd)


## Kubernetes API
Everything, ie all logic, goes through the [kube API](https://kubernetes.io/docs/concepts/overview/kubernetes-api/).
- code base: [https://github.com/kubernetes/kubernetes/tree/master/staging/src/k8s.io/api](https://github.com/kubernetes/kubernetes/tree/master/staging/src/k8s.io/api)

The API itself can be broken down in many "endpoints", which are different ressources. There are default/core ressources and then custom ones which can be created by operators.
A short list of the basic resource types APIs
- Workload
	Workloads resources are responsible for managing and running your containers on the cluster. Containers are created by Controllers through Pods. Pods run Containers and provide environmental dependencies such as shared or persistent storage Volumes and Configuration or Secret data injected into the container.
  Examples: Deployments, StatefulSets, Jobs

- Service
	Service API resources are responsible for stitching your workloads together into an accessible Loadbalanced Service. By default, Workloads are only accessible within the cluster, and they must be exposed externally using a either a *LoadBalancer* or *NodePort* Service. For development, internally accessible Workloads can be accessed via proxy through the api master using the kubectl proxy command.
	Examples: Services, Ingress

- Config and Storage
	Config and Storage resources are responsible for injecting data into your applications and persisting data externally to your container.
	Examples: ConfigMaps, Secrets, Volumes

- Metadata
	Metadata resources are responsible for configuring behavior of your other Resources within the Cluster.
	Examples: HorizontalPodAutoscaler (replicaCount Scaling), PodDisruptionBudget, Event

- Cluster
	Cluster resources are responsible for defining configuration of the cluster itself, and are generally only used by cluster operators.
	Example: Node, Namespace, ServiceAccount


## Nodes
Everything gets done on them, k8s places containers (Clear Containers/Kata/tiny vms) in pods that run on nodes.
Each node has to have at the minumun kubelet, a container runtime (cri-o), and the kube-proxy.

Nodes can be added via self registry or manually.

A critical component of the control plane is the **Node Controller**.
- Assigns a CIDR block to the node when it is registered (if enabled)
- Keeps the list of available machines (compares health).
- Healthchecks (NodeReady and NodeStatus) monitors node availability via heartbeats.

Note: kubelet is responsible for creating and updating the NodeStatus and a Lease object (runs the healthbearts -ish)


## Controllers
Basically fancy objects. Continuously looping to remain/keep their desired state.

There are many core controllers and a bunch custom controllers, you can easily [create your own](https://kubernetes.io/docs/concepts/extend-kubernetes/extend-cluster/#extension-patterns).
The built-in controllers manage state by interacting with the cluster API server. Also, core controllers run within the kube-controller-manager.

Examples of core controllers:
- [Deployment controller](https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/deployment/deployment_controller.go)
- [Job controller](https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/job/job_controller.go)
- [Daemon controller](https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/daemon/daemon_controller.go)

[More info on controller](https://kubernetes.io/docs/concepts/architecture/controller/)


## Etcd
Simple key-value store, easily ran in clusters (uses the same algo as OVN for consistency: [Raft](https://raft.github.io/raft.pdf)).
This is used as the backend for config and state storage of your k8s env.

You can poke at it some more to see how things are stored and the clusters config via `etcdctl` command or via the RESTful API.
Short Example:
```
# set the key and value
curl http://192.168.1.171:2379/v2/keys/testmessage -XPUT -d value="Nothing Burger"
# retrieve
etcdctl get testmessage
```

[More info](https://etcd.io/docs/v3.4.0/learning/api/)
