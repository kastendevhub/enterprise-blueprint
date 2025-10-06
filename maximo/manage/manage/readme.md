# Goal 

A blueprint to label all the components that need to be backed up in the namespace `mas-$MAS_INSTANCE_ID-manage`

# How does it work 

The [documentation](https://www.ibm.com/docs/en/masv-and-l/cd?topic=manage-namespace) leads to backing up the `mas-$MAS_INSTANCE_ID-manage` namespace with a [script](https://www.ibm.com/docs/en/masv-and-l/cd?topic=namespace-backing-up-maximo-manage-script) that can be found in [github](https://github.com/ibm-mas/cli/blob/master/image/cli/mascli/backup-restore/manage-backup-restore.sh)  


## Preliminary test 

We have changed the script : instead of creating the resource manisfest yaml files in your machine we just label the resources with `kasten-backup=true`.

```
cd maximo/manage
mas-backup-restore.sh -i <MAS_INSTANCE_ID> -f ./ -m backup
```

Now, We only have to create a policy of the `mas-$MAS_INSTANCE_ID-manage` namespace that include only resources that have the label `kasten-backup:true`.

TODO Image 

For backing up the attachment just include the PVCs that store the attachments in the policy.

TODO Image 

# Install and execute the blueprint 

TODO

# Restoring 

Find the kasten restore point that contains the component you want to restore using the overwrite option.

Follow the [IBM documentation to validate](https://www.ibm.com/docs/en/masv-and-l/cd?topic=manage-validating-restoration-maximo) the restoration.


