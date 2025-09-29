# Goal 

A blueprint to backup the mongoce database used by Maximo 

# How does it work 

We follow the IBM documentation for [backing up](https://www.ibm.com/docs/en/masv-and-l/cd?topic=suite-mongodb-maximo-application) and [restoring](https://www.ibm.com/docs/en/masv-and-l/cd?topic=suite-restoring-mongodb-maximo-application) the mongodb database. 

# Install and execute the blueprint 

If you need to repro an environment close to the mongoce [we provide a guide](./repro-mongoce.md) that let you build a mongo instance with a very similar configuration.

## Test your blueprint before deploying it

We will create a mongoce-backup pod which is a mongo client that will store the dump in it's own pvc before we backup the mongoce namespace.

```
oc create -n mongoce -f mongoce-backup.yaml
```

The operation you see here is what the blueprint will do. You can execute them to check if this is working in your own environment : 

```
oc exec -n mongoce -it mongoce-backup -- bash 

# in the pod create the dump of mas_{MAS_INSTANCE_ID}_core and mas_{MAS_INSTANCE_ID}_catalog

MAS_INSTANCE_ID="dev"

mongodump --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_${MAS_INSTANCE_ID}_core.archive -d mas_${MAS_INSTANCE_ID}_core

mongodump --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_${MAS_INSTANCE_ID}_catalog.archive -d mas_${MAS_INSTANCE_ID}_catalog
```

Notice that by using the `--uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin"` one doesn't need to look for the primary this url will always select the primary.

Once you finished your tests delete the pod and its pvc 
```
oc delete -f mongoce-backup.yaml
``` 

## Deploy the blueprint 

```
oc create -f mongoce-blueprint.yaml 
```

The `preBackupHook` and `postBackupHook` must be applied before and after the policy execute.

![Setting up pre and post backup hook](./pre-post-snapshot-actions-hook.png)

# Restoring 

For restoring we need to restore the mongoce-backup pod and the mongoce-backup-pvc in the namespace mongoce and trigger a mongorestore: 

Configure the post restore hook 
![PostRestoreHook action](./postRestoreHook.png)

Then only restore the pvc and the pod 
![Restore the mongoce-backup pvc and pod](./restore-mongoce-pvc-pod.png)

Once the restore is finished exec the pod and execute the restore actions 

```
oc exec -it mongoce-backup -- bash 

mongorestore --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_dev_core.archive --drop

mongorestore --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_dev_catalog.archive --drop
```






