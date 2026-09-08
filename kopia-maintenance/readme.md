# Goal

Find the Kopia repositories that hold the exported data of **one given namespace**, and answer the
only question that really matters about them:

> *When did maintenance last run successfully on this repository?*

Everything is done with `oc get` (or `kubectl get`) against the `StorageRepository` API in the
`kasten-io` namespace. No exec into pods, no Kopia CLI, no credentials to the bucket.

> All the outputs on this page were captured on a live cluster running **Veeam Kasten 9.0.4** on
> OpenShift, exporting to a MinIO bucket named `mod`. Field names and layouts are version
> dependent — the method holds, the exact strings may drift.

# Why should I care about Kopia maintenance?

When Kasten exports a restore point to an object store, it does not write a tarball. It writes into
a **Kopia repository**: a content-addressable store made of pack blobs, index blobs and metadata
blobs, shared and deduplicated across every restore point it contains.

That design is what makes exports incremental and cheap. It is also what makes the repository a
living data structure that needs to be tidied up. The
[Veeam Kasten StorageRepository documentation](https://docs.kasten.io/latest/api/repositories/)
puts it this way:

> Veeam Kasten periodically runs maintenance on the StorageRepositories it creates. Among other
> tasks, the maintenance process **tidies up unused data, detects inconsistent states, and measures
> the overall storage usage over time**.

The performance consequence is spelled out in the upstream
[Kopia maintenance documentation](https://kopia.io/docs/advanced/maintenance/), which splits the
work in two:

- **Quick maintenance** (frequent) — *"primarily responsible for keeping the number of
  frequently-accessed blobs (`q` and `n`) low to ensure good performance."* Those are the index
  blobs. Every single operation on the repository — every export, every restore, every
  `SnapshotList` — starts by loading the index. Without compaction the index stops being a handful
  of blobs and becomes thousands of tiny ones, and the *opening* of the repository gets slower and
  slower, before a single byte of your data has moved. Kopia is blunt about it: *"While the user can
  disable quick maintenance, it's not recommended, as it will lead to reduced performance."*

- **Full maintenance** (daily) — *"responsible for keeping the repository compact and eliminate
  deleted files that the user no longer wishes to store."* This is snapshot GC plus compaction of
  pack blobs. Without it, the blobs belonging to restore points that your retention policy already
  expired are never actually deleted from the bucket: *"the resulting repository will still be
  correct, but will not benefit from compaction and will run more slowly."*

So a repository whose maintenance has silently stopped shows two symptoms, and they arrive in this
order:

1. **The bucket keeps growing** even though retention is expiring restore points. You delete restore
   points in the Kasten UI and the object storage bill does not move.
2. **Exports and restores get slower**, then start hitting timeouts, because opening the repository
   means fetching an ever-growing pile of index blobs over the network.

Symptom 1 is the early warning. By the time you notice symptom 2 you usually have a repository that
takes a very long time to repair. Which is why it is worth checking, and why this page exists.

Two spec fields govern the behaviour, both documented on the page linked above:

| Field | Default | Meaning |
|---|---|---|
| `spec.disableMaintenance` | `false` | Set to `true` to stop maintenance on this repository |
| `spec.backgroundProcessTimeout` | 10h | Timeout for the background operations |

# Anatomy of a StorageRepository

`StorageRepository` is **not a CRD**. It is an aggregated API served by `aggregatedapis-svc`:

```bash
oc api-resources --api-group=repositories.kio.kasten.io
```

```
NAME                  SHORTNAMES   APIVERSION                            NAMESPACED   KIND
storagerepositories                repositories.kio.kasten.io/v1alpha1   true         StorageRepository
```

```bash
oc get apiservice | grep repositories
```

```
v1alpha1.repositories.kio.kasten.io   kasten-io/aggregatedapis-svc   True   55d
```

Practically this means two things: there is nothing to find in `oc get crd`, and if
`aggregatedapis-svc` is unhealthy the whole API returns errors rather than an empty list. The good
news is that server-side **label selectors do work** through the aggregation layer — which is what
Step 2 relies on.

Here is a real object, trimmed to the parts we will use:

```yaml
apiVersion: repositories.kio.kasten.io/v1alpha1
kind: StorageRepository
metadata:
  name: kopia-volumedata-repository-l55crqzv8c
  namespace: kasten-io
  labels:
    k10.kasten.io/appName: klusterlet-guest1        # the protected namespace
    k10.kasten.io/exportProfile: my-s3-bucket
    k10.kasten.io/policyName: basic-app-backup
    k10.kasten.io/policyNamespace: kasten-io
spec:
  disableMaintenance: false
  backgroundProcessTimeout: null
status:
  appName: klusterlet-guest1
  backendType: kopia
  contentType: volumedata                            # volumedata | metadata
  location:
    objectStore:
      endpoint: http://minio.minio.svc.cluster.local:9000
      name: mod
      objectStoreType: S3
      path: k10/aaf602aa-e337-48f8-bf9c-2203d041d379/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/
  processResults:
    processCount: 5
    recentResults:
    - procedure: MaintenanceRun
      startTime: "2026-07-25T08:55:09Z"
      endTime: "2026-07-25T08:55:13Z"
      succeeded: true
      commandResults:
      - {desc: RepoStatus,      succeeded: true, ...}
      - {desc: MaintenanceRun,  succeeded: true, ...}
      - {desc: MaintenanceInfo, succeeded: true, ...}
      - {desc: SnapshotList,    succeeded: true, ...}
      - {desc: BlobStats,       succeeded: true, ...}
```

Two things to retain:

- **`metadata.name` is opaque.** `kopia-volumedata-repository-l55crqzv8c` tells you nothing about
  which application it belongs to. You must go through the labels or the path.
- **`status.location.objectStore.path` is the ground truth**, and it is not random. But it does not
  follow *one* convention — it follows two, and that is the next section.

# :warning: The two path conventions — volumedata is per namespace, metadata is per policy

This is the part that catches everybody. On the cluster used here, `migration/` has exactly three
children:

```bash
CU=aaf602aa-e337-48f8-bf9c-2203d041d379   # cluster uid, see below
mc ls kastenminio/mod/k10/$CU/migration/
```

```
[2026-09-08 09:44:59 CEST]     0B basic-app-backup/
[2026-09-08 09:44:59 CEST]     0B clusters-backup/
[2026-09-08 09:44:59 CEST]     0B repo/
```

`repo/` holds the volume data. The other two are **policy names**, and they hold the Kubernetes
metadata. Written out:

| contentType | Path convention | One per | `status.appName` |
|---|---|---|---|
| `volumedata` | `k10/<cluster-uid>/migration/repo/<namespace-uid>/` | **protected namespace** | the namespace |
| `metadata` | `k10/<cluster-uid>/migration/<policyName>/kopia/` | **policy** | `kasten-io` |

Here is the whole inventory of that cluster, which makes the asymmetry obvious:

```bash
oc get storagerepositories -n kasten-io -o json \
| jq -r '["NAME","CONTENT","APP","POLICY","PATH"],
  (.items[] | [.metadata.name, .status.contentType, .status.appName,
   .metadata.labels."k10.kasten.io/policyName",
   .status.location.objectStore.path]) | @tsv' | column -t -s $'\t'
```

```
NAME                                    CONTENT     APP                 POLICY            PATH
kopia-volumedata-repository-l55crqzv8c  volumedata  klusterlet-guest1   basic-app-backup  k10/aaf6…/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/
kopia-volumedata-repository-bmfdrgf6sw  volumedata  openshift-cluster…  basic-app-backup  k10/aaf6…/migration/repo/18fccf8b-c327-4ffd-9eea-184dabe51d31/
kopia-volumedata-repository-98v2rkz7sx  volumedata  basic-app           basic-app-backup  k10/aaf6…/migration/repo/f7c34364-7451-4efb-b8f5-f29cf8255a8d/
…  (22 of them, one per protected namespace)
kopia-metadata-repository-sv6qxrvbvd    metadata    kasten-io           basic-app-backup  k10/aaf6…/migration/basic-app-backup/kopia/
kopia-metadata-repository-2fs864hlsv    metadata    kasten-io           clusters-backup   k10/aaf6…/migration/clusters-backup/kopia/
```

```bash
oc get storagerepositories -n kasten-io -o json | jq -r '.items[].status.contentType' | sort | uniq -c
```

```
   2 metadata
  22 volumedata
```

**22 volumedata repositories for 22 protected namespaces, but only 2 metadata repositories for 2
policies.** The metadata of `klusterlet-guest1` does not live in a repository of its own — it is
mixed into `migration/basic-app-backup/kopia/` together with the metadata of every other namespace
that the `basic-app-backup` policy protects.

The direct consequence, and the reason this matters for Step 2:

> On a metadata repository, `status.appName` and the `k10.kasten.io/appName` label are **`kasten-io`**,
> not the protected namespace. Filtering on `-l k10.kasten.io/appName=<your-namespace>` will
> therefore return the volumedata repository **only**. To reach the metadata repository you must go
> through `k10.kasten.io/policyName`.

## The volumedata path, decoded

```
k10/<cluster-uid>/migration/repo/<namespace-uid>/
```

| Segment | Where it comes from |
|---|---|
| `<cluster-uid>` | the UID of the **`default` namespace** of the cluster that owns the data |
| `<namespace-uid>` | the UID of the **protected namespace** |

```
k10/aaf602aa-e337-48f8-bf9c-2203d041d379/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/
    └─ uid of ns "default" ──────────────┘             └─ uid of ns "klusterlet-guest1" ────┘
```

A neat confirmation of the first segment: the cluster also protects the `default` namespace itself,
and its repository path is `…/migration/repo/aaf602aa-e337-48f8-bf9c-2203d041d379/` — the same UID
that appears as `<cluster-uid>`.

This is what lets you go **both ways**: from a namespace to its prefix in the bucket, and from an
unknown prefix you found in the bucket back to the namespace it belongs to.

> :warning: The UID is the namespace UID, not its name. If a namespace is deleted and recreated with
> the same name, it gets a **new UID**, and Kasten creates a **new repository** under a new prefix.
> The old prefix stays in the bucket, and it stops being maintained. That is one of the classic ways
> to end up paying for orphaned data.

# Step 1 — list every repository

```bash
oc get storagerepositories.repositories.kio.kasten.io -n kasten-io
```

The short form works too, and is used from here on:

```bash
oc get storagerepositories -n kasten-io
```

```
NAME                                     LOCATIONTYPE
kopia-volumedata-repository-l55crqzv8c   ObjectStore
kopia-volumedata-repository-bmfdrgf6sw   ObjectStore
…
```

The default columns are useless. This is the listing worth keeping:

```bash
oc get storagerepositories -n kasten-io \
  -o custom-columns=\
'NAME:.metadata.name,'\
'CONTENT:.status.contentType,'\
'APP:.status.appName,'\
'POLICY:.metadata.labels.k10\.kasten\.io/policyName,'\
'PROFILE:.metadata.labels.k10\.kasten\.io/exportProfile,'\
'DISABLED:.spec.disableMaintenance'
```

# Step 2 — find the repositories of a given namespace

A namespace is covered by **two kinds** of repository, and you need a different query for each.

## 2a — the volumedata repository (private to the namespace)

```bash
NS=klusterlet-guest1

oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS \
  -o custom-columns='NAME:.metadata.name,CONTENT:.status.contentType,PATH:.status.location.objectStore.path'
```

```
NAME                                     CONTENT      PATH
kopia-volumedata-repository-l55crqzv8c   volumedata   k10/aaf602aa-…/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/
```

One line, `volumedata` only. That is expected — see the warning above.

## 2b — the metadata repository (shared, one per policy)

Get the policies that protect the namespace straight from the labels of the repository found in 2a,
then look up the metadata repository of each:

```bash
NS=klusterlet-guest1

POLICIES=$(oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS -o json \
  | jq -r '[.items[].metadata.labels."k10.kasten.io/policyName"] | unique | join(" ")')
echo "policies protecting $NS: $POLICIES"

for p in $POLICIES; do
  oc get storagerepositories -n kasten-io -l k10.kasten.io/policyName=$p -o json \
  | jq -r --arg p "$p" '.items[] | select(.status.contentType=="metadata")
      | "\(.metadata.name)\t\($p)\t\(.status.location.objectStore.path)"'
done | column -t
```

```
policies protecting klusterlet-guest1: basic-app-backup

kopia-metadata-repository-sv6qxrvbvd  basic-app-backup  k10/aaf602aa-…/migration/basic-app-backup/kopia/
```

Remember what you are looking at: this repository is **not** specific to `klusterlet-guest1`. If its
maintenance is broken, the metadata of every namespace under `basic-app-backup` is affected — which
is precisely why it deserves as much attention as the per-namespace ones, and why the fleet-wide
check in Step 3 is the one to schedule.

## 2c — by object store path, the authoritative way

2a relies on a label. 2c relies on where the data actually is, and it is the one to use when you are
auditing a bucket, when the namespace has been recreated, or when you simply do not trust the label.

```bash
NS=klusterlet-guest1

CLUSTER_UID=$(oc get ns default -o jsonpath='{.metadata.uid}')
NS_UID=$(     oc get ns "$NS"   -o jsonpath='{.metadata.uid}')
PREFIX="k10/${CLUSTER_UID}/migration/repo/${NS_UID}/"
echo "$PREFIX"

oc get storagerepositories -n kasten-io -o json \
| jq -r --arg p "$PREFIX" '.items[] | select(.status.location.objectStore.path == $p)
    | "\(.metadata.name)\t\(.status.contentType)\t\(.status.location.objectStore.endpoint)"' \
| column -t
```

```
k10/aaf602aa-e337-48f8-bf9c-2203d041d379/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/
kopia-volumedata-repository-l55crqzv8c   volumedata   http://minio.minio.svc.cluster.local:9000
```

If 2a and 2c disagree, you have found something worth investigating: a stale label, or data left
over from a previous incarnation of the namespace.

## 2d — the other direction, from a bucket prefix back to a namespace

You are looking at the bucket, you see a `migration/repo/<uid>/` prefix, and you want to know whose
data it is:

```bash
UID_FOUND=180334e5-1259-4637-bf64-9f50ba82b88d

oc get ns -o json | jq -r --arg u "$UID_FOUND" \
  '.items[] | select(.metadata.uid == $u) | .metadata.name'
```

```
klusterlet-guest1
```

No output means the namespace no longer exists on this cluster — the prefix is orphaned data, and
nothing is maintaining it. To check the whole bucket at once, compare the two counts:

```bash
CU=$(oc get ns default -o jsonpath='{.metadata.uid}')
echo -n "prefixes on the bucket: "; mc ls kastenminio/mod/k10/$CU/migration/repo/ | wc -l
echo -n "repositories in the API: "; oc get storagerepositories -n kasten-io -o json \
  | jq '[.items[]|select(.status.contentType=="volumedata")]|length'
```

```
prefixes on the bucket: 22
repositories in the API: 22
```

Equal numbers, no orphans. A bucket count higher than the API count is data nobody maintains any
more.

# Step 3 — when did maintenance last succeed?

## What the API records

Each background run is appended to `status.processResults.recentResults[]`, with:

- `procedure` — the kind of run. `MaintenanceRun` is the one we want.
- `succeeded` — whether the **whole** run succeeded.
- `startTime` / `endTime`.
- `commandResults[]` — the individual Kopia commands, each with its own `succeeded` flag:
  `RepoStatus`, `MaintenanceRun`, `MaintenanceInfo`, `SnapshotList`, `BlobStats`.

`processResults.processCount` is the total number of runs recorded, but only the **last five** are
kept in `recentResults`. This matters: if maintenance has been failing for a long time, the last
successful run may have already scrolled out of the list, and you will get "NEVER" below even though
it did work once. In that case go to the logs (Step 4).

## For one repository

```bash
REPO=kopia-volumedata-repository-l55crqzv8c

oc get storagerepositories "$REPO" -n kasten-io -o json \
| jq -r '
    [ .status.processResults.recentResults[]?
      | select(.procedure == "MaintenanceRun" and .succeeded == true)
      | .endTime ]
    | sort | last // "NEVER (in the retained history)"'
```

```
2026-07-25T08:55:13Z
```

Do not just read `recentResults[0]` — the ordering of the list is not something to rely on. Sorting
the ISO-8601 timestamps is safe because they are all UTC with the same format.

The full retained history, successes and failures alike:

```bash
oc get storagerepositories "$REPO" -n kasten-io -o json \
| jq -r '
    ["PROCEDURE","START","END","OK"],
    (.status.processResults.recentResults[]?
      | [.procedure, .startTime, .endTime, (.succeeded|tostring)])
    | @tsv' | column -t
```

```
PROCEDURE       START                  END                    OK
MaintenanceRun  2026-07-25T08:55:09Z   2026-07-25T08:55:13Z   true
MaintenanceRun  2026-07-24T08:54:06Z   2026-07-24T08:54:10Z   true
MaintenanceRun  2026-07-23T08:53:01Z   2026-07-23T08:53:07Z   true
MaintenanceRun  2026-07-22T08:51:57Z   2026-07-22T08:52:03Z   true
MaintenanceRun  2026-07-21T08:50:47Z   2026-07-21T08:50:58Z   true
```

One run per day, a few seconds each, `true` all the way down, start time drifting by a minute
between runs. That is what a healthy repository looks like — **while the runs are happening**. Note
what this view cannot tell you: whether they are *still* happening. Which brings us to the next
query.

## For every repository at once — the check you actually want

This is the one to keep. Every repository with the **age** of its last successful maintenance, so a
problem jumps out of the list:

```bash
oc get storagerepositories -n kasten-io -o json \
| jq -r '
    ["REPOSITORY","APP","CONTENT","POLICY","DISABLED","LAST_OK_MAINTENANCE","AGE_H"],
    (.items[]
     | . as $r
     | ( [ $r.status.processResults.recentResults[]?
           | select(.procedure == "MaintenanceRun" and .succeeded == true)
           | .endTime ] | sort | last ) as $last
     | [ $r.metadata.name,
         ($r.status.appName // "-"),
         ($r.status.contentType // "-"),
         ($r.metadata.labels."k10.kasten.io/policyName" // "-"),
         (($r.spec.disableMaintenance // false) | tostring),
         ($last // "NEVER"),
         (if $last
            then (((now - ($last | fromdateiso8601)) / 3600) | floor | tostring)
            else "-" end) ])
    | @tsv' | column -t -s $'\t'
```

Run on the cluster used for this page, on 2026-09-08:

```
REPOSITORY                              APP                 CONTENT     POLICY            DISABLED  LAST_OK_MAINTENANCE   AGE_H
kopia-volumedata-repository-l55crqzv8c  klusterlet-guest1   volumedata  basic-app-backup  false     2026-07-25T08:55:13Z  1078
kopia-volumedata-repository-bmfdrgf6sw  openshift-cluster…  volumedata  basic-app-backup  false     2026-07-25T08:55:19Z  1078
kopia-volumedata-repository-pcm8vl9hch  openshift-ovirt-in… volumedata  basic-app-backup  false     2026-07-25T08:55:41Z  1078
kopia-metadata-repository-sv6qxrvbvd    kasten-io           metadata    basic-app-backup  false     2026-07-26T08:23:02Z  1054
kopia-metadata-repository-2fs864hlsv    kasten-io           metadata    clusters-backup   false     2026-07-25T12:28:25Z  1074
…
```

**1078 hours is 45 days.** Alarming at first glance — and, on this cluster, entirely normal. Which
is the single most important thing to understand before you build an alert on this number.

## :warning: A large AGE_H is not a fault. Read it against repository activity

Maintenance is **driven by repository activity, not by a wall clock**. A repository that nothing
writes to has nothing to compact and nothing to garbage collect, so no run is recorded and its
timestamp stays frozen at whenever it was last used. That is the expected steady state of an idle
repository, not a broken one.

Here is the demonstration, captured live. Every policy on this cluster is either `@onDemand` or
paused:

```bash
oc get policies.config.kio.kasten.io -n kasten-io -o json \
| jq -r '.items[]|"\(.metadata.name)\tpaused=\(.spec.paused // false)\tfreq=\(.spec.frequency // "onDemand")"'
```

```
basic-app-backup              paused=false  freq=@onDemand
clusters-backup               paused=true   freq=@hourly
cp4d-projects-backup-policy   paused=false  freq=@onDemand
```

Nothing had run since July, so nothing had been maintained since July. Then `basic-app-backup` was
triggered by hand at 12:32, and maintenance on the two repositories it touches fired **within a
minute**, unprompted:

```
restore point created   2026-09-08T12:32:48Z
restore point created   2026-09-08T12:33:20Z
MaintenanceRun          2026-09-08T12:33:38Z → 12:33:43Z   succeeded: true
StorageScan             2026-09-08T12:34:08Z → 12:34:13Z   succeeded: true
```

Nothing was fixed in between. The scheduler was never wedged — the repositories were simply idle.
The same query that read `1078` for those two repositories now reads `0`, while the other twenty
still read `1078` because they are still idle.

And idle here is literal: **20 of the 22 volumedata repositories hold no restore point at all**.

```bash
oc get storagerepositories -n kasten-io -o json \
  | jq -r '.items[]|select(.status.contentType=="volumedata")|.status.appName' | sort > /tmp/repoapps
oc get restorepoints.apps.kio.kasten.io -A --no-headers | awk '{print $1}' | sort -u > /tmp/rpapps
echo "repositories: $(wc -l < /tmp/repoapps)   with restore points: $(wc -l < /tmp/rpapps)   empty: $(comm -23 /tmp/repoapps /tmp/rpapps | wc -l)"
```

```
repositories: 22   with restore points: 4   empty: 20
```

`klusterlet-guest1` is one of the twenty, and the bucket agrees — its prefix contains Kopia's
housekeeping blobs and **not a single `p` pack blob** (see the listing in 4.4). There is no data
left in it to maintain.

So read `AGE_H` in context, never on its own:

| Situation | Verdict |
|---|---|
| Recent exports to this repository, `AGE_H` under ~24 h | healthy |
| **Recent exports**, `AGE_H` climbing past ~72 h | **investigate** — this is the real fault signal |
| No recent exports, large `AGE_H` | expected. Idle repository, nothing to do |
| No restore points at all | empty shell from an expired or deleted application. Candidate for cleanup, not for an alert |
| `DISABLED = true` | someone turned it off on purpose. Was that on purpose? |

The useful alert is therefore a **join**, not a threshold: page when a repository that received an
export in the last 24 h has not recorded a successful `MaintenanceRun` since. Alerting on `AGE_H`
alone would have fired twenty times on this cluster and been wrong every time.

> The exact lifecycle of a repository once its last restore point expires — how much is garbage
> collected and when the `StorageRepository` object itself goes away — is not something this page
> establishes. What is established is the part that matters for monitoring: idle repositories stop
> recording maintenance runs, and that is not a fault.

## The `succeeded` flag alone is not enough either

On the idle cluster, every single retained run has `succeeded: true`. There is not one failure to
find:

```bash
oc get storagerepositories -n kasten-io -o json \
| jq -r '.items[] | [([.status.processResults.recentResults[]?|.endTime]|sort|last),
                     .metadata.name,
                     ([.status.processResults.recentResults[]?|select(.succeeded!=true)]|length),
                     (.status.processResults.processCount//0)] | @tsv' \
| sort -r | head -5 | column -t
```

```
2026-07-28T08:25:09Z  kopia-volumedata-repository-98v2rkz7sx  0  11
2026-07-27T08:57:16Z  kopia-volumedata-repository-625gsg6qb8  0  9
2026-07-26T08:23:02Z  kopia-metadata-repository-sv6qxrvbvd    0  8
2026-07-25T12:28:25Z  kopia-metadata-repository-2fs864hlsv    0  175
2026-07-25T12:28:22Z  kopia-volumedata-repository-ddkcwrqdsk  0  400
```

(columns: last run of any kind, repository, failed runs retained, total runs ever)

Zero failures everywhere, and yet nothing had run for a month and a half. Whether the cause is a
genuinely wedged scheduler or simply an idle repository, the shape in the API is identical: no new
entries are written, and the last thing recorded stays green forever. **A dashboard that alerts on
`succeeded == false` is silent in both cases.**

That is why neither field works on its own. `succeeded` tells you how the last run went; `endTime`
tells you when it was; only the **export activity of the repository** tells you whether another run
should have happened by now. Note also that `MaintenanceRun` is not the only procedure recorded —
`StorageScan` appears in the same list — so keep the `select(.procedure == "MaintenanceRun")` filter
in every query above rather than taking the newest entry of any kind.

## Restrict it to one namespace, both repository kinds

Putting Step 2 and Step 3 together:

```bash
NS=klusterlet-guest1

POLICIES=$(oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS -o json \
  | jq -r '[.items[].metadata.labels."k10.kasten.io/policyName"] | unique | join(" ")')

{
  oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS -o json
  for p in $POLICIES; do
    oc get storagerepositories -n kasten-io -l k10.kasten.io/policyName=$p -o json
  done
} | jq -sr --arg ns "$NS" '
    ["REPOSITORY","CONTENT","SCOPE","LAST_OK_MAINTENANCE","AGE_H"],
    ([.[].items[]] | unique_by(.metadata.name)[]
     | select(.status.appName == $ns or .status.contentType == "metadata")
     | ([.status.processResults.recentResults[]?
         | select(.procedure=="MaintenanceRun" and .succeeded==true) | .endTime]
        | sort | last) as $l
     | [ .metadata.name,
         .status.contentType,
         (if .status.contentType == "metadata"
            then "shared by policy " + (.metadata.labels."k10.kasten.io/policyName")
            else "private to " + $ns end),
         ($l // "NEVER"),
         (if $l then (((now-($l|fromdateiso8601))/3600)|floor|tostring) else "-" end) ])
    | @tsv' | column -t -s $'\t'
```

```
REPOSITORY                              CONTENT     SCOPE                              LAST_OK_MAINTENANCE   AGE_H
kopia-metadata-repository-sv6qxrvbvd    metadata    shared by policy basic-app-backup  2026-07-26T08:23:02Z  1055
kopia-volumedata-repository-l55crqzv8c  volumedata  private to klusterlet-guest1       2026-07-25T08:55:13Z  1078
```

Two lines, and the `SCOPE` column is the reminder that matters: fixing the second one fixes
`klusterlet-guest1`, fixing the first one fixes every namespace under `basic-app-backup`.

Drop the `select(...)` clause if you want the opposite view — the full fan-out of every repository
sharing the namespace's policies (22 lines on this cluster).

## The scheduling side: `status.maintenanceInfo`

`processResults` tells you what already happened. `status.maintenanceInfo` tells you what Kopia
itself thinks about the schedule — the quick and full maintenance intervals and when the next ones
are due. The exact shape depends on the Kasten version, so dump it rather than guess at field names:

```bash
oc get storagerepositories "$REPO" -n kasten-io -o jsonpath='{.status.maintenanceInfo}' | jq .
```

Likewise `status.storageUsage` carries the blob and snapshot statistics collected by the `BlobStats`
command of the last run — useful to confirm that bucket usage actually goes *down* after a full
maintenance:

```bash
oc get storagerepositories "$REPO" -n kasten-io -o jsonpath='{.status.storageUsage}' | jq .
```

Both are empty on repositories that have never completed a run.

# Step 4 — when a *busy* repository is behind, where to look

Only enter this section once Step 3 has shown you a repository that is **receiving exports** and
still not recording successful `MaintenanceRun` entries. A stale timestamp on an idle repository is
normal and needs nothing from this page.

## 4.1 Is it disabled?

```bash
oc get storagerepositories -n kasten-io \
  -o custom-columns='NAME:.metadata.name,DISABLED:.spec.disableMaintenance' | grep true
```

To re-enable:

```bash
oc patch storagerepositories "$REPO" -n kasten-io \
  --type merge -p '{"spec":{"disableMaintenance":false}}'
```

## 4.2 Which command failed?

The top-level `succeeded: false` does not say why. Drill into `commandResults`:

```bash
oc get storagerepositories "$REPO" -n kasten-io -o json \
| jq -r '.status.processResults.recentResults[]?
         | select(.succeeded != true)
         | "=== \(.procedure) \(.startTime)",
           (.commandResults[]? | "  \(.desc)\tok=\(.succeeded)\t\(.error // "")")'
```

Typical causes, in the order you should suspect them:

- **Credentials or endpoint.** The location profile no longer works — rotated keys, expired token,
  changed CA. Validate the profile in the Kasten UI or with `k10tools`.
- **Timeout.** A very large repository whose first maintenance after a long gap does not fit in the
  10 h `backgroundProcessTimeout`. Raise it:
  ```bash
  oc patch storagerepositories "$REPO" -n kasten-io \
    --type merge -p '{"spec":{"backgroundProcessTimeout":"24h"}}'
  ```
- **Object lock / immutability on the bucket.** Maintenance needs to *delete* blobs. If the bucket
  enforces retention beyond the Kasten retention, the delete phase fails and the repository never
  shrinks.

## 4.3 Which component actually runs maintenance?

There is **no `kopia-maintenance` CronJob and no maintenance pod** to look for — on 9.0.4 both
`oc get cronjob -n kasten-io` and `oc get jobs -n kasten-io` come back empty. The work runs
in-process, and the component that does it is easy to miss because **it is not a Deployment**:

```bash
oc get pod -n kasten-io -l run=crypto-svc -o jsonpath='{.items[0].spec.containers[*].name}'
```

```
crypto-svc repositories-svc bloblifecyclemanager-svc garbagecollector-svc
```

`repositories-svc` is a **container inside the `crypto-svc` pod**. So:

| Where | Role |
|---|---|
| `aggregatedapis-svc` (Deployment) | **serves** the `repositories.kio.kasten.io` API you have been querying |
| `crypto-svc` pod, `repositories-svc` container | **owns and maintains** the repositories — this is where maintenance actually runs |

This matters for the log commands: `oc logs deploy/crypto-svc` without `-c` only gives you the first
container. You want `-c repositories-svc`, or `--all-containers`.

You can confirm the ownership from the source file names that show up in the logs:

```bash
for d in crypto-svc executor-svc controllermanager-svc catalog-svc jobs-svc state-svc; do
  echo "--- $d ---"
  oc logs -n kasten-io deploy/$d --all-containers --tail=20000 2>/dev/null \
    | grep -oE '"File":"[^"]*(maintenance|repositor)[^"]*"' | sort -u | head -5
done
```

```
--- crypto-svc ---
"File":"kasten.io/k10/kio/storagemgr/repository_manager_init.go"
"File":"kasten.io/k10/rest/srv/repositoriesserver/kio_repositories_handler.go"
--- executor-svc ---
--- controllermanager-svc ---
--- catalog-svc ---
--- jobs-svc ---
--- state-svc ---
```

So `repositories-svc` is where to look. It is a very quiet log — on the cluster used here it emitted
**seven lines in two weeks**, which is itself the useful signal:

```bash
POD=$(oc get pod -n kasten-io -l run=crypto-svc -o jsonpath='{.items[0].metadata.name}')
oc logs -n kasten-io "$POD" -c repositories-svc --tail=200 \
  | jq -r '"\(.time // .Time)  [\(.level // .Level)]  \(.msg // .Message)  <\(.File)>"'
```

```
2026-08-25T02:18:24.609Z  [info]   Initializing Repositories Service          <…/kio_repositories_handler.go>
2026-08-25T02:18:24.612Z  [info]   Initializing repository manager            <…/kio_repositories_handler.go>
2026-08-25T02:18:24.612Z  [info]   initializing repositories manager          <…/storagemgr/repository_manager_init.go>
2026-08-25T02:18:24.624Z  [info]   Serving repositories at http://[::]:8003   <…/utils/swagger_utils.go>
2026-08-25T02:19:07.361Z  [info]   repositories manager initialization complete <…/storagemgr/repository_manager_init.go>
2026-09-04T06:57:08.067Z  [error]  repository stream hit an error             <…/storagemgr/repostream/repostream.go>
```

The repository manager keeps its view of the repositories in sync by consuming a long-lived event
stream from `catalog-svc`:

```
GET http://catalog-svc:8000/v0/artifacts/stream?offset=3695&streamName=REPOSITORY.MODIFIED
```

That connection is the fragile part. It breaks whenever `catalog-svc` moves — and on this cluster
the timestamps line up exactly: the stream died at `2026-09-04T06:57:08`, and the node hosting
`catalog-svc` went `Ready` again at `2026-09-04T06:57:10`, two seconds later. A node reboot, nothing
more.

### :warning: Prove the reachability claim before you believe it

A `connection refused` in the log is a statement about **the moment it was written**, not about now.
Both times this cluster logged one, the cause was transient restart ordering — and both had already
healed. Test the current state from inside the pod rather than inferring it:

```bash
POD=$(oc get pod -n kasten-io -l run=crypto-svc -o jsonpath='{.items[0].metadata.name}')

oc exec -n kasten-io "$POD" -c repositories-svc -- \
  curl -s -o /dev/null -w 'search: http_code=%{http_code} time=%{time_total}s\n' --max-time 10 \
  'http://catalog-svc:8000/v0/artifacts/search?key=artifact-type&value=Repository'

oc exec -n kasten-io "$POD" -c repositories-svc -- \
  curl -s -o /dev/null -w 'stream: http_code=%{http_code} time=%{time_total}s size=%{size_download}\n' --max-time 5 \
  'http://catalog-svc:8000/v0/artifacts/stream?offset=0&streamName=REPOSITORY.MODIFIED'
```

```
search: http_code=200 time=0.018201s
stream: http_code=200 time=0.014619s size=286821
```

Both fine. So on this cluster the catalog is reachable *today*, and the logged errors are the
archaeology of two past restarts, not a live fault.

Two traps to avoid while chasing this:

- **`catalog-svc` does not log HTTP requests.** Its whole log is 15 startup lines. Grepping it for
  `/artifacts/stream` and finding nothing proves nothing at all.
- **A transient error at startup looks alarming and is not.** On 2026-08-25 `crypto-svc` logged
  `Catalog unavailable, waiting for catalog to become available` plus a burst of connection-refused
  retries — then `Catalog is now available` 53 seconds later. That is normal pod start ordering.
  Always look for the recovery line before blaming the error.

### The timeline test

The decisive question is never "is there an error in the log" but "does the error **cover the whole
gap**". Line the two up:

| When | What |
|---|---|
| 2026-07-25 → 07-28 | last successful maintenance on every repository |
| 2026-08-10 | last policy run |
| 2026-08-25 02:19 | `crypto-svc` pod recreated, repository manager initialised cleanly |
| 2026-08-25 → 09-04 | **10 days, everything healthy, still no maintenance** |
| 2026-09-04 06:57 | repository stream breaks on a node reboot |
| 2026-09-08 12:32 | `basic-app-backup` triggered by hand → **maintenance runs 50 seconds later** |

The ten healthy days in the middle rule out both logged errors as the cause, and the last line rules
out a fault altogether: nothing was repaired between 09-04 and 09-08, yet maintenance ran the moment
a policy did. The gap was **an idle cluster**, not a broken one — every policy was on-demand or
paused, so no export touched a repository for six weeks.

The lesson generalises past this cluster. Both red lines in the log were real, both were transient
restart artefacts, and neither had anything to do with the symptom that started the investigation.
Before reading a single log line, ask the cheap question first:

```bash
# has anything actually been written to this repository lately?
oc get restorepoints.apps.kio.kasten.io -A --sort-by=.metadata.creationTimestamp | tail -5
oc get policies.config.kio.kasten.io -n kasten-io -o json \
  | jq -r '.items[]|"\(.metadata.name)\tpaused=\(.spec.paused // false)\tfreq=\(.spec.frequency // "onDemand")"'
```

If the answer is "nothing since July, and every policy is paused or on-demand", you are done — there
is no fault to find, and the rest of this section is not the tool you need. Only when a repository is
**actively receiving exports** and still not recording `MaintenanceRun` entries do the logs below
become worth reading; at that point the remaining moves are to restart the `crypto-svc` pod and watch
whether entries reappear, and to open a support case with a `k10tools debug logs` bundle.

Do not forget the boring one either — if the API itself is unhealthy you are reading stale or empty
data:

```bash
oc get apiservice v1alpha1.repositories.kio.kasten.io
oc logs -n kasten-io deploy/aggregatedapis-svc --tail=50
```

## 4.4 Cross-check on the bucket

The API is one source of truth, the bucket is the other. Port-forward MinIO (or point `mc` at your
real endpoint) and count blobs by prefix:

```bash
oc -n minio port-forward svc/minio 19000:9000 &
mc alias set kastenminio http://127.0.0.1:19000 minio minio123

CU=$(oc get ns default -o jsonpath='{.metadata.uid}')

blobs() {
  mc ls --recursive "$1" \
  | awk '{print $NF}' \
  | sed -E 's|.*/||; s/^_log.*/_log/; s/^(x[a-z]).*/\1/; s/^([pq]).*/\1/' \
  | sort | uniq -c | sort -rn
}

blobs kastenminio/mod/k10/$CU/migration/clusters-backup/kopia/
```

```
 161 _log
 145 xn
   4 xw
   3 xs
   2 xe
   1 q
   1 p
   1 kopia.repository
   1 kopia.maintenance
   1 kopia.blobcfg
```

The Kopia prefixes you will see (this repository format uses **epoch-based indexes**, so the index
blobs are `x*`, not the bare `n` that older Kopia documentation mentions):

| Prefix | What it is |
|---|---|
| `p` | pack blobs — your actual data |
| `q` | metadata packs |
| `xn` | per-epoch index blobs — **the ones quick maintenance compacts** |
| `xs` | single-epoch compacted index |
| `xe` | epoch-range compacted index |
| `xw` | epoch advance markers |
| `kopia.repository`, `kopia.blobcfg` | repository format and blob configuration |
| `kopia.maintenance` | the maintenance schedule and owner |
| `_log` | maintenance and session logs |

There is no universal threshold, but the *ratio* is telling. Compare a repository against itself
over time: under regular quick maintenance, `xn` blobs get folded into `xs`/`xe` and their count
stays bounded. A large and monotonically growing `xn` count with only a handful of `xs`/`xe` means
compaction is not keeping up — exactly the *"reduced performance"* the Kopia documentation warns
about. Do not compare two different repositories head-on: a busy repository legitimately has more
blobs than a quiet one.

Same repository, the volumedata side, for contrast:

```bash
mc ls --recursive kastenminio/mod/k10/$CU/migration/repo/180334e5-1259-4637-bf64-9f50ba82b88d/ \
  | awk '{print $NF}' | grep -v '^_log' | sort
```

```
kopia.blobcfg
kopia.maintenance
kopia.repository
q9ade6affd8990905801290abcc5fbd43-s1bc3a6109bb162b2143
xn0_5eb17a92478e1237b260f3b59577c8b8-sec7a846834427c02143-c1
xn0_9336cd7d72eb5fa962994833ce852dbc-s2c66d1e2f3bc609a143-c1
xn0_c5190693799a455c3696ae0cbb51926b-s1bc3a6109bb162b2143-c1
xn0_cb4a1af51eb05eea716054ba6378777c-s160822c5745b6e58143-c1
xw1784706722
xw1784879649
```

# Recap

```bash
NS=klusterlet-guest1

# 1. the volumedata repository of that namespace
oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS

# 2. the metadata repository is per POLICY, not per namespace
POLICIES=$(oc get storagerepositories -n kasten-io -l k10.kasten.io/appName=$NS -o json \
  | jq -r '[.items[].metadata.labels."k10.kasten.io/policyName"] | unique | join(" ")')
for p in $POLICIES; do
  oc get storagerepositories -n kasten-io -l k10.kasten.io/policyName=$p -o json \
  | jq -r '.items[] | select(.status.contentType=="metadata") | .metadata.name'
done

# 3. confirm through the path
CU=$(oc get ns default -o jsonpath='{.metadata.uid}')
NU=$(oc get ns "$NS" -o jsonpath='{.metadata.uid}')
echo "volumedata : k10/${CU}/migration/repo/${NU}/"
echo "metadata   : k10/${CU}/migration/<policyName>/kopia/"

# 4. age of the last successful maintenance, fleet-wide — the alert to build
oc get storagerepositories -n kasten-io -o json \
| jq -r '.items[]
    | . as $r
    | ([$r.status.processResults.recentResults[]?
        | select(.procedure=="MaintenanceRun" and .succeeded==true) | .endTime]
       | sort | last) as $l
    | "\($r.metadata.name)\t\($r.status.appName)\t\($l // "NEVER")\t" +
      (if $l then (((now-($l|fromdateiso8601))/3600)|floor|tostring)+"h" else "-" end)' \
| column -t
```

# References

- [Veeam Kasten — StorageRepository API](https://docs.kasten.io/latest/api/repositories/)
- [Kopia — Maintenance](https://kopia.io/docs/advanced/maintenance/)
- [Kopia — Verifying validity of snapshots/repositories](https://kopia.io/docs/advanced/consistency/)
