#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Returns a list of public / private IP addresses for each node in the cluster

. ./autoscaling_vars.sh

echo "Suspend autoscaling group processing"
aws autoscaling suspend-processes --auto-scaling-group-name $autoscaling_group_name

echo "Get public IP address of first instance"
publicIp=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].PublicIpAddress" | head -1 | cut -f 1)

echo "Stop the database [$database_name] from node [$publicIp]"
ssh -i $pem_file -o "StrictHostKeyChecking no" dbadmin@$publicIp admintools -t stop_db -d $database_name 

echo "Stop all node instances in cluster"
instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name Name=instance-state-code,Values=16 --query "Reservations[*].Instances[*].InstanceId")

aws ec2 stop-instances --instance-id $instanceIds

echo "Database cluster [$autoscaling_group_name] suspended"
