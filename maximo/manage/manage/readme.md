# Goal

Explain how the namespace `mas-$MAS_INSTANCE_ID-manage` should be backed up

# Backup 

Create a policy that backs up the whole namespace. 

If the PVCs support CSI snapshots just backup as usual.

If the PVCs are CephFS you'll have to use [Shallow volume configuration](../../../ceph/cephfs/)

## If the PVCs do not support CSI snapshots

We do not encourage the use of [Generic Storage Backup](../../../gsb/) because: 

- Sidecar injection must be done on a lot of workloads and it's difficult to maintain, maintaining all the deployment injection is a daunting task
- GSB on openshift always creates security challenges and [proper setting must be engaged](../../../gsb/)
- Once you have injected the container, any update of Kasten will require that you upgrade all the injected containers
- You may have to review requests and limits for your pods now that they embed the data mover container

Instead exclude all the PVCs in the policy and use VBR (Veeam Backup and Replication) to treat the files share as a NAS. For instance in this [knowledge base](https://www.veeam.com/kb4011) you'll see how to configure VBR to backup azure file shares. We also provide a [detailed guide](./VBR_Azurefileshare_Kub.pdf) for step by step configuration for azure file share. 

If you use VBR however you need to map the name of the physical volume with the name of the PVC in the maximo namespace so that 
you know in which VBR backup you need to restore the files. You can easily save this info in a config map before you start a backup using the 
[pvc-info blueprint](https://github.com/michaelcourcy/kasten-claude/tree/main/pvc-info).
 
# Restore

First restore only the top objects ManageWorkspace, ManageDeployment, ManageBuild  with "overwrite existing". This will ensure a consistent reconciliation when reconciliation will start. 

But the reconciliation is a long process (involving the rebuild of all the images), in order to get back quickly the application 
scale down all the deployments in the manage namespace 

```
oc scale --replicas 0 deployment --all -n mas-${MAS_INSTANCE_ID}-manage
```

Then restore with "overwrite existing" and unselect the pod and certificateRequest resource if it is present in the restore point. 

## If you manage the backup of the PVCs with VBR 

In this situation the PVCs are already excluded from the restore point, and those PVCs won't be recreated by Kasten. If the restoration of the files 
inside those PVCs are needed they should be handled with VBR.

## If you use S3 or Azure blob storage for your files 

The configuration of your s3 or azure blob storage is saved in the manage database, as soon as you restore it Manage will reconnect to this object storage.







