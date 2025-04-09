#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.

namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); do
    echo "Found cassandradatacenter: $cassandradatacenter"
    counterIncrementalBackups=$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/counterIncrementalBackups"]')
    numIncrementalBackupsBeforeFullBackup=$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.metadata.annotations["kasten.io/numIncrementalBackupsBeforeFullBackup"]')
    if [ $numIncrementalBackupsBeforeFullBackup -le $counterIncrementalBackups ]; then
        echo "The number of incremental backups $counterIncrementalBackups is greater than numIncrementalBackupsBeforeFullBackup $numIncrementalBackupsBeforeFullBackup, a full backup was done. Set the annotation kasten.io/counterIncrementalBackups to 0"
        kubectl annotate cassandradatacenter -n $namespace $cassandradatacenter kasten.io/counterIncrementalBackups=0 --overwrite
    else
        echo "The number of incremental backups $counterIncrementalBackups is lesser or equal than numIncrementalBackupsBeforeFullBackup $numIncrementalBackupsBeforeFullBackup, an incremental backup or a first full backup was done. increment annotation kasten.io/counterIncrementalBackups"
        counterIncrementalBackups=$((counterIncrementalBackups + 1))
        kubectl annotate cassandradatacenter -n $namespace $cassandradatacenter kasten.io/counterIncrementalBackups=$counterIncrementalBackups --overwrite
    fi
done