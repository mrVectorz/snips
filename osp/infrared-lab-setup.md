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
  echo ". $(pwd)/etc/bash_completion.d/infrared" >> ${.venv}/bin/activate
  source ~/.venv/bin/activate
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
infrared virsh --host-address $YOURLABSERVER --host-key ~/.ssh/key_sbr_lab --topology-nodes undercloud:1,controller:3,compute:1 -e override.controller.cpu=4 -e override.controller.memory=8092 -e override.undercloud.disks.disk1.size=150G -e override.compute.memory=12288 --image-url url_to_download_/7.5/.../rhel-guest-image....x86_64.qcow2
```

Install the undercloud :

```shell
infrared tripleo-undercloud --version 13 --images-task=rpm --build ga
```

Once this is deployment, depending on the size of you lab server (typical is 64Gb), I recommend to lower the worker counts to 1 to limit memory usage:
https://github.com/mrVectorz/snips/blob/master/osp/low_memory_uc.sh

Launch a partial deployment, it will only register, introspect and tag nodes :

```shell
infrared tripleo-overcloud --deployment-files virt --version 13 --introspect yes --tag yes --deploy no --post no
```

Alternatively, deploy the OC aswell:

```shell
infrared tripleo-overcloud --deployment-files virt --version 13 --introspect yes --tag yes --deploy yes --post yes --containers yes
```
