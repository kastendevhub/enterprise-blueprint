#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.


namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); do
    echo "Found cassandradatacenter: $cassandradatacenter"
    echo "check if the annotations are present"
    if [[ "null" == "$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/numIncrementalBackupsBeforeFullBackup"]')" ]]; then
        echo "The annotation kasten.io/numIncrementalBackupsBeforeFullBackup is missing set it up to 24."
        kubectl annotate cassandradatacenter -n $namespace $cassandradatacenter kasten.io/numIncrementalBackupsBeforeFullBackup=24
    else
        echo "The annotation kasten.io/numIncrementalBackupsBeforeFullBackup is present."
    fi
    fullBackup=false
    counterIncrementalBackups=$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/counterIncrementalBackups"]')
    echo "counterIncrementalBackups: $counterIncrementalBackups"
    if [[ "null" == "$counterIncrementalBackups" ]]; then
        echo "The annotation kasten.io/counterIncrementalBackups is missing set it up to 0 and enable full backup"
        kubectl annotate cassandradatacenter -n $namespace $cassandradatacenter kasten.io/counterIncrementalBackups=0
        fullBackup=true
    else 
        echo "The annotation kasten.io/counterIncrementalBackups is present."
    fi
    numIncrementalBackupsBeforeFullBackup=$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/numIncrementalBackupsBeforeFullBackup"]')
    counterIncrementalBackups=$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/counterIncrementalBackups"]')
    if [ $numIncrementalBackupsBeforeFullBackup -le $counterIncrementalBackups ]; then
        echo "The number of incremental backups is greater than the number of incremental backups before full backup. Set the annotation kasten.io/counterIncrementalBackups to 0 and enable full backup"
        fullBackup=true
    fi

    secret="$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.spec.clusterName')-superuser"
    user=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.username | base64decode }}')
    password=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.password | base64decode }}')
    schema_saved=false
        
    for pod in $(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o go-template='{{range $key, $value := .status.nodeStatuses}}{{$key}} {{end}}'); do
        echo "Working on $pod"
        if [ $schema_saved = false ]; then
            echo "Schema is not saved yet"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "cqlsh -u '$user' -p '$password' -e 'DESCRIBE SCHEMA' > /backups/schema.cql"
            schema_saved=true
        fi
        # we need to discover the keyspaces and tables in the cluster, especially each table use a unique id
        # for instance if the guests table in the restaurants keyspace is having an id of 06c67ef0-1387-11f0-b576-0b6d1f3c36b1
        # {"id": "06c67ef0-1387-11f0-b576-0b6d1f3c36b1", "table_name": "guests", "keyspace_name": "restaurants"}
        # snapshots will be found in /var/lib/cassandra/data/restaurants/guests-06c67ef0138711f0b5760b6d1f3c36b1/snapshots
        # and the backups will be found in /var/lib/cassandra/data/restaurants/guests-06c67ef0138711f0b5760b6d1f3c36b1/backups
        # we need to move the snapshots and backups files under /backups/[keyspace_name]/[table_name]/snapshots/[hostname]
        # we store the table description in /backups/table_desc.txt
        kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "cqlsh -u '$user' -p '$password' -e 'SELECT JSON id, table_name, keyspace_name FROM system_schema.tables;' | grep  '{' | grep -v system" > /tmp/table_desc.txt
        PREVIOUS_IFS=$IFS
        IFS=$'\n'
        cassandra_prefix="/var/lib/cassandra/data"
        backup_pvc_mount_point="/backups"
        if [ $fullBackup = true ]; then
            echo "doing a full backup"
            echo "clean up all the keyspace directory under /backup" 
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "find /backups -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +"
            echo "calling nodetool"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool cleanup"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool clearsnapshot --all"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool snapshot -t ${pod}"

            for line in $(cat /tmp/table_desc.txt); 
            do
                id=$(echo $line | jq -r '.id')
                id="${id//-/}"
                table_name=$(echo $line | jq -r '.table_name')
                keyspace_name=$(echo $line | jq -r '.keyspace_name')    
                target_directory="${backup_pvc_mount_point}/${keyspace_name}/${table_name}/"
                kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "mkdir -p $target_directory"
                snapshot_directory="${cassandra_prefix}/${keyspace_name}/${table_name}-${id}/snapshots/${pod}"
                kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "mv $snapshot_directory $target_directory"
                # clean up backup directory because we don't need the incremental backup anymore 
                backup_directory="${cassandra_prefix}/${keyspace_name}/${table_name}-${id}/backups"
                kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "if [ -d $backup_directory ]; then rm -rf $backup_directory; fi"
            done
            IFS=$PREVIOUS_IFS
            # now that all snaps has been saved on the backups repo let's remove them 
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool clearsnapshot --all"
            
        else
            echo "doing an incremental backup"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool flush"
            
            for line in $(cat /tmp/table_desc.txt); 
            do
                id=$(echo $line | jq -r '.id')
                id="${id//-/}"
                table_name=$(echo $line | jq -r '.table_name')
                keyspace_name=$(echo $line | jq -r '.keyspace_name')    
                target_directory="${backup_pvc_mount_point}/${keyspace_name}/${table_name}/${pod}"
                kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "mkdir -p $target_directory"
                backup_directory="${cassandra_prefix}/${keyspace_name}/${table_name}-${id}/backups"
                kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "if [ -d $backup_directory ]; then cp $backup_directory/* $target_directory/; rm -rf $backup_directory; fi"
            done
            IFS=$PREVIOUS_IFS
        fi
    done
done