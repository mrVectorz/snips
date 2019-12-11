# Java Container Setup
Creating and using a container to execute older versions of java.
Example use case is with old iDrac viewer.jnlp files that require unsecure cipher suite

## Setup
Need to pull and create an older version of fedora which has in it's repos older version of java

- Building the container with `buildah` with the following Dockerfile

~~~
FROM fedora:26

RUN yum -y install xorg-x11-apps
RUN yum -y install icedtea-web

CMD [ "/usr/bin/xclock" ]
[mmethot@localhost tmp]$ cat Dockerfile 
FROM fedora:26

RUN yum -y install xorg-x11-apps
RUN yum -y install icedtea-web

CMD [ "/usr/bin/xclock" ]
~~~

Note that the xclock command is only used to validate if the process works.

- building the image with `buildah bud -t xclockimage .`
- selinux may give you gripes, in the past `setenforce 0` needed to be applied to avoid some fuss

## Running the javaws applet
First download a new viewer.jnlp (iDrac example) file from the BMC, once done we start the container with the following:
~~~
podman run -ti -e DISPLAY --privileged --rm -v /run/user/${UID}/gdm/Xauthority:/run/user/0/gdm/Xauthority:Z -v /home/${USER}/Downloads/viewer.jnlp:/root/viewer.jnlp:Z --net=host localhost/xclockimage javaws.itweb /root/viewer.jnlp
~~~

Parameters:
- `-e DISPLAY` is the env variable to forward a display
- `--piveledged` is required to avoid selinux denying access to `java` to open a `unix_stream_socket`
- `-v ...Xauthority` binds a volume (file) to the container, this file is the display cookie
- `--net=host` is the easiest path to simply using host's network to connect to the iDrac host
- `localhost/xclockimage` is the repo/imageName
- `javaws.itweb /root/viewer.jnlp` is the command to run

## Troubleshooting
1. **selinux** should be checked, test setting it to Permissive
2. stale session token in the `viewer.jnlp` file. The ERROR should be something like "Login failed with an access denied error." - Simply relogin to the BMC and redownload a new console file.

