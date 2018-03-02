#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run as part of bootstrapping first instance.. creates 1-node cluster
. ./autoscaling_vars.sh

autoscale_dir=/home/dbadmin/autoscale

# This script can get called from bootstrap.sh potentially before the aws cli is installed by launch.sh on newly started instance.
# So, if aws isn't installed yet, wait for it.

while [ 1 ]; do
   testAws=$(aws --version)
   [ $? -eq 0 ] && break
   echo "Waiting another 60s for aws CLI to be installed by instance launch script"
   sleep 60
done

AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq '.region' -r)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

if [ "$privateIp" == "" ]; then
  privateIp=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4); echo PrivateIP: $privateIp
fi

[ -e $autoscale_dir/license.dat ] && license=$autoscale_dir/license.dat || license=CE
sudo /opt/vertica/sbin/install_vertica --add-hosts $privateIp --point-to-point --ssh-identity $autoscale_dir/key.pem -L $license --dba-user-password-disabled --data-dir /vertica/data -Y --failure-threshold HALT


