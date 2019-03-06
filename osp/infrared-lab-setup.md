## infrared installation

On your workstation, install the required dependencies :

```shell
sudo dnf install git gcc libffi-devel openssl-devel python-virtualenv libselinux-python redhat-rpm-config -y
```
Installing infrared :

```shell
  git clone https://github.com/redhat-openstack/infrared.git
  cd infrared
  virtualenv .venv
  source .venv/bin/activate
  pip install --upgrade pip
  pip install --upgrade setuptools
  pip install .
  echo ". $(pwd)/etc/bash_completion.d/infrared" >> ${VIRTUAL_ENV}/bin/activate
```

## SSH key for the lab

infrared use ssh for the deployment and needs an ssh key.

NOTE : You can use your already existing ssh key but be sure to replace the relevant argument when running infrared commands.

To generate a ssh key on your wks:

```shell
ssh-keygen -f ~/.ssh/key_sbr_lab
```

Copy the key to your lab server :

```shell
ssh-copy-id -i ~/.ssh/key_sbr_lab.pub root@$YOURLABSERVER
```

## OSP 13 full deployment

Create a workspace (if it does not exist yet) :

```shell
infrared workspace create $YOURLABSERVER
```

Cleanup the system :

```shell
infrared virsh --host-address $YOURLABSERVER --host-key ~/.ssh/key_sbr_lab --cleanup yes
```

Prepare the environment :

```shell
infrared virsh --host-address $YOURLABSERVER --host-key ~/.ssh/key_sbr_lab --topology-nodes undercloud:1,controller:3,compute:1 -e override.controller.cpu=6 -e override.controller.memory=12288 -e override.undercloud.disks.disk1.size=200G --image-url url_to_download_/7.5/.../rhel-guest-image....x86_64.qcow2
```

Install the undercloud :

You have to set the container registry namespace to the version required, as default has now changed to rhosp14
```shell
infrared tripleo-undercloud --version 13 --registry-namespace rhosp13 --images-task=rpm --build ga
```

Once this is deployment, depending on the size of you lab server (typical is 64Gb), I recommend to lower the worker counts to 1 to limit memory usage:
https://github.com/mrVectorz/snips/blob/master/osp/low_memory_uc.sh

Backup the UC node :
```shell
tripleo-undercloud --snapshot-backup yes
```

Launch a partial deployment, it will only register, introspect and tag nodes :

```shell
infrared tripleo-overcloud --deployment-files virt --version 13 --introspect yes --tagging yes --deploy no
```

Alternatively, deploy the OC aswell:

```shell
infrared tripleo-overcloud --deployment-files virt --version 13 --introspect yes --tag yes --deploy yes --containers yes
```

Once done you can use the cloud-config plugin post creation to create networks and stuff:

```shell
infrared cloud-config -vv \ 
-o cloud-config.yml \ 
--deployment-files virt \ 
--tasks create_external_network,forward_overcloud_dashboard,network_time,tempest_deployer_input
```

## Additional Recommendations

- Lowering the UC node's memory footprint
Once the UC node deployed, depending on the size of you lab server (typical is 64Gb), it could be useful to lower the worker counts to 1 to limit memory usage.
Just run the bellow script as root:
https://github.com/mrVectorz/snips/blob/master/osp/low_memory_uc.sh

- Lowering the memory usage on the controllers
Just as before, in a lab/PoC environment, operators do not need all the workers configured.
To lower the counts on the controller nodes simply include the tripleo environment template:
/usr/share/openstack-tripleo-heat-templates/environments/low-memory-usage.yaml

To do this in your OC deployment via IR create a template locally:
example: infra_low_mem.yaml
```shell
tripleo_heat_templates:
    - /usr/share/openstack-tripleo-heat-templates/environments/low-memory-usage.yaml
```

Once saved simply include it in your tripleo-overcloud command. Example:
```shell
infrared tripleo-overcloud --deployment-files virt --version 13 --introspect yes --tag yes --deploy yes --containers yes --overcloud-templates infra_low_mem.yaml
```
This will add it to the OC deployment command as an environment file.

