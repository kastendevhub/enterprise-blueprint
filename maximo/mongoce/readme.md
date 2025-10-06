# Goal 

A blueprint to backup the mongoce database used by Maximo 

# How does it work 

We follow the IBM documentation for [backing up](https://www.ibm.com/docs/en/masv-and-l/cd?topic=suite-mongodb-maximo-application) and [restoring](https://www.ibm.com/docs/en/masv-and-l/cd?topic=suite-restoring-mongodb-maximo-application) the mongodb database. 

# Repro the nevironment

If you need to repro an environment close to the mongoce [we provide a guide](./repro-mongoce.md) that let you build a mongo instance with a very similar configuration than the one you'll find in maximo.

## Preliminary test

We will create a mongoce-backup pod which is a mongo client that will store the dump in it's own pvc before we backup the mongoce namespace.

```
oc create -n mongoce -f mongoce-backup.yaml
```

The operation you see here is what the blueprint will do. You can execute them to check if this is working in your own environment : 

```
oc exec -n mongoce -it mongoce-backup -- bash 

# in the pod create the dump of mas_{MAS_INSTANCE_ID}_core and mas_{MAS_INSTANCE_ID}_catalog

#adapt to your situation
MAS_INSTANCE_ID="masdev"

mongodump --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_${MAS_INSTANCE_ID}_core.archive -d mas_${MAS_INSTANCE_ID}_core

mongodump --uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin" --sslCAFile=/var/lib/tls/ca/ca.crt --archive=/data/mongo/dumps/mas_${MAS_INSTANCE_ID}_catalog.archive -d mas_${MAS_INSTANCE_ID}_catalog
```

Notice that by using the `--uri="mongodb://admin:$MONGO_ADMIN_PASSWORD@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/?replicaSet=mas-mongo-ce&tls=true&authSource=admin"` one doesn't need to look for the primary this url will always select the primary.

Once you finished your tests delete the pod and its pvc 
```
oc delete -f mongoce-backup.yaml
``` 

# Install and execute the blueprint 

## If you pull from a private registry or docker hub

Create a pull secret to pull the mongo:6.0 image.
```
kubectl create secret docker-registry my-dockerhub-secret \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  --docker-email=<your-email> \
  -n mongoce
```

Now link this pull secret to the default service account  
```
oc secrets link default my-dockerhub-secret --for=pull -n mongoce
```

If you need to add docker pull secret to the global openshift check the [documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html/images/managing-images#images-update-global-pull-secret_using-image-pull-secrets).


## Allow discovery of the `MAS_INSTANCE_ID`

we need to find a way to discover the MAS_INSTANCE_ID, always make sure you created the configmap mas-instance-id in the mongoce namespace

```
oc create configmap -n mongoce mas-instance-id --from-literal mas-instance-id=masdev
```

Then deploy the blueprint

```
oc create -f mongoce-blueprint.yaml 
```

The `preBackupHook` and `postBackupHook` must be applied before and after the policy execute.

The `postRestoreHookError` must be applied after the policy execute if there is an error during policy backup.

![Setting up pre and post backup hook](./pre-post-snapshot-actions-hook.png)

# Restoring 

For restoring we need to restore the mongoce-backup-pvc and recreate the mongoce-backup pod in the namespace mongoce. Once the pod is ready we trigger a mongorestore in a post restore hook: 

Configure the post restore hook including the post restore hook error.
![PostRestoreHook action](./postRestoreHook.png)

Then only restore the pvc by deselecting all artifacts but the PVC.
![Restore the mongoce-backup pvc and pod](./deselectAllArtifactsButBackupPVC.png)