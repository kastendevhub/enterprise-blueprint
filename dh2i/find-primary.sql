SELECT 
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ars.role_desc AS ReplicaRole
FROM 
    sys.availability_groups ag
JOIN 
    sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN 
    sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE 
    ars.role_desc = 'PRIMARY';