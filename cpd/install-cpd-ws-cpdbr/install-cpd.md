# Installing CPD 

## Setting up a client workstation to install Cloud Pak for Data

We need the Cloud Pak for Data command-line interface otherwise known as cpd-cli. You'll find its release in their [github repository](https://github.com/IBM/cpd-cli), go to [releases](https://github.com/IBM/cpd-cli/releases) and choose a version that suits your OS.

```
cd cpd/install-cpd-ws-cpdbr
wget https://github.com/IBM/cpd-cli/releases/download/v14.1.3/cpd-cli-darwin-EE-14.1.3.tgz
tar xvzf cpd-cli-darwin-EE-14.1.3.tgz
./cpd-cli-darwin-EE-14.1.3-1968/cpd-cli version
```

The previous command automatically generated folders in your current directory which are git-ignored.
- cpd-cli-darwin-EE-14.1.3-1968
- cpd-cli-workspace

Add them to your .gitignore, to your path and test 
```
export PATH=$PWD/cpd-cli-darwin-EE-14.1.3-1968:$PATH
export CPD_CLI_MANAGE_WORKSPACE=$PWD/cpd-cli-workspace
cpd-cli version
```

## Setting Up the Openshift Cluster to install Cloud Pak for Data

For this install, an ARO (Openshift on Azure) cluster is used. 

Documentation for setting up an [openshift cluster for cpd](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-installing-red-hat-openshift).


```
oc version 
Client Version: 4.13.0-202311021930.p0.g717d4a5.assembly.stream-717d4a5
Kustomize Version: v4.5.7
Server Version: 4.16.20
Kubernetes Version: v1.29.9+5865c5b
```

Cloud Pak for Data is very resource intensive and hence use large size worker nodes(16 core, 64 GB memory is preferred). 
Here is an example of my cluster running the core components plus watson studio and a bunch of other applications like Kasten.

```
oc adm top nodes
NAME                                               CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%   
se-lab-aro-prod-67bsq-master-0                     6288m        79%    23733Mi         85%       
se-lab-aro-prod-67bsq-master-1                     2347m        29%    19298Mi         69%       
se-lab-aro-prod-67bsq-master-2                     1750m        22%    18714Mi         67%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-7n9vd   395m         4%     9838Mi          35%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-b2jlw   381m         4%     8359Mi          29%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-hkpmb   308m         3%     8397Mi          30%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-hn89p   161m         2%     10942Mi         39%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-jxmfd   255m         3%     11212Mi         40%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-lqfh7   1224m        15%    12171Mi         43%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-xhwb4   407m         5%     8721Mi          31%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-2brmh   221m         2%     8655Mi          31%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-4jlww   378m         4%     11767Mi         42%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-brw7x   256m         3%     12304Mi         44%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-cr722   229m         2%     9061Mi          32%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-dl7zs   468m         5%     10729Mi         38%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-k7snp   124m         1%     7009Mi          25%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-ng46d   745m         9%     10453Mi         37%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-thmzk   454m         5%     9849Mi          35%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-dt28c   193m         2%     9491Mi          34%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-g6wgd   2623m        33%    10852Mi         38%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-gdnn4   2599m        32%    8854Mi          31%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-hhk5b   433m         5%     6969Mi          24%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-l8vn5   1318m        16%    14437Mi         51%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-ntkms   244m         3%     15048Mi         53%       
se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-vsldm   1280m        16%    13137Mi         47%   
```


The next step is to create a new user cpdadmin and grant cluster-admin privilege. 

Refer the link [here](https://access.redhat.com/solutions/4039941) for instructions on how to add a new user using htpasswd identity provider. 

Since I am using an ARO cluster that already has users configured using htpasswd as the identity provider, I am adding a new user to an existing provider.

Retrieve the existing users configured
```
oc get secret htpass-secret -ojsonpath={.data.htpasswd} -n openshift-config | base64 --decode > se-lab-provider-users.htpasswd
```

Add a new user to the generated htpasswd file 
```
htpasswd -bB se-lab-provider-users.htpasswd cpdadmin <cpdadmin password>
# TODO remove htpasswd -bB se-lab-provider-users.htpasswd cpdadmin mcourcycpdadmin123
```

Apply the change by updating the existing secret 
```
oc create secret generic htpass-secret --from-file=htpasswd=se-lab-provider-users.htpasswd --dry-run=client -o yaml -n openshift-config | oc replace -f -
```

Grant cluster admin access to the cpdadmin user
```
oc adm policy add-cluster-role-to-user cluster-admin cpdadmin
```

## Installing the Red Hat OpenShift Container Platform cert-manager Operator

Documentation is [here](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-installing-cert-manager-operator).

## Verifying OpenShift and CPD Version Compatibility

**Before proceeding with the installation, always verify that your OpenShift version is supported by your chosen CPD version.**

### Check your OpenShift version
```bash
oc version
```

### Check CPD version compatibility
Use the cpd-cli health cluster command to verify compatibility:
```bash
cpd-cli health cluster
```

Look for the "Cluster Version Check" section in the output:
```
Cluster Version Check                                                      
Checks if the Red Hat OpenShift version is supported by IBM Software Hub   
[SUCCESS...]  The location version matches with 4.12,4.13,4.14,4.15,4.16
```

If you see a **[WARN...]** or **[FAIL...]** message instead, your OpenShift version is not supported by the current CPD version.

### CPD Version Matrix (Reference)
- **CPD 5.1.x**: Supports OpenShift 4.12, 4.13, 4.14, 4.15, 4.16
- **CPD 5.2.x**: Supports OpenShift 4.16, 4.17, 4.18 (check IBM documentation for exact versions)
- **CPD 5.3.x**: Supports newer OpenShift versions (check IBM documentation)

**⚠️ Important:** Using an unsupported OpenShift version can lead to installation failures, authentication issues, networking problems, and RBAC errors. Always use a compatible version combination.

In our cluster cert manager was already installed for other reason but still using the operator hub.

```
oc get ns |grep cert-manager
cert-manager                                       Active        303d
cert-manager-operator                              Active        303d
oc get po -n cert-manager-operator
NAME                                                        READY   STATUS    RESTARTS   AGE
cert-manager-operator-controller-manager-59675b4779-247jj   1/1     Running   0          6d19h
oc get po -n cert-manager 
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-595c9bf95b-pl827              1/1     Running   0          6d19h
cert-manager-cainjector-686fc97bb6-q9dhz   1/1     Running   0          6d19h
cert-manager-webhook-6dc9bf4ffb-rknc2      1/1     Running   0          6d19h
```

## Setting up persistent storage 

Documenation is [here](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-installing-persistent-storage). 

The SE-LAB cluster is an ARO cluster that has managed-csi storage class configured. However, CPD requires both block storage that support RWO mode and file storage that supports RWX with snapshots capacity. 

Even though Azure’s azurefile-csi supports RWX, the CSI drivers provided by Openshift does not support Volume snapshot and restore. Hence, I have configured a new ceph storage using Openshift Data Foundation. Once the storage system is successfully configured, you should see new storage classes added.

```
oc get sc
NAME                                         PROVISIONER                             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
azurefile-csi                                file.csi.azure.com                      Delete          Immediate              true                   253d
managed-csi (default)                        disk.csi.azure.com                      Delete          WaitForFirstConsumer   true                   299d
ocs-storagecluster-ceph-rbd                  openshift-storage.rbd.csi.ceph.com      Delete          Immediate              true                   183d
ocs-storagecluster-ceph-rbd-virtualization   openshift-storage.rbd.csi.ceph.com      Delete          Immediate              true                   183d
ocs-storagecluster-cephfs                    openshift-storage.cephfs.csi.ceph.com   Delete          Immediate              true                   183d
openshift-storage.noobaa.io                  openshift-storage.noobaa.io/obc         Delete          Immediate              false                  183d
s3-store-with-std-ia                         openshift-storage.ceph.rook.io/bucket   Delete          Immediate              false                  11d
```

## Setting up a private container registry for IBM Software Hub

Docmentation is [here](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-setting-up-private-container-registry) but this is a recommandation for better performance and security than a requirement. 

We skipped this step.

## Collecting the required information for the install

### Obtaining your IBM entitlement API key for IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=information-obtaining-your-entitlement-api-key).

Open the link to sign up and obtain a free 60-days trial license [Sign up for the IBM Cloud Pak for Data trial](https://www.ibm.com/account/reg/us-en/signup?formid=urx-42212). 

If you don’t have an existing IBM ID, create a new one. 

Note: this trial license can be used only once per IBM ID. It can’t be requested again.

Once the trial license has been issued, be sure to copy the IBM Cloud Pak entitlement Key. If you missed to copy, it can also be obtained from the link :  https://myibm.ibm.com/products-services/containerlibrary

More informations about entitlement is available [here](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=planning-licenses-entitlements#licensing__cpd_ent_api__title__1)


###  Determining which IBM Cloud Pak for Data components to install

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=information-determining-which-components-install).

The following cluster-wide components will be installed on the cluster.

- License Service
- Scheduling service
- IBM Cloud Pak foundational services
- IBM Software Hub control plane

#### Determine the CPD modular services that will be installed.

 For this experiment, I keep it simple and add only one service :

- Watson Studio

### Setting up installation environment variables

[Documenation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=information-setting-up-installation-environment-variables).

Create the cpd-vars.sh file and set the env variables. Follow the instructions from the [link](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.8.x?topic=information-setting-up-installation-environment-variables) 
Below is the sample [cpd-vars.sh](./cpd-vars.sh) file I used for the install. Make sure you update the cpdadmin password and entitlement key obtained earlier.

Apply the environment variables to the session and test 

```
bash
source ./cpd-vars.sh 
${CPDM_OC_LOGIN}
```

The last command `${CPDM_OC_LOGIN}` os using your local docker or podman installation and spin up a container that has the necessary ansible playbook for the rest 
of the installation.

It should end up with this output
```
KUBECONFIG is /opt/ansible/.kubeconfig
WARNING: Using insecure TLS client config. Setting this option is not supported!

Login successful.

You have access to 83 projects, the list has been suppressed. You can list all projects with 'oc projects'

Using project "default".
Using project "default" on server "https://api.kasten-se-lab-baremetal.kasten.veeam.local:6443".
[SUCCESS] 2025-08-14T11:25:01.134749Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/enterprise-blueprint/cpd/install-cpd-ws-cpdbr/cpd-cli-workspace/work directory.
[SUCCESS] 2025-08-14T11:25:01.134798Z The login-to-ocp command ran successfully.
```

## Preparing your cluster for IBM Cloud Pak for Data

### Updating the global image pull secret for IBM Cloud Pak for Data

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-updating-global-image-pull-secret)

The global image pull secret ensures that your cluster has the necessary credentials to pull images. The credentials that you add to the global image pull secret depend on where you want to pull images from.

```
cpd-cli manage add-icr-cred-to-global-pull-secret \
--entitled_registry_key=${IBM_ENTITLEMENT_KEY}
```

Get the status of the nodes

```
cpd-cli manage oc get nodes
```

Wait until all the nodes are Ready before you proceed to the next step. For example, if you see Ready,SchedulingDisabled, wait for the process to complete.

### Manually creating projects (namespaces) for the shared cluster components for IBM Software Hub

[Documentation](./https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-manually-creating-projects-namespaces-shared-components)


```
${OC_LOGIN}
oc new-project ${PROJECT_LICENSE_SERVICE}
oc new-project ${PROJECT_SCHEDULING_SERVICE}
```

## Installing shared cluster components for IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-installing-shared-components)

Install the cluster components 
```
${CPDM_OC_LOGIN}
cpd-cli manage apply-cluster-components \
--release=${VERSION} \
--license_acceptance=true \
--licensing_ns=${PROJECT_LICENSE_SERVICE}
```

Wait for the cpd-cli to return the following message before proceeding to the next step:
```
[SUCCESS] 2025-06-03T14:26:14.475326Z The apply-cluster-components command ran successfully.
```

Install the scheduler 
```
cpd-cli manage apply-scheduler \
--release=${VERSION} \
--license_acceptance=true \
--scheduler_ns=${PROJECT_SCHEDULING_SERVICE}
```

Wait for the cpd-cli to return the following message before proceeding to the next step:

```
[SUCCESS] 2025-06-03T14:37:22.392406Z The apply-scheduler command ran successfully.
```

**Note: RBAC Issue and Resolution**

We encountered an RBAC privilege escalation error during the scheduler installation. The operator failed with this message:

```
"ibm-cpd-scheduler-kube-sched-crb" is forbidden:
user "system:serviceaccount:ibm-cpd-scheduler:ibm-cpd-scheduling-operator" (groups=["system:serviceaccounts" "system:serviceaccounts:ibm-cpd-scheduler" "system:authenticated"])
is attempting to grant RBAC permissions not currently held:
{APIGroups:["storage.k8s.io"], Resources:["volumeattachments"], Verbs:["get" "list" "watch"]},"reason":"Forbidden","details":{"name":"ibm-cpd-scheduler-kube-sched-crb","group":"rbac.authorization.k8s.io","kind":"clusterrolebindings"},"code":403}
```

**Root Cause:**
- The operator needs to create a ClusterRoleBinding for the `system:kube-scheduler` ClusterRole (which includes `volumeattachments` permissions)
- Kubernetes RBAC prevents privilege escalation - a service account cannot grant permissions it doesn't already hold
- The operator service account (`ibm-cpd-scheduling-operator`) doesn't have `volumeattachments` permissions, so it cannot create the required ClusterRoleBinding

**Investigation:**
We confirmed the issue using impersonation:
```bash
oc auth can-i get volumeattachments --as=system:serviceaccount:ibm-cpd-scheduler:ibm-cpd-scheduling-operator
# Returns: no
```

**Resolution:**
Since only users with existing permissions can grant those permissions to others, we manually created the ClusterRoleBinding as cluster-admin:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ibm-cpd-scheduler-kube-sched-crb
  labels:
    app.kubernetes.io/instance: cpd-scheduler
    app.kubernetes.io/managed-by: ansible
    app.kubernetes.io/name: ibm-cpd-scheduler
    icpdsupport/addOnId: scheduling
    lsfcluster: ibm-cpd-scheduler
    lsftype: ibm-wmla-pod-scheduler-prod
    release: cpd-scheduler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-scheduler
subjects:
- kind: ServiceAccount
  name: ibm-cpd-scheduling-operator
  namespace: ibm-cpd-scheduler
EOF
```

**Operator Recovery:**
After creating the ClusterRoleBinding, the operator was stuck in a "Failed" state and required a restart to resume reconciliation:

```bash
# Restart the operator pod to clear the failed state
oc delete pod -n ibm-cpd-scheduler -l name=ibm-cpd-scheduling-operator

# Verify the operator resumes and completes successfully
oc get scheduling ibm-cpd-scheduler -n ibm-cpd-scheduler
```

**Outcome:**
The scheduler installation completed successfully with all components running.

**Root Cause Identified:**
The RBAC issue was likely caused by an OpenShift version compatibility problem. The `cpd-cli health cluster` command revealed:

```
Checks if the Red Hat OpenShift version is supported by IBM Software Hub   
[WARN...]  The location version does not match with                        
4.12,4.13,4.14,4.15,4.16                                                   
Current Cluster Version is 4.18.21  
```

**Analysis:**
- CPD 5.1.3 was designed and tested for OpenShift versions 4.12-4.16
- The cluster is running OpenShift 4.18.21, which is newer than the supported range
- The operator's RBAC configuration may not account for changes in newer OpenShift versions
- This version mismatch likely explains why the operator lacks the necessary permissions to create the required ClusterRoleBinding

**Recommendation:**
For production deployments, use a supported OpenShift version (4.12-4.16) to avoid compatibility issues. If you must use a newer OpenShift version, be prepared to manually resolve RBAC issues as demonstrated above.


## Configuring persistent storage for IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-configuring-persistent-storage)

this step was completed as part of setting up the Openshift cluster

## Creating custom security context constraints for services

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-creating-custom-sccs-services)

this steps is needed depending on the CPD services being installed. Since Watson Service doesn’t require scc, I skipped this step

## Changing required node settings

[Documenation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-changing-required-node-settings).

### Changing load balancer timeout settings

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=settings-changing-load-balancer)

For Watson Studio, the minimum recommended timeout is:
- Client timeout: 300s (5m)
- Server timeout: 300s (5m)

But we cannot change the timeout settings in Azure Red Hat OpenShift (ARO) environments. The default timeout value is 4 minutes (240 seconds).

### Changing the process IDs limit

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=settings-changing-process-ids-limit)

Check whether there is an existing kubeletconfig on the cluster:
```
oc get kubeletconfig
```

If the command returns the name of a kubeletconfig then 
```
export KUBELET_CONFIG=<kubeletconfig-name>
oc patch kubeletconfig ${KUBELET_CONFIG} \
--type=merge \
--patch='{"spec":{"kubeletConfig":{"podPidsLimit":16384}}}'
```

If not 
```
oc apply -f - << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpd-kubeletconfig
spec:
  kubeletConfig:
    podPidsLimit: 16384
  machineConfigPoolSelector:
    matchExpressions:
    - key: pools.operator.machineconfiguration.openshift.io/worker
      operator: Exists
EOF
```

### Changing kernel parameter settings

[documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=settings-changing-kernel-parameter)

Since Watson studio does not need this tuning we skip this step

## Installing prerequisite software

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=cluster-installing-prerequisite-software)

### Installing operators for services that require GPUs

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=software-installing-operators-services-that-require-gpus) We don't need it for watson studio

### Installing Red Hat OpenShift AI

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=software-installing-red-hat-openshift-ai) We don't need it for watson studio

### Installing and setting up Multicloud Object Gateway for IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=software-installing-multicloud-object-gateway) We don't need it for watson studio

### Installing Red Hat OpenShift Serverless Knative Eventing

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=software-installing-red-hat-openshift-serverless-knative-eventing) We don't need it for watson studio

### Installing IBM App Connect in containers

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=software-installing-app-connect) Does not apply for cpd 5.1.3

## Preparing to install an instance of IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=installing-preparing-install-instance-software-hub)

### Checking the health of your cluster before installing IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-checking-health-your-cluster)

```
${OC_LOGIN}
cpd-cli health cluster
```

Make sure ou have success for each of them. 


### Manually creating projects (namespaces) for an instance of IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-manually-creating-projects-namespaces)

```
${OC_LOGIN}
oc new-project ${PROJECT_CPD_INST_OPERATORS}
oc new-project ${PROJECT_CPD_INST_OPERANDS}
```

### Applying the required permissions to the projects (namespaces) for an instance of IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-applying-required-permissions-projects-namespaces)

We choose the first option [Applying the required permissions by running the authorize-instance-topology command](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=arppn-applying-required-permissions-by-running-authorize-instance-topology-command) without tethered projects

```
cpd-cli manage authorize-instance-topology \
--cpd_operator_ns=${PROJECT_CPD_INST_OPERATORS} \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
```

You must get this message at the end 
```
[SUCCESS] 2025-06-03T17:11:38.785017Z The authorize-instance-topology command ran successfully.
```

### Authorizing a user to act as an IBM Software Hub instance administrator

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-authorizing-instance-administrator)

We skip this task because it's not a user other than the cluster administrator that will install IBM Software Hub. 

### Creating secrets for services that use Multicloud Object Gateway

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=piish-creating-secrets-services-that-use-multicloud-object-gateway)

We don't need this task for watson studio.

## Installing an instance of IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=installing-instance-software-hub)

### Installing the required components for an instance of IBM Software Hub

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-installing-software)

As we use ODF 

```
cpd-cli manage setup-instance \
--release=${VERSION} \
--license_acceptance=true \
--cpd_operator_ns=${PROJECT_CPD_INST_OPERATORS} \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
--block_storage_class=${STG_CLASS_BLOCK} \
--file_storage_class=${STG_CLASS_FILE} \
--run_storage_tests=false
```

Notice the option `--run_storage_tests=false` because our storage is not performant enough and it fails the install.

If all go well you should get this message 
```
[✔] [SUCCESS] The cpd management server was successfully created in the cpd-instance project
[SUCCESS] 2025-06-03T18:26:56.757250Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/kasten-cpd/cpd-cli-workspace/work directory.
[SUCCESS] 2025-06-03T18:26:56.757430Z The setup-instance command ran successfully.
```

This step is long and can last up to 2 hours. You can monitor progress with 
```
# Check overall CPD platform progress
oc get ibmcpd ibmcpd-cr -n cpd-instance -o jsonpath='{.status.progress}' && echo

# Check zen service progress  
oc get zenservice lite-cr -n cpd-instance -o jsonpath='{.status.progress}' && echo

# Watch deployments being created
oc get deployment -n cpd-instance --watch
```

Confirm that the status of the operands is Completed:
```
cpd-cli manage get-cr-status \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
```

you should get something like this 
```
[INFO] The results of the command as a chart:
Components    CR Kind        CR Name         Creation Timestamp    Namespace     Expected Version    Reconciled Version    Operator Information                 Progress    Progress Message                    Reconcile History                                                              Status
------------  -------------  --------------  --------------------  ------------  ------------------  --------------------  -----------------------------------  ----------  ----------------------------------  -----------------------------------------------------------------------------  ---------
cpd_platform  Ibmcpd         ibmcpd-cr       2025-06-03T16:04:23Z  cpd-instance  5.1.3               5.1.3                 cpd-platform operator 6.1.3 build 5  100%        The Current Operation Is Complete   N/A                                                                            Completed
zen           ZenService     lite-cr         2025-06-03T16:08:09Z  cpd-instance  6.1.3               6.1.3                 zen operator 6.1.3 build 22          100%        The Current Operation Is Completed  2025-06-03T16:22:09.32694Z The last reconciliation was completed successfully  Completed
cpfs          CommonService  common-service  2025-06-03T15:57:07Z  cpd-instance  N/A                 N/A                   N/A                                  N/A         N/A                                 N/A                                                                            Succeeded
```

Check the health of the resources in the operators project:

```
cpd-cli health operators \
--operator_ns=${PROJECT_CPD_INST_OPERATORS} \
--control_plane_ns=${PROJECT_CPD_INST_OPERANDS}
```

Verify that all the heathcheck are successful or skipped
```
...
Common Services Healthcheck                                   
Checks if the commonservice custom resource has succeeded     
[SUCCESS...]                                                  
                                                              
Custom Resource Healthcheck                                   
Checks if custom resources have succeeded                     
[SKIP...]                                                     
                                                              
Operand Requests Healthcheck                                  
Checks if the operand requests are running                    
[SUCCESS...]     
```

Check the health of the resources in the operands project:
```
cpd-cli health operands \
--control_plane_ns=${PROJECT_CPD_INST_OPERANDS}
```

All the heathcheck were ok except the pod usage
```
Pod Usage Healthcheck                                              
Checks if pod resource usage is within CPU and memory limits       
[FAIL...]  Report:                                                 
Location                                                                Namespace       Name                    Message                                      
hub                                                                     cpd-instance    zen-metastore-edb-1     Memory usage has exceeded the 90% threshold. 
```

But checking the logs on this pod 
```
oc -n cpd-instance logs zen-metastore-edb-1
```

I could not see any error message and the pod was running so I choose to ignore it.

### Tethering projects to the IBM Software Hub control plane

[Documenation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-tethering-projects-control-plane)

We have no tethered project for the moment so we skip this section 

## Setting up IBM Software Hub

### Installing privileged monitors for an instance of IBM Software Hub

[documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-installing-privileged-monitors)

Make sure that in you cpd-vars.sh file the value 
```
export PROJECT_PRIVILEGED_MONITORING_SERVICE=ibm-cpd-privileged
```
is set.

Then create the project 
```
oc new-project ${PROJECT_PRIVILEGED_MONITORING_SERVICE}
```

I choose to install the Operator namespace status check for the operators project only
```
cpd-cli manage apply-privileged-monitoring-service \
--privileged_service_ns=${PROJECT_PRIVILEGED_MONITORING_SERVICE} \
--cpd_operator_ns=${PROJECT_CPD_INST_OPERATORS} \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
```

Your command should end up like this 
```
Restarting zen-watchdog pod in namespace cpd-instance
pod "zen-watchdog-777ffcf47-7kpdx" deleted
--------------------------------------------------
[SUCCESS] 2025-06-16T10:36:09.106838Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/kasten-cpd/cpd-cli-workspace/work directory.
[SUCCESS] 2025-06-16T10:36:09.106976Z The apply-privileged-monitoring-service command ran successfully.
```

### Installing the IBM Software Hub configuration admission controller webhook

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-installing-configuration-admission-controller-webhook)

This task is needed for Watson Studio 5.1.2 and later (we are 5.1.3).

Install the configuration admission controller webhook:
```
cpd-cli manage install-cpd-config-ac \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
```

You should get an output like this one at the end 
```
Monday 16 June 2025  08:44:57 +0000 (0:00:00.018)       0:01:03.339 *********** 
=============================================================================== 
utils : Wait until cpd config admission controller webhook deployment is up and running -- 11.07s
utils : Get rsi-webhook-deployment deployment -------------------------- 11.02s
utils : Look for the cpd config admission controller webhook if it exists -- 10.91s
utils : Apply cpd config admission controller webhook service ----------- 9.32s
utils : Look for the cpd-config-ac-webhook-svc-certs secret ------------- 2.43s
utils : Create cpd config admission controller webhook deployment ------- 2.06s
utils : Apply cpd config admission controller service account ----------- 1.94s
utils : get cluster arch ------------------------------------------------ 1.94s
utils : Apply cpd config admission controller webhook configuration ----- 1.91s
utils : Create cpd config admission controller configmap ---------------- 1.89s
utils : Get cpd-config-ac-webhook-svc-certs secret ---------------------- 1.65s
utils : checking ocp cluster connection status -------------------------- 1.65s
utils : Check existence of namespace cpd-instance ----------------------- 1.57s
utils : Print trace information ----------------------------------------- 0.90s
utils : Create admission controller install namespace if not present cpd-instance --- 0.24s
utils : Delete cpd-config-ac-webhook-svc -------------------------------- 0.23s
utils : Delete secret cpd-config-ac-webhook-svc-certs ------------------- 0.23s
utils : Delete cpd config admission controller webhook deployment ------- 0.23s
utils : fail ------------------------------------------------------------ 0.22s
utils : Re-apply cpd config admission controller webhook deployment with cpd config admission controller RBAC with the latest image --- 0.21s
[SUCCESS] 2025-06-16T10:44:58.072190Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/kasten-cpd/cpd-cli-workspace/work directory.
[SUCCESS] 2025-06-16T10:44:58.073414Z The install-cpd-config-ac command ran successfully.
```

Then enable it 
```
cpd-cli manage enable-cpd-config-ac \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
```

You should get this output 
```
Monday 16 June 2025  08:47:37 +0000 (0:00:00.019)       0:00:26.931 *********** 
=============================================================================== 
utils : Get tethered namespaces from zen service cr -------------------- 11.27s
utils : Apply cpd config admission controller RBAC ---------------------- 1.99s
utils : Write namespace information to configmap ------------------------ 1.95s
utils : get cluster arch ------------------------------------------------ 1.89s
utils : Add cpd config admission controller feature label for the input CPD namespace --- 1.83s
utils : checking ocp cluster connection status -------------------------- 1.62s
utils : Check existence of namespace cpd-instance ----------------------- 1.48s
utils : Check existence of namespace cpd-instance ----------------------- 1.44s
utils : Print trace information ----------------------------------------- 0.92s
utils : Create admission controller install namespace if not present cpd-instance --- 0.23s
utils : set_fact -------------------------------------------------------- 0.23s
utils : set_fact -------------------------------------------------------- 0.23s
utils : Create admission controller install namespace if not present cpd-instance --- 0.23s
utils : fail ------------------------------------------------------------ 0.22s
utils : Get component metadata defined in enable-cpd-config-ac-08:47:08.yaml --- 0.19s
utils : set_fact -------------------------------------------------------- 0.19s
utils : Get default variables defined in global.yml --------------------- 0.08s
utils : set_fact -------------------------------------------------------- 0.04s
utils : Enable cpd config admission controller for namespaces: ['cpd-instance'] --- 0.04s
include_role : utils ---------------------------------------------------- 0.04s
[SUCCESS] 2025-06-16T10:47:38.046559Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/kasten-cpd/cpd-cli-workspace/work directory.
[SUCCESS] 2025-06-16T10:47:38.046759Z The enable-cpd-config-ac command ran successfully.
```

### Applying your entitlements to monitor and report use against license terms

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=hub-applying-your-entitlements)

We choose to not use node pinning because we work with a temporary entitlement.

#### Applying your entitlements without node pinning

We used the Entreprise Edition (EE) but we are not in production 

```
cpd-cli manage apply-entitlement \
--cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
--entitlement=cpd-enterprise \
--production=false
```

You should get an output like this 
```
zen-lite                                zen-watchdog-777ffcf47-5sq28                          se-lab-aro-prod-67bsq-worker-d8sv5-eastus3-gdnn4  Running               2025-06-16T08:36:05Z
zen-lite                                zen-watchdog-create-tables-job-bhkm7                  se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-dl7zs  Succeeded             2025-06-03T16:15:03Z
zen-lite                                zen-watchdog-post-requisite-job-xzw9l                 se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-dl7zs  Succeeded             2025-06-03T16:20:42Z
zen-lite                                zen-watchdog-pre-requisite-job-pktbc                  se-lab-aro-prod-67bsq-worker-d8sv5-eastus2-dl7zs  Succeeded             2025-06-03T16:20:22Z
zen-lite                                zen-watcher-5cb94fcbbb-8hzxv                          se-lab-aro-prod-67bsq-worker-d8sv5-eastus1-xhwb4  Running               2025-06-03T16:15:45Z
--------------------------------------------------

[SUCCESS] 2025-06-16T10:58:18.702544Z You may find output and logs in the /Users/michaelcourcy/kasten.io/github/kasten-cpd/cpd-cli-workspace/work directory.
[SUCCESS] 2025-06-16T10:58:18.702631Z The apply-entitlement command ran successfully.
```

## Installing solutions and services

[Documentation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=installing-solutions-services)

As we limit our operation to watson studio we jump directly to "Specifying installation options for services"

### Specifying installation options for services

[Documenation](https://www.ibm.com/docs/en/software-hub/5.1.x?topic=services-specifying-installation-options)

Watson Studio require no installation option so there is nothing to do 

# Watson studio tutorial 

[Check our separate watson studio tutorial for installing [watson studio](./watson-studio-tutorial.md). 

# Install CPDBR (CPD Backup and restore)

We create another note for [this task](./install-cpdbr.md).




