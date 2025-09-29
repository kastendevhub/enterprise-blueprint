#!/bin/bash

# -----------------------------------------------------------
# This script is transformed from mascore-backup-restore.sh 
# https://github.com/ibm-mas/cli/blob/master/image/cli/mascli/backup-restore/mascore-backup-restore.sh
# instead of taking the manifest of the resource in a folder we add the label kasten-backup=true to the resources
# we want to back up and restore with K10.
# -----------------------------------------------------------

function backupSingleResource {
    RESOURCE_KIND=$1
    RESOURCE_NAME=$2

    if [ -z "$3" ]; then
        RESOURCE_NAMESPACE=$MAS_CORE_NAMESPACE
    else
        RESOURCE_NAMESPACE=$3
    fi
    
    echo "Backing up $RESOURCE_KIND/$RESOURCE_NAME in the $RESOURCE_NAMESPACE namespace..."
    echo "Saving $RESOURCE_KIND/$RESOURCE_NAME to $BACKUP_FOLDER/$RESOURCE_KIND-$RESOURCE_NAME.yaml"
    # change
    # kubectl get $RESOURCE_KIND  $RESOURCE_NAME -n $RESOURCE_NAMESPACE -o yaml | yq 'del(.metadata.creationTimestamp, .metadata.ownerReferences, .metadata.generation,  .metadata.resourceVersion, .metadata.uid, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"], .status)' >  $BACKUP_FOLDER/$RESOURCE_KIND-$RESOURCE_NAME.yaml
    kubectl label $RESOURCE_KIND  $RESOURCE_NAME -n $RESOURCE_NAMESPACE kasten-backup=true --overwrite
}

function backupResources {
    RESOURCES=$1

    echo "Backing up all $RESOURCES resources in the $MAS_CORE_NAMESPACE namespace..."
    # change
    kubectl label $RESOURCES -n $MAS_CORE_NAMESPACE kasten-backup=true --overwrite --all
    
    numberOfItems=`(kubectl get $RESOURCES -n $MAS_CORE_NAMESPACE -o yaml | yq '.items | length')`
    
    for (( i = 0; i < $numberOfItems; i++ ))
    do
        resourceYaml=`(kubectl get $RESOURCES  -n $MAS_CORE_NAMESPACE -o yaml | yq .items[$i])`
        resourceKind=`(echo "$resourceYaml" | yq .kind)`
        resourceName=`(echo "$resourceYaml" | yq .metadata.name)`
        hasCredentials=`(echo "$resourceYaml" | yq '.spec.config.credentials | has("secretName")')`
        if [ "$hasCredentials" == "true" ]; then
            credentialsName=`(echo "$resourceYaml" | yq .spec.config.credentials.secretName)`
            echo "The credentials $credentialsName will be backed up for the resource $resourceName "
            backupSingleResource Secret $credentialsName
        fi
        echo "Saving "$resourceKind" named $resourceName to $BACKUP_FOLDER/$resourceKind-$resourceName.yaml"
        # change 
        # echo "$resourceYaml" |  yq 'del(.metadata.creationTimestamp, .metadata.ownerReferences, .metadata.generation,  .metadata.resourceVersion, .metadata.uid, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"], .status)' >  $BACKUP_FOLDER/$resourceKind-$resourceName.yaml
    done
}

function checkForManualCertMgmt {

    echo "Determining if Manual Certificate Management is enabled..."
    
    suiteYaml=`(kubectl get Suite  $MAS_INSTANCE_ID -n $MAS_CORE_NAMESPACE -o yaml)`
    hasCertMgmt=`(echo "$suiteYaml" |  yq '.spec.settings | has("manualCertMgmt")')`
    if [ "$hasCertMgmt" == "true" ]; then
        hasCertMgmtValue=`(echo "$suiteYaml" | yq .spec.settings.manualCertMgmt)`
        if [ "$hasCertMgmtValue" == "true" ]; then
            echo "Manual Certificate Management is detected - the Secret $MAS_INSTANCE_ID-cert-public will be backed up..."
            backupSingleResource Secret $MAS_INSTANCE_ID-cert-public
        fi
    fi

}

function checkForCustomIssuer {

    echo "Determining if a custom ClusterIssuer is being used..."
    
    suiteYaml=`(kubectl get Suite  $MAS_INSTANCE_ID -n $MAS_CORE_NAMESPACE -o yaml)`
    hasCustomIssuer=`(echo "$suiteYaml" |  yq '.spec | has("certificateIssuer")')`
    
    if [ "$hasCustomIssuer" == "true" ]; then
        customIssuerName=`(echo "$suiteYaml" | yq .spec.certificateIssuer.name)`
        certManagerNamespace==`(echo "$suiteYaml" | yq .spec.certManagerNamespace)`
        echo -e "\n\n+-----------------------------------------------------+\n"
        echo -e "ATTENTION!!!\n"
        echo -e "A custom ClusterIssuer configuration has been detected!!!"
        echo -e "The ClusterIssuer instance name is: $customIssuerName"
        echo -e "The cert-manager namespace specified is:  instance name is $certManagerNamespace"
        echo -e "Consult cert-manager documentation for details on backing up cert-manager resources https://cert-manager.io/v1.1-docs/configuration/"
        echo -e "\n+-----------------------------------------------------+\n"
        read  -n 1 -p "It is your responsibilit to back up the ClusterIssuer $customIssuerName and its associasciated Secret resources. Press any key to continue." mainmenuinput
        echo -e "\n"
    else 
        echo "Custom ClusterIssuer has not been detected."
    fi

}
        

# =============================================================================
# MAS Core Namespace Backup and Restore
# =============================================================================


# Process command line arguments
while [[ $# -gt 0 ]]
do
    key="$1"
    shift
    case $key in
        -i|--mas-instance-id)
        MAS_INSTANCE_ID=$1
        shift
        ;;

        -f|--backup-folder)
        BACKUP_FOLDER=$1
        shift
        ;;

        -m|--mode)
        MODE=$1
        shift
        ;;


        -h|--help)
        echo "IBM Maximo Application Suite Core Namespace Backup and Restore "
        echo "---------------------------------------------------------------"
        echo "  mascore-backup-restore.sh -i MAS_INSTANCE_ID -f BACKUP_FOLDER -m backup|restore"
        echo ""
        echo "Example usage: "
        echo "  mascore-backup-restore.sh -i dev -f ./ -m backup"
        echo "  mascore-backup-restore.sh -i dev -f ./ -m restore"
        echo ""
        echo "  -i, --mas-instance-id   The MAS instance id that should be backed up or restored to"
        echo "  -f, --backup-folder     The folder where backup artifacts should be written to or read from"
        echo "  -m, --mode              Whether to backup or restore. Valid values are backup or restore"
        echo ""
        exit 0
        ;;

        *)
        # unknown option
        echo -e "\nUsage Error: Unsupported flag \"${key}\"\n\n"
        exit 1
        ;;
    esac
done

: ${MAS_INSTANCE_ID?"Need to set -i|--mas-instance-id argument"}
: ${BACKUP_FOLDER?"Need to set -f|--backup-folder argument"}
: ${MODE?"Need to set -m|--mode argument backup|restore"}

MAS_CORE_NAMESPACE=mas-$MAS_INSTANCE_ID-core

# 2. Pre-req checks
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { echo >&2 "Required executable \"kubectl\" not found on PATH.  Aborting."; exit 1; }
command -v yq >/dev/null 2>&1 || { echo >&2 "Required executable \"yq\" not found on PATH.  Aborting."; exit 1; }


kubectl whoami &> /dev/null
if [[ "$?" == "1" ]]; then
  echo "You must be logged in to your OpenShift cluster to proceed (oc login)"
  exit 1
fi


if [ "$MODE" == "backup" ]; then
    echo "Starting MAS Core backup using the instance id $MAS_INSTANCE_ID to $BACKUP_FOLDER"
    mkdir -p $BACKUP_FOLDER
    checkForCustomIssuer
    checkForManualCertMgmt
    backupSingleResource Subscription ibm-mas-operator
    backupSingleResource Secret ibm-entitlement
    backupSingleResource Secret $MAS_INSTANCE_ID-credentials-superuser
    backupSingleResource OperatorGroup ibm-mas-operator-group
    backupSingleResource Suite $MAS_INSTANCE_ID
    backupResources mongocfgs
    backupResources kafkacfgs
    backupResources jdbccfgs
    backupResources slscfgs
    backupResources bascfgs
    backupResources workspaces
    backupResources smtpcfgs
    backupResources watsonstudiocfgs
    backupResources objectstoragecfgs
    backupResources pushnotificationcfgs
    backupResources scimcfgs
    backupResources idpcfgs
    backupResources appconnects
    backupResources humai
    backupResources mviedges
elif [ "$MODE" == "restore" ]; then
     echo "Starting MAS Core restore of theinstance id $MAS_INSTANCE_ID from $BACKUP_FOLDER"
    if [ -d "$BACKUP_FOLDER" ]; then
        kubectl new-project $MAS_CORE_NAMESPACE
        for yamlFile in $BACKUP_FOLDER/*.yaml; do
            echo "Applying recouce from $yamlFile"
            kubectl apply -f $yamlFile
        done
    else 
        echo "MAS Core restore cannot complete. The folder $BACKUP_FOLDER does not exist."
    fi
else
    echo "Unknown mode $MODE specified. Valid values for mode are backup or restore."
fi