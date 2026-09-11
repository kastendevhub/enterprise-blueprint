# Recommended storage architecture for Veeam Kasten on VMware vSphere

**Audience:** architects and platform teams deploying Veeam Kasten (K10) against vSphere CSI / CNS.
**Purpose:** avoid the datastore-consumption and orphaned-disk problems that arise from the default,
unconstrained configuration — and make the remaining drift *reliably detectable*.

> **The core idea.** Most "Kasten filled up my datastore" incidents are not bugs. They are the
> predictable result of running a backup product against a storage architecture that allows disks to
> outlive every object that references them, combined with retention settings that keep local
> snapshots alive. Constrain the architecture and the problem largely disappears; the residual drift
> becomes trivially detectable instead of a forensic exercise.


---

## Table of contents

- [A. The architecture: CNS, datastores and FCDs](#a-the-architecture-cns-datastores-and-fcds)
- [B. Why the datastore fills up when Kasten runs](#b-why-the-datastore-fills-up-when-kasten-runs)
- [C. Recommendations](#c-recommendations)
- [D. Detection scripts](#d-detection-scripts)

---

## A. The architecture: CNS, datastores and FCDs

### A.1 The object hierarchy

```
vCenter Server ─── one CNS control plane, covering every K8s cluster on this vCenter
  └── Datacenter ─── belongs to exactly ONE vCenter (strict)
        ├── Cluster / Hosts
        └── Datastore ─── PHYSICAL: the same LUN/NFS/vSAN can be presented
                          to hosts under a DIFFERENT vCenter
              └── fcd/ ─── where First Class Disks live (by convention)
```

Two asymmetries in that diagram cause most of the confusion:

- A **Datacenter** is strictly one vCenter's inventory object. Enhanced Linked Mode shares an SSO
  domain and a unified *view*, not the objects.
- A **datastore** is physical storage. Nothing stops it being presented to hosts managed by another
  vCenter — and FCD catalog metadata lives *on the datastore*, which is what makes FCDs portable.
  This is the root of the most dangerous false positive (§B.7).

### A.2 What a First Class Disk actually is

An FCD is **not a different file format**. It is an ordinary VMDK — same extension, same on-disk
layout. What differs is the management plane:

| | Regular VMDK | FCD / Improved Virtual Disk (IVD) |
| --- | --- | --- |
| **Identity** | Datastore path, referenced from a VM's `.vmx` | vCenter-assigned UUID (`VStorageObject` ID), independent of any VM |
| **Catalog** | None — you browse the datastore to find it | vCenter maintains a VStorageObject catalog; **this is what `govc disk.ls` queries** |
| **Lifecycle** | Tied to its VM | create / delete / clone / extend / attach / detach via the vslm API, **with no VM involved** |
| **Snapshots** | Only as part of a VM snapshot | **Per-disk snapshots via the FCD API** — what K10 uses, and what blocks disk deletion |
| **Location** | VM folder | Datastore's `fcd/` folder, *by convention* |

**Lifecycle independence is the whole point of FCDs, and also the whole problem.** A disk designed
to outlive any VM or Kubernetes object has, by design, no owner to garbage-collect it.

Two properties to remember:

- **`disk.ls` is authoritative, the `fcd/` path is not.** `disk.ls` returns only FCDs because it
  queries the catalog. Treat the path as a convention, never as the test for "is this an FCD".
- **FCD snapshots are embedded in the parent disk.** Per Kasten's own documentation: *"a VMware
  snapshot is embedded in its associated FCD volume and does not exist independent of this volume,
  and it is not possible to delete an FCD volume if it has snapshots."* This single fact drives
  most of section B.

### A.3 Two registries that must agree

| API | `govc` surface | Question it answers |
| --- | --- | --- |
| vslm / FCD | `disk.ls` (scoped to `GOVC_DATASTORE`) | Which disk objects physically exist here? |
| CNS | `volume.ls` | Which of those are known Kubernetes volumes? |

They are kept consistent by convention and best-effort sequencing, **not by a transaction**. Drift
has a characteristic direction: a disk present on the datastore with no CNS record. That asymmetry
is what makes drift detectable — and why every detection method in section D is a comparison
between these two lists.

CNS itself is a **vCenter-level service**:

> "The CNS server component, or the CNS control plane, resides in vCenter Server. It is an extension
> of vCenter Server management that implements the provisioning and life cycle operations for the
> container volumes."

One per vCenter, covering *every* Kubernetes cluster registered to it — including a Tanzu supervisor
and all its guest clusters. Per-volume container-cluster metadata distinguishes them; it appears as
the cluster-ID column in `govc volume.ls -l` output, e.g. `vmware-system-csi/k8s-prod`.

**Consequence:** `volume.ls` is already the union across every cluster on that vCenter. You never
need to enumerate clusters to ask "does anything still reference this disk?" — provided all the
relevant clusters are on that one vCenter. Which is precisely what recommendation R1 guarantees.

---

## B. Why the datastore fills up when Kasten runs

Seven distinct mechanisms. Only some are avoidable, and they need different fixes — which is why
"Kasten is leaking disks" is never a useful diagnosis.

### B.1 Retained local snapshots — by design, not a leak

An FCD cannot be deleted while it carries snapshots. So while K10 holds local restore points, the
disk stays, at full size. If the PVC is deleted, CSI's `DeleteVolume` fails and the PV sits in
`Released`.

**This is correct behaviour and it self-heals.** Per the vSphere CSI driver and Kasten
documentation, the driver retries periodically; when the last snapshot is reaped the delete
succeeds and both the PV and the FCD are reclaimed. Broadcom's KB is explicit: *"Existing snapshot
prevents deletion of PVC. This is by design."*

The space is not wasted — **it is the storage cost of the local-snapshot retention you configured.**
This is the single largest contributor to datastore consumption, and it is a settings choice
(see R3).

### B.2 Force-deleting a `Released` PV — the one irreversible mistake

The `Released` PV, held by its protection finalizer, is the **anchor** that keeps the CSI driver
retrying the delete. The widely-circulated workaround destroys it:

```bash
kubectl patch pv <pv> -p '{"metadata":{"finalizers":null}}'   # DO NOT DO THIS
```

Afterwards nothing will ever call `DeleteVolume` again, and the FCD is stranded **permanently**.
Kasten's documentation warns about exactly this: *"do not force delete Kubernetes PersistentVolume
objects in the Released state as this would orphan the associated FCD volumes!"*

It also destroys evidence: `spec.csi.volumeHandle` on that PV is your only convenient link from
Kubernetes to the FCD ID. Once the PV is gone, cleanup degrades from a two-command lookup to a
datastore-wide search with no provenance.

> **Why operators do it anyway:** in FCD-native mode the blocking snapshot has **no Kubernetes
> representation at all** — `kubectl get volumesnapshot -A` returns nothing. The operator sees a
> wedged PV with no visible cause and reasonably concludes it is stale metadata. R3 removes this
> situation entirely; R5 is the interim rule.

### B.3 In-place restores — capacity doubling

Restoring an application into the same namespace *replaces* its PVCs. The old PVC is deleted, firing
`DeleteVolume` against an FCD that is carrying K10's restore points — refused (B.1). Meanwhile the
restore provisions replacements: *"new Kubernetes PersistentVolume objects (with new FCD volumes)
are created for the application."*

Net effect of one in-place restore: **a new FCD in use plus the old one retained at full size.**
Consumption roughly doubles per restore and compounds across repeats. Kasten's docs confirm the
retained disk is still needed: *"any restore point that involves local snapshots will now point into
FCD volumes associated with PersistentVolume objects in the Released state!"*

### B.4 Temporary full clones in CSI VolumeSnapshot mode

Documented product behaviour, and entirely avoidable:

> "Exports using this mechanism create a temporary, full clone from a VolumeSnapshot to read its
> data, which could be an expensive operation for underlying storage infrastructure."

Every export in this mode creates a full-size clone FCD, uses it, and deletes it. That is a lot of
create/delete churn on the CSI path — and every one of those operations is a chance to leave a
partial artifact (B.5). **Configuring an Infrastructure Profile eliminates the clone entirely**
(R2), because FCD-native and Hybrid modes read data directly from vSphere via VDDK.

### B.5 Partial volume creation under load

FCD creation and CNS registration are **not atomic**: the disk is created on the datastore, then
registered with CNS. Interrupt that sequence and you get a VMDK with no CNS record.

In the field this clusters around **large policies that fan out across many PVCs at once**:

- CSI sidecars (`csi-provisioner`, `csi-snapshotter`) enforce per-operation timeouts. An operation
  that exceeds one is abandoned **client-side while still running server-side**.
- The sidecar then retries. Because the driver correlates retries against *CNS state*, and the
  missing CNS registration is exactly what is absent, it cannot recognise its own in-flight work
  and creates a **second** disk. The first is stranded permanently.
- vCenter serialises and rate-limits tasks, so a large burst queues and more operations cross the
  timeout threshold.
- A CSI controller or K10 pod restarting mid-burst abandons every in-flight operation at once.

This happens in **every** backup mode. The underlying non-atomicity is VMware's, but the fan-out
that triggers it is yours to control (R4).

### B.6 Generic CNS drift

CNS runs a periodic full-sync between its catalog, the FCDs and the Kubernetes API. That sync has a
history of races, particularly around vCenter restarts, CSI driver upgrades, and volumes relocated
by Storage vMotion or SDRS. Not preventable from Kasten; R1 and R6 limit the blast radius.

### B.7 Not a cause, but the reason detection is dangerous

Two ways a **live** disk can look orphaned:

- **Shared datastore.** A datastore presented to hosts under two vCenters can expose an FCD whose
  CNS registration lives in the *other* vCenter. `disk.ls` sees it, the local `volume.ls` does not.
- **Foreign FCD consumers.** FCDs are not Kubernetes-only. VMware Integrated OpenStack uses them,
  Veeam Backup & Replication can restore as FCD, other CSI drivers and backup vendors create them.

Absence from CNS means *"not a container volume **here**"* — it does **not** mean "unused". This is
why the scripts in section D are only trustworthy once R1 is in place.

---

## C. Recommendations

Ordered by impact. R1 and R3 together eliminate or make-detectable the great majority of what
section B describes.

### R1. Dedicate datastores: one datastore serves exactly one cluster, on exactly one vCenter

**Rule:** a datastore used for Kubernetes persistent volumes must contain *only* FCDs backing PVCs,
for *one* Kubernetes cluster, reachable from *one* vCenter.

- One cluster **may** use several dedicated datastores.
- A datastore **must not** be shared by two clusters, host VM disks alongside FCDs, or be presented
  to hosts under a second vCenter.

**Why.** This is what converts detection from inference into arithmetic. On a dedicated datastore:

| Hazard | Effect of R1 |
| --- | --- |
| Foreign FCD consumers (B.7) | Impossible — nothing else provisions here |
| Second vCenter's CNS holds the record (B.7) | Impossible — single vCenter |
| Another cluster still references the disk | Impossible — single cluster |
| "Is this FCD ours?" | Answered by construction |

The comparison "FCDs on this datastore" versus "volume handles in this cluster" becomes
**complete and authoritative**. False positives are not merely unlikely; they are structurally
excluded. That is the whole basis of section D.

**How to implement.** Pin the StorageClass to the intended datastore rather than relying on
convention:

```yaml
# Option 1 — direct datastore targeting
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: vsphere-k8s-prod-ds01
provisioner: csi.vsphere.vmware.com
parameters:
  # obtain with: govc datastore.info -json <ds> | jq -r '.datastores[].info.url'
  datastoreurl: "ds:///vmfs/volumes/<datastore-uuid>/"
reclaimPolicy: Delete
allowVolumeExpansion: true
```

```yaml
# Option 2 — tag-based SPBM policy (preferable at scale: tag the datastores,
# build a storage policy from the tag, reference the policy here)
parameters:
  storagePolicyName: "k8s-prod-fcd-only"
```

**Operational guardrails:**

- **Disable SDRS automation / Storage vMotion** for these datastores, or at minimum alert on it.
  Relocating an FCD breaks the dedication invariant and is a known trigger for CNS drift (B.6).
- **Name the datastore for its purpose** — e.g. `K8S-PROD-FCD-01`. Anyone browsing vCenter should
  see immediately that it is not a general-purpose datastore.
- **Size for the retention commitment**, not just the live PVC footprint. With local snapshots
  retained, plan for live volumes plus retained restore points plus in-place-restore headroom
  (B.1, B.3). With R3 applied, live footprint plus a modest working margin is sufficient.

### R2. Configure a vSphere Infrastructure Profile (use FCD-native or Hybrid mode)

**Why.** Eliminates the temporary full clone on every export (B.4) — documented behaviour, not an
optimisation — and is the only way to get CBT-based incremental exports. Fewer volume
create/delete cycles means fewer opportunities for the partial-creation failure in B.5.

Also enable **changed block tracking on the VMware cluster nodes**, per the Kasten documentation,
to reduce data transferred on incremental exports.

**Prefer Hybrid mode where available.** FCD-native takes snapshots directly via vCenter, so those
snapshots have **no Kubernetes representation** — which is what makes B.2 so easy to walk into.
Hybrid (annotated `VolumeSnapshotClass` **and** an Infrastructure Profile) gives CSI-visible
`VolumeSnapshot` objects *and* VDDK-based export.

#### R2 trade-offs — evaluate these before committing

R2 is the one recommendation in this guide that can be **blocked by constraints outside the
storage team's control**, and the one with a genuine performance downside. All four points below
are load-bearing.

**1. CBT slows write-heavy operations. Validate against your RTO SLA, not just your backup window.**

CBT optimises *incremental backup* — less data read and transferred. It does so by adding
per-block tracking overhead on the **write** path. A full restore is all writes, so CBT penalises
exactly the operation your recovery SLA is written against.

> **Field data point:** a ~10 TB Cassandra database restored in **6 hours with CBT enabled**, where
> the same restore completed in **3 hours with CBT disabled**. CBT doubled RTO for a full restore.

The ratio is workload- and storage-dependent, so measure it in your own environment — but treat
"enable CBT" as an RTO decision, not a backup-efficiency tweak. If your recovery SLA has little
headroom, CBT may be the wrong choice even though it makes backups cheaper. Consider differing
settings per workload tier rather than a blanket policy.

**2. Network: worker nodes must reach ESXi hosts on TCP 902, and resolve them by DNS.**

Per [Veeam KB4615](https://www.veeam.com/kb4615):

> "TCP Port 902 must be open between Kubernetes worker nodes and ESXi hosts."
>
> "Veeam Kasten *for Kubernetes* requires network access from the cluster to vCenter and the ESX
> hosts in TKGs environments."

This is frequently the hard blocker. It means the **pod/node network must reach the ESXi management
network** — which security teams often refuse outright, and reasonably so: it is a path from
workload networks into the hypervisor management plane. Budget time for that conversation early,
because if the answer is no, R2 is unavailable and you fall back to CSI VolumeSnapshot mode.

Two related failure modes, both surfacing as the same opaque VDDK error
`Open virtual disk file failed. The error code is 14009`:

- **DNS.** "if the ESX server cannot be resolved using DNS, it throws error 14009" — the ESXi hosts
  must be resolvable *from inside the cluster*, not merely reachable by IP.
- **Timeout.** The Kanister backup timeout (default **45 minutes**) can be exceeded by long-running
  exports, producing the same error. Large volumes may need this raised regardless of CBT.

Verify before rollout, from a pod on the cluster network rather than from a laptop:

```bash
# from inside the cluster — substitute a real ESXi host
kubectl run netcheck --rm -it --restart=Never --image=busybox -- \
  sh -c 'nslookup esx01.example.com && nc -zv -w5 esx01.example.com 902'
```

**3. Tanzu supervisor-provisioned workload clusters: CBT enablement is awkward and poorly
documented.**

On guest/workload clusters created by a Tanzu supervisor, enabling changed block tracking requires
supervisor-side configuration that VMware documents poorly, and in practice the data path runs
through the **Velero vSphere Operator / vSphere plugin for Velero** — so backup vendors end up
documenting "install the Velero vSphere Operator" as a prerequisite even for products that do not
otherwise use Velero. Veeam and Dell PowerProtect both carry versions of this instruction.

Practical consequences:

- Confirm the exact procedure against **your** TKG and vSphere versions; it has changed between
  releases and third-party write-ups go stale quickly.
- Expect to install a supervisor service you did not plan for, with its own lifecycle and upgrade
  considerations.
- Budget significantly more time here than for a vanilla cluster, and validate end-to-end on a
  non-production guest cluster first.

**4. If R2 is unavailable, the other recommendations matter more, not less.**

Where port 902 cannot be opened, CBT breaks the restore SLA, or the Tanzu path is not worth the
complexity, you remain in **CSI VolumeSnapshot mode** and inherit the temporary full clone on every
export (B.4). That raises the volume-operation count substantially, which makes **R4 (bound
fan-out)** considerably more important — the clone churn is exactly what triggers B.5. **R1 and
R3 are unaffected and remain the highest-value changes**; neither depends on R2 in any way.

### R3. Retain no local snapshots — export to the repository and release the disk

**This is the single highest-value setting, and it is the model Veeam Backup & Replication has
always used:** snapshot, copy the data to the repository, remove the snapshot. VBR does not keep
its snapshots, which is precisely why it never encounters the FCD-snapshot-blocks-deletion problem.

Configure K10 policies so local snapshot retention is zero (or the minimum your version allows),
with exports enabled and retention applied to the **exported** restore points. The snapshot then
exists only for the duration of the export and is removed when the run action completes.

**What this buys you:**

| Mechanism | With local snapshots retained | With R3 applied |
| --- | --- | --- |
| B.1 retained disks | Largest consumer of capacity | **Eliminated** |
| B.2 `Released` PVs | Common; invites the fatal patch | **Never occurs** — PVC deletion releases the FCD immediately |
| B.3 in-place restore doubling | Old FCD retained | **Eliminated** — old FCD released at once |
| Snapshot detection (D.2) | Must distinguish live restore points from strays | **Any snapshot at rest is an anomaly** |

That last row is why R3 matters as much for *detection* as for capacity: once no snapshot is
supposed to exist outside a running policy window, finding one is unambiguous. No cross-referencing
of restore-point catalogues, no risk of deleting live backup data.

**Trade-off, stated plainly.** You give up fast local restore. Every recovery comes from the export
repository, so RTO is bounded by restore-from-object-storage speed rather than snapshot revert
speed. That is the same trade VBR makes by default. Where a specific application genuinely needs
fast local rollback, keep local retention **short** for that policy only, and accept that the
datastore-consumption and `Released`-PV management described in B.1–B.3 apply to it.

> **Open question: when exactly is the snapshot released?** The mechanism itself is established
> from field experience — with local retention at zero, K10 creates the snapshot only for the
> duration of the export and removes it afterwards. What is **not** established is the cleanup
> *boundary*:
>
> | Boundary | Peak snapshot footprint | Implication |
> | --- | --- | --- |
> | End of each **export action** (per namespace/application) | One application's snapshot at a time, bounded by export concurrency | Negligible; datastore sized for live PVCs plus a small margin |
> | End of the **run action** (per policy) | **Every** application's snapshot in the policy, held simultaneously until the whole policy completes | A policy covering 50 namespaces briefly holds 50 snapshots — size the datastore for the whole set |
>
> For a policy spanning many namespaces these differ enormously. **Until this is confirmed on your
> version, assume the pessimistic case** (per run action) and size accordingly — or apply R4 and
> split large policies, which bounds the peak either way.
>
> **How to measure it.** Run a multi-namespace policy and sample the snapshot count during the run.
> If the count climbs across applications and only drops at the very end, the boundary is the run
> action. If it rises and falls per application, it is the export action.
>
> ```bash
> # sample every 30s during a policy run; Ctrl-C to stop
> while :; do
>   n=$(govc disk.ls | awk 'NF {print $1}' \
>        | xargs -I{} sh -c 'govc disk.snapshot.ls {} 2>/dev/null | grep -c .' \
>        | awk '{s+=$1} END {print s+0}')
>   printf '%s  fcd_snapshots=%s\n' "$(date +%T)" "${n}"
>   sleep 30
> done
> ```
>
> Also worth confirming at the same time: Kasten's documentation describes snapshot and export
> retention as independently configurable but does not explicitly document a zero-local-snapshot
> configuration, so verify the end state too — after a completed policy run, **D.2** should report
> nothing. If snapshots persist once the run has finished, R3 is not in effect and the assumptions
> behind section D do not hold.

### R4. Bound policy fan-out

Large policies that snapshot or clone many PVCs simultaneously are the observed trigger for the
partial-creation orphans in B.5 — **and, depending on the R3 cleanup boundary, they also determine
peak snapshot footprint on the datastore.** If snapshots are only released at the end of a run
action, a policy covering 50 namespaces holds 50 snapshots at once. Splitting policies bounds that
peak regardless of which boundary applies, which makes it the safe choice while the question is
open.

- Split very large policies into several smaller ones on staggered schedules, rather than one
  policy covering hundreds of volumes.
- Stagger start times so bursts do not overlap across policies.
- Review K10's concurrency settings and confirm the effective limit is appropriate for your vCenter
  rather than left at an unbounded default.
- Watch for the signature in CSI sidecar logs during backup windows:
  ```bash
  kubectl logs -n vmware-system-csi deploy/vsphere-csi-controller -c csi-provisioner \
    | grep -iE 'context deadline exceeded|timeout|failed to provision'
  ```
  Any hits mean operations are being abandoned client-side while possibly still running
  server-side — the exact condition that strands disks.

R2 helps here too: eliminating the temporary full clone removes a large share of the volume
operations that would otherwise be in flight.

### R5. Never force-delete a `Released` PV — make this an operational rule

Until R3 is fully in place, `Released` PVs will occur. The rule for operators:

> A PV in `Released` state on a vSphere CSI storage class is a **pending** delete, not a stuck one.
> Leave it alone. It clears itself when the restore points holding it expire.

If the space is needed sooner, work from Kubernetes and Kasten — never from vCenter:

```bash
# 1. Which application does this PV belong to?
kubectl get pv <pv> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'

# 2. Capture the FCD ID while the PV still exists — this mapping is lost if the PV is deleted
kubectl get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

# 3. Confirm the cause
kubectl describe pv <pv> | grep -i -A3 'failed to delete'
```

Then **expire or delete that application's restore points in Kasten**. Kasten removes its own FCD
snapshots, the CSI retry succeeds, and the PV and FCD are reclaimed automatically.

Do **not** delete FCD snapshots directly in vCenter or with `govc disk.snapshot.rm` to unstick a
PV — that removes them behind Kasten's back and leaves restore points in its catalogue that can no
longer restore. Understand also that deleting restore points to reclaim space **is deleting
backups**; it is a deliberate trade, not a tidy-up.

### R6. Monitor, and run detection on a schedule

- Alert on datastore free space with enough headroom to absorb one in-place restore of the largest
  protected application (B.3), unless R3 is in place.
- Run **D.1** and **D.2** on a schedule and alert on any non-empty result. Under R1 and R3 both
  should normally return nothing, which makes them useful signals rather than noisy reports.
- Alert on `Released` PVs so they are investigated rather than discovered by someone improvising.
- Alert on CSI sidecar timeouts during backup windows (R4).

---

## D. Detection scripts

> ## ⚠ Read this before running anything below
>
> **These scripts are reliable if and only if the recommendations above are in force.**
>
> | Requirement | Why the script depends on it |
> | --- | --- |
> | **R1** — datastore dedicated to one cluster, one vCenter, FCDs only | Without it, a disk absent from this CNS may belong to another cluster, another vCenter, or another product entirely. Every "orphan" it reports could be live data. |
> | **R3** — no local snapshots retained | Without it, a disk with snapshots may be backing **live restore points**. Deleting it destroys recoverable backups, discovered only at the next restore. |
>
> Without R1 and R3, treat all output as **questions to investigate**, never as a delete list.
> Under R1 and R3 the results are authoritative — which is the entire point of adopting them.
>
> Every script here is **read-only**. Deletion is D.4, manual and deliberate.

### D.0 Connect

```bash
export GOVC_URL=https://vcenter.example.com
export GOVC_USERNAME=k10-storage-ro@vsphere.local
export GOVC_INSECURE=true            # omit if the vCenter certificate is trusted
export GOVC_DATASTORE=/MyDatacenter/datastore/K8S-PROD-FCD-01
echo -n 'Password: ' && read -rs GOVC_PASSWORD && export GOVC_PASSWORD && echo

govc about >/dev/null && echo "connected: ${GOVC_URL}"
```

`GOVC_DATASTORE` scopes every `disk.*` command. **Repeat the whole procedure once per dedicated
datastore** — and under R1 you know exactly which cluster each one belongs to.

### D.1 Detect orphaned FCDs

Compares the datastore's FCD catalogue against CNS. Under R1, anything absent from CNS is
genuinely unreferenced.

```bash
#!/usr/bin/env bash
# detect-orphan-fcd.sh — read-only. Requires R1 to be meaningful.
set -euo pipefail
: "${GOVC_DATASTORE:?set GOVC_DATASTORE}"

printf 'Datastore: %s\n\n' "${GOVC_DATASTORE}"
printf '%-38s %-10s %s\n' "FCD ID" "SNAPSHOTS" "NAME / SIZE / CREATED"
printf '%s\n' "$(printf '=%.0s' {1..100})"

total=0
while read -r id _rest; do
  [ -n "${id}" ] || continue

  # Present in CNS? Non-empty means a Kubernetes volume still owns it.
  if [ -n "$(govc volume.ls -l "${id}" 2>/dev/null)" ]; then
    continue
  fi

  snaps=$(govc disk.snapshot.ls "${id}" 2>/dev/null | grep -c . || true)
  # disk.ls -l prints: <id> <name> <size> <date>; strip the leading id we already show
  detail=$(govc disk.ls -l "${id}" 2>/dev/null | head -1 | sed "s/^${id}[[:space:]]*//")

  printf '%-38s %-10s %s\n' "${id}" "${snaps}" "${detail}"
  total=$((total + 1))
done < <(govc disk.ls)

printf '\n%d FCD(s) with no CNS record.\n' "${total}"
[ "${total}" -eq 0 ] && printf 'No drift detected.\n'
printf '\nNOTE: a non-zero SNAPSHOTS count means this disk may back live restore\n'
printf 'points. Under R3 that should never happen — investigate before deleting.\n'
```

### D.2 Detect orphaned FCD snapshots

**Under R3 this script should always return nothing.** A snapshot found at rest — outside a running
policy window — is by definition an anomaly, which is what makes this check trustworthy.

```bash
#!/usr/bin/env bash
# detect-orphan-snapshots.sh — read-only. Only meaningful under R3.
set -euo pipefail
: "${GOVC_DATASTORE:?set GOVC_DATASTORE}"

printf 'Datastore: %s\n' "${GOVC_DATASTORE}"
printf 'Expectation under R3 (no local snapshot retention): no output below.\n\n'

found=0
while read -r id _rest; do
  [ -n "${id}" ] || continue
  snaps=$(govc disk.snapshot.ls "${id}" 2>/dev/null || true)
  if [ -n "${snaps}" ]; then
    in_cns=$([ -n "$(govc volume.ls -l "${id}" 2>/dev/null)" ] && echo "yes" || echo "NO")
    printf 'FCD %s  (in CNS: %s)\n' "${id}" "${in_cns}"
    sed 's/^/    /' <<<"${snaps}"
    found=$((found + 1))
  fi
done < <(govc disk.ls)

if [ "${found}" -eq 0 ]; then
  printf 'Clean: no FCD snapshots on this datastore.\n'
else
  printf '\n%d FCD(s) carry snapshots.\n' "${found}"
  printf 'If a policy is running now, this is expected and transient — re-run when idle.\n'
  printf 'If no policy is running, either R3 is not in effect or these are strays.\n'
fi
```

### D.3 Definitive reconciliation: datastore versus cluster

The payoff of R1. Because the datastore serves exactly one cluster on exactly one vCenter, a set
difference gives a complete and authoritative answer — no heuristics, no age thresholds, no
guessing about provenance.

```bash
#!/usr/bin/env bash
# reconcile-datastore-vs-cluster.sh — read-only. R1 is what makes this authoritative.
set -euo pipefail
: "${GOVC_DATASTORE:?set GOVC_DATASTORE}"

tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT

# Every FCD physically present on this datastore
govc disk.ls | awk 'NF {print $1}' | sort -u > "${tmp}/on_datastore"

# Every volume handle referenced by this cluster, in ANY PV phase
kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' \
  | awk 'NF' | sort -u > "${tmp}/in_cluster"

# Everything CNS still knows about on this vCenter (all clusters)
govc volume.ls | awk 'NF {print $1}' | sort -u > "${tmp}/in_cns"

printf 'FCDs on datastore : %s\n' "$(wc -l < "${tmp}/on_datastore")"
printf 'Handles in cluster: %s\n' "$(wc -l < "${tmp}/in_cluster")"
printf 'Volumes in CNS    : %s\n\n' "$(wc -l < "${tmp}/in_cns")"

printf '== On datastore but NOT referenced by any PV and NOT in CNS ==\n'
printf '   (under R1 + R3: true orphans, reclaimable)\n'
comm -23 "${tmp}/on_datastore" "${tmp}/in_cluster" | comm -23 - "${tmp}/in_cns" | sed 's/^/  /'

printf '\n== On datastore, not referenced by a PV, but STILL IN CNS ==\n'
printf '   (a CNS record with no PV — investigate, do NOT delete)\n'
comm -23 "${tmp}/on_datastore" "${tmp}/in_cluster" | comm -12 - "${tmp}/in_cns" | sed 's/^/  /'

printf '\n== Referenced by a PV but MISSING from the datastore ==\n'
printf '   (serious: a PV pointing at a disk that is not here. Wrong datastore, or data loss)\n'
comm -13 "${tmp}/on_datastore" "${tmp}/in_cluster" | sed 's/^/  /'
```

The third section matters as much as the first: a PV whose volume handle is absent from the
datastore means either the dedication invariant has been broken (the volume lives elsewhere) or a
disk has already been deleted underneath a live PV.

### D.4 Reclaiming — manual, deliberate, one at a time

Only for IDs that D.3 reports in the **first** section, with R1 and R3 both in force.

```bash
ID=<fcd-id>

# 1. Re-verify immediately before acting — state may have changed
govc disk.ls -L "${ID}"            # resolves => disk exists
govc volume.ls -l "${ID}"          # MUST be empty
govc disk.snapshot.ls "${ID}"      # MUST be empty
kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' | grep -F "${ID}"
                                   # MUST return nothing

# 2. Confirm no Kasten job is running. Then, and only then:
govc disk.rm "${ID}"

# 3. Confirm
govc disk.ls -L "${ID}"            # expect: not found
```

**Rules, not suggestions:**

- **One disk at a time.** Never loop `disk.rm` over a report.
- **Re-verify each ID at the moment of deletion.** A report generated an hour ago is a hypothesis.
- **If a disk has snapshots, stop.** `disk.rm` will fail anyway — treat that failure as a signal,
  not an obstacle to route around with `disk.snapshot.rm`. Snapshots mean R3 is not in effect and
  the disk may back live restore points.
- **Never during a backup, restore or export window.**
- **Deletion is irreversible.** If the dedication invariant (R1) is not actually true in your
  environment, these commands can destroy live application data or recoverable backups.

### D.5 Command reference

| Command | Purpose |
| --- | --- |
| `govc disk.ls` | FCDs on `GOVC_DATASTORE` (queries the VStorageObject catalogue) |
| `govc disk.ls -l <id>` | Long listing: name, size, creation date |
| `govc disk.ls -L <id>` | Resolve an FCD to its VMDK backing path |
| `govc disk.snapshot.ls <id>` | Snapshots of one FCD |
| `govc volume.ls` | CNS volumes on this vCenter (all clusters) |
| `govc volume.ls -l <id>` | CNS detail: PVC name, capacity, storage class, cluster ID |
| `govc volume.snapshot.ls -i <id>` | CNS snapshots of one volume |
| `govc disk.rm <id>` | **Destructive** — delete an FCD |
| `govc datastore.info <ds>` | Datastore detail, including the URL needed for a StorageClass |
| `kubectl get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}'` | PV → FCD ID (lost if the PV is force-deleted) |
| `kubectl get pv <pv> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'` | PV → owning application |

---

## Summary

| # | Recommendation | Primarily addresses |
| --- | --- | --- |
| **R1** | One datastore → one cluster → one vCenter, FCDs only | Makes detection authoritative; eliminates all false positives (B.7) |
| **R2** | Configure an Infrastructure Profile; prefer Hybrid mode | Removes temporary full clones (B.4); enables CBT; keeps snapshots CSI-visible. **Check the trade-offs** — CBT can double restore time, needs TCP 902 to ESXi, awkward on Tanzu guest clusters |
| **R3** | Retain no local snapshots — the VBR model | Eliminates B.1, B.2 and B.3; makes snapshot detection unambiguous |
| **R4** | Bound policy fan-out | Reduces partial-creation orphans (B.5); bounds peak snapshot footprint under R3 |
| **R5** | Never force-delete a `Released` PV | Prevents the one irreversible mistake (B.2) |
| **R6** | Monitor and run D.1/D.2 on a schedule | Catches residual drift (B.5, B.6) while it is still traceable |

**R1 and R3 are the two that matter most** — and notably neither depends on R2, which is the only
recommendation here that an external constraint (hypervisor network access, an RTO SLA, or a Tanzu
supervisor topology) can take off the table. R1 makes drift detectable with certainty rather than
inference. R3 removes the largest source of consumption and, by ensuring no snapshot should ever
exist at rest, turns snapshot detection into a simple yes/no question. Together they reduce a
problem that currently requires forensic analysis to two scheduled scripts that should both return
nothing.
