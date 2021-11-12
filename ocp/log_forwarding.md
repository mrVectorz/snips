Testing different log forwarding configurations on Openshift's logging-operator

- Validate if we can configure a pipeline not to forward logs to the default ES
This is doable by simply overriding the ClusterLogForwarder instance ressource.
Example using a local ES cluster, no logs will go to the default ES that comes
 with the operator.
```
apiVersion: "logging.openshift.io/v1"
kind: ClusterLogForwarder
metadata:
  name: instance 
  namespace: openshift-logging 
spec:
  outputs:
   - name: elasticsearch-insecure 
     type: "elasticsearch" 
     url: http://elasticsearch-svc-log-test.apps.ipi-cluster.example.com:9200 
  pipelines:
   - name: infra-logs 
     inputRefs: 
     - infrastructure
     outputRefs:
     - elasticsearch-insecure 
     parse: json 
```

To confirm this we can run the following command against one of the fluentd pods: 
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

Notice that the only defined `host` are the newly added.

- Validate if only certain application logs can be forwarded to non-default endpoint
This require setting this operator in an unManaged state (which is also unsupported)
First edit the ClusterLogging instance ressource:
`oc edit -n openshift-logging ClusterLogging instance`
Setting spec.managementState to "Unmanaged".
```
[root@openshift-jumpserver-0 ~]# oc get -n openshift-logging ClusterLogging instance -o yaml | grep managementState:
  managementState: Unmanaged
```

I suggest dumping the default `fluentd.conf` file prior to making changes in
order to have a backup.
`oc get -n openshift-logging cm fluentd -o json | jq -r '.data."fluent.conf"' > fluentd.conf.bak`

We can now modify the fluentd configuration with anything we like that fluentd allows[0]:
`oc edit -n openshift-logging cm fluentd`
Note: that this method will have a bunch of newline characters

In the case where the oprator wishes to split up application logs they will be
required to edit the section where logs get labelled with APPLICATION:
```
  <match **_default_** **_kube-*_** **_openshift-*_** **_openshift_** journal.** system.var.log**>
    @type relabel
    @label @_INFRASTRUCTURE
  </match>
  <match kubernetes.**>
    @type relabel
    @label @_APPLICATION
  </match>
  <match linux-audit.log** k8s-audit.log** openshift-audit.log** ovn-audit.log**>
    @type null
  </match>
```
Or/and the section where further relabeling is done (this is my recommendation):
```
# Relabel specific sources (e.g. logs.apps) to multiple pipelines
<label @_APPLICATION>
  <filter **>
    @type record_modifier
    <record>
      log_type application
    </record>
  </filter>
  <match **>
    @type copy
    <store>
      @type relabel
      @label @APP_LOGS
    </store>
  </match>
</label>

(...truncated...)

# Relabel specific pipelines to multiple, outputs (e.g. ES, kafka stores)
<label @APP_LOGS>
  <filter **>
    @type parser
    key_name message
    reserve_data yes
    hash_value_field structured
    <parse>
      @type json
    json_parser oj
    </parse>
  </filter>
  <match **>
    @type copy
    <store>
      @type relabel
      @label @ELASTICSEARCH_SECURE_EX
    </store>
  </match>
</label>
```

In the above case all application logs go to the ELASTICSEARCH_SECURE_EX labeled
store, a match could be added above and relabel certain application logs and new
store could be added matching that label. Any new applications would be sent
 to the default.

[0] - [Official fluentd documentation](https://docs.fluentd.org/configuration/config-file)

- Provide example for mTLS configuration
All sensitive authentication information is provided via a kubernetes Secret object. A Secret is a key:value map, common keys are described here. Some output types support additional specialized keys, documented with the output-specific configuration field. All secret keys are optional, enable the security features you want by setting the relevant keys.

Using a TLS URL (https://... or ssl://...) without any secret enables basic TLS: client authenticates server using system default certificate authority.
Additional TLS features are enabled by including a Secret and setting the following optional fields:
- `tls.crt`: (string) File name containing a client certificate. Enables mutual authentication. Requires `tls.key`.
- `tls.key`: (string) File name containing the private key to unlock the client certificate. Requires `tls.crt`
- `passphrase`: (string) Passphrase to decode an encoded TLS private key. Requires `tls.key`.
- `ca-bundle.crt`: (string) File name of a custom CA for server authentication.

Username and Password
- `username`: (string) Authentication user name. Requires `password`.
- `password`: (string) Authentication password. Requires `username`.

Simple Authentication Security Layer (SASL)
- `sasl.enable`: (boolean) Explicitly enable or disable SASL. If missing, SASL is automatically enabled when any of the other `sasl.` keys are set.
- `sasl.mechanisms`: (array) List of allowed SASL mechanism names. If missing or empty, the system defaults are used.
- `sasl.allow-insecure`: (boolean) Allow mechanisms that send clear-text passwords. Default false.

The bellow ClusterLogForwarder instance resource worked on 4.8:
```
apiVersion: "logging.openshift.io/v1"
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  outputs:
   - name: elasticsearch-secure-ex
     type: "elasticsearch"
     url: https://elasticsearch-svc-log-test.apps.ipi-cluster.example.com:9200
     secret:
        name: es-secret
  pipelines:
   - name: application-logs
     inputRefs:
     - application
     - audit
     outputRefs:
     - elasticsearch-secure-ex
     - default
     parse: json
   - name: infrastructure-audit-logs
     inputRefs:
     - infrastructure
     outputRefs:
     - elasticsearch-secure-ex
     labels:
       logs: "audit-infra"
```
Create the secret within the `openshift-logging` namespace. Example:
```
kind: Secret
- tls.crt: (BASE64 cert)
- tls.key: (BASE64 key)
```

## References
Some links that have been useful when looking into these topics

- https://www.ibm.com/docs/en/cloud-paks/cp-applications/4.3?topic=SSCSJL_4.3.x/guides/guide-app-logging-ocp-4.2/app-logging-ocp-4.2.html
- https://github.com/openshift/cluster-logging-operator/blob/master/docs/unmanaged_configuration.md
- https://docs.openshift.com/container-platform/4.9/logging/cluster-logging-external.html
- https://docs.fluentd.org/configuration/config-file
- https://github.com/openshift/cluster-logging-operator/blob/master/scripts/cert_generation.sh
