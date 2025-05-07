#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.

namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); do
    echo "Found cassandradatacenter: $cassandradatacenter"
            
    for pod in $(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o go-template='{{range $key, $value := .status.nodeStatuses}}{{$key}} {{end}}'); do
        echo "Working on $pod clearing snapshots"
        kubectl exec -it $pod -c cassandra -n $namespace -- bash -c "nodetool clearsnapshot --all"        
    done
done