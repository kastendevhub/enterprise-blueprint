#! bash
# This script is designed to clean up Cassandra data directories by moving snapshot contents
# to their respective table directories and removing any non-directory files in the table directories.

for dir in $(find /var/lib/cassandra/data -mindepth 1 -maxdepth 1 -type d ! -name "system*"); do
        keyspace_name=$(basename $dir)
        echo "Working on keyspace: $keyspace_name, lising all the tables that have a non empty snapshot directory"
        for table_dir in $(find $dir -mindepth 1 -maxdepth 1 -type d); do
            table_name=$(basename $table_dir)
            echo "Working on table: $table_name"
            if [ ! -d "$table_dir/snapshots" ] || [ -z "$(ls -A $table_dir/snapshots)" ]; then 
                echo "No snapshot directory found for table: $table_dir or it is empty, skipping"
            else
                echo "Snapshot directory found for table: $table_dir let's work on it"
                echo "There should be only one directory in $table_dir/snapshots"
                snapshot_dir=$(ls -d $table_dir/snapshots/*)
                if [ -f "$snapshot_dir/restore-completed" ]; then
                    echo "The snapshot directory $snapshot_dir has already been processed, skipping"
                    continue
                fi
                if [ -d "$snapshot_dir" ]; then
                    echo "Cleaning up all the non directory files in $table_dir but not in subdirectories"
                    find $table_dir -maxdepth 1 -type f -exec rm -f {} \;
                    echo "moving the contents of $snapshot_dir to $table_dir"
                    mv $snapshot_dir/* $table_dir/
                    date > $snapshot_dir/restore-completed
                fi
            fi
        done
        echo "ending work on keyspace: $keyspace_name"
        echo "----------------------------------------"
        echo "----------------------------------------"
done