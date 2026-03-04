# Goal 

Explain how the namespace `mas-$MAS_INSTANCE_ID-manage` should be backed up

# A single backup policy 

You need to create a policy that will capture this list of namespaces

- mas-$MAS_INSTANCE_ID-manage
- cert-manager
- cert-manager-operator (optional)
- ibm-sls 
- grafana

These backups are very useful for retrieving manifests that have been changed either directly with
kubectl or by action on the UI. You often use them for comparison or to fix manipulation errors.

The Grafana PVC stores the Grafana database (SQLite by default), which contains:

- Dashboard definitions
- Datasource configurations
- User accounts and preferences
- Alert rules
- Folder structure

It does not store metrics/monitoring data — that lives in the datasource (typically Prometheus, which has its own PVC).

This is important for backup: the Grafana PVC is worth backing up because it holds the dashboard definitions that may have been customized. If you only back up manifests and not the PVC, you lose any dashboards created or modified via the UI.



