#!/bin/sh
#
# Takes the JBoss PID as an argument. 
#
# Captures cpu by light weight thread and thread dumps a specified number of
# times and INTERVAL. Thread dumps are retrieved using jstack and are placed in 
# high-cpu-tdump.out
#
# Usage: sh ./high_cpu_linux_jstack.sh <JBOSS_PID>
#

FOLDER=$1
PID=$2
echo $PID
export JAVA_HOME=/usr/lib/jvm/jre
export PATH=$JAVA_HOME/bin:$PATH

# Number of times to collect data.
LOOP=10
# Interval in seconds between data points.
INTERVAL=10

for ((i=1; i <= $LOOP; i++))
do
   _now=$(date)
   echo "${_now}" >>$FOLDER/high-cpu.out
   echo top -b -n 1 -H -p $PID >>$FOLDER/high-cpu.out
   top -b -n 1 -H -p $PID >>$FOLDER/high-cpu.out
   echo "${_now}" >> $FOLDER/high-cpu-tdump.out
   jstack -l $PID >>$FOLDER/high-cpu-tdump.out
   echo "thread dump #" $i
   if [ $i -lt $LOOP ]; then
      echo "Sleeping..."
      sleep $INTERVAL
   fi
done
