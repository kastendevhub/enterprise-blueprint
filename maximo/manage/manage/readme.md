# Goal

Explain how the namespace `mas-$MAS_INSTANCE_ID-manage` should be backed up

# Backup 

Create a policy that backup the whole namespace. 

If the PVC support CSI snapshot just backup as usual.

If the PVC are CephFS you'll have to use [Shallow volume configuration](../../../ceph/cephfs/)

## If the PVCs does not support CSI snapshots 

We do not encourage the use of [Generic Storage Backup](../../../gsb/) because: 

    - Sidecar injection must be done on a lot of workloads and it's difficult to maintain, 
      maintaining all the deployment injection is a daunting task
    - GSB on openshift always create security challenges and [proper setting must be engaged](../../../gsb/)
    - Once you have injected the container any update of Kasten will require that you ugrade all the injected containers
    - You may have to review request and limit for your pods now that they embed the data mover container

Instead exclude all the PVCs in the policy and use VBR (Veeam Backup and Replication) to treat the files share as a NAS. For instance in this [knowledge base](https://www.veeam.com/kb4011) you'll see how to configure VBR to backup azure file shares.

If you use VBR however you need to map the name of the physical volume with the name of the PVC in the maximo namespace so that 
you know in which VBR backup you need to restore the files. You can easily save this info in a config map before you start a backup using the 
[pvc-info blueprint](https://github.com/michaelcourcy/kasten-claude/tree/main/pvc-info).
 
# Restore

You can granulary restore manifest from a restore point. 

## If you backup the files with Kasten

You can granulary restore a file or a whole filesystem using [File Recovery session](https://docs.kasten.io/latest/usage/restorefiles/#filerecoverysession-example). You can use this [helper script](https://github.com/michaelcourcy/kasten-calibrate/blob/main/explorer.md) to create a file recovery session pod that attached the pvc you want to restore.

Directly restoring a PVC is complex because you need to scale down all the deployment to release the PVCs, but those 
deployments are controlled by all the maximo operator controller and this is a daunting task to stop all the reconcile process. The best 
approach we tested for the moment is the file level recovery.

## If you backup the files with VBR 

You can restore directly using VBR.

For instance if you want to restore doclinks from a source cluster to the DR cluster 

| Cluster | PVC | PV |
|---|---|---|
| Source | instance1-workspace1-doclinks | pvc-75de996e-552d-417c-bae3-9ca922f573e2 |
| Disaster | instance1-workspace1-doclinks | pvc-4f057762-7acb-4713-ba16-199ab69c90ea |

You can use VBR to copy the content of the pvc-75de996e-552d-417c-bae3-9ca922f573e2 *backup* into the  pvc-4f057762-7acb-4713-ba16-199ab69c90ea *share*.

You can obtain the mapping between the source PVC / Source PV by reading the config map created by the [pvc-info blueprint](https://github.com/michaelcourcy/kasten-claude/tree/main/pvc-info).

# If you use S3 or Azure blob storage for your files 

TODO : identify in which resource the S3 or azure storage is defined and restore it.







