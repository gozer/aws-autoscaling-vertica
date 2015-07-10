#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run as part of bootstrapping first instance.. creates and configures 1-node auto scale compatible database


. ./autoscaling_vars.sh

# get instance configuration
resId=$(curl -s http://169.254.169.254/latest/meta-data/reservation-id); echo Reservation: $resId
instId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id); echo InstanceId: $instId
privateIp=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4); echo PrivateIP: $privateIp
publicIp=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4); echo PublicIP: $publicIp
macs=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/) 
subnetCIDR=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$macs/subnet-ipv4-cidr-block/); echo Subnet CIDR: $subnetCIDR

# create database
admintools -t create_db -s $privateIp -d $database_name -p $password

# configure database for autoscaling
./database_configure.sh

# Add first log entry for bootstrap node
time=$( date +"%Y-%m-%d %H:%M:%S")
echo "$privateIp|$time|$time|0|$resId|$instId|$privateIp||$publicIp|SUCCESS|0|Initial Bootstrap node" | vsql -c "COPY autoscale.launches FROM STDIN" 


