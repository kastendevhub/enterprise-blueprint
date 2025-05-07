#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.


namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); do
    echo "Found cassandradatacenter: $cassandradatacenter"
    
    secret="$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.spec.clusterName')-superuser"
    user=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.username | base64decode }}')
    password=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.password | base64decode }}')
            
    for pod in $(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o go-template='{{range $key, $value := .status.nodeStatuses}}{{$key}} {{end}}'); do
        echo "Working on $pod saving schema"
        kubectl exec  $pod -c cassandra -n $namespace -- bash -c "cqlsh -u '$user' -p '$password' -e 'DESCRIBE SCHEMA' > /var/lib/cassandra/data/schema.cql"
        echo "Working on $pod clearing snapshots"
        kubectl exec  $pod -c cassandra -n $namespace -- bash -c "nodetool cleanup"
        kubectl exec  $pod -c cassandra -n $namespace -- bash -c "nodetool clearsnapshot --all"
        echo "Working on $pod creating snapshots"
        kubectl exec  $pod -c cassandra -n $namespace -- bash -c "nodetool snapshot -t ${pod}"        
    done

done