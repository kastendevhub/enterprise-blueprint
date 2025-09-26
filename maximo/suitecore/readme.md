# Goal 

- A blueprint to label all the components that need to be backed up in the namespace `mas-$MAS_INSTANCE_ID-core`

# Backing up the components in the `mas-$MAS_INSTANCE_ID-core` namespace

We follow the documentation for [backing up](https://www.ibm.com/docs/en/masv-and-l/cd?topic=namespace-backing-up-resources-manually) and [restoring](https://www.ibm.com/docs/en/masv-and-l/cd?topic=core-namespace) the application suite core that leads to a [backup and restore script](https://github.com/ibm-mas/cli/blob/master/image/cli/mascli/backup-restore/mascore-backup-restore.sh).

We change the script : instead of creating the resource manisfest yaml files in your machine we just label the resources with `kasten-backup=true`.

```
cd maximo/suitecore
./mascore-backup-restore.sh -i <MAS_INSTANCE_ID> -f ./ -m backup
```

Now, we only have to create a policy for the `mas-$MAS_INSTANCE_ID-core` namespace that include only resource that have the label `kasten-backup:true`.

## If you have a custom cert manager

If you have a custom cert manager you need to back it up in another policy.

To check if you are using a custom cert-manager, run the following command:
```
oc get Suite  $MAS_INSTANCE_ID -n $MAS_CORE_NAMESPACE -o yaml | yq '.spec | has("certificateIssuer")') 
```

If the result is `true` then review [mas-certmanager-policy.yaml](./mas-certmanager-policy.yaml) and apply it 
```
oc create -f mas-certmanager-policy.yaml
```

Edit the policy to add frequency, retention and a backup location.

# Restoring

Find the kasten restore point that contains the component you want to restore using the overwrite option.

Follow the [IBM documentation to validate](https://www.ibm.com/docs/en/masv-and-l/cd?topic=core-validating-restoration-maximo-application-suite) the restoration.
