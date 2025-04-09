#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.

namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); do
    echo "Found cassandradatacenter: $cassandradatacenter"
    echo "The annotation kasten.io/counterIncrementalBackups must be removed so that the next backup will be a full backup"
    kubectl annotate cassandradatacenter -n $namespace $cassandradatacenter kasten.io/counterIncrementalBackups- --overwrite

    echo "Wait 10 minutes for it to be ready"
    kubectl wait --for='jsonpath={.status.cassandraOperatorProgress}=Ready' -n $namespace cassandradatacenter/$cassandradatacenter --timeout=600s
    
    echo "we don't need to clean up existing user tables because we don't restore the database pvc only the backups pvc"
    echo "Hence there is no schema after restore and we can restore from the schema stored in the /backups/schema.cql file on the first pod"
    secret="$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.spec.clusterName')-superuser"
    user=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.username | base64decode }}')
    password=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.password | base64decode }}')
    schema_restored=false
    for pod in $(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o go-template='{{range $key, $value := .status.nodeStatuses}}{{$key}} {{end}}'); do
        echo "Working on $pod"
        if [ $schema_restored = false ]; then
            echo "Schema is not restored yet"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "cqlsh -u '$user' -p '$password' -e \"\$(cat /backups/schema.cql)\" --request-timeout=300"
            schema_restored=true
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
        for line in $(cat /tmp/table_desc.txt); 
        do
            id=$(echo $line | jq -r '.id')
            id="${id//-/}"
            table_name=$(echo $line | jq -r '.table_name')
            keyspace_name=$(echo $line | jq -r '.keyspace_name')    
            keyspace_directory="${cassandra_prefix}/${keyspace_name}/${table_name}-${id}"
            snap_directory="${backup_pvc_mount_point}/${keyspace_name}/${table_name}/${pod}"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "cp -r ${snap_directory}/* ${keyspace_directory}/"
            kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool refresh $keyspace_name $table_name"
        done
        IFS=$PREVIOUS_IFS
    done
done