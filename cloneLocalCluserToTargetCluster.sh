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


# Find active local database name
localdb=$(admintools -t show_active_db)
if [ -z "$localdb" ]; then
   echo "No local database running. Please start database, and try again."
   exit 1
else
   echo "Active local database: $localdb"
fi

# Check that local database name matches the database name configured for target cluster
if [ $localdb != $database_name ]; then
   echo "ERROR: local database name [$localdb] must match the database name configured for target cluster [$database_name]"
   exit 1
fi

# create password file, and restrict to owner rw
cat <<EOF > $pwdFile
[Passwords]
dbPassword = $pwd
EOF
chmod 600 $pwdFile

# Make vbr config file
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

# Append backup config for each node, of the form:
# v_vmart_node0001 = 10.0.10.149:/ignorepath
# get Ips for target cluster, and look up corresponding node_names
instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name Name=instance-state-code,Values=16 --query "Reservations[*].Instances[*].InstanceId")
for instanceId in $instanceIds
do
   privateIps=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" | perl -ne "chomp; print reverse join(',', map { qq/'\$_'/ } split(/ /,$_))")
   publicIp=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].Association.PublicIp")
   sql="select node_name from nodes where node_address in ($privateIps)"
   node_name=$(ssh -o "StrictHostKeyChecking no" $publicIp "vsql -qAt -c \"$sql\"") # passwordless ssh is already configured
   if [ -z "$node_name" ]; then
      echo "ERROR: Unable to run query on remote cluster. Is database running?"
      exit 1
   fi
   # validate that node name exists in local cluster
   match=$(vsql $pwdArg -qAt -c "select count(*) from nodes where node_name = '$node_name'") 
   if [ $match -ne 1 ]; then 
      echo "ERROR: Node_name [$node_name] does not exist in local database! Local and remote node names must match."
      exit 1
   fi
   mapping="$node_name = $publicIp:/ignorepath"
   echo "Add node mapping to target [$mapping]"
   echo $mapping >> $configFile
done
echo "Backup Config file created: $configFile"

# verify node counts match
local_node_count=$(vsql $pwdArg -qAt -c "select count(*) from nodes")
remote_node_count=$(ssh $publicIp "vsql $pwdArg -qAt -c \"select count(*) from nodes\"")
if [ $local_node_count -ne $remote_node_count ]; then
   echo "ERROR: Local node count [$local_node_count] does not match remote node count [$remote_node_count]"
   exit 1
fi

echo "Stop database on remote cluster"
ssh $publicIp "admintools -t stop_db -d $database_name"

cmd="vbr.py -t copycluster --config-file $configFile"
echo "Run the copy cluster command [$cmd]"
$cmd
if [ $? -ne 0 ]; then
  echo "Copy Cluster command failed"
  exit 1
fi

echo "Start database on remote cluster"
ssh $publicIp "admintools -t start_db -d $database_name"

echo "Install autoscaling on target database"
ssh $publicIp "cd /home/dbadmin/autoscale; sh database_configure.sh"

echo "Done"
exit 0

