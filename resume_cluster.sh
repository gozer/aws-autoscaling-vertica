#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Returns a list of public / private IP addresses for each node in the cluster

. ./autoscaling_vars.sh

echo "Start all stopped node instances in cluster"
instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name Name=instance-state-code,Values=80 --query "Reservations[*].Instances[*].InstanceId")

if [ -z "$instanceIds" ]; then
   echo "There are no stopped instances with cluster name [$autoscaling_group_name]"
else
   echo "Starting instances [$instanceIds]"
   aws ec2 start-instances --instance-id $instanceIds
fi


instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].InstanceId")
echo "Wait for all cluster instances to be in running state"
for instId in $instanceIds
do
   while [ 1 ]; do
      aws --output=text ec2 describe-instances --instance-ids $instId --query "Reservations[*].Instances[*].State.Name" | grep running
      [ $? -eq 0 ] && break
      echo "Waiting another 60s for instance [$instId] to be in running state"
      sleep 60
   done
   echo "Instance [$instId] running."
done

echo "Get public IP address of first instance"
publicIp=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].PublicIpAddress" | head -1 | cut -f1)

# wait till instance is accepting connections
while [ 1 ]; do
   ssh -i $pem_file -o "StrictHostKeyChecking no" dbadmin@$publicIp echo "test ssh connection" > /dev/null
   [ $? -eq 0 ] && break
   echo "Waiting another 60s for instance to accept connections, and try again"
   sleep 60
done
echo "Start database [$database_name] on node [$publicIp]"
ssh -i $pem_file -o "StrictHostKeyChecking no" dbadmin@$publicIp admintools -t start_db -d $database_name 

echo "Resume autoscaling group processing"
aws autoscaling resume-processes --auto-scaling-group-name $autoscaling_group_name

echo "Database cluster ($autoscaling_group_name) resumed. Check cluster_ip_addresses.sh for changed public IP addresses."
