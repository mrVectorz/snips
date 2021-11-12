```
[root@openshift-jumpserver-0 ~]# oc version
Client Version: 4.8.18
Server Version: 4.8.18
Kubernetes Version: v1.21.1+6438632
```

- default.fluentd.conf
This file was taking before create the `instance` ressource.

- cert_signer.sh
WIP sign your ES cert with the one our operator uses.

Copying the certificate from the operator pod
`oc cp -n openshift-logging cluster-logging-operator-5c8b9bb7bd-6djp4:/tmp/ocp-clo/ ./`

Validating the applied changes from `instance-no-sec.yaml`
```
[root@openshift-jumpserver-0 ~]# oc exec -ti -n openshift-logging fluentd-qp5xw -c fluentd -- grep host /etc/fluent/fluent.conf
    hostname ${hostname}
    hostname ${hostname}
    hostname ${hostname}
        hostname ${hostname}
        hostname ${hostname}
    default_keep_fields CEE,time,@timestamp,aushape,ci_job,collectd,docker,fedora-ci,file,foreman,geoip,hostname,ipaddr4,ipaddr6,kubernetes,level,message,namespace_name,namespace_uuid,offset,openstack,ovirt,pid,pipeline_metadata,rsyslog,service,systemd,tags,testcase,tlog,viaq_msg_id
      remove_keys host,pid,ident
      host elasticsearch-svc-log-test.apps.ipi-cluster.example.com
      host elasticsearch-svc-log-test.apps.ipi-cluster.example.com
```
