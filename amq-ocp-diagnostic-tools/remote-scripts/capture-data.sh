#!/bin/sh
FOLDER=$1
PID_KEYWORD=$2

#PID=$(ps -ef | grep $PID_KEYWORD | grep -v grep | awk '{print $2}')
#PID=$(ps -ef | grep spring-boot | grep -v grep | awk '{print $2}')
#PID=$(ps -ef | grep java | grep $PID_KEYWORD | awk '{print $2}')
PID=$PID_KEYWORD
if [ -z "$PID" ]
then
  echo "***** ERROR ****"
  echo "Invalid PID returned. Please check $PID_KEYWORD and ensure application is currently running."
  echo
else
  echo " * Gathering data for Process id=$PID  "
fi
echo

echo "POD: Capturing sequence of thread dumps "
echo "---------------------------------------"
/home/jboss/$FOLDER/remote-scripts/ocp_high_cpu_linux_jstack.sh $FOLDER $PID
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Error capturuing thread dumps for pid=$PID."
  echo "This run of the script will not gather all the required data."
else
  echo "Done."
fi
echo

echo "POD: Taking heap dump"
echo "---------------------------------------"
jmap -dump:live,format=b,file=$FOLDER/spring-boot-dump.hprof $PID
#/usr/lib/jvm/java-1.8.0-openjdk/bin/jmap -J-d64 -dump:format=b,file=$FOLDER/heap.hprof $PID
#jcmd $PID GC.heap_dump $FOLDER/heap.hprof
if [ $? != 0 ]
then
  echo "***** ERROR ****"
  echo "Error taking JVM heap dump of the Spring Boot container  with pid $processId."
  echo "This run of the script will not gather all the required data."
else
  echo "Done."
fi
echo

#echo "Capture SOS Report "
#sosreport --batch --ticket-number=TBD --name=customer
