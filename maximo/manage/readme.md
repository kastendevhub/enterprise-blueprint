# Goal 

- A blueprint to backup the db2 database in the db2u namespace 
- A blueprint to label all the components that need to be backed up in the namespace `mas-$MAS_INSTANCE_ID-manage`

# Backing up the manage database in db2u namespace

## Documentation reference

We follow the documentation reference for [backing up and restoring manage](https://www.ibm.com/docs/en/masv-and-l/cd?topic=manage-databases) -> [Backing up and restoring Db2](https://www.ibm.com/docs/en/db2/11.5.x?topic=ad-backing-up-restoring-db2) -> [Backing up a Db2 database](https://www.ibm.com/docs/en/db2/11.5.x?topic=db2-backing-up-database) which finally leads to [Performing a snapshot backup with Db2 container commands](https://www.ibm.com/docs/en/db2/11.5.x?topic=database-performing-snapshot-backup-db2-container-commands)

Where IBM recommand to perform a snapshot of the storage between a suspend and resume operation.

In order to validate the blueprint execute the following command 
```
oc exec -n db2u -it c-mas-masdev-masdev-manage-db2u-0 -- /bin/sh
manage_snapshots --action suspend
# do we have a way to not confirm the authenticity of the host manage_snapshots --help ?
# confirm HA monitoring is disabled 
wvcli system status

# here Kasten will take a snspshot of the PVCs

manage_snapshots --action resume
# confirm HA monitoring is enabled
wvcli system status
```

## Configure and deploy the blueprint 

If all those operations are successful then update the blueprint [db2u-blueprint.yaml](./db2u-blueprint.yaml) and 
apply it in the policy of the namespace db2u where you only backup the pvc.

The `preBackupHook` and `postBackupHook` must be applied before and after the policy execute.

## Restoring db2 

From the [documentation](https://www.ibm.com/docs/en/db2/11.5.x?topic=restoring-snapshot-restores)  we should put the database in maintenance mode, and restore the PVC. 

But if we follow the [detailed procedure](https://www.ibm.com/docs/en/db2/11.5.x?topic=restores-using-container-commands-db2ucluster), actually this is exactly what kasten do when you restore.

Depending of your specific configuration. We should just backup and restore this namespace with the blueprint for the backup.

# Backing up the components in the `mas-$MAS_INSTANCE_ID-manage` namespace

The [documentation](https://www.ibm.com/docs/en/masv-and-l/cd?topic=manage-namespace) leads to backing up the `mas-$MAS_INSTANCE_ID-manage` namespace with a [script](https://www.ibm.com/docs/en/masv-and-l/cd?topic=namespace-backing-up-maximo-manage-script) that can be found in [github](https://github.com/ibm-mas/cli/blob/master/image/cli/mascli/backup-restore/manage-backup-restore.sh)  

We have changed the script : instead of creating the resource manisfest yaml files in your machine we just label the resources with `kasten-backup=true`.

```
cd maximo/manage
mas-backup-restore.sh -i <MAS_INSTANCE_ID> -f ./ -m backup
```

Now, We only have to create a policy of the `mas-$MAS_INSTANCE_ID-manage` namespace that include only resources that have the label `kasten-backup:true`.

# Backing up attachments 

Just include the PVCs that store the attachments in the policy.

# Restoring 

Find the kasten restore point that contains the component you want to restore using the overwrite option.

Follow the [IBM documentation to validate](https://www.ibm.com/docs/en/masv-and-l/cd?topic=manage-validating-restoration-maximo) the restoration.


