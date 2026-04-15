# Goal 

An example of a cross instance restore operation.

# On the source cluster 

Create a backup 
```bash
BACKUP_DIR=/mnt/backup/backup
su - db2inst1 -c "db2 backup db BLUDB online to $BACKUP_DIR compress include logs"
```

Get the label used by the database 
```bash
su - db2inst1 -c "/mnt/blumeta0/home/db2inst1/sqllib/adm/db2pd -db BLUDB -encrypt" 
```

In the output of this command you get the master key label 
```
Master Key Label: DB2_SYSGEN_db2inst1_BLUDB_2026-03-19-01.33.01_8628446B
```

Notice that this is also this label that you can read on the /mnt/blumeta0/db2/keystore/keystore.p12
```bash
su - db2inst1 -c " ls /mnt/blumeta0/db2/keystore/"
su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -list -db /mnt/blumeta0/db2/keystore/keystore.p12 -stashed"
* default, - personal, ! trusted, # secret key
#       DB2_SYSGEN_db2inst1_BLUDB_2026-03-19-01.33.01_8628446B
```

Then create the raw file with its stached 
```bash
su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -export \
  -db /mnt/blumeta0/db2/keystore/keystore.p12 \
  -stashed \
  -label DB2_SYSGEN_db2inst1_BLUDB_2026-03-19-01.33.01_8628446B \
  -target /mnt/backup/backup/BLUDB-source.raw -target_type pkcs12 -target_stashed"
```

Take a backup with kasten and export. 
 
# On the destination cluster 

Scaled down manages namespaces.
```bash
kubectl get db2ucluster -n db2u -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read NAME; do
  MANAGE=$(echo "$NAME" | sed 's/^mas-\([^-]*\).*/\1/')
  MANAGE_NS=mas-$MANAGE-manage
  echo "Scaling down Maximo namespace: $MANAGE_NS"
  kubectl scale deployment --all -n "$MANAGE_NS" --replicas=0
  echo "Waiting 300s for all pods in $MANAGE_NS to terminate."
  sleep 5
  kubectl delete pod --all -n "$MANAGE_NS"
  kubectl wait pod --all -n "$MANAGE_NS" --for=delete --timeout=300s 2>/dev/null || true
  echo "Pods in $MANAGE_NS terminated."
done
```

and scale down db2u.
```bash
DB2U_NS=db2u
echo "Scaling down DB2u namespace: $DB2U_NS"
kubectl scale deployment --all -n "$DB2U_NS" --replicas=0 2>/dev/null || true
kubectl scale statefulset --all -n "$DB2U_NS" --replicas=0 2>/dev/null || true
for cronjob in $(kubectl get cronjob -o name -n "$DB2U_NS"); do kubectl patch $cronjob -n "$DB2U_NS" -p '{"spec":{"suspend":true}}'; done
kubectl delete pod --all -n $DB2U_NS
kubectl wait pod --all -n "$DB2U_NS" --for=delete --timeout=300s 2>/dev/null || true
echo "DB2u pods terminated."
```

With kasten, import only the backup pvc from the source, leave the others pvc untouched. Do not restore any other resources.

Scale up only db2u.
```bash
DB2U_NS=db2u
echo "Scaling up DB2u namespace: $DB2U_NS"
kubectl scale deployment --all -n "$DB2U_NS" --replicas=1 2>/dev/null || true
kubectl scale statefulset --all -n "$DB2U_NS" --replicas=1 2>/dev/null || true
for cronjob in $(kubectl get cronjob -o name -n "$DB2U_NS"); do kubectl patch $cronjob -n "$DB2U_NS" -p '{"spec":{"suspend":false}}'; done
echo "DB2u pods re-started."
```

Connect to the sts pod and import the key in the key store of the destination :
```bash
BACKUP_DIR=/mnt/backup/backup
su - db2inst1 -c "ls /mnt/blumeta0/db2/keystore/"
su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -list -db /mnt/blumeta0/db2/keystore/keystore.p12 -stashed"
su - db2inst1 -c "cp /mnt/blumeta0/db2/keystore/keystore.p12 /mnt/blumeta0/db2/keystore/keystore-previous.p12"
su - db2inst1 -c "cp /mnt/blumeta0/db2/keystore/keystore.sth /mnt/blumeta0/db2/keystore/keystore-previous.sth"
su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 \
   -cert -import -db $BACKUP_DIR/BLUDB-source.raw \
   -stashed -target /mnt/blumeta0/db2/keystore/keystore.p12 \
   -target_stashed -target_type pkcs12"
``` 

Check now that the keystore has the 2 labels/encryption the source and the destination 
```bash
su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -list -db /mnt/blumeta0/db2/keystore/keystore.p12 -stashed"
```

you should see something like this 
```
* default, - personal, ! trusted, # secret key
#       DB2_SYSGEN_db2inst1_BLUDB_2026-03-19-01.33.01_8628446B
#       DB2_SYSGEN_db2inst1_BLUDB_2026-04-14-15.05.32_27E00A05
```

find the timestamp of the backup 
```bash
TIMESTAMP=$(su - db2inst1 -c "ls $BACKUP_DIR/BLUDB.*.001 | sort | tail -1 | xargs basename | cut -d. -f5")
```

Now restore 
```bash
su - db2inst1 "db2 force application all"
su - db2inst1 "db2 terminate"
su - db2inst1 "db2 deactivate db bludb"
su - db2inst1 -c "db2 restore db bludb from $BACKUP_DIR taken at $TIMESTAMP replace existing without prompting"
su - db2inst1 "db2 rollforward db bludb to end of logs and complete"
```

scale up the manage namespaces 
```bash
kubectl get db2ucluster -n db2u -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read NAME; do
  MANAGE=$(echo "$NAME" | sed 's/^mas-\([^-]*\).*/\1/')
  MANAGE_NS=mas-$MANAGE-manage
  echo "Scaling up Maximo namespace: $MANAGE_NS"
  kubectl scale deployment --all -n "$MANAGE_NS" --replicas=1  
done
```
