# Cloning an HP Vertica cluster to AWS

Our latest enhancement to the [HP Vertica AWS Auto Scaling](https://community.dev.hp.com/t5/Vertica-Blog/Automatic-Vertica-Scaling-and-Node-Replacement-on-AWS/ba-p/230468) open-source package makes it quite easy to create a working replica of your existing cloud hosted or on-premise HP Vertica cluster.
 
Here are some of the reasons you might find this capability useful:
 
#### Create a Disaster Recovery cluster

By replicating your database to a "cluster in the cloud", you establish a working backup database that you can use if disaster strikes your primary cluster.

You can save money by suspending the backup cluster when it is not in use, and resuming it again when needed. Use the `suspendCluster.sh` and `resumeCluster.sh` utilities provided with the HP Vertica AWS Auto Scaling open-source package. While the cluster is suspended, your AWS usage charges will be significantly reduced.

Once your backup cluster has been established, you can periodically re-synchronize it with the primary cluster to keep it up to date.  

If your primary HP Vertica cluster is hosted on AWS, you can defend against disaster by creating your backup cluster in a subnet hosted in a different AWS Availability Zone.


#### Create Sandbox Clusters

You can easily create on-demand sandbox environments for development and test by cloning your production database to the AWS cloud. You can create as many replica clusters as you need, and, when you are done, you can terminate them. 

This is a great way to try and test changes to your application, schema, projections, etc., before comitting them to the production cluster. By leveraging the auto scaling features of your new replica cluster, you can also experiment with the effects of scaling the cluster size up and down, again before committing the changes to production.


#### Establish Regional Database Replicas 

You may want to load balance your application workload across replicated clusters in multiple AWS regions. 

You should engineer your ETL processes to keep the replica clusters current. Replicas can can be periodically resynchronised with the primary cluster during maintainance windows. 


#### Migrate from On-premise to the Cloud.

You can set up experimental copies of your on-premise database in the AWS cloud, see how it works, and when you are ready you can clone the most recent data before going live with your new cloud based cluster.

#### Take advantage of Auto Scaling

Copy data from your existing on-premise or cloud based cluster to a new AWS Auto Scaling cluster, and take advantage of all the features offered by [auto scaling](https://community.dev.hp.com/t5/Vertica-Blog/Automatic-Vertica-Scaling-and-Node-Replacement-on-AWS/ba-p/230468) and [Elastic Load Balancing](https://github.com/vertica/aws-autoscaling-vertica/blob/master/AWS-ElasticLoadBalancer-for-Vertica.md).


## Overview

There are two main steps to cloning your database cluster:

1. Create a new target cluster by installing the [HP Vertica AWS Auto Scaling](https://community.dev.hp.com/t5/Vertica-Blog/Automatic-Vertica-Scaling-and-Node-Replacement-on-AWS/ba-p/230468) open source package on one of the nodes of your existing cluster. 
Follow the instructions to setup the configuration, making sure you match the database name and password, and that you specify that the new cluster has a desired node count matching the number of nodes in your local cluster.

2. Once the new cluster is up and running, use the `copyCluster.sh` script to initiate the cloning process. The script will verify the connectivity between the two clusters, and ensure that the node names and data file paths match. Once everything is aligned, the HP Vertica [copycluster](http://my.vertica.com/docs/7.1.x/HTML/index.htm#Authoring/AdministratorsGuide/BackupRestore/CopyingTheDatabaseToAnotherCluster.htm?Highlight=copycluster) task is used to replicate the local database on the remote cluster.
This step may be run periodically to incrementally resynchronize the clusters.

 
<img style="margin-left: 100px;" src="images/CopyCluster.png" alt="Architecture" height="300" width="480">


## Setup target cluster

Install the [HP Vertica AWS Auto Scaling](https://community.dev.hp.com/t5/Vertica-Blog/Automatic-Vertica-Scaling-and-Node-Replacement-on-AWS/ba-p/230468) open source package on one of your existing cluster nodes. 

Set up the config file as instructed in the directions, to specify your credentials, region, subnet, etc. 
NB: Be sure to set `autoscaling_group_name` variable to specify a unique name for your new cluster, set the `desired` cluster size to match the node count of your existing cluster, and set `datbase_name` and `password` to match your source database.
Hint: If your existing cluster was itself created using the HP Vertica AWS Auto Scaling package, then you can make a copy of the `/home/dbadmin/autoscale` directory and edit the (already completed) `autoscale_vars.sh` in your copy to specify a new unique cluster name for `autoscaling_group_name`. 

Once you have the config file set up the way you want it, you can create your new cluster by running:
```
./setup_autoscaling.sh
./bootstrap.sh
./scale_cluster.sh
```

If you want to clone your cluster multiple times, then make multiple copies of the autoscale directory, once for each target cluster. Specify unique values for `autoscaling_group_name` in each copy of the config file, and create your clusters by repeating the above commands in each directory. 

Use `cluster_ip_addresses.sh` to check that the cluster scaleup has completed, and that your new cluster has the required number of nodes.
You new cluster has also been set up with passwordless ssh access from your source cluster nodes, for the dbadmin user. This is not only a convenience, but a pre-requisite for the HP Vertica copycluster task.

You are now ready to clone your local database to the new cluster.


## Cloning the database

Run the `copyCluster.sh` script from the autoscale directory where you configured the new target cluster.

The script will connect to both local and target clusters, comparing database names, node count, node names, and data & catalog file paths.
If data and catalog directory paths used on the source database exist on the target cluster nodes, these paths will use used directly, otherwise the paths will be recreated as symbolic links to the `/vertica/data` directory used by default on the Vertica Amazon Machine Image (AMI). the database will be dropped and recreated on the target cluster, to use the new matching paths.
If the node names used on the source cluster do not match those used on the target cluster, the target cluster database will be dropped and recreated to use the same node names as the source.  

Once database names, passwords, node counts, node names and paths are all aligned, the database is stopped on the target cluster, and the HP Vertica vbr.py copycluster tool is executed to copy data from the source nodes to the target nodes. The copy is done using the target cluster public IP addresses, thus supporting copies from on premise clusters or across AWS regions and availability zone subnets.

 

 








 







