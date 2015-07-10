#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Returns a list of public / private IP addresses for each node in the cluster

. ./autoscaling_vars.sh

instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name Name=instance-state-code,Values=16 --query "Reservations[*].Instances[*].InstanceId")

for instanceId in $instanceIds
do
   privateIps=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" | perl -ne "chomp; print reverse join(',', map { qq/'\$_'/ } split(/ /,$_))")
   publicIp=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].Association.PublicIp")
   sql="select node_name from nodes where node_address in ($privateIps)"
   node_name=$(ssh -i $pem_file -o "StrictHostKeyChecking no" $publicIp "vsql -qAt -c \"$sql\"")
   echo "$node_name: PublicIP ['$publicIp'], PrivateIP [$privateIps], EC2 InstanceId [$instanceId]"
done

