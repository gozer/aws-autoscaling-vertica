#! /bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.

# This script will attempt to copy a local database to a remote AWS cluster.
# 1. The remote AWS cluster must be configured from a node on the local cluster, using the aws-autoscaling-vertica package
#     - this script must be run from that same node (it leverages the aws-autoscaling-vertica configuration)
# 2. The remote cluster must be scaled to be the same node count as the local cluster
# 4  If database names or node names do not match between local an dremote clusters, the database on the remote
#    cluster will be recreated to match.
# 4. The path used for data and catalog files will be replicated on the remote cluster
#     - if the paths do not exist on remote cluster nodes, they will be created as symblic links to '/vertica/data'
#       (the default data/catalog directory on the Vertica AWS machine image)
#     - There must be sufficient disk space on the remote cluster nodes
# 5. A Catalog editor batch script is used (via admintools) on the target cluster to ensure it is configured to run in point-to-point
#    mode ( arequirement for AWS)


. ./autoscaling_vars.sh

# defaults
PWD=$(pwd)
configFile="${PWD}/copyclusterConfig.ini"
pwdFile="${PWD}/copyclusterPasswd.ini"
user=dbadmin
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
   echo "Change node count of remote cluster using 'scale_cluster.sh -s $local_node_count'"
   exit 1
fi
echo "Local and Remote clusters have $local_node_count nodes"

# capture local and remote node info
database_name=$(admintools -t show_active_db)
remote_db=$(ssh $publicIp admintools -t show_active_db)
if [ -z "$database_name" ]; then
   echo "No local database running. Please start database, and try again."
   exit 1
fi
local_node_names=($(vsql $pwdArg -qAt -c "select node_name from nodes order by node_name"))
remote_node_names=($(vsql -h $publicIp $pwdArg -qAt -c "select node_name from nodes order by node_name"))
remote_node_addrs=($(vsql -h $publicIp $pwdArg -qAt -c "select node_address from nodes order by node_name"))
local_db_paths=$(cat /opt/vertica/config/admintools.conf | egrep "^${local_node_names[0]} " | awk -F, '{printf "%s %s", $2, $3}')
remote_db_paths=$(ssh $publicIp cat /opt/vertica/config/admintools.conf | egrep "^${remote_node_names[0]} " | awk -F, '{printf "%s %s", $2, $3}')

# recreate remote database if database name,  node names or paths don't match
recreate_remote_db=0
if [ "$database_name" != "$remote_db" ]; then
   echo "Local database name => $database_name"
   echo "Remote database name => $remote_db"
   echo "Database [$database_name] will be recreated on the target cluster"
   recreate_remote_db=1  
else 
   echo "Local and remote database names match [$database_name]"
fi
if [ "${local_node_names[*]}" != "${remote_node_names[*]}" ]; then
   echo "Cluster node names do not match. Recreate remote DB with matching names."
   recreate_remote_db=1
else 
   echo "Local and remote node names match"
fi
if [ "$local_db_paths" != "$remote_db_paths" ]; then
   echo "Local data/catalog path [$local_db_paths]. Remote data/catalog path [$remote_db_paths]"
   echo "Cluster data/catalog paths do not match. Recreate remote DB with matching paths."
   recreate_remote_db=1
else
   echo "Local and remote paths match"
fi

# recreate database on remote cluster with aligned databaes name, node names, and paths
if [ $recreate_remote_db -eq 1 ]; then
   echo "Recreating database [$database_name] on remote cluster [$autoscaling_group_name / $publicIp]"
   site_host_file="site_host.txt"; rm -f $site_host_file
   count=0
   # loop through each node name
   while [ ! -z "${local_node_names[count]}" ]
   do
      # create site_host entry to map node names and data/catalog paths to remote cluster node
      # Format: v_vmart_node0001 10.0.10.149 /vertica/data /vertica/data
      site_host_mapping="${local_node_names[count]} ${remote_node_addrs[count]} $local_db_paths"
      echo "node_name mapping [$site_host_mapping]"
      echo $site_host_mapping >> $site_host_file
      count=$(( $count + 1 ))
   done
   node_list=$(cat $site_host_file | cut -d ' ' -f1 | paste -d, -s)
   scp $site_host_file $publicIp:/home/dbadmin/autoscale/site_host.txt
   catalog_path=$(echo $local_db_paths | cut -d" " -f1)
   data_path=$(echo $local_db_paths | cut -d" " -f2)
   ssh $publicIp "(
      cd ~/autoscale
      echo "Check data and catalog paths"
      for node in ${remote_node_addrs[*]}
      do
         echo "Check paths [$local_db_paths] on node [\$node]"
         ssh -o \"StrictHostKeyChecking no\" \$node \"(
            # Catalog Path
            if [ -d $catalog_path ]; then 
               echo "[\$node] Catalog path exists [$catalog_path]"
            else
               echo "[\$node] Catalog path does not exist. Create symbolic link from [$catalog_path] to [/vertica/data]"
               sudo mkdir -p $(dirname $catalog_path)
               sudo ln -s /vertica/data/ $catalog_path 
            fi
            sudo chown dbadmin $catalog_path
            touch $catalog_path/writetest.tmp
            if [ \$? -eq 0 ]; then
               rm -f $catalog_path/writetest.tmp
            else
               echo "[\$node] ERROR: Unable to write test file to $catalog_path/writetest.tmp"
               exit 1
            fi
            # Data Path
            if [ -d $data_path ]; then
               echo "[\$node] Data path exists [$data_path]"
            else
               echo "[\$node] Data path does not exist. Create symbolic link from [$data_path] to [/vertica/data]"
               sudo mkdir -p $(dirname $data_path)
               sudo ln -s /vertica/data/ $data_path 
            fi
            sudo chown dbadmin $data_path
            touch $data_path/writetest.tmp
            if [ \$? -eq 0 ]; then
               rm -f $data_path/writetest.tmp
            else
               echo "[\$node] ERROR: Unable to write test file to $data_path/writetest.tmp"
               exit 1
            fi
         )\"
         [ \$? -ne 0 ] && exit 1
      done
      echo "Stop and drop database [$remote_db] on target cluster [$autoscaling_group_name / $publicIp]"
      admintools -t stop_db -d $remote_db
      admintools -t drop_db -d $remote_db
      echo "Configure remote node names for database [$database_name]"
      admintools -u -t config_nodes -f ./site_host.txt -c
      echo "Create remote database [$database_name] on named nodes [$node_list]"
      admintools -u -t create_db -d $database_name -p $pwd -s $node_list --compat21
      echo "Install autoscaling features on remote database [$database_name]"
      sh ./database_configure.sh > /dev/null 2>&1
   )"
   if [ $? -ne 0 ]; then
      echo "Failed to create database on remote cluster"
      exit 1
   fi
   remote_node_names=($(vsql -h $publicIp $pwdArg -qAt -c "select node_name from nodes order by node_name"))
   if [ "${local_node_names[*]}" != "${remote_node_names[*]}" ]; then
      echo "Attempt to align remote cluster node names failed!"
      echo "Local node names [${local_node_names[*]}]"
      echo "Remote node names [${remote_node_names[*]}]"
      exit 1
   fi
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
snapshotName = CopyTo_$autoscaling_group_name
restorePointLimit = 1
passwordFile = $pwdFile

[Database]
dbName = $database_name
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

# workaround for VER-37726 (fixed in 7.1 SP2)
mkdir -p /tmp/vbr

cmd="vbr.py -t copycluster --config-file $configFile"
echo "Run the copy cluster command [$cmd]"
$cmd
if [ $? -ne 0 ]; then
  echo "Copy Cluster command failed. Copy aborted. Restarting remote database"
  ssh $publicIp "admintools -t start_db -d $database_name"
  exit 1
fi

# AWS clusters MUST run with spread in point-to-point mode.. broadcast mode does not work.
# We will use the catalog editor to ensure that spread controlmode is set to pt2pt
echo "Setting target cluster to run in spread point-to-point controlmode (reqd on AWS)"
ssh $publicIp "(
   echo "set singleton GlobalSettings controlMode pt2pt" > /tmp/setcontrolmode.cmd
   echo "spreadconf overwrite" >> /tmp/setcontrolmode.cmd
   echo "versionsjson" >> /tmp/setcontrolmode.cmd
   echo "commit" >> /tmp/setcontrolmode.cmd
   admintools -t dist_catalog_edit -f setcontrolmode.cmd -d $database_name
)"

echo "Start database on remote cluster"
ssh $publicIp "admintools -t start_db -d $database_name"

echo "Install autoscaling features on target database"
ssh $publicIp "cd /home/dbadmin/autoscale; sh database_configure.sh > /dev/null 2>&1"

echo "Done - local database [$database_name] copied to remote cluster [$publicIp]"
exit 0

