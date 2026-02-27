# Goal

Explain how the namespace `mas-$MAS_INSTANCE_ID-manage` should be backe up

# Backup 

Create a policy that backup the whole namespace. 

The PVC are Read Write Many and with some storage provider like Azure, Oracle there is no support for snapshot. You'll have to use [Generic Storage Backup](../../../gsb/). You'll have to do sidecar injection in all the deployment using this pvc : use oc describe <pvc> to find all the pods using this pvc.

If the PVC are CephFS you'll have to use [Shallow volume configuration](../../../ceph/cephfs/)

# Restore


You can granulary restore manifest from a restore point. But restoring the whole namespace is not supported. If you need to recover from a complete DR check the DR section

You can granulary restore a file using a [File Recovery session](https://docs.kasten.io/latest/usage/restorefiles/#filerecoverysession-example). 


If you need to restore the whole PVC you need to make sure that kasten and the maximo operator are not going to compete on scaling the deployments before deleting and recreating the pvc. 

```
oc describe pvc instance1-workspace1-doclinks
Used By:       instance1-workspace1-cron-64594dcbdc-nqphn
               instance1-workspace1-foundation-85bd778464-tvhbp
               instance1-workspace1-manage-maxinst-5bdbc7d47-68qt7
               instance1-workspace1-mea-5d5f7f95d-fz8jf
               instance1-workspace1-rpt-7797ccf69d-lcm7z
               instance1-workspace1-ui-5bdb4b98ff-qfg44
```

We could not find a way to scale down all the deployments because they are controlled by maximo operator (this will probably change soon), so for the moment we use volume clone restore and create a pod that attach both the volume clone restore and the orriginal volume then we proceed the copy inside the pod.

We then delete the pod and the volume clone restore.


# Disaster Recovery 

Disaster recovery is covered in another section.



