# DB2u / IBM Maximo — Kasten Blueprint

Kasten blueprint for backing up and restoring IBM DB2 running under the DB2u operator inside an
IBM Maximo Application Suite (MAS) environment.

---

## Versions

| Component | Version |
|---|---|
| Kubernetes | `1.31.10` (OpenShift / OCS) |
| Kasten | `8.5.5` |
| DB2u operator | `db2u.databases.ibm.com/v1` |
| DB2 | `11.5.9.0-cn6` (image tag `s11.5.9.0-cn6`) |
| IBM Maximo Application Suite | MAS 9.x |

---

## Architecture overview

DB2 is deployed by the DB2u operator as a `Db2uCluster` CR. Each cluster creates:

| PVC | Mount | Access mode | Storage class | Kasten snapshotted |
|---|---|---|---|---|
| `c-<name>-meta` | `/mnt/blumeta0` | RWX | `ocs-storagecluster-cephfs` | Yes |
| `data-<name>-db2u-0` | `/mnt/bludata0` | RWO | `ocs-storagecluster-ceph-rbd` | Yes |
| `c-<name>-backup` | `/mnt/backup` | RWX | `ocs-storagecluster-cephfs` | Yes |
| `activelogs-<name>-db2u-0` | `/mnt/blulogs0` | RWO | `ocs-storagecluster-ceph-rbd` | Yes |
| `tempts-<name>-db2u-0` | `/mnt/blutempts0` | RWO | `ocs-storagecluster-ceph-rbd` | Yes |

Those storage class can change depending of your installation.

The blueprint uses [**Pattern 3A — database snapshot on a permanent backup PVC**](https://github.com/michaelcourcy/kasten-claude/blob/main/kasten-kanister.md#3-database-snapshot-on-a-permanent-pvc-sub-case-a--pvc-mounted-by-workload). The `backupPrehook`
runs `db2 backup db BLUDB online … include logs` inside the DB2u engine pod, writing the backup
image to the backup PVC at `/mnt/backup/backup/`. Kasten then snapshots all PVCs (including the
backup PVC). 

The blueprint does not implement the restore phase, the restore is described later on [the restore steps section](#restore-steps).

**Blueprint binding approach:** The blueprint is bound to the `Db2uCluster` CR (the top-level
resource in the DB2u operator ownership chain: `Db2uCluster → Formation → StatefulSet`). The
recommended approach is to annotate the `Db2uCluster` CR directly. A `BlueprintBinding` targeting
`db2uclusters` is also provided as a fleet automation mechanism.

---

## Backup strategy — encryption keystore

DB2 encrypts the database at rest and the backup image using a PKCS12 keystore stored at
`KEYSTORE_LOCATION` (typically `/mnt/blumeta0/db2/keystore/keystore.p12`). The backup image
cannot be restored without the matching keystore — `db2 restore` will fail with a decryption error
if the keystore has changed since the backup was taken.

**What the blueprint does:**

* `backupPrehook` copie the label and encryption master key alongside the backup image *before* 
  Kasten takes the snapshot. The backup PVC therefore always holds a matched pair (image + key).
* `restorePosthook` is for the moment manual and described in this document, it must be executed
  after the backup PVC is restored and db2u restored.

**SSL keystore (not backed up):** The DB2 SSL keystore (`bludb_ssl.kdb`) is stored on the meta PVC
and is intentionally *not* copied to the backup PVC because for cross-instance restore we need the 
client (in the manage namespace) to continue to trust the certificate exposed by db2. In other
words we restore only the data.

---

## One-time prerequisite — enabling archive logging

DB2 defaults to circular logging (`LOGARCHMETH1=OFF`). Circular logging blocks online backups.
Archive logging must be enabled via the `Db2uCluster` CR so the operator does not overwrite it
on the next reconciliation:

```bash
kubectl patch db2ucluster mas-instance1-workspace1-manage -n db2u \
  --type=merge \
  --patch '{
    "spec": {
      "environment": {
        "database": {
          "dbConfig": {
            "LOGARCHMETH1": "DISK:/mnt/backup/archivelog/"
          }
        }
      }
    }
  }'
```

> **Important:** Do NOT use `db2 update db cfg` directly — the operator will overwrite it on the
> next reconciliation. Always change `dbConfig` values through the `Db2uCluster` CR.

After the patch, verify the operator has applied it:
```bash
kubectl exec -n db2u c-mas-instance1-workspace1-manage-db2u-0 -c db2u -- \
  su - db2inst1 -c "db2 get db cfg for BLUDB | grep -i LOGARCHMETH"
```

Expected output:
```
First log archive method                 (LOGARCHMETH1) = DISK:/mnt/backup/archivelog/
```

**Mandatory initial offline backup:** After enabling archive logging for the first time, DB2
enters `BACKUP PENDING` state and refuses online operations until an offline backup is taken:

```bash
kubectl exec -n db2u c-mas-instance1-workspace1-manage-db2u-0 -c db2u -- \
  su - db2inst1 -c "
    db2 force applications all
    db2 deactivate db BLUDB
    mkdir -p /mnt/backup/backup /mnt/backup/archivelog
    db2 backup db BLUDB to /mnt/backup/backup compress
    db2 activate db BLUDB
  "
```

This one-time offline backup clears the `BACKUP PENDING` state. All subsequent backups run by
Kasten will be online backups with `INCLUDE LOGS`.

---

## Test data

The DB2 database (BLUDB) and all Maximo application data are pre-provisioned by MAS. No
installation is required. To validate backup/restore, alter a description field in the database:

```bash
kubectl exec -n db2u c-mas-instance1-workspace1-manage-db2u-0 -c db2u -- \
  su - db2inst1 -c "
    db2 connect to BLUDB
    db2 \"UPDATE MAXIMO.MAXVARS SET VARVALUE='KASTEN_TEST_MARKER' WHERE VARNAME='MAXUPG'\"
    db2 disconnect all
  "
```

Verify the change:
```bash
kubectl exec -n db2u c-mas-instance1-workspace1-manage-db2u-0 -c db2u -- \
  su - db2inst1 -c "
    db2 connect to BLUDB
    db2 \"SELECT VARVALUE FROM MAXIMO.MAXVARS WHERE VARNAME='MAXUPG'\"
    db2 disconnect all
  "
```

After restore, re-run the select and confirm `KASTEN_TEST_MARKER` is gone (original value restored).

---

## Blueprint actions

| Action | Trigger | Description |
|---|---|---|
| `backupPrehook` | Before Kasten PVC snapshots | Removes previous backup image; runs online `db2 backup … include logs` to `/mnt/backup/backup/`; copies `keystore.p12` + `keystore.sth` alongside backup image; calls `sync` |
| `backupPosthook` | After Kasten PVC snapshots | Verifies backup image and `keystore.p12` are present on the backup PVC |

---

## Deploying the blueprint

```bash
kubectl apply -f blueprint.yaml
kubectl apply -f blueprintbinding.yaml
```

---

## Running a backup via Kasten

1. Create a Kasten backup policy for the `db2u` namespace with a **Location** profile (S3, GCS,
   Azure Blob, etc.) and run on demand.
2. Kasten discovers all PVCs attached to the `c-mas-instance1-workspace1-manage-db2u-0`
   StatefulSet, calls `backupPrehook`, takes CSI snapshots, then calls `backupPosthook`.
3. Check blueprint execution in the Kanister logs:
   ```bash
   kubectl logs -n kasten-io -l component=kanister --tail=10000 -f | grep -oP "Out\":\"\K(.*?)\""
   ```

--- 

## Restore steps 

### On the source cluster 

The blueprint take care of backing up the database and the encrytion key in the backup pvc. 

### On the destination cluster 

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

Wait for all pods to be ready and connect to the sts pod (eg: c-mas-instance1-workspace1-manage-db2u-0):

```bash
BACKUP_DIR=/mnt/backup/backup
```

> **If you are doing a cross instance restore execute those steps**
> ```bash
> su - db2inst1 -c "ls /mnt/blumeta0/db2/keystore/"
> su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -list -db /mnt/blumeta0/db2/keystore/keystore.p12 -stashed"
> su - db2inst1 -c "cp /mnt/blumeta0/db2/keystore/keystore.p12 /mnt/blumeta0/db2/keystore/keystore-previous.p12"
> su - db2inst1 -c "cp /mnt/blumeta0/db2/keystore/keystore.sth /mnt/blumeta0/db2/keystore/keystore-previous.sth"
> su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 \
>   -cert -import -db $BACKUP_DIR/BLUDB-source.raw \
>   -stashed -target /mnt/blumeta0/db2/keystore/keystore.p12 \
>   -target_stashed -target_type pkcs12"
> ``` 
> 
> Check now that the keystore has the 2 labels/encryption: the source and the destination 
> ```bash
> su - db2inst1 -c "/opt/ibm/db2/V11.5.0.0/gskit/bin/gsk8capicmd_64 -cert -list -db /mnt/blumeta0/db2/keystore/keystore.p12 -stashed"
> ```
> 
> you should see something like this 
> ```
> * default, - personal, ! trusted, # secret key
> #       DB2_SYSGEN_db2inst1_BLUDB_2026-03-19-01.33.01_8628446B
> #       DB2_SYSGEN_db2inst1_BLUDB_2026-04-14-15.05.32_27E00A05
> ```

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

---

## Cleanup

Remove restore point content for the test namespace:
```bash
kubectl delete restorepointcontent -l k10.kasten.io/appNamespace=db2u
```

Remove the blueprint and binding:
```bash
kubectl delete -f blueprintbinding.yaml
kubectl delete -f blueprint.yaml
```
