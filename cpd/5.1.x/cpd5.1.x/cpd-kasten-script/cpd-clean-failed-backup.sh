#!/bin/bash

OADP_PROJECT=${$1:-openshift-adp}

export HOME=/tmp
cd /tmp/
cpd-cli oadp client config set namespace=$OADP_PROJECT
for failedTenantBackup in $(cpd-cli oadp tenant-backup list | grep -v Completed | grep -v NAME | awk '{print $1}'); do
    echo "Deleting failed tenant backup: $failedTenantBackup"
    cpd-cli oadp tenant-backup delete $failedTenantBackup
    # substring failedTenantBackup after 14 characthers
    failedTenantBackupDate=${failedTenantBackup:14} 
    schedulingBackup="scheduling-online-$failedTenantBackupDate"
    cpd-cli oadp backup delete $schedulingBackup
done
