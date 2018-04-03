#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# SQL command to create database objects for autoscaling package
# Run during bootstrapping, and also after a cloneCluster (in case source cluster was not set up for autoscaling)


. ./autoscaling_vars.sh

# get instance subnet configuration
macs=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/) 
subnetCIDR=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$macs/vpc-ipv4-cidr-block/); echo Subnet CIDR: $subnetCIDR

# configure trust for local host and local subnet & avoids need to transmit / store password on local subnet
vsql -w $password -c "CREATE AUTHENTICATION trustLocal METHOD 'trust' LOCAL; GRANT AUTHENTICATION trustLocal TO dbadmin;"
vsql  -c "CREATE AUTHENTICATION trustSubnet METHOD 'trust' HOST '$subnetCIDR'; GRANT AUTHENTICATION trustSubnet TO dbadmin;"
# configure default password authentication from everywhere else
vsql  -c "CREATE AUTHENTICATION passwd METHOD 'hash' HOST '0.0.0.0/0'; GRANT AUTHENTICATION passwd TO dbadmin;"

# install external stored procedures used to expand and contract cluster
admintools -t install_procedure -d $database_name -f /home/dbadmin/autoscale/add_nodes.sh
admintools -t install_procedure -d $database_name -f /home/dbadmin/autoscale/remove_nodes.sh
vsql -c "CREATE SCHEMA autoscale"
vsql -c "CREATE PROCEDURE autoscale.add_nodes() AS 'add_nodes.sh' LANGUAGE 'external' USER 'dbadmin'"
vsql -c "CREATE PROCEDURE autoscale.remove_nodes() AS 'remove_nodes.sh' LANGUAGE 'external' USER 'dbadmin'"

# enable Vertica's elastic cluster with local segmentation for faster rebalancing. See documentation for details on tuning elastic cluster parameters, such as scaling factor, maximum skew, etc.
vsql -c " SELECT ENABLE_ELASTIC_CLUSTER();"
vsql -c " SELECT ENABLE_LOCAL_SEGMENTS();"

# Disable connection warnings from load-balancers
vsql -c " SELECT set_config_parameter('WarnOnIncompleteStartupPacket', 0);"

# Create logging tables - 
vsql -c "CREATE TABLE autoscale.launches (added_by_node varchar(15), start_time timestamp, end_time timestamp, duration_s int, reservationid varchar(20), ec2_instanceid varchar(20), node_address varchar(15), node_subnet_cidr varchar(25), replace_node_address varchar(15), node_public_address varchar(15), status varchar(120), is_running boolean, comment varchar(128)) ORDER BY start_time UNSEGMENTED ALL NODES";
vsql -c "CREATE TABLE autoscale.terminations (queued_by_node varchar(15), removed_by_node varchar(15), start_time timestamp, end_time timestamp, duration_s int, ec2_instanceid varchar(20), node_address varchar(15), node_subnet_cidr varchar(25), node_public_address varchar(15), lifecycle_action_token varchar(128), lifecycle_action_asg varchar(128), status varchar(128), is_running boolean) ORDER BY start_time UNSEGMENTED ALL NODES";
vsql -c "CREATE TABLE autoscale.downNodes (detected_by_node varchar(15), trigger_termination_time timestamp, node_down_since timestamp, ec2_instanceid varchar(20), node_address varchar(15), node_subnet_cidr varchar(25), status varchar(128)) UNSEGMENTED ALL NODES";


