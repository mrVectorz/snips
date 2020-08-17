#!/bin/sh
#Required parameters:
#   PDO Name is required. To identify the name of the pod, please run:
#      oc get pod
# This will return a list of all of the running pods.

if [ -z "$1" ]
then
	echo
	echo "*** ERROR - POD name is required. To identify the name of the pod, please run 'oc get pod' to list running pods"
	exit
fi

echo
if [ "$1" == "--help" ]
then
	echo
	echo "     - This script captures a series of thread dumps, top output and a heap dump"
	echo
	echo "   * Syntax "
	echo "     - ./gather-ocp-diagnostic-data <POD NAME> <REMOTE PID KEYWORD> "
	echo
	echo "     - <POD NAME> = pod where the command should be exuctued. This is a reuired paramater. "
	echo "     - <REMOTE PID KEYWORD> = keyword in the process ID of application running on the pod. Optional and defaults to 'spring-boot' "
	echo
	echo "       You may use the script against any Java application by passing in a a key word within the process id on the remote pod. "
	echo "       For example, a Fuse Integration Service application looks like: "
	echo "        ps -ef |grep spring-boot"
	echo         "jboss        1     0  0 Mar19 ?        00:07:06 java -javaagent:/opt/jolokia/jolokia.jar=config=/opt/jolokia/etc/jolokia.properties -XX:ParallelGCThreads=1 -XX:ConcGCThreads=1 -Djava.util.concurrent.ForkJoinPool.common.parallelism=1 -cp . -jar /deployments/fis-spring-boot-1.0-SNAPSHOT.jar"
	echo
	echo  "      The script will use the "spring-boot" as a keyword to identify the process ID to execute the jstack hand jmap commands."
	echo "       You may override the keyword as the second parameter, i.e. ./gather-ocp-diagnostic-data  fis-spring-boot-2-mwk53 my-java-app to capture data any java application"
	echo
	echo "  * Example Usage "
	echo "     ./gather-ocp-diagnostic-data  fis-spring-boot-2-mwk53 "
	echo "     ./gather-ocp-diagnostic-data  fis-spring-boot-2-mwk53 my-java-app"
	echo "     ./gather-ocp-diagnostic-data --help"
	echo
	exit
fi


POD=$1
echo
if [ -z "$2" ]
then
    PID_KEYWORD="spring-boot"
else
    PID_KEYWORD=$2
fi
echo

OUTPUT_SEPERATOR="---------------------------------------"
FOLDER=diagnostics-`date +%Y-%m-%d--%H-%M-%S`

echo "LOCAL: Creating $FOLDER"
echo $OUTPUT_SEPERATOR
mkdir $FOLDER
if [ $? != 0 -a -d $FOLDER ]
then
  echo "***** ERROR ****"
  echo "Error creating local folder $FOLDER!"
  echo "Please review the script as data will not be downloaded appropriately!!"
else
  echo " * Created folder $FOLDER."
fi
echo

echo "LOCAL: Copying scripts to remote pod $POD"
echo $OUTPUT_SEPERATOR
oc rsync ./remote-scripts $POD:/home/jboss/$FOLDER
echo
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Unable to copy scripts to the remote pod. "
  echo "This run of the script will not gather all the required data."
else
  echo " * Scripts copied to $POD"
fi
echo


echo "LOCAL: Executing capture-data.sh on remote pod '$POD' for process id keyword '$PID_KEYWORD'"
echo $OUTPUT_SEPERATOR
oc exec $POD /home/jboss/$FOLDER/remote-scripts/capture-data.sh $FOLDER $PID_KEYWORD
echo
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Error during remote execution of capture-data.sh. "
  echo "This run of the script will not gather all the required data."
else
  echo " * Remote execution complete."
fi
echo

echo "LOCAL: Copying data captured from the remote pod to local $FOLDER"
echo $OUTPUT_SEPERATOR
oc rsync $POD:/home/jboss/$FOLDER .
echo
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Unable to download data from the remote pod. "
  echo "This run of the script will not gather all the required data."
else
  echo " * Remote copy completed. Deleting $FOLDER on $POD. "
  echo " * Removing $FOLDER from $POD."
  oc exec $POD /home/jboss/$FOLDER/remote-scripts/clean.sh $FOLDER
   if [ $? != 0 ]
   then
      echo "***** ERROR ****"
      echo "Error unable to remove $FOLDER on $POD. "
      echo "Files may be left from the scripts run on the remote pod. Please use oc rsh to remove them. ."
    else
      echo " * Remove $FOLDER removed."
    fi
  fi
echo
echo "Downloading application log file"
echo $OUTPUT_SEPERATOR
oc rsync $POD:/opt/amq/data/activemq.log $FOLDER
oc rsync $POD:/opt/amq/data/audit.log $FOLDER
#oc logs --since-time="2015-11-27T09:54:10Z" --timestamps=true  $f > $FOLDER/application.log
  echo
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Failed to download application logs."
else
  echo " * Application logs downloaded."
fi
echo

echo "LOCAL: Compressing local $FOLDER"
echo $OUTPUT_SEPERATOR
tar cvzf $FOLDER.tgz $FOLDER
echo

if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Failed to tar up folder $FOLDER. Please manually tar up and attach to support case."
else
  echo " * Created $PWD/$FOLDER.tgz. Please attach to support case."
fi
echo

echo "LOCAL: Remove local $FOLDER"
echo $OUTPUT_SEPERATOR
rm -rf $FOLDER
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Failed to remove local folder $FOLDER. Please manually remove if desired."
else
  echo " * Local $FOLDER removed".
fi
echo
