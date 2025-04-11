# Architecture Reference for Using cass-operator (K8ssandra) with Kasten by Veeam

## Goal

This document explains how to integrate the cass-operator (K8ssandra) with Kasten by Veeam to perform effective backup and restore operations for a Cassandra cluster.

## Architecture Card

| Description                                   | Values                                                                      | Comment                                                                                                                                                   |
|-----------------------------------------------|-----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Database**                                  | Cassandra                                                                   |                                                                                                                                                           |
| **Database Version Tested**                   | Cassandra 4.0.1                                                             |                                                                                                                                                           |
| **Operator Vendor**                           | DataStax                                                                    | License is required for DSE                                                                                                                               |
| **Operator Vendor Validation**                | In progress                                                                 |                                                                                                                                                           |
| **Operator Version Tested**                   | Helm version 0.41.1, Cassandra Operator version v1.15.0                     |                                                                                                                                                           |
| **High Availability**                         | Yes by design                                                               | Cassandra is an active-active data service and features native data replication                                                                          |
| **Unsafe Backup & Restore**                   | No                                                                          | Unsafe backup/restore can lead to token errors. We do not recommend this approach. See [Unsafe Backup and Restore](../#unsafe-backup-and-restore)       |
| **PIT (Point In Time) Support**               | No                                                                          | We support incremental backups that provide a 5-minute RTO even for very large clusters                                                                   |
| **Blueprint and BlueprintBinding Example**    | Yes                                                                         |                                                                                                                                                           |
| **Blueprint Actions**                         | Backup & Restore                                                            | Deletion is done through restore point deletion since backup artifacts reside on their own PVC (one PVC per node)                                           |
| **Backup Performance Impact**                 | Full backups have a greater impact than incremental backups                 | See [Architecture Diagrams](#architecture-diagrams) for details                                                                                           |

## Limitations

- **PIT Restore Not Implemented:**  
  Point-in-time restore is not available—not due to a Cassandra limitation, but because field experience shows that incremental backups are sufficient, and avoiding PIT simplifies the design.
- **Sequential Backup within a Namespace:**  
  Datacenters in the same namespace are backed up sequentially. We recommend deploying one datacenter per namespace and using Kasten to parallelize backups.
- **Partial Support for K8ssandraCluster:**  
  The blueprint supports backup of CassandraDatacenter objects but not the entire K8ssandraCluster. The blueprint discovers and protects CassandraDatacenter resources even when created via a K8ssandraCluster. We have not verified whether a K8ssandraCluster might overwrite the annotations set by the blueprint.

## Architecture Diagrams

We based our blueprint on insights from this excellent [DataStax Guide](https://support.datastax.com/s/article/Manual-Backup-and-Restore-with-Pointintime-and-tablelevel-restore). In brief, we use an intermediate storage area to transfer backups and snapshots that Kasten then protects.

![Cassandra Backup Diagram](./images/cassandra-backup-example.png)

The Cassandra operator Custom Resource (CassandraDatacenter) allows you to define an additional storage volume for backup operations. For example:

```yaml
storageConfig:
  additionalVolumes:
  - mountPath: /backups
    name: backup
    pvcSpec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 10Gi
```

See the complete [datacenter.yaml](./datacenter.yaml) for a full example.

## Full vs. Incremental Backup

- **Incremental Backup:**  
  Each incremental backup flushes the table and copies the backups directory for every table.
- **Full Backup:**  
  A full backup creates a new Cassandra snapshot and cleans up the existing backup directory. Although you can perform an initial full backup and then incremental backups indefinitely, the backup directory may grow without bounds. Therefore, periodic full backups are necessary. Note that full backups are disk-intensive and impact Cassandra performance more than incremental backups.

In both cases, the data is removed from the Cassandra disk after being copied to the backup disk. **Ensure that the data disk has enough capacity to accommodate this temporary storage requirement.**

## Controlling Full vs. Incremental Backup

Backup strategy is managed by two annotations on the CassandraDatacenter custom resource:

```yaml
annotations:
  "kasten.io/counterIncrementalBackups": "5"
  "kasten.io/numIncrementalBackupsBeforeFullBackup": "24"
```

- The `kasten.io/counterIncrementalBackups` value is incremented at each backup.
- A full backup is triggered if:
  - The `kasten.io/counterIncrementalBackups` annotation is missing, **or**
  - Its value is greater than or equal to the value of `kasten.io/numIncrementalBackupsBeforeFullBackup`.  
    When this condition is met, the counter is reset to zero.

To manually trigger a full backup, remove the `kasten.io/counterIncrementalBackups` annotation:

```bash
kubectl annotate -n cass-operator cassandradatacenters.cassandra.datastax.com cass-prd kasten.io/counterIncrementalBackups-
```

> During restore, this annotation is removed to enforce that the next backup is a full backup.

## Installation Overview

There are two operators available:
- **k8ssandra operator:**  
  Manages CassandraDatacenter resources across multiple clusters and supports cross-cluster replication via a K8ssandraCluster custom resource.
- **cassandra operator:**  
  Manages CassandraDatacenter within a single cluster.

Although Kasten includes a built-in blueprint that leverages **Medusa** (the backup tool for k8ssandra), we do not use it because we focus on fast, granular restores based on snapshots. Medusa is not available when using just the cassandra operator.

When you install the k8ssandra operator, the cassandra operator is automatically installed. However, you can install the cassandra operator independently if desired. You can also install the k8ssandra operator and create only CassandraDatacenter resources—skipping the K8ssandraCluster.

## Installing Only the Cassandra Operator

1. **Add the k8ssandra Helm Repository:**

   ```bash
   helm repo add k8ssandra https://helm.k8ssandra.io/stable
   helm repo update
   ```

2. **Install cert-manager (if not already installed):**

   ```bash
   helm install \
     cert-manager jetstack/cert-manager \
     --namespace cert-manager \
     --create-namespace \
     --set installCRDs=true
   ```

3. **Install the Cassandra Operator:**

   ```bash
   helm install cass-operator k8ssandra/cass-operator -n cass-operator --create-namespace --version 0.41.1
   ```

4. **Create a CassandraDatacenter Cluster:**

   ```bash
   kubectl create -f datacenter.yaml
   ```

5. **Create Data:**

   Retrieve the superuser credentials:

   ```bash
   kubectl get secret dse-superuser -n cass-operator -o go-template='{{ .data.username | base64decode }}'
   kubectl get secret dse-superuser -n cass-operator -o go-template='{{ .data.password | base64decode }}'
   ```

   Then, connect to the first Cassandra pod:

   ```bash
   kubectl exec -it dse-cass-prd-default-sts-0 -- bash
   cqlsh -u dse-superuser -p <password>
   ```

   Example CQL commands to create data:

   ```cql
   CREATE KEYSPACE restaurants WITH replication = {'class':'SimpleStrategy', 'replication_factor': 3};
   CREATE TABLE restaurants.guests (
       id UUID PRIMARY KEY,
       firstname text,
       lastname text,
       birthday timestamp
   );
   INSERT INTO restaurants.guests (id, firstname, lastname, birthday)
       VALUES (uuid(), 'Michael', 'Courcy', '1972-11-22');
   INSERT INTO restaurants.guests (id, firstname, lastname, birthday)
       VALUES (uuid(), 'Michael', 'Cycour', '1972-11-22');
   INSERT INTO restaurants.guests (id, firstname, lastname, birthday)
       VALUES (uuid(), 'Mic', 'Cour', '1972-11-22');
   SELECT * FROM restaurants.guests;
   ```

   **Tip:** To generate a valid UUID in bash, use:

   ```bash
   generated_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
   echo $generated_uuid
   ```

## Manual Backup and Restore Process

It is recommended to test the backup and restore process manually before running it via Kasten. This helps in troubleshooting and ensures that you understand the blueprint’s behavior.

### Backup

1. **Pre-Backup:** Run the pre-backup script:

   ```bash
   bash ./scripts/cassandra_before_backup.sh cass-operator
   ```

   This script creates backup data on each cluster’s backup PVC.

2. **Post-Backup:** Run the post-backup script:

   ```bash
   bash ./scripts/cassandra_after_backup.sh cass-operator
   ```

   This script updates the incremental counter annotation and is executed only if previous steps succeed. These scripts are integrated into the blueprint ([cassandradatacenter-bp.yaml](./cassandradatacenter-bp.yaml)) under the respective `beforeBackup` and `afterBackup` actions.

   To use these with Kasten, create hooks in your backup policy:

   ![Backup Hooks](./images/before-after-backup.png)

### Restore

After the backup PVCs are restored by Kasten, execute the following scripts:

1. **Pre-Restore:** Run the pre-restore script:

   ```bash
   bash ./scripts/cassandra_before_restore.sh cass-operator
   ```

   (This script is currently a placeholder.)

2. **Post-Restore:** Run the post-restore script:

   ```bash
   bash ./scripts/cassandra_after_restore.sh cass-operator
   ```

   This script copies the backup folder into the correct location on the Cassandra filesystem and calls `nodetool refresh`. These are integrated into the blueprint ([cassandradatacenter-bp.yaml](./cassandradatacenter-bp.yaml)) under the `beforeRestore` and `afterRestore` actions.

   Add the pre-restore and post-restore hooks to your restore policy:

   ![Restore Hooks](./images/before-after-restore.png)

## Deploying the Blueprints

1. **Install the Kasten Blueprints for Cassandra:**  
   Override the built-in Cassandra blueprint since we do not use the Medusa approach:

   ```bash
   kubectl create -f k10-k8ssandra-bp-0.0.4.yaml
   kubectl create -f k10-k8ssandra-bp-0.0.4-binding.yaml
   ```

2. **Install the Cassandra Hooks Blueprint:**

   ```bash
   kubectl create -f cassandradatacenter-bp.yaml
   ```

## Building the Backup Policy

**Exclude the Following:**

- **PVCs:**  
  Exclude `server-data-*` PVCs:  
  1. They aren’t used in restoration—excluding them conserves backup storage and snapshot space.
  2. You want Cassandra to restart with an empty data set so that you can recreate the schema and load data.
  
- **StatefulSets:**  
  Exclude StatefulSets created by the operator to prevent conflicts between Kasten and the operator’s management.

**Hooks:**  
Include before/after backup hooks in your backup policy.

![Backup Hooks](./images/before-after-backup.png)

Refer to the policy example below:

![Policy Example for Cassandra](./images/policy.png)

## Building Your Restore Action

To test your restore, you can delete the CassandraDatacenter resource, which will remove all PVCs created by the operator:

```bash
kubectl delete -f datacenter.yaml
```

For restore, simply add the pre-restore and post-restore hooks to your policy:

![Restore Hooks](./images/before-after-restore.png)

### Granular Restore of a Keyspace or Table

You can perform a granular restore of a specific keyspace or table using the "Volume Clone Restore" option in the restore point. This creates timestamp-appended clones of the selected volumes without replacing the existing ones, enabling you to selectively copy data into the `server-data-*` PVC.  
**Warning:** This operation requires advanced Cassandra knowledge and should be performed only by experienced users.

Happy backing up and restoring!