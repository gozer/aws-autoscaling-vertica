#! /bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.

# Setup and run copycluster from local cluster to the target autoscaling cluster defined 
# by the ./autoscaling_vars.sh settings in this folder

. ./autoscaling_vars.sh

# defaults
configFile="./copyclusterConfig.ini"
pwdFile="./copyclusterPasswd.ini"
user=dbadmin
userArg="-U $user"
pwd="$password"
pwdArg="-w $pwd"
dbPath=/vertica/data  # constant for target database on AWS AMI

function show_help {
   echo "$0 [-w dbadminPasswd]"
   echo "	dbadminPasswd	- default is '$pwd'"
   exit 0
}

while getopts "h?w:P:p:" opt; do
   case "$opt" in
   h|\?)
      show_help
      exit 0
      ;;
   P|p|w)
      pwd="$OPTARG"
      pwdArg="-w $OPTARG"
      ;;
   esac
done


function get_instance_by_ip() {
   ip=$1
   instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].InstanceId")
   for instanceId in $instanceIds
   do
      privateIps=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" | perl -ne "chomp; print reverse join(',', map { qq/'\$_'/ } split(/ /,$_))")
      echo $privateIps | grep $ip > /dev/null
      if [ $? -eq 0 ]; then
         echo $instanceId
         break
      fi
   done
}


# Find active local database name
localdb=$(admintools -t show_active_db)
if [ -z "$localdb" ]; then
   echo "No local database running. Please start database, and try again."
   exit 1
else
   echo "Active local database: $localdb"
fi

# get Public IP address for remote cluster
echo "Get public IP address of an instance in remote cluster"
publicIp=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].PublicIpAddress" | head -1 | cut -f 1)
# test ssh
ssh -o "StrictHostKeyChecking no" $publicIp echo "Verify passwordless ssh to [$publicIp]"
if [ $? -ne 0 ]; then
   echo "Passwordless ssh failed [ssh -o "StrictHostKeyChecking no" $publicIp]"
   exit 1
fi

# verify node counts of local and remote clusters match
local_node_count=$(vsql $pwdArg -qAt -c "select count(*) from nodes")
remote_node_count=$(vsql -h $publicIp $pwdArg -qAt -c "select count(*) from nodes")
if [ "$local_node_count" != "$remote_node_count" ]; then
   echo "ERROR: Local node count [$local_node_count] does not match remote node count [$remote_node_count]"
   exit 1
fi
echo "Local and Remote clusters have $local_node_count nodes"

# capture local and remote node info
local_node_names=($(vsql $pwdArg -qAt -c "select node_name from nodes order by node_name"))
remote_node_names=($(vsql -h $publicIp $pwdArg -qAt -c "select node_name from nodes order by node_name"))
remote_node_addrs=($(vsql -h $publicIp $pwdArg -qAt -c "select node_address from nodes order by node_name"))

# configure node names on remote cluster if names don't align
if [ "${local_node_names[*]}" != "${remote_node_names[*]}" ]; then
   echo "Cluster node names do not match.. configuring names on remote cluster"
   site_host_file="site_host.txt"; rm -f $site_host_file
   count=0
   # loop through each node name
   while [ ! -z "${local_node_names[count]}" ]
   do
      # create site_host entry to map node names to remote cluster node
      # Format: v_vmart_node0001 10.0.10.149 /vertica/data /vertica/data
      site_host_mapping="${local_node_names[count]} ${remote_node_addrs[count]} $dbPath $dbPath"
      echo "node_name mapping [$site_host_mapping]"
      echo $site_host_mapping >> $site_host_file
      count=$(( $count + 1 ))
   done
   node_list=$(cat $site_host_file | cut -d ' ' -f1 | paste -d, -s)
   scp $site_host_file $publicIp:/home/dbadmin/autoscale/site_host.txt
   ssh $publicIp "(
      cd ~/autoscale
      echo "Stop and drop database [$database_name] on target cluster [$publicIp]"
      admintools -t stop_db -d $database_name
      admintools -t drop_db -d $database_name
      echo "Configure remote node names"
      admintools -u -t config_nodes -f ./site_host.txt -c
      echo "Recreate remote database [$database_name] on named nodes [$node_list]"
      admintools -u -t create_db -d $database_name -p $pwd -s $node_list --compat21
      echo "Install autoscaling features on remote database [$database_name]"
      sh ./database_configure.sh > /dev/null 2>&1
   )"
   remote_node_names=($(vsql -h $publicIp $pwdArg -qAt -c "select node_name from nodes order by node_name"))
   if [ "${local_node_names[*]}" != "${remote_node_names[*]}" ]; then
      echo "Attempt to align remote cluster node names failed!"
      echo "Local node names [${local_node_names[*]}]"
      echo "Remote node names [${remote_node_names[*]}]"
      exit 1
   fi
   echo "Remote node names sucessfully aligned with local cluster"
else
   echo "Node names of source and target clusters match."
fi

# create password file, and restrict to owner rw
cat <<EOF > $pwdFile
[Passwords]
dbPassword = $pwd
EOF
chmod 600 $pwdFile

# Make vbr config file - mapping section initially empty
echo "Create backup copyCluster config [$configFile]"
cat <<EOF > $configFile
[Misc]
snapshotName = CopyTo_
restorePointLimit = 1
passwordFile = $pwdFile

[Database]
dbName = $db
dbUser = $user

[Transmission]

[Mapping]
EOF


# Append Mapping entries
count=0
while [ ! -z "${local_node_names[count]}" ]
do
   # create vbr config mapping entry, using publicIp address for each node
   # Format: v_vmart_node0001 = 52.32.23.124:/ignorepath
   remote_instId=$(get_instance_by_ip ${remote_node_addrs[count]})
   remote_publicIp=$(aws --output=text ec2 describe-instances --instance-id $remote_instId --query "Reservations[*].Instances[*].PublicIpAddress")
   vbr_mapping="${local_node_names[count]} = $remote_publicIp:/ignorepath"
   echo "Append backup copyCluster config mapping [$vbr_mapping]"
   echo $vbr_mapping >> $configFile
   count=$(( $count + 1 ))
done
echo "Backup Config file created: $configFile"

echo "Stop database on remote cluster"
ssh $publicIp "admintools -t stop_db -d $database_name"

cmd="vbr.py -t copycluster --config-file $configFile"
echo "Run the copy cluster command [$cmd]"
$cmd
if [ $? -ne 0 ]; then
  echo "Copy Cluster command failed. Copy aborted. Restarting remote database"
  ssh $publicIp "admintools -t start_db -d $database_name"
  exit 1
fi

echo "Start database on remote cluster"
ssh $publicIp "admintools -t start_db -d $database_name"

echo "Install autoscaling features on target database"
ssh $publicIp "cd /home/dbadmin/autoscale; sh database_configure.sh > /dev/null 2>&1"

echo "Done - local database [$database_name] copied to remote cluster [$publicIp]"
exit 0

