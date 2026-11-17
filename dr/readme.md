# Understand the KDR restore point versions

When you create a `KastenDRReview` to prepare a Kasten Disaster Recovery (KDR) restore, each restore point comes with a `version`: `v3`, `v3.2_metadata`, `v3.2_data` or `v2`. This page explains what these versions really mean, what each KDR mode produces, and which restore point id to use in a `KastenDRRestore`.

> Tested with Kasten 9.0.10. For each [Quick DR](https://docs.kasten.io/latest/operating/dr/#enable-quick-dr) mode, the KDR policy was run several times against its own bucket, then a `KastenDRReview` was created and compared with the raw kopia snapshots in the bucket. Legacy DR (`v2`) is deprecated and not covered.

## 1. What a KDR policy run produces

Forget the versions for a moment. A KDR policy run can produce up to three things:

| | What | Produced when | In the `KastenDRReview` |
|---|---|---|---|
| **A** | **Catalog metadata export**: a small kopia snapshot (`k10backup.json`) with the Kasten resources (policies, profiles, secrets, ...), the master keys and the minimal catalog data needed to rebuild the exported restore points | always | a restore point, version **`v3`** or **`v3.2_metadata`** |
| **B** | **Local catalog snapshot**: a snapshot of the catalog PVC, kept on the cluster storage | `takeLocalCatalogSnapshot: true` | **not** a restore point. It shows as flags on **A**: `localSnapshotTaken` and `validSnapshotAvailable` |
| **C** | **Exported catalog snapshot**: the content of the catalog PVC exported to the repository | `exportCatalogSnapshot: true` | a separate restore point, version **`v3.2_data`**, paired with **A** |

The versions then follow one simple rule:

- **`v3`**: **A** alone, with no exported catalog.
- **`v3.2_metadata`**: **A** written together with a **C**.
- **`v3.2_data`**: the **C** of that pair.

So `v3` says nothing about the local catalog snapshot. Only the flags do.

> The [KastenDRReview API reference](https://docs.kasten.io/latest/api/dr#kastendrreview-api-type) maps the versions to the modes differently (`v3` = Local Catalog Snapshot, `v3.2_metadata` = No Catalog Snapshot). That is not what Kasten produces: the No Catalog Snapshot mode gives `v3`, not `v3.2_metadata`.

## 2. What each mode writes

| Mode (UI option) | `kdrSnapshotConfiguration` | A | B | C | Review shows, per policy run |
|---|---|:-:|:-:|:-:|---|
| [Local Catalog Snapshot](https://docs.kasten.io/latest/operating/dr/#quick-dr-local-catalog-snapshot) (default)<br>*Create local catalog snapshots only* | `takeLocalCatalogSnapshot: true` | ✅ | ✅ | | 1 × `v3`, `localSnapshotTaken: true` |
| [Exported Catalog Snapshot](https://docs.kasten.io/latest/operating/dr/#quick-dr-exported-catalog-snapshot)<br>*Export local catalog snapshots* | `takeLocalCatalogSnapshot: true`<br>`exportCatalogSnapshot: true` | ✅ | ✅ | ✅ | 1 × `v3.2_metadata`, `localSnapshotTaken: true`<br>1 × `v3.2_data`, `exportedCatalogAvailable: true` |
| [No Catalog Snapshot](https://docs.kasten.io/latest/operating/dr/#quick-dr-no-catalog-snapshot)<br>*Disable local catalog snapshots* | `{}` | ✅ | | | 1 × `v3`, `localSnapshotTaken: false` |

The Exported Catalog Snapshot mode also needs an export action in the policy (see [Sample policies](#sample-policies)).

## 3. What you can recover, and which id to use

What a KDR restore can bring back:

- **Kasten resources**: policies, profiles, secrets, blueprints and other Kasten custom resources;
- **Exported restore points**;
- **Local restore points and action history**: these need the full catalog, so they come either from **B** (local snapshot) or from **C** (exported catalog).

| Mode | Restore in place (original cluster) | Restore on another cluster |
|---|---|---|
| Local Catalog Snapshot | `v3` id → **everything**, from **B** | `v3` id → Kasten resources + exported restore points only |
| Exported Catalog Snapshot | `v3.2_metadata` id → **everything**, from **B**<br>or `v3.2_data` id → **everything**, from **C** | `v3.2_data` id → **everything**, from **C** |
| No Catalog Snapshot | `v3` id → Kasten resources + exported restore points only | same as in place |

Notes:

- "Exported restore points only": `k10backup.json` does not list them. Kasten imports them again from the export repositories, using the migration tokens of the export policies saved in the KDR restore point (see [Migration tokens](#migration-tokens-how-exported-restore-points-come-back)).
- "Everything, from **B**" needs `validSnapshotAvailable: true` on the chosen entry. If the local snapshot is gone, you only get Kasten resources and exported restore points.
- Local restore points restored on another cluster are listed in the catalog, but usually cannot be restored there: the snapshots they point to do not exist on that cluster.
- **Only the Exported Catalog Snapshot mode lets you keep the action history and local restore points on another cluster**, and only with the `v3.2_data` id.
- **If your storage cannot provision a volume from a VolumeSnapshot, use the `v3.2_data` id, even in place.** Examples are NetApp Trident `ontap-nas-economy`, or CephFS when the file system is large: there, a volume from a snapshot is a full copy and is not practical. With a `v3.2_metadata` (or `v3`) id and `validSnapshotAvailable: true`, Kasten tries to re-create the catalog PVC from the local VolumeSnapshot (**B**). With the `v3.2_data` id, it never uses **B** and restores the catalog from the exported catalog snapshot (**C**) instead. This is the use case the docs give for the [Exported Catalog Snapshot](https://docs.kasten.io/latest/operating/dr/#quick-dr-exported-catalog-snapshot) mode: storage that can create snapshots but cannot provision volumes from them.

## 4. Details

### How the review fills its status

Create the review with only the source cluster information, as in the [Create a KastenDRReview example](https://docs.kasten.io/latest/api/dr#create-a-kastendrreview-example). Kasten discovers the restore points in the repository and fills the `status`.

```yaml
apiVersion: dr.kio.kasten.io/v1alpha1
kind: KastenDRReview
metadata:
  name: example-kdrreview
  namespace: kasten-io
spec:
  sourceClusterInfo:
    profileName: <name of the location profile holding the KDR restore points>
    sourceClusterID: <source cluster UID>
```

For each kopia snapshot in the KDR repository, the review:

1. sets `version` from the snapshot's `drVersion` tag;
2. verifies the snapshot;
3. for `v3.2_data` (**C**): sets `exportedCatalogAvailable: true`;
4. for `v3` and `v3.2_metadata` (**A**): reads `k10backup.json`. If it references a local catalog snapshot (**B**), it sets `localSnapshotTaken: true`. It then checks **on the cluster where the review runs** that this snapshot still exists (VolumeSnapshot or VolumeSnapshotContent for CSI, or the cloud provider API). If it does, it sets `validSnapshotAvailable: true`.

So `validSnapshotAvailable` is a live check: it is normally `false` when the review runs on another cluster.

Only one `KastenDRReview` can exist at a time. It needs the location profile and the `k10-dr-secret` in the install namespace.

### Example review outputs

Local Catalog Snapshot and No Catalog Snapshot: same version, different flags.

```yaml
# Local Catalog Snapshot
- version: v3
  id: 3ec93a39db9038b230e4e331f2915fbc
  creationTime: "2026-11-16T08:15:34Z"
  localSnapshotTaken: true
  validSnapshotAvailable: true
  exportedCatalogAvailable: false

# No Catalog Snapshot
- version: v3
  id: be6793012dd348b21f1665b244d949b2
  creationTime: "2026-11-16T08:26:14Z"
  localSnapshotTaken: false
  validSnapshotAvailable: false
  exportedCatalogAvailable: false
```

Exported Catalog Snapshot: one pair per run. **C** is written first and **A** a few seconds later, so in the list (sorted newest first) each `v3.2_metadata` sits just above its `v3.2_data`.

```yaml
- version: v3.2_metadata
  id: b32b9468145d2ed357df27b42108eb83
  creationTime: "2026-11-16T08:24:11Z"
  localSnapshotTaken: true
  validSnapshotAvailable: true
  exportedCatalogAvailable: false
- version: v3.2_data
  id: 8d49d9b12cc0c9bf2f809e5518005014
  creationTime: "2026-11-16T08:24:02Z"
  localSnapshotTaken: false
  validSnapshotAvailable: false
  exportedCatalogAvailable: true
```

### Migration tokens: how exported restore points come back

**Every KDR restore point (`v3`, `v3.2_metadata`) saves the migration token of each policy that exports.** This is what brings back the exported restore points when the catalog cannot be restored.

When a policy has an export action, Kasten creates a migration-token secret for it, owned by the policy (`<policy name>-<hash>-migration-token`). This token opens the exported data of that policy, the same token you would give an import policy on another cluster. Each KDR run writes into `k10backup.json` (**A**):

- the **policy**, with its export profile and the name of its migration-token secret;
- the **migration-token secret** itself;
- the **repository** that holds the exported restore points of the policy: `<profile path>/k10/<clusterID>/migration/<policy name>/kopia`.

`k10backup.json` has **no list of restore points**. Restore points live in the catalog, so a KDR restore gets them back in one of two ways:

- **The catalog is restored** from **B** or **C**: all restore points come back with it, local and exported, with the action history.
- **The catalog is not restored** (No Catalog Snapshot mode, local snapshot gone, or another cluster without **C**): for each export policy, Kasten takes its migration token and export profile from `k10backup.json` and **imports the exported restore points again**, as an import policy would. Local restore points and action history are lost.

Example: namespace `dummy-rp` backed up and exported twice by policy `dummy-rp-backup` to profile `rustfs-apps`, then a No Catalog Snapshot KDR run (`v3`, `localSnapshotTaken: false`). No restore point name appears in `k10backup.json`; these entries do:

```
Policies:            dummy-rp-backup   export -> profile rustfs-apps, migrationToken dummy-rp-backup-0acbf51672d25d64-migration-token
Secrets:             dummy-rp-backup-0acbf51672d25d64-migration-token   (key: migrationToken, owner: Policy/dummy-rp-backup)
RepositoryArtifacts: type Collection, repoPath dummy-rp-backup/kopia, bucket app-exports
```

Consequences:

- **Delete an export policy and you lose its migration token** (the secret is owned by the policy). The next KDR runs no longer contain it, and its exported restore points are not imported back. To keep them recoverable, save the migration token before deleting the policy, and use it later in an import policy.
- If the import fails for one policy, the restore continues with the others and reports the error.
- Protect the KDR repository as much as the export repositories: the migration tokens in `k10backup.json` open all your exported data (see [Protect the DR passphrase](#protect-the-dr-passphrase)).

For reference, the top-level sections of `k10backup.json`:

| Section | Content |
|---|---|
| `Policies`, `Profiles`, `CustomResources`, `ConfigMaps`, `RoleBindings` | Kasten resources |
| `Secrets` | Kasten secrets, including the migration tokens |
| `K10MasterKeyArtifact(List)` | the master keys |
| `RepositoryArtifacts` | the repositories Kasten exported to |
| `LocalSnapshotArtifacts` | the local catalog snapshot (**B**), or `null` |
| `ExportSnapshotArtifacts` | the exported catalog snapshot (**C**), or `null` |

### Why a v3.2_data id needs its v3.2_metadata

**C** only holds the catalog PVC content. The Kasten resources and keys are in **A**. When you give a `v3.2_data` id, Kasten takes the `v3.2_metadata` entry just above it in the review list and runs a restore of that **A** using **C** as the catalog.

- If no `v3.2_metadata` is found above it, the restore fails with `No corresponding V3.2 metadata found for exportable catalog snapshot`.
- A `v3.2_metadata` id restored directly never uses **C**. It behaves like a `v3`.
- If you build a review `status` by hand instead of letting Kasten discover it, keep the list newest first, with each `v3.2_metadata` above its `v3.2_data`. Prefer the spec-only review.

### The KastenDRRestore

See the [KastenDRRestore API](https://docs.kasten.io/latest/api/dr#kastendrrestore-api-type) and [Use a specific KDR restore point](https://docs.kasten.io/latest/api/dr#use-specific-kdr-restore-point).

```yaml
apiVersion: dr.kio.kasten.io/v1alpha1
kind: KastenDRRestore
metadata:
  name: example-kdrrestore
  namespace: kasten-io
spec:
  kastenDRReviewDetails:
    kastenDRReviewRef:
      name: example-kdrreview
      namespace: kasten-io
    id: <restore point id, see section 3>
```

If you give only `spec.sourceClusterInfo` instead of a review (see [Use the latest KDR restore point](https://docs.kasten.io/latest/api/dr#use-latest-kdr-restore-point)), Kasten takes the newest restore point. When that is a `v3.2_metadata` followed by a `v3.2_data`, it restores from the exported catalog (**C**).

### Cluster ID trap

A cluster that was itself recovered with KDR keeps writing its KDR data under the **source** cluster ID until you delete the `k10-dr-remove-to-get-ownership` config map. If a review fails with `Failed to find kopia repository, please confirm source cluster ID and profile are correct`, check which cluster ID appears in the bucket path.

### Sample policies

Local Catalog Snapshot (default):

```yaml
spec:
  actions:
  - action: backup
    backupParameters:
      filters: {}
      profile:
        name: <kdr-profile>
        namespace: kasten-io
  kdrSnapshotConfiguration:
    takeLocalCatalogSnapshot: true
```

Exported Catalog Snapshot (adds an export action):

```yaml
spec:
  actions:
  - action: backup
    backupParameters:
      filters: {}
      profile:
        name: <kdr-profile>
        namespace: kasten-io
  - action: export
    exportParameters:
      frequency: '@hourly'
      profile:
        name: <kdr-profile>
        namespace: kasten-io
      exportData:
        enabled: true
    retention: {}
  kdrSnapshotConfiguration:
    takeLocalCatalogSnapshot: true
    exportCatalogSnapshot: true
```

No Catalog Snapshot:

```yaml
spec:
  actions:
  - action: backup
    backupParameters:
      filters: {}
      profile:
        name: <kdr-profile>
        namespace: kasten-io
  kdrSnapshotConfiguration: {}
```

### Protect the DR passphrase

The value in `k10-dr-secret` is used as-is as the kopia repository password. Kopia derives the encryption key with scrypt, which slows each guess but adds no strength to a weak passphrase. Anyone with read access to the bucket can try passphrases offline.

**A** contains the Kasten secrets, the location profile credentials and the master keys that protect the exported application data. A guessed passphrase exposes much more than the catalog.

- Use a long random passphrase (for example `openssl rand -base64 32`) and store it safely outside the cluster. Without it you cannot recover.
- Consider an external secret manager (HashiCorp Vault or AWS Secrets Manager); see [DR passphrase secret](https://docs.kasten.io/latest/operating/dr/#dr-passphrase-secret).
- Restrict read access to the KDR bucket and protect it with object lock or immutability.

## 5. Discover manually the KDR on your profile

The `KastenDRReview` does this discovery for you. Doing it by hand is useful when the review fails, when you want to check what a profile really holds before a restore, or when you want to look inside a restore point. You only need `kubectl` and the `kanister-tools` image, which ships the `kopia` binary.

### Where the KDR data lives

The KDR data of a source cluster is one kopia repository, at this path inside the profile's bucket or share:

```
[<profile path>/]k10/<source cluster id>/migration/<source cluster id>/k10/repo/
```

For example `k10/5c774d52-4c56-4640-bd31-5c1f49573f14/migration/5c774d52-4c56-4640-bd31-5c1f49573f14/k10/repo/` for a profile without a path. If you are not sure, look for the `kopia.repository` file: it sits at the root of the repository.

It contains one kopia snapshot per artifact (see [section 1](#1-what-a-kdr-policy-run-produces)):

| | Kopia snapshot source | Size (test cluster) | `drVersion` tag |
|---|---|---|---|
| **A** | `k10-admin@backup-k10-host:dr` | ~1 MB | `v3` or `v3.2_metadata` |
| **C** | `k10-admin@backup-k10-host:/mnt/vol_data/kanister-pvc` | ~50 MB (catalog size) | `v3.2_data` |

The kopia snapshot id (`manifest:<id>`) is the restore point `id` shown in the `KastenDRReview` and used in the `KastenDRRestore`.

### What you need

- The **source cluster id**: the UID of the `kube-system` namespace of the source cluster (`kubectl get ns kube-system -o jsonpath='{.metadata.uid}'`), unless the cluster was itself recovered with KDR (see [Cluster ID trap](#cluster-id-trap)).
- The **repository password**: the `key` field of `k10-dr-secret` in passphrase mode. The commands below read it from the secret. On a new cluster, create `k10-dr-secret` first, as you would for a KDR restore.
- Access to the **profile storage**: the profile credentials for an object store, or the profile PVC for an NFS/SMB file store.
- The **`kanister-tools` image** that matches your Kasten version:

  ```bash
  K10_VERSION=$(kubectl get pods -n kasten-io -o jsonpath='{..image}' | tr -s '[[:space:]]' '\n' | grep kanister-tools | sort -u | head -1 | cut -d: -f2)
  echo $K10_VERSION
  ```

All the commands below connect to the repository **read-only**.

### Object store profile (S3 and S3-compatible)

Get the profile values:

```bash
kubectl get profiles.config.kio.kasten.io <PROFILE_NAME> -n kasten-io -o jsonpath='bucket={.spec.locationSpec.objectStore.name} endpoint={.spec.locationSpec.objectStore.endpoint} region={.spec.locationSpec.objectStore.region} path={.spec.locationSpec.objectStore.path} secret={.spec.locationSpec.credential.secret.name}{"\n"}'
```

List the KDR snapshots:

```bash
kubectl run kdr-list-snaps -n kasten-io --rm -i --restart=Never --quiet \
  --image=gcr.io/kasten-images/kanister-tools:$K10_VERSION \
  --overrides='{"spec":{"containers":[{"name":"kdr-list-snaps","image":"gcr.io/kasten-images/kanister-tools:'$K10_VERSION'","command":["sh","-c","kopia repository connect s3 --readonly --bucket=<BUCKET> --endpoint=<ENDPOINT> --region=<REGION> --prefix=<PROFILE_PATH>/k10/<SOURCE_CLUSTER_ID>/migration/<SOURCE_CLUSTER_ID>/k10/repo/ && kopia snapshot list --all --manifest-id && kopia snapshot list --all --json | grep -o \"\\\"tags\\\":{[^}]*}\""],"env":[{"name":"HOME","value":"/tmp"},{"name":"KOPIA_CHECK_FOR_UPDATES","value":"false"},{"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"<PROFILE_SECRET>","key":"aws_access_key_id"}}},{"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"<PROFILE_SECRET>","key":"aws_secret_access_key"}}},{"name":"KOPIA_PASSWORD","valueFrom":{"secretKeyRef":{"name":"k10-dr-secret","key":"key"}}}]}]}}'
```

- No profile path: start the prefix at `k10/`.
- AWS S3: remove `--endpoint`.
- S3-compatible endpoint: give it without the scheme (`host:port`). For plain HTTP, add `--disable-tls`. For a self-signed certificate, add `--disable-tls-verification`.

### NFS/SMB file store profile

An NFS or SMB [file store profile](https://docs.kasten.io/latest/usage/configuration#nfs-file-storage) points to a PVC in the Kasten namespace. The KDR repository is a directory inside that PVC, so the pod mounts the same PVC and kopia connects with `kopia repository connect filesystem`.

Get the profile values:

```bash
kubectl get profiles.config.kio.kasten.io <PROFILE_NAME> -n kasten-io -o jsonpath='claim={.spec.locationSpec.fileStore.claimName} path={.spec.locationSpec.fileStore.path} suppGroup={.spec.locationSpec.fileStore.suppGroup}{"\n"}'
```

List the KDR snapshots:

```bash
kubectl run kdr-list-snaps -n kasten-io --rm -i --restart=Never --quiet \
  --image=gcr.io/kasten-images/kanister-tools:$K10_VERSION \
  --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"kdr-list-snaps","image":"gcr.io/kasten-images/kanister-tools:'$K10_VERSION'","command":["sh","-c","kopia repository connect filesystem --readonly --path=/mnt/kdr/<PROFILE_PATH>/k10/<SOURCE_CLUSTER_ID>/migration/<SOURCE_CLUSTER_ID>/k10/repo && kopia snapshot list --all --manifest-id && kopia snapshot list --all --json | grep -o \"\\\"tags\\\":{[^}]*}\""],"env":[{"name":"HOME","value":"/tmp"},{"name":"KOPIA_CHECK_FOR_UPDATES","value":"false"},{"name":"KOPIA_PASSWORD","valueFrom":{"secretKeyRef":{"name":"k10-dr-secret","key":"key"}}}],"volumeMounts":[{"name":"kdr","mountPath":"/mnt/kdr","readOnly":true}]}],"volumes":[{"name":"kdr","persistentVolumeClaim":{"claimName":"<PROFILE_PVC>","readOnly":true}}]}}'
```

- The pod **must run in the Kasten namespace**: a pod can only mount a PVC of its own namespace.
- The profile PVC is `ReadWriteMany`, so the pod can mount it while Kasten uses it. It is mounted read-only here.
- **`runAsUser: 0` is needed** because `kanister-tools` runs as uid 1000, and Kasten creates the repository directories as root with mode `drwx------`. Without it, kopia fails with `cannot access storage path: ... permission denied`. If the profile uses a supplemental group (`suppGroup`), you can instead keep the default user and add `"supplementalGroups":[<SUPP_GROUP>]` to the pod `securityContext`.
- No profile path: remove `<PROFILE_PATH>/` from `--path`.
- The command is the same for NFS and SMB: only the PV behind the PVC differs. It was tested with NFS.

### Example output

From an NFS profile with the Exported Catalog Snapshot mode, after one policy run:

```
Connected to repository.
k10-admin@backup-k10-host:/mnt/vol_data/kanister-pvc
  2026-11-16 15:24:12 UTC kebdc6f9a6b226cdaea9f3cdf814ae512 50.4 MB dgrwxrwxr-x manifest:b8794d9a601cbf7a29fd9bebfb5db97b files:1 dirs:4 (latest-1)

k10-admin@backup-k10-host:dr
  2026-11-16 15:24:20 UTC k46433e05e82db6e28833f7e18dec7b44 1.1 MB drwxrwxrwx manifest:72365fdc3c01eec89aaa2c6ce8123145 files:1 dirs:1 (latest-1)
"tags":{"tag:drVersion":"v3.2_data"}
"tags":{"drVersion":"v3.2_metadata"}
```

- `manifest:b8794d9a…` is **C**, the `v3.2_data` restore point.
- `manifest:72365fdc…` is **A**, its `v3.2_metadata` partner, written 8 seconds later.

The `KastenDRReview` on the same profile shows these two ids with the same versions.

In the `--json` output, the tags appear in the same order as the snapshots: first all the `kanister-pvc` snapshots (**C**), then all the `dr` snapshots (**A**). With only the Local or No Catalog Snapshot mode, you only get `dr` snapshots, tagged `"drVersion":"v3"`.

### Look inside a restore point

To check whether a `v3` or `v3.2_metadata` restore point references a local catalog snapshot (**B**), restore its `dr` snapshot to a temporary folder and read `k10backup.json`. In the `sh -c` command of the list commands above, replace everything after `&&` with:

```
kopia snapshot restore <RESTORE_POINT_ID> /tmp/r && grep -o '"LocalSnapshotArtifacts":[^,]*' /tmp/r/k10backup.json
```

- `"LocalSnapshotArtifacts":null` means no local catalog snapshot: the review shows `localSnapshotTaken: false`.
- A list means a local catalog snapshot was taken: the review shows `localSnapshotTaken: true`. The list holds the VolumeSnapshot (or provider snapshot) and the catalog PVC spec.

`k10backup.json` also contains the Kasten secrets and keys (see [Protect the DR passphrase](#protect-the-dr-passphrase)). The pod is deleted when the command ends, but do not copy the file out of the cluster.

## References

- [Kasten Disaster Recovery](https://docs.kasten.io/latest/operating/dr/)
  - [Legacy DR vs Quick DR](https://docs.kasten.io/latest/operating/dr/#legacydr-vs-quickdr)
  - [Quick DR (Local Catalog Snapshot)](https://docs.kasten.io/latest/operating/dr/#quick-dr-local-catalog-snapshot)
  - [Quick DR (Exported Catalog Snapshot)](https://docs.kasten.io/latest/operating/dr/#quick-dr-exported-catalog-snapshot)
  - [Quick DR (No Catalog Snapshot)](https://docs.kasten.io/latest/operating/dr/#quick-dr-no-catalog-snapshot)
  - [KDR resource matrix](https://docs.kasten.io/latest/operating/dr/#kdr-resource-matrix)
  - [Recovering with KDR](https://docs.kasten.io/latest/operating/dr/#dr-recovery)
- [KDR API](https://docs.kasten.io/latest/api/dr)
  - [KastenDRReview API type](https://docs.kasten.io/latest/api/dr#kastendrreview-api-type)
  - [Create a KastenDRReview example](https://docs.kasten.io/latest/api/dr#create-a-kastendrreview-example)
  - [KastenDRRestore API type](https://docs.kasten.io/latest/api/dr#kastendrrestore-api-type)
