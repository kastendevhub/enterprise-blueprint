# Goal 

When configuring Kasten with VMware a lot of prerequisite is expected that are often discovered the hardway when operating Kasten.
In order to save a lot of time and not "running for discovering" the issue we'll list the prerequisite and the simple command or simple check that you should do to check that the next operation will be successful. 

## How it works 

It works with this structure 
 - If you .... (use VBR as a backup repository)
 - Then you must .... (Make sure the firewall rule allow connection from ... to ... on port ... )
 - To check it .... (from pod ... curl httts://$VBR_REPO_ADRESS:10006 )


## If you want to send your backup to VBR 

Before creating a VBR location profile you must check this list of prerequisites. 

### PVC must support block mode 
The storage class of the PVC you will backup must support block mode export. 
You can check with the [blockmount command](https://docs.kasten.io/latest/operating/k10tools#primer-block-mount-check)
```
curl https://docs.kasten.io/downloads/9.0.8/tools/k10_primer.sh | bash /dev/stdin blockmount -s ${STORAGE_CLASS_NAME}
```

These storage provisioners are known to support block mode export. Still run the blockmount check: support can depend on the driver version and the backend configuration.

| Storage | CSI provisioner | Note |
| --- | --- | --- |
| vSphere CNS (block volumes) | `csi.vsphere.vmware.com` | Block volumes only; vSAN file share volumes (RWX) are not block |
| ODF / Ceph RBD | `openshift-storage.rbd.csi.ceph.com` / `rbd.csi.ceph.com` | CephFS (`cephfs.csi.ceph.com`) is file only |
| NetApp Trident (SAN backends) | `csi.trident.netapp.io` | `ontap-san`, `ontap-san-economy`; `ontap-nas*` is file only |
| Portworx / Pure | `pxd.portworx.com` | |
| Dell PowerStore / PowerFlex / PowerMax | `csi-powerstore.dellemc.com`, `csi-vxflexos.dellemc.com`, `csi-powermax.dellemc.com` | Block protocols (iSCSI, FC, NVMe, SDC) only |
| HPE CSI (Alletra, Nimble, Primera) | `csi.hpe.com` | |
| IBM block storage (FlashSystem) | `block.csi.ibm.com` | |
| Longhorn | `driver.longhorn.io` | |
| AWS EBS | `ebs.csi.aws.com` | |
| Azure Disk | `disk.csi.azure.com` | |
| Google Persistent Disk | `pd.csi.storage.gke.io` | |

As a rule of thumb, provisioners backed by NFS or another shared file system (NFS CSI, CephFS, `ontap-nas`, Azure File, EFS) do not support block mode.

Once the check passes, annotate the storage class so Kasten uses block mode export:

```
kubectl annotate storageclass ${STORAGE_CLASS_NAME} k10.kasten.io/sc-supports-block-mode-exports=true
```

### Firewall rule between the pod network and VBR 
The kasten datamover pods act as VBR proxy and several port are involved during the upload session 

- [VBR 13 Kasten Integration Guide - Used Ports](https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html?ver=13)
- [KB4626: Veeam Kasten for Kubernetes - Used Ports](https://www.veeam.com/kb4626)

As of the referenced VBR 13 documentation, the Kasten integration uses these
main VBR-side ports:

| Source | Destination | Protocol | Port | Purpose |
| --- | --- | --- | --- | --- |
| Veeam Kasten | VBR server | TCP | 10006 | Connect to the VBR server |
| Veeam Kasten | VBR REST API service | HTTPS | 9419 | Validate the VBR location profile |
| Veeam Kasten | VBR backup repository | TCP | 6162 | Repository communication |
| Veeam Kasten | VBR backup repository | TCP | 2500-3300 | Optional failover range when 6162 is unavailable |


To verify create a netshoot pod 

```bash
oc run netshoot \
  --namespace=kasten-io \
  --image=nicolaka/netshoot \
  --restart=Never \
  --env VBR_PRIVATE_IP="$VBR_PRIVATE_IP" \
  --rm -it \
  -- /bin/bash
```

Then check all the connectivity 
```
export VBR_SERVER=<adresse of your vbr server>
export VBR_REPO=<adresse of your vbr backup repository if different from your vbr sever>
nc -vz -w 5 $VBR_SERVER 10006
curl -vk --max-time 10 https://$VBR_SERVER:10006
nc -vz -w 5 $VBR_SERVER 9419
nc -vz -w 5 $VBR_REPO 6162
nc -vz -w 5 $VBR_REPO  2500 # deprecated (fall back if 6162 can't ne opened)
nc -vz -w 5 $VBR_REPO  3300 # deprecated (fall back if 6162 can't ne opened)
```

### The VBR user in the VBR location profile must be granted access to the repository 

The account used in the location profile needs two things in VBR ([Required Permissions](https://helpcenter.veeam.com/docs/vbr/kasten_integration/req_permissions.html)):

1. The **Veeam Backup Administrator** role, assigned directly or through a group (Main menu → Users and Roles).
2. Access permissions on the target backup repository. A new repository is set to **Deny to everyone** by default, so Kasten cannot write to it until you change this.

To check and grant repository access ([Editing Access Permissions](https://helpcenter.veeam.com/docs/vbr/userguide/access_permissions.html)):

1. In the VBR console, open **Backup Infrastructure** → **Backup Repositories**.
2. Right-click the repository and select **Access permissions**.
3. Select **Allow to everyone**, or select **Allow to the following accounts or groups only** and add the Kasten account (or a group it belongs to).

Watch out for these:
- Do not change the access permissions of a repository that already holds Kasten exports. The Kasten policy will fail.
- If VBR runs on Linux (VSA), you cannot use a domain user in the Kasten location profile. Use a local account.


## If you want to create a vmware infrastructure profile for exporting using CBT 

### Content block trafic must be enabled at the worker node level 

#### In the general case 
The PVCs are First Class Disks attached to the worker node VMs, so CBT must be enabled on every worker node VM. Without it, every export reads the full disk.

To check in the vSphere Client:
1. Select the worker node VM, then **Edit Settings** → **VM Options** → **Advanced** → **Edit Configuration**.
2. Search for `ctkEnabled`. It must be `TRUE`. Each disk also has an entry such as `scsi0:0.ctkEnabled = TRUE`.

To check all the worker nodes at once with [govc](https://github.com/vmware/govmomi/tree/main/govc):

```bash
for vm in $(govc find / -type m -name '<worker-name-prefix>*'); do
  echo "$vm $(govc object.collect -s "$vm" config.changeTrackingEnabled)"
done
```

or with PowerCLI:

```powershell
Get-VM -Name "<worker-name-prefix>*" | Select-Object Name, @{N='CBT';E={$_.ExtensionData.Config.ChangeTrackingEnabled}}
```

To enable it, set `ctkEnabled = TRUE` in the VM advanced configuration (same screen as above). The change takes effect after a power cycle, or after you create and delete a snapshot (stun/unstun). If the nodes are created by a machine API (OpenShift MachineSet, Cluster API, Rancher), enable CBT in the VM template too. Otherwise new or replaced nodes come up without CBT.

#### In a guest cluster managed by supervisor 
Enable Changed Block Tracking for Guest Cluster on vSphere with Tanzu (VKS) by following [this procedure](https://www.veeam.com/kb4599) 

You can control with 

```
kubectl get -n <guest cluster namespace> virtualmachine <guest cluster worker node VM name> -o jsonpath='{.status.changeBlockTracking}'
```

### Authorization must be granted to the user 

Follow this [documentation](https://docs.kasten.io/latest/install/storage#vsphere-infrastructure-profile) to make sure you have the proper authorization for the user in the infrastructure profile. 

We notice that customer often miss this item 
> Assign this role to the dedicated Veeam Kasten user account on the following objects:
>
>.  The root vCenter object
>.  The datacenter objects (propagate down each subtree to reach datastore and virtual machine objects)

You can check with the [vSphere First Class Disk Integration Check](https://docs.kasten.io/latest/operating/k10tools#primer_check_vsphere)

If you are using vSphere with Tanzu (VKS) make sure you did not miss this point 

> Also for vSphere with Tanzu, assign the can edit role to the custom user in the vSphere Namespace using the following UI path:
> 
>.  Workload Management > Namespaces > Select the namespace associated with the TKG service > Permissions > Add (assign [can edit] role)

To check that in vSphere 
1. Go to Menu → Workload Management → Namespaces.
2. Click the vSphere Namespace that hosts the TKG cluster.
3. On the Summary tab, find the Permissions card and click Manage Permissions.
4. The list shows each user or group with its role (Can view / Can edit / Owner). The Kasten user (or a group it belongs to) must be listed with Can edit. If it isn’t, use Add.

### Ensure the pod network can access the 902 port on the ESX 

To read snapshot data, the Kasten datamover uses VMware VDDK in NBD/NBDSSL transport mode. The session starts against vCenter on port 443. vCenter then hands the datamover a ticket, and the datamover opens the NFC data connection **directly to the ESXi host** that serves the disk, on TCP 902. vCenter does not proxy the data path.

As a result:
- The pod network (or the node network the pods are NATed to) must reach **every ESXi host** that can access the datastores holding the PVCs, not only vCenter. A disk can be served by any host in the cluster.
- The datamover connects to the host by the name it is registered under in vCenter. If hosts are registered by FQDN, pods must also be able to resolve that FQDN.

List the ESXi hosts as vCenter knows them:

```bash
govc find / -type h | xargs -n1 basename
```

Then check from a netshoot pod:

```bash
oc run netshoot \
  --namespace=kasten-io \
  --image=nicolaka/netshoot \
  --restart=Never \
  --rm -it \
  -- /bin/bash
```

```bash
export VCENTER=<vcenter fqdn>
export ESX_HOSTS="<esx1> <esx2> <esx3>"   # names exactly as registered in vCenter
nc -vz -w 5 $VCENTER 443
for h in $ESX_HOSTS; do
  nslookup $h > /dev/null || echo "DNS FAILED for $h"
  nc -vz -w 5 $h 902
done
```

Every host must answer `succeeded`/`open` on 902. If a single host fails, exports fail only when the disk is served by that host, so the problem shows up intermittently.

## If you want to monitor Kasten operation in VBR 

- [VBR 13 Kasten Integration Guide - Used Ports](https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html?ver=13)
- [KB4626: Veeam Kasten for Kubernetes - Used Ports](https://www.veeam.com/kb4626)

| Source | Destination | Protocol | Port | Purpose |
| --- | --- | --- | --- | --- |
| VBR backup server | Veeam Kasten | TCP/HTTPS | 443 | VBR plug-in connection to Kasten |
| VBR Remote Console | Veeam Kasten | TCP | 443 | Open Kasten UI from the VBR console |
| Kasten datamover | vmb agent port | TCP | 51515 |  |

On the VBR server 

```powershell
Get-Service Veeam*
Test-NetConnection -ComputerName "<kasten-route-hostname>" -Port 443
```

On kubernetes 

```
kubectl run netshoot \
  --namespace=kasten-io \
  --image=nicolaka/netshoot \
  --restart=Never \
  --env VBR_PRIVATE_IP="$VBR_PRIVATE_IP" \
  --rm -it \
  -- /bin/bash
export VBR_SERVER=<adresse of your vbr server>
nc -vz -w 5 $VBR_SERVER 51515
```

