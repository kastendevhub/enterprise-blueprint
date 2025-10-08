# Goal 

When working we enterprise blueprint we often have to deal with RWX cephFS volume. 
But backing up (snap + export) ceph FS have performance issue that can be adressed with the [proper configuration of the kasten policy](https://docs.kasten.io/latest/install/storage/#ceph_fs_shallow_volumes).

## What's the issue with Ceph FS and Kasten ?

When Kasten backup a csi volume it take a snapshot first then clone it for export.

Also when kasten restore from a snapshot it clones the volume from the snapshot. 

The issue is that cephFS is very inefficient at cloning... 

## Why cephfs is inefficient at cloning, why is it different for RBD ?

The performance characteristics are very different between CephFS and RBD when it comes to cloning from snapshots, and this is a key architectural distinction.

### RBD (Block Storage) - Efficient Cloning

RBD cloning is cheap and fast because:

- Copy-on-Write (COW): RBD uses COW at the block level. When you clone from a snapshot, it creates a new image that initially shares all blocks with the parent snapshot.
- Block-level deduplication: Only when you write to a block in the clone does RBD actually copy that specific block. Unmodified blocks remain shared.
- Metadata operation: The initial clone is essentially a metadata operation that sets up the COW relationship - no data copying occurs upfront.
- RADOS object sharing: At the RADOS level, the clone and parent share the same objects until divergence occurs.

### CephFS - Expensive Cloning

CephFS cloning is slow and resource-intensive because:

- File-level semantics: CephFS operates at the file level, not block level. Each file must be individually handled.
- No native COW for files: Unlike block devices, CephFS doesn't have efficient copy-on-write at the file level in the clone-from-snapshot operation.
- Full data copy: When cloning a CephFS snapshot to a new volume, the CSI driver must copy all the file data, not just metadata.
- Directory tree reconstruction: The entire directory structure and all file contents must be duplicated.

## How can we adress this issue ? 

For backup a [proposal](https://github.com/ceph/ceph-csi/blob/devel/docs/design/proposals/cephfs-snapshot-shallow-ro-vol.md) has been implemented to create read only volume that does not require the full copy of the filesystem.

In Kubenetes this is supported by adding the parameter `backingSnapshot: true` to the storage class.

## Leveraging this feature in Kasten 

### Create a shallow storage class 

You can create a specific storage class which is a clone of the cephfs whith the parameter `backingSnapshot: "true"`.

Also Kasten need to know that this volume can be mounted in read only mode to the data mover for this we have the `k10.kasten.io/sc-supports-read-only-mount: "true"` annotations

Here is an example of how you can proceed to create this new storage class 

```
oc get sc ocs-storagecluster-cephfs -o yaml > ocs-storagecluster-cephfs-shallow.yaml
```

Then edit it, change the name, add the parameter and the annotation.
```
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  #####################
  ## change the storage class name
  name: ocs-storagecluster-cephfs-shallow  
  
  annotations:
    description: Provides RWO and RWX Filesystem volumes    
    ######################
    ## add this annotation
    k10.kasten.io/sc-supports-read-only-mount: "true"
parameters:
  #####################
  ## add this parameter 
  backingSnapshot: "true"
  clusterID: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  fsName: ocs-storagecluster-cephfilesystem
provisioner: openshift-storage.cephfs.csi.ceph.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
```

Create the shallow storage class 
```
oc create -f ocs-storagecluster-cephfs-shallow.yaml
```

### Use this storage class for exporting 

Edit the policy to override the exporter storage class 
```
exportData:
  enabled: true
  overrides:
    - storageClassName: ocs-storagecluster-cephfs
      enabled: true
      exporterStorageClassName: ocs-storagecluster-cephfs-shallow
```

## When you restore 

Now export of cephFS volume are much more efficient but for the same reason explained above you should not restore from a ceph FS snapshot instead you should use the exported restore point to restore those volumes.



