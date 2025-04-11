# Enterprise Blueprints

## Goal

Enterprise Blueprints is a repository of architectural references designed to integrate Kasten by Veeam with leading data services operators.

## Motivation

Migrating databases to Kubernetes offers numerous benefits, including:

- Co-location and security
- Agility
- Ease of deployment
- Self-healing
- Cost efficiency
- Microservices architecture
- Scalability
- Resilience

With Kubernetes' operator pattern, deploying high-availability data services that meet enterprise requirements has become much easier. Nearly all major database vendors or specialists now provide operators that encapsulate their expertise.

## Supported Operators

We provide architectural references for integrating Kasten with the following data services/vendors:

- [MSSQL/DH2I](./dh2i/)
- Elasticsearch
- MongoDB/Mongo-Enterprise
- MongoDB/Percona
- [PostgreSQL/EDB](./edb)
- PostgreSQL/Crunchy
- MySQL/Oracle
- MySQL/Percona
- Kafka/Strimzi
- Kafka/Confluent
- [Cassandra/K8ssandra](./k8ssandra/)

## Five Principles Guiding Enterprise Blueprints

Each architectural reference adheres to these five core principles:

### 1. Always Choose an Enterprise Database Operator

We prioritize enterprise database operators developed by vendors recognized as market leaders in database expertise and Kubernetes deployments. Having access to vendor support before or after deployment is essential when managing critical company data.

While we recommend open-source solutions, we only support those backed by a reputable vendor. We outline how operators should be deployed to work seamlessly with Kasten by Veeam, specifying both the operator and database versions. 

Depending on the collaboration with the vendor, we may request validation of the architectural reference document. All data services are deployed in high-availability mode, ensuring compatibility with Kasten. We also provide failover testing scenarios.

### 2. Backup Using Snapshots Whenever Possible

Backing up with storage snapshots offers two key advantages:

- Kasten excels in managing snapshots. A snapshot-based backup blueprint simplifies your architecture by offloading consistency, retention, protection, immutability, incrementality, and portability management to Kasten.
- Local snapshots enable faster restores, which are critical for most enterprise use cases.

If the vendor doesn’t support snapshotting database disks, we use vendor backups stored on an additional Persistent Volume Claim (PVC), which is then snapshotted.

### 3. Perform Backups on a Read Replica When Possible

To minimize backup impact on applications, we use read replicas whenever feasible. This approach allows operations like properly shutting down or fencing the replica to ensure no dirty pages remain. Once the backup is complete, the replica is resynchronized with the primary.

### 4. Leverage Point-in-Time (PIT) Restore Capabilities When Possible

If PIT restore is supported, we make every effort to enable it. While this may increase blueprint complexity, the benefits outweigh the effort. Note that using snapshots is compatible with PIT restores since log files are included in the snapshot process.

### 5. Focus on Comprehensive Restore Documentation When Automation Is Too Complex

Backups are frequent, automated operations with minimal impact on applications. In contrast, restores are rare, high-stress operations that involve writes (and sometimes overwrites) and can significantly impact applications. 

Pre-restore operations may be required, and in some cases, in-place restores may not be supported due to design or field-learned limitations. When automation isn't feasible, we provide detailed, step-by-step documentation for manual restores.

**While we ensure detailed restore documentation, full automation is not always guaranteed.**

## Blueprint Examples

Kasten enables safe backup and restore workflows for your databases by extending workflows with [Blueprints](https://docs.kanister.io/architecture.html#architecture). 

Blueprints capture data-service expertise in a sequence of reusable functions, which can be applied across clusters using blueprint bindings. Each architectural reference includes a blueprint example for testing, understanding, and customizing.

These examples are intended to be adapted to your specific deployment. If you configure the database differently from the reference architecture, the provided blueprint may need modifications, which is expected.

## This Repository Is Not the Kanister Example Repository

Blueprints are provided by the [Kanister project](https://docs.kanister.io/overview.html). The Kanister project maintains [an excellent example repository](https://github.com/kanisterio/kanister/tree/master/examples) for various data services.

The Enterprise Blueprints repository builds upon Kanister while integrating Kasten, offering features that go beyond Kanister's capabilities, including:

- Auto-discovery and metadata capture
- Auto-discovery and data capture via the Kasten Data Mover
- Migration support
- Polyglot backup with blueprint binding
- Disaster recovery
- Immutability
- Fast restores from snapshots
- A GUI with authentication and authorization

…and more.

# Unsafe backup and restore

In the different blueprints example we'll speak of unsafe backup and restore. This section describe what is unsafe backup and restore.

An Unsafe backup and restore consist of capturing the namespace that contains the database without any extended behaviour 
from Kasten (freeze/flush or logical dump) by just backing up using the standard Kasten workflow. Then restore it to see if database : 
1. Restarts and can accept new read/write connections 
2. Is in a state consistent with the state of the database at the backup but this is very difficult to check 

## Should I rely on unsafe backup and restore ?

Short answer : No !!

Long answer : Database are designed to restart after a crash and Kasten take crash consistent backup. Hence the quality of your 
restore will be similar to a restart after a crash.

**With unsafe backup and restore your workload may restart but silent data loss can occur with no error message to let you know.**

## So what's the point with unsafe backup and restore ? 

If you don't have the time to implement a blueprint for your database, unsafe backup and restore is always better than nothing ... 
Actually it's far better than nothing. But your backup may be dirty and you'll see it just after a restoration. It's why later we will use 
our extension mechanism (blueprint) to take proper backups.
