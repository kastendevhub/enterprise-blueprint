#!/bin/bash
# clean-up-cassandra-volume.sh
# This script mount a pod that will copy the content of the snapshot directory into the table directory
# use it if at restore if cassandra did not start properly because data were in a dirty state when we took the snapshot
# the blueprint is doing the same thing when cassadra manage to start. But if cassandra does not start we have to do it manually with this script
# first restore on the volumes of cassandra apply the script on each volume when the pod are completed 
# you can restore the rest of the namespace with Kasten.

pvc=$1
namespace=$2
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $pvc-cleaner
  namespace: $namespace
spec:
  ttlSecondsAfterFinished: 30  # Automatically delete job after completion (K8s 1.21+)
  backoffLimit: 0
  template:    
    spec:      
      restartPolicy: Never  # Critical setting for run-once jobs
      containers:
      - name: cleaner
        image: bash:latest    
        command:
        - bash
        - -x
        - -o
        - errexit
        - -o
        - pipefail
        - -c
        - |
          for dir in \$(find /var/lib/cassandra/data -mindepth 1 -maxdepth 1 -type d ! -name "system*"); do
                  keyspace_name=\$(basename \$dir)
                  echo "Working on keyspace: \$keyspace_name, lising all the tables that have a non empty snapshot directory"
                  for table_dir in \$(find \$dir -mindepth 1 -maxdepth 1 -type d); do
                      table_name=\$(basename \$table_dir)
                      echo "Working on table: \$table_name"
                      if [ ! -d "\$table_dir/snapshots" ] || [ -z "\$(ls -A \$table_dir/snapshots)" ]; then 
                          echo "No snapshot directory found for table: \$table_dir or it is empty, skipping"
                      else
                          echo "Snapshot directory found for table: \$table_dir let's work on it"
                          echo "There should be only one directory in \$table_dir/snapshots"
                          snapshot_dir=\$(ls -d \$table_dir/snapshots/*)
                          if [ -f "\$snapshot_dir/restore-completed" ]; then
                              echo "The snapshot directory \$snapshot_dir has already been processed, skipping"
                              continue
                          fi
                          if [ -d "\$snapshot_dir" ]; then
                              echo "Cleaning up all the non directory files in \$table_dir but not in subdirectories"
                              find \$table_dir -maxdepth 1 -type f -exec rm -f {} \;
                              echo "moving the contents of \$snapshot_dir to \$table_dir"
                              mv \$snapshot_dir/* \$table_dir/
                              date > \$snapshot_dir/restore-completed
                          fi
                      fi
                  done
                  echo "ending work on keyspace: \$keyspace_name"
                  echo "----------------------------------------"
                  echo "----------------------------------------"
          done
        volumeMounts:
        - name: data
          mountPath: /var/lib/cassandra/
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: $pvc
EOF
echo "Wait for the pod $pvc to be ready"