# Debugging gcore for Openshift

Delve install requirements:
- dnf install gdb gcc git go -y

If you require newer go release:
```
url='https://go.dev/dl/'
version=$(curl -L -s $url | awk '/downloadBox.*href.*go[0-9]\.[0-9]+\.[0-9]\.linux\-amd64/ {print gensub(/.*"\/dl\/(.+tar\.gz)".*/, "\\1", "g", $NF)}')
curl -L ${url}${version} -o ${version}
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.18.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version
```

## Some Advantages over plain gbd
- goroutine aware, threads have fixed memory allocation where goroutines are "dynamic"
- slices

## Getting a gcore
To generate a coredump without interrupting the process.
```
gcore $pid
```
- [kcs link](https://access.redhat.com/solutions/9952)

On Openshift we have to do this via the toolbox.
```
toolbox
dnf install gdb -y
# Example
pid=$(ps fauxxxww | awk '/\/usr\/bin\/crio/ {print $2; print $0 > "/dev/stderr"}')
# Having validated that the pid is accurate
gcore -o /host/vat/tmp/crio.gcore $pid
```

From there we can extract it from the node.
```
# still on the node, we compress it if it is a large dump
gzip /host/vat/tmp/crio.gcore.$pid
# on the remote host
oc debug node/$NODE -- cat /host/vat/tmp/crio.gcore.$pid > /host/vat/tmp/crio.gcore.$pid
```
Note: if unsure what version of the dumped process make sure to grab that bin file too

## Usage
To inspect a core file:
```
dlv core <executable> <core>
# Example
dlv core main example.3616154
```

Quick command examples
```
# backtrace
bt
# list all goroutines
goroutines
# inspect goroutine
goroutine 8
bt
# inspect frame from that bt
frame 1
# dump specific channels
print msgQueue
```

## References
- [Delve documentation](https://github.com/go-delve/delve/blob/master/Documentation/cli/README.md)
- [GopherCon presentation by maintainer](https://www.youtube.com/watch?v=IKnTr7Zms1k)
