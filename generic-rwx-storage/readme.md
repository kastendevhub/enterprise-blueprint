# Goal 

When building enterprise blueprint you often need a intermediate read/write/many (called RWX) storage to store your backup and that will be itself snapshotted to be protected by Kasten. This guide explain you how to build this storage if you don't have one already.

# Why do I need RWX storage with CSI snapshots for Enterprise Blueprint ?

If you already read the different enterprise blueprint you'll see many use cases that rely on a RWX CSI snaphotable storage .

For instances: 
- in the [dh2i](../dh2i/) blueprint the operator mount a shared folder between each pods where the mssql client can launch their full and log backup.
- in the [elasticsearch](../elasticsearch) blueprint each node in the elastic cluster need a common snapshot repository by mounting the same PVC


```mermaid
graph TD
    A[Blueprint] -->|Create backup artifacts| B[Backup PVC]
    B -->|Kasten exports from a snapshot of the backup PVC| C[S3 Storage]
```


Having an intermediate storage to store the backup before having Kasten backing up this storage itself turns to be very practical:
- The kanister blueprint rely on it for backup and restore operation allowing the use of incremental dump or redo log streaming 
- Your DBA will be at home as he will face a directory built as usual and any "custom hotfix manual operation" is still possible if you don't want to run the kanister automation
- This intermediate backup location will be backed up itself by Kasten and incrementally. If you need to do some "custom hotfix manual operation" far in the past it's still possible, you just have to restore granulary the Kasten restorepoint and you'll retreive the "intermediate" backup location storage without executing the kanister automation.
- You'll be able to filter out the storage PVC used by the database because now the backup is living on this intermediate storage

# How do I build RWX storage with CSI snapshots ?

## Maybe you already have it ? 

You may already have a RWX storage with CSI Snapshot and you have nothing to do. For instance : 
- OpenShift Data Foundation (ODF) offers RWX capabilities and CSI snapshot support through CephFS and Kasten even supports shallow backup
- NetApp storage backends, including ONTAP, SolidFire, and Azure NetApp Files
- Dell EMC PowerFlex and Dell EMC PowerStore
- IBM Spectrum Scale
- Amazon EFS (Elastic File System) can be used with CSI (Container Storage Interface) and supports snapshots
- Azure File has recently provided support for CSI snapshot when using SMB protocol (snapshot is not supported with NFS protocol until now)
- Google Cloud Filestore is a managed file storage service that provides RWX capabilities and supports CSI snapshots
- LINSTOR provides RWX capabilities and supports CSI snapshots
- Portworx provides sharedV4 that supports CSI snapshots
- HPE storage backends, including HPE Nimble Storage and HPE 3PAR offers RWX capabilities and CSI snapshot support.

This list is not exhaustive and as a good practice we strongly advice to rely on a good storage provider. You should reach out your storage administrator and check with him if you're not just few minutes away from the solution.

## I only have an NFS sever

Maybe you don't have such storage and only have a NFS server. Then it's possible with the the 
[csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs) project to build a "nearly" fully csi compliant storage. 

It works by using a NFS `share` that you defined at the level of the storage class
```
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.default.svc.cluster.local
  share: /
  # csi.storage.k8s.io/provisioner-secret is only needed for providing mountOptions in DeleteVolume
  # csi.storage.k8s.io/provisioner-secret-name: "mount-options"
  # csi.storage.k8s.io/provisioner-secret-namespace: "default"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
```

- Every time you create a PVC a directory with the name of the PV that is bound to the PVC will be created on the share
- Every time you create a Snapshot of the PVC 

## VERY IMPORTANT TO KNOW 

This driver is very practical if you have very limited storage however you must know that the snapshot of this specific
driver **are not crash consistent because it uses tar**. And tar is not a real snapshot solution. A snapshot solution 
ensure crash conistency which means that the data is in a state that would be consistent if the system crashed at any point during the backup process.

Creating a tar archive does not guarantee that the files being archived are in a consistent state, especially if the files are being modified during the tar process. To achieve crash consistency, you would need to ensure that the data is quiesced (i.e., all write operations are paused) before creating the tar archive.

But for an intermediate backup storage when the blueprint finish its job and dump the data on the intermediate backup PVC 
the data are indeed quiesced and it's safe to use tar for the "pseudo snapshot". Now your backup pvc can be fully managed 
by Kasten leveraging encryption, portability and immutability! 

# A full example on a kind cluster 


## Let's create one master and two worker nodes 

Let's create an environment where we have very limited storage option by creating a stand alone [kind cluster](https://kind.sigs.k8s.io) 

```
cat<<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

You should see this output 
```
Creating cluster "kind" ...
 ✓ Ensuring node image (kindest/node:v1.30.0) 🖼 
 ✓ Preparing nodes 📦 📦 📦  
 ✓ Writing configuration 📜 
 ✓ Starting control-plane 🕹️ 
 ✓ Installing CNI 🔌 
 ✓ Installing StorageClass 💾 
 ✓ Joining worker nodes 🚜 
Set kubectl context to "kind-kind"
You can now use your cluster with:

kubectl cluster-info --context kind-kind

Thanks for using kind! 😊
```

Let's verify what storage we have  
```
kubectl get storageclass
```

You'll see something like that 
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  3m56s
```


The rancher.io/local-path provisioner is a simple Kubernetes storage provisioner that uses local storage on the node where the pod is scheduled. It is part of the Local Path Provisioner project by Rancher:
- When a PersistentVolumeClaim (PVC) is created, the Local Path Provisioner dynamically provisions a PersistentVolume (PV) by creating a directory on the local file system of the node where the pod is scheduled.
- The provisioner uses a predefined path on the host node to store the data.
- This provisioner is useful for development and testing environments where you want to use local storage instead of network-attached storage.


This provisioner is not a csi provisioner to verify you can check the installed CSI drivers using the following command:
```
kubectl get csidrivers.storage.k8s.io
```

If rancher.io/local-path is not listed, it confirms that it is not a CSI provisioner. In this specific situation we'll 
have 
```
no resources found
```

## Let's install the nfs-csi-driver 

