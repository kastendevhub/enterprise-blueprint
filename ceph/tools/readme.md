# Goal

This page collect common operations to maintain  

## Activate the ceph toolbox 

Taken from [Configuring the Rook-Ceph Toolbox in OpenShift Data Foundation 4.x](https://access.redhat.com/articles/4628891)

With ODF v4.15 and above To enable the toolbox pod, patch/edit the StorageCluster CR like below:
```
oc patch storageclusters.ocs.openshift.io ocs-storagecluster -n openshift-storage --type json --patch '[{ "op": "replace", "path": "/spec/enableCephTools", "value": true }]'
```

## Quick checking 

```
oc rsh -n openshift-storage deployment/rook-ceph-tools

# Cluster status
ceph status
ceph health detail

# OSD information
ceph osd status
ceph osd df
ceph osd tree

# Pool information
ceph osd pool ls
ceph df

# Monitor your CephFS performance issues
ceph fs status
ceph fs dump

# Check for any stuck operations (related to your clone issues)
ceph -w
```

## Troubleshoot an osd down 

Find the osd down 
```
ceph osd tree
```

You get 
```
ID   CLASS  WEIGHT   TYPE NAME                                                 STATUS  REWEIGHT  PRI-AFF
 -1         1.50000  root default                                                                       
 -5         1.50000      region eastus                                                                  
-10         0.50000          zone eastus-1                                                              
 -9         0.50000              host ocs-deviceset-managed-csi-0-data-0j8pf9                           
  1    ssd  0.50000                  osd.1                                         up   1.00000  1.00000
 -4         0.50000          zone eastus-2                                                              
 -3         0.50000              host ocs-deviceset-managed-csi-1-data-056j4t                           
  0    ssd  0.50000                  osd.0                                         up   1.00000  1.00000
-14         0.50000          zone eastus-3                                                              
-13         0.50000              host ocs-deviceset-managed-csi-2-data-058q5p                           
  2    ssd  0.50000                  osd.2                                       down   1.00000  1.00000
```


Checking the pod, one is pending 
```
oc get po |grep rook-ceph-osd
rook-ceph-osd-0-6d5bd49d5b-j892f                                  2/2     Running                       0               21d
rook-ceph-osd-1-6bcc6967c6-9r2qw                                  2/2     Running                       0               21d
rook-ceph-osd-2-5bf9dd45db-b786c                                  0/2     Pending                       0               21d
```

I can see that's because 2 worke nodes are unavailable 
```
Warning  FailedScheduling  176m                 default-scheduler  0/17 nodes are available: 12 node(s) didn't match Pod's node affinity/selector, 2 node(s) were unschedulable, 3 node(s) had untolerated taint {node-role.kubernetes.io/master: }. preemption: 0/17 nodes are available: 17 Preemption is not helpful for scheduling.
```

the reason was that some eastus-3 node lost their label `cluster.ocs.openshift.io/openshift-storage`.

once fixed we can see that the cluster recover 
```
ceph -w
2025-10-09T13:57:45.806437+0000 mon.b [WRN] Health check update: Degraded data redundancy: 466073/1580796 objects degraded (29.483%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:57:51.709255+0000 mon.b [WRN] Health check update: Degraded data redundancy: 466074/1580802 objects degraded (29.483%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:57:56.714259+0000 mon.b [WRN] Health check update: Degraded data redundancy: 464709/1580799 objects degraded (29.397%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:01.719239+0000 mon.b [WRN] Health check update: Degraded data redundancy: 464708/1580796 objects degraded (29.397%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:06.724568+0000 mon.b [WRN] Health check update: Degraded data redundancy: 463468/1580802 objects degraded (29.319%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:11.735957+0000 mon.b [WRN] Health check update: Degraded data redundancy: 463467/1580799 objects degraded (29.319%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:16.741390+0000 mon.b [WRN] Health check update: Degraded data redundancy: 462134/1580796 objects degraded (29.234%), 165 pgs degraded, 165 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:21.900669+0000 mon.b [WRN] Health check update: Degraded data redundancy: 461618/1580796 objects degraded (29.202%), 164 pgs degraded, 164 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:29.961534+0000 mon.b [WRN] Health check update: Degraded data redundancy: 461105/1578960 objects degraded (29.203%), 163 pgs degraded, 163 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:35.892839+0000 mon.b [WRN] Health check update: Degraded data redundancy: 460618/1576980 objects degraded (29.209%), 162 pgs degraded, 162 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:41.091727+0000 mon.b [WRN] Health check update: Degraded data redundancy: 460056/1576977 objects degraded (29.173%), 161 pgs degraded, 162 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:46.778820+0000 mon.b [WRN] Health check update: Degraded data redundancy: 459714/1576965 objects degraded (29.152%), 160 pgs degraded, 160 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:51.783353+0000 mon.b [WRN] Health check update: Degraded data redundancy: 459492/1576956 objects degraded (29.138%), 160 pgs degraded, 160 pgs undersized (PG_DEGRADED)
2025-10-09T13:58:56.787651+0000 mon.b [WRN] Health check update: Degraded data redundancy: 458856/1576944 objects degraded (29.098%), 159 pgs degraded, 159 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:01.795907+0000 mon.b [WRN] Health check update: Degraded data redundancy: 458570/1576926 objects degraded (29.080%), 158 pgs degraded, 158 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:06.800918+0000 mon.b [WRN] Health check update: Degraded data redundancy: 458031/1576896 objects degraded (29.046%), 157 pgs degraded, 158 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:11.805933+0000 mon.b [WRN] Health check update: Degraded data redundancy: 458032/1576887 objects degraded (29.047%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:16.810302+0000 mon.b [WRN] Health check update: Degraded data redundancy: 456711/1576839 objects degraded (28.964%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:21.819770+0000 mon.b [WRN] Health check update: Degraded data redundancy: 456712/1576824 objects degraded (28.964%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:26.825218+0000 mon.b [WRN] Health check update: Degraded data redundancy: 455472/1576776 objects degraded (28.886%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:31.829770+0000 mon.b [WRN] Health check update: Degraded data redundancy: 455471/1576758 objects degraded (28.887%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
2025-10-09T13:59:36.834504+0000 mon.b [WRN] Health check update: Degraded data redundancy: 454237/1576743 objects degraded (28.809%), 157 pgs degraded, 157 pgs undersized (PG_DEGRADED)
```