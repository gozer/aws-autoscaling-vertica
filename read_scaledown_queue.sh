#!/bin/bash
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run from cron schedule - checks for lifecycle hook termination messages on the SQS queue, and initiates cluster scaledown

. /home/dbadmin/.bashrc
PATH=/usr/local/bin:/opt/vertica/bin:${PATH}
autoscaleDir=/home/dbadmin/autoscale
. $autoscaleDir/autoscaling_vars.sh
time=$( date +"%Y-%m-%d %H:%M:%S")

# in non terminal mode, redirect stdout and stderr to logfile
if [ ! -t 0 ]; then exec &> >(ts >> $autoscaleDir/read_scaledown_queue.log) 2>&1; fi

# Get this node's IP
myIp=$(hostname -I | awk '{print $NF}')

# Read and parse all pending messages, one at a time
i=0
while [ 1 ]; do
   # read queue
   # (a scaleDown may involve multiple instances / messages - we want to read them all)
   msg=$(aws --output=json sqs receive-message --wait-time-seconds 20 --queue-url $scaleDown_url)
   [ -z "$msg" ] && break  # no more messages waiting
   msgBody=$(echo "$msg" | python -c 'import sys, json; print json.load(sys.stdin)["Messages"][0]["Body"]')
   msgHandle=$(echo "$msg" | python -c 'import sys, json; print json.load(sys.stdin)["Messages"][0]["ReceiptHandle"]')
   lifecycleTransition=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["LifecycleActionToken"]')
   if [ "$lifecycleTransition" == "autoscaling:EC2_INSTANCE_TERMINATING" ] ; then
      echo "ScaleDown SQS Message Received - $msgBody"
      lifecycleActionToken=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["LifecycleActionToken"]')
      autoscalingGroupName=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["AutoScalingGroupName"]')
      eC2InstanceId=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["EC2InstanceId"]')
      privateIps=$(aws --output=text ec2 describe-instances --instance-id $eC2InstanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" | perl -ne "chomp; print join(',', map { qq/'\$_'/ } reverse split(/\s+/,$_))")
      if [ ! -z "$privateIps" ]; then
         publicIp=$(aws --output=text ec2 describe-instances --instance-id $eC2InstanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].Association.PublicIp")
         # in case instance has multiple private IPs, retrieve the one use by vertica in nodes table
         privateIp=$(vsql -qAt -c "select node_address from nodes where node_address in ($privateIps)")
         node_name=$(vsql -qAt -c "select node_name from nodes where node_address in ($privateIps)")
         # Add each terminating instance to the autoscale.terminations table
         echo "$myIp|$time|$eC2InstanceId|$privateIp|$publicIp|$lifecycleActionToken|$autoscalingGroupName|COLLATING INSTANCES|1" | vsql -c "COPY autoscale.terminations (queued_by_node, start_time, ec2_instanceid, node_address, node_public_address, lifecycle_action_token, lifecycle_action_asg, status, is_running) FROM STDIN" 
         if [ $? -ne 0 ]; then 
            echo Unable to add to autoscale.terminations - exiting without deleting message
            exit 1
         fi
         echo "Node [$node_name / $privateIp] queued for termination"
         ((i=i+1))
      else
         echo "No Private IP found for [$eC2InstanceId] in autoscale.launches. Perhaps a rogue (old) message? Skipping"
      fi
   else
      echo "Skipping unimportant message: $lifecycleTransition"
      echo "$msg" | jq .
   fi
   aws sqs delete-message --queue-url $scaleDown_url --receipt-handle $msgHandle
   echo "Message deleted from SQS queue"
done

numMessages=$i
if [ $numMessages -eq 0 ]; then
   # echo "No pending ScaleDown messages - exiting"
   exit 0
else
   echo "ScaleDown: $numMessages nodes queued for termination"
fi

# make sure termination list has settled - ie that nodes aren't still being added
lastCount=0
thisCount=$(vsql -qAt -c "select count(*) from autoscale.terminations where is_running")
while [ $lastCount -ne $thisCount ]; do
   echo Ensure queued node count is stable - $thisCount nodes. Sleep 30s.
   lastCount=$thisCount
   sleep 30
   thisCount=$(vsql -qAt -c "select count(*) from autoscale.terminations where is_running")
done

# Remove nodes on an active DB node that is NOT currently queued for termination
connectTo=$(vsql -qAt -c "select node_address from nodes where node_state='UP' AND node_name NOT IN (select node_address from autoscale.terminations where is_running) ORDER BY node_name LIMIT 1")
if [ -z "$connectTo" ]; then
   echo "All nodes queued for deletion! Connect locally [$myIp]"
   connectTo=$myIp
fi
echo "connect to $connectTo and run remove_nodes()." 
vsql -h $connectTo -c "select autoscale.remove_nodes()"

echo Done! [`date`]
exit 0
