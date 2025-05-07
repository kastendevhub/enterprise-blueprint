#!/bin/bash
set -o errexit   # Exit immediately if a command exits with a non-zero status.
set -o pipefail  # This causes a pipeline to return the exit status of the last command that returned a non-zero status.
set -o xtrace    # (Optional) Enables debug mode, printing each command before it is executed.

namespace=$1
for cassandradatacenter in $(kubectl get cassandradatacenter -n $namespace -o json | jq -r '.items[] | .metadata.name'); 
do

echo "Found cassandradatacenter: $cassandradatacenter"

echo "Wait 10 minutes for it to be ready"
kubectl wait --for='jsonpath={.status.cassandraOperatorProgress}=Ready' -n $namespace cassandradatacenter/$cassandradatacenter --timeout=600s

echo "we need to clean up existing user tables and replace them with the schema in /var/lib/cassandra/data and the data in the snapshots"    
secret="$(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o json | jq -r '.spec.clusterName')-superuser"
user=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.username | base64decode }}')
password=$(kubectl get secret $secret -n cass-operator -o go-template='{{ .data.password | base64decode }}')
schema_restored=false

for pod in $(kubectl get cassandradatacenter -n $namespace $cassandradatacenter -o go-template='{{range $key, $value := .status.nodeStatuses}}{{$key}} {{end}}'); 
do

echo "Working on $pod"

if [ $schema_restored = false ]; then
echo "Schema is not restored yet, first delete the existing schema and then restore the schema from the schema.cql file"
cat <<EOF | kubectl exec -i -c cassandra $pod -- /bin/bash
echo "Working on \$HOSTNAME"
for dir in \$(find /var/lib/cassandra/data -mindepth 1 -maxdepth 1 -type d ! -name "system*"); do
    keyspace_name=\$(basename \$dir)
    echo "Dropping keyspace: \$keyspace_name"
    cqlsh -u '$user' -p '$password' -e "DROP KEYSPACE IF EXISTS \$keyspace_name;"
done
echo "Restoring the schema now"
cqlsh -u '$user' -p '$password' -e "\$(cat /var/lib/cassandra/data/schema.cql)" --request-timeout=300
EOF
schema_restored=true
fi

echo "Discover the new uid of the tables"
kubectl exec -i $pod -c cassandra -n $namespace -- bash -c "cqlsh -u '$user' -p '$password' -e 'SELECT JSON id, table_name, keyspace_name FROM system_schema.tables;' | grep  '{' | grep -v system" > /tmp/table_desc.txt
PREVIOUS_IFS=$IFS
IFS=$'\n'
cassandra_prefix="/var/lib/cassandra/data"  
for line in $(cat /tmp/table_desc.txt); 
do
    id=$(echo $line | jq -r '.id')
    id="${id//-/}"
    table_name=$(echo $line | jq -r '.table_name')
    keyspace_name=$(echo $line | jq -r '.keyspace_name')    
    keyspace_directory="${cassandra_prefix}/${keyspace_name}/${table_name}-${id}"
    snap_directory=$(kubectl exec -i $pod -c cassandra -n $namespace -- bash -c "find /var/lib/cassandra/data/$keyspace_name -type d -regextype posix-extended -regex '.*/${table_name}-[a-f0-9\-]+/snapshots/$pod$'")
    kubectl exec -i $pod -c cassandra -n $namespace -- bash -c "cp -r ${snap_directory}/* ${keyspace_directory}/"
    kubectl exec -i $pod -c cassandra -n $namespace -- bash -c "nodetool refresh $keyspace_name $table_name"
done
IFS=$PREVIOUS_IFS

done
done