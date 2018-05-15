#!/bin/bash
# Script to gather all deployment logs

echotee() {
  echo $1 | tee -a $file
}

file_create() {
  counter=1
  if [ ! -a $file ] ; then
    touch $file
  else
    file=$file-$counter
    counter=$(echo $counter+1 | bc)
    file_create
  fi
}

file=/tmp/resource-show-$(date +"%F").txt
file_create

stackname=$(openstack stack list -f value -c "Stack Name")
source_file=/home/stack/stackrc

if [ -a $source_file ] ; then
	source $source_file
else
	echo "Source file missing (\"/home/stack/stackrc\")"
	exit 2
fi

echotee "openstack software deployment list"
echotee "====================="
sw=($(openstack software deployment list -f value | awk '/FAILED/ {print $1 " " $3}'))
for ((i=0;i<${#sw[@]};i++)); do
  if [ $((i % 2)) -eq 0 ]; then 
    openstack software deployment show ${sw[${i}]} | tee -a $file
  else
    openstack server show ${sw[${i}]} | tee -a $file
  fi
done

echotee "openstack stack resource list -n5 $stackname"
echotee "====================="
openstack stack resource list -n5 $stackname | tee -a $file

openstack stack resource list -n5 $stackname -c stack_name -c resource_name -f value \
| awk '{print $2 " " $1}' | while read line; do
  echotee "===========";
  echotee $line;
  echotee "openstack stack resource show $line"
  echotee "===================="; 
  openstack stack resource show $line | tee -a $file
done

echo -e "\n\nOutput written to file $file"
echo "Please send and attach the file to the current open case."
#sosreport KCS - https://access.redhat.com/solutions/3592

