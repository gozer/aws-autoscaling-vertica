#! /bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.

# Create a new cluster with the same number of nodes, same node names, and data/catalog path as the local cluster.

. ./autoscaling_vars.sh

# defaults
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

# Get local database name
localdb=$(admintools -t show_active_db)
if [ -z "$localdb" ]; then
   echo "No local database running. Please start database, and try again."
   exit 1
else
   echo "Active local database: $localdb"
fi

# Get node count
local_node_count=$(vsql $pwdArg -qAt -c "select count(*) from nodes")

echo "Done"
exit 0

