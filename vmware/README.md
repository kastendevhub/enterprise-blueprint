# Goal

This part of the repo covers running Veeam Kasten on Kubernetes clusters hosted on VMware vSphere (vSphere CSI / CNS, OpenShift on vSphere, vSphere with Tanzu / VKS).

It has two documents, one for each stage of a project:

- [Storage architecture recommendations](./k10-on-vmware-storage-recommandation.md): use this when you **design** the platform, or when a datastore keeps filling up. It explains how CNS, datastores and First Class Disks work together. It shows why the default setup lets disks and snapshots outlive the Kubernetes objects that reference them. It then gives recommendations: dedicated datastores, an infrastructure profile, no retained local snapshots, export concurrency, free space. It ends with read-only scripts that detect orphaned FCDs and snapshots.

- [Prerequisites check list](./check-list.md): use this **before** you configure Kasten. Many VMware prerequisites only show up when the first backup or export fails. For each prerequisite, the check list gives the rule, why it matters and a simple command to verify it. It covers:
  - sending backups to VBR: block mode support, firewall ports, repository permissions
  - exporting with CBT through a vSphere infrastructure profile: CBT on worker nodes, vCenter permissions, port 902 to the ESXi hosts
  - monitoring Kasten from VBR


## Links used in these documents

### Veeam Kasten documentation
- [k10tools primer: block mount check](https://docs.kasten.io/latest/operating/k10tools#primer-block-mount-check) (check-list)
- [k10tools primer: vSphere First Class Disk integration check](https://docs.kasten.io/latest/operating/k10tools#primer_check_vsphere) (check-list)
- [vSphere infrastructure profile and required vCenter permissions](https://docs.kasten.io/latest/install/storage#vsphere-infrastructure-profile) (check-list)

### Veeam Backup & Replication documentation
- [VBR 13 Kasten Integration Guide: Used Ports](https://helpcenter.veeam.com/docs/vbr/kasten_integration/used_ports.html?ver=13) (check-list)
- [VBR Kasten Integration Guide: Required Permissions](https://helpcenter.veeam.com/docs/vbr/kasten_integration/req_permissions.html) (check-list)
- [VBR User Guide: Editing Access Permissions](https://helpcenter.veeam.com/docs/vbr/userguide/access_permissions.html) (check-list)

### Veeam knowledge base
- [KB4599: Enable Changed Block Tracking for guest clusters on vSphere with Tanzu (VKS)](https://www.veeam.com/kb4599) (check-list)
- [KB4615: ESXi port 902 and DNS requirements for worker nodes](https://www.veeam.com/kb4615) (storage recommendations)
- [KB4626: Veeam Kasten for Kubernetes: Used Ports](https://www.veeam.com/kb4626) (check-list)

### Tools
- [govc](https://github.com/vmware/govmomi/tree/main/govc) (check-list, storage recommendations)
- [k10_primer.sh](https://docs.kasten.io/downloads/9.0.8/tools/k10_primer.sh) (check-list)
