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

See the [performance test](#test-the-difference-performance-when-cloning) to understand the impact but this is very impactful from 5s to 20 minutes !!

## How can we adress this issue ? 

For backup a [proposal](https://github.com/ceph/ceph-csi/blob/devel/docs/design/proposals/cephfs-snapshot-shallow-ro-vol.md) has been implemented to create read only volume that does not require the full copy of the filesystem.

In Kubenetes this is supported by adding the parameter `backingSnapshot: true` to the storage class.

## Leveraging this feature in Kasten 

### Create a shallow storage class 

You can create a specific storage class which is a clone of the cephfs whith the parameter `backingSnapshot: "true"`.

Also Kasten need to know that this volume must be created in ReadOnlyMany mode (ROX) for this we have to set up the `k10.kasten.io/sc-supports-read-only-mount: "true"` annotations on the storage class.

Here is an example of how you can proceed to create this new storage class 

clone your manifest in a file 
```
oc get sc ocs-storagecluster-cephfs -o yaml > ocs-storagecluster-cephfs-shallow.yaml
```

Then edit it, change the name, add the parameter and the annotation. Here is an example but the value will depends on your own setting.
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


# Test the difference performance when cloning 

Create a workload with cephfs 

```
oc create -f workload-cephfs.yaml 
```

Set up your context and check the logs to see if all the files where created 
```
oc project test-calibrate-100k-10k
oc logs deployment/workload-calibrate-1 
```

check the size regulary
```
oc exec -it deployment/workload-calibrate-1 -- du -hs /data
```

When you are close to 1gb (for instance 976.5M  /data) you can create a snap.

Create a snapshot : 
```
oc create -f snap-workload.yaml 
```

Check if the snap is ready to use
```
oc get volumesnashot -w
```

Clone it with the ocs-storagecluser-cephfs storage class 
```
oc create -f clone-ocs-storagecluster-cephfs.yaml
```

The pvc will be pending with a lot of message in its event like 
```
  Warning  ProvisioningFailed    3s (x8 over 2m)     openshift-storage.cephfs.csi.ceph.com_csi-cephfsplugin-provisioner-fc86bf65f-82jkg_eacf7ad8-91c5-4621-9a8d-6e13109c994b  failed to provision volume with StorageClass "ocs-storagecluster-cephfs": rpc error: code = Aborted desc = clone from snapshot is already in progress
```

After 13 minutes the pvc is still pending... 
```
NAME                              STATUS    VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                VOLUMEATTRIBUTESCLASS   AGE
calibrate-1                       Bound     pvc-af6b75c8-ff4d-4095-b43a-bf77680c8197   32Gi       RWO            ocs-storagecluster-cephfs   <unset>                 30m
pvc-clone-from-snap-calibrate-1   Pending                                                                        ocs-storagecluster-cephfs   <unset>                 13m
```

Let's delete it and create a clone with the swallow volume.
```
oc delete pvc pvc-clone-from-snap-calibrate-1
oc create -f clone-ocs-storagecluster-cephfs-shallow.yaml
```

In less than 5s the volume is ready 
```
oc get pvc
NAME                                      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                        VOLUMEATTRIBUTESCLASS   AGE
calibrate-1                               Bound    pvc-af6b75c8-ff4d-4095-b43a-bf77680c8197   32Gi       RWO            ocs-storagecluster-cephfs           <unset>                 44m
pvc-clone-from-snap-calibrate-1-shallow   Bound    pvc-f7c87687-255e-452d-b510-c05692384436   32Gi       ROX            ocs-storagecluster-cephfs-shallow   <unset>                 7s
```

Notice that the access mode is ROW (Read Only many) for this clone.

clean up 
```
oc delete ns test-calibrate-100k-10k
```



