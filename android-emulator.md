# Android
Running virtualized android on Fedora 31

### Android-x86

Download the latest [ISO](https://www.android-x86.org/download.html) image and then start a guest.
~~~
virt-install   --name test-android   --memory 8192   --vcpus 4 --accelerate  --soundhw es1370 --disk /media/images/android.qcow2,device=disk,size=20,sparse=yes,cache=none,format=qcow2,bus=virtio  --vnc --cdrom ~/Downloads/android-x86_64-9.0-r2.iso
## OR
virt-install   --name test-android   --memory 8192   --vcpus 4 --accelerate --disk /media/images/android.qcow2,device=disk,size=10,sparse=yes,cache=none,format=qcow2,bus=virtio  --qemu-commandline '-audiodev pa,id=pa1,server=192.168.0.148' --vnc --cdrom /media/images/android-x86_64-9.0-r2.iso

~~~

`virt-viewer` will be required to complete the installation process.


