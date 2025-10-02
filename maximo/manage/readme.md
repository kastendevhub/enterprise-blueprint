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

We should follow this steps :[Using container commands - Db2uInstance](https://www.ibm.com/docs/en/db2/11.5.x?topic=restores-using-container-commands-db2uinstance) to restore from a previous backup.

But with kasten a simpler approach can be taken : 
1. delete the db2instance :
```
oc delete -f db2instance.yaml 
```
It will remove all artifacts created by the operator (pvc included)

2. with kasten we restore all the pvc + all the secrets 

3. with kasten we restore the db2uinstances and wait for all the pods to be ready 

```
NAME                                                READY   STATUS      RESTARTS   AGE
c-db2-example-db2u-0                                1/1     Running     0          26m
c-db2-example-etcd-0                                1/1     Running     0          27m
c-db2-example-restore-morph-2qpvf                   0/1     Completed   0          25m
db2u-day2-ops-controller-manager-5bdcbfd869-vtl6w   1/1     Running     0          5h21m
db2u-operator-manager-fdc864bd7-9nv59               1/1     Running     0          7h20m
```

4. Because we did a backup when all write operations were suspended we need to resume the write 
```
oc exec -it c-mas-masdev-masdev-manage-db2u-0 -n db2u -- bash
manage_snapshots --action resume
```


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


