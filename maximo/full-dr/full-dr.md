# Full DR 

We call full DR the restoring of your maximo instance on another cluster. 

We suppose that you got on this new cluster all the Kasten restorepoints 
created on the previous cluster by either an [import policy](https://docs.kasten.io/latest/usage/migration/) or through a Kasten [disaster recovery action](https://docs.kasten.io/latest/operating/dr#dr-recovery) those topics are not the object of this document.

# General approach 

Restoring on the new cluster by applying all the restorepoints in a single action does not work. 

That would be indeed the ideal approach and the less complex but it does not align with the relative complexity of the Maximo application :
- Installation of Maximo follow a strict pipeline and reapplying all the manifest 
blindly without taking in account this pipeline order does not work
- Not only the pipeline folllow a strict order but a lot of objects are created by 
operator controller. This create a complex chain of dependency between object. Restoring all together create a simultaneous children and parent birth leading to potential reconciliation errors. 
- A lot of certificates managed by the cert-manager instance installed on your 
previous  openshift cluster won't validate anymore leading to complex rebuilding and reconfiguration of your application.

The approach consist in re-installing (not restoring) Maximo with the same 
configuration that used on your previous cluster. Then you restore component by components. We'll describe thos steps in the rest of this document. 

# Reinstall maximo on the new cluster 

Depending on how you install Maximo, with a full devops maintained pipeline or using the CLI. Apply the same installation process on the new cluster. Once your new maximo installation is ready you can proceed with the restore of the different component.

# Restore the components 

You must follow this order for the component you need to restore.

## 1. Restore MongoCE database

Follow the restore proecedure describe in the [mongoce](./mongoce/)

## 2. Restore the manage database 

If you're using DB2U (built in database for manage) follow the [DB2U restore guide](./manage/db2u/readme.md#restoring-db2)


## 3. Restore crypto key 

Whatever the database you choose for the manage database (DB2U or Oracle/MSSQL/...)
Crypto key are used to encrypt sensible information and in order to restore the crypto key consistently we must restore in the manage namespace. the secret 

```
<workspace>-manage-encryptionsecret in the mas-<instance>-manage.
```

You'll find this secret in the manage restorepoint of the previous cluster.

 Once this secret has been restored restart the pod `<instance>-<workspace>-manage-maxinst-xxxxxx-yyyyy` that will update the the old field.

Check in the container the old field has been updated by checking the file "/opt/IBM/SMP/maximo/applications/maximo/properties/maximo.properties"

![Inside the manage-maxinst container](./manage-maxinst.png)

## Restoring attachments 

Follow the [restore section](./manage/manage/readme.md#restore) of the manage guide.

https://ibm-mas.github.io/cli/guides/backup-restore/
https://ibm-mas.github.io/cli/commands/backup/#default-values


