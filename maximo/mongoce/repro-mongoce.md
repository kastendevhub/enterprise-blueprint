# Repro the mongoce environment 

1. **Generate TLS Certificates**

On your workstation:

```
# 1.1 Generate CA key and certificate
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=MyMongoCA"

# 1.2 Generate server key and CSR
openssl genrsa -out mongo.key 4096
cat > mongo.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local       
DNS.2 = mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local
DNS.3 = mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local
DNS.4 = mas-mongo-ce-0.mas-mongo-ce.mongoce.svc.cluster.local
DNS.5 = mas-mongo-ce-1.mas-mongo-ce.mongoce.svc.cluster.local
DNS.6 = mas-mongo-ce-2.mas-mongo-ce.mongoce.svc.cluster.local
DNS.7 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -new -key mongo.key -out mongo.csr -subj "/CN=mas-mongo-ce" -config mongo.cnf

# 1.3 Sign server certificate with CA
openssl x509 -req -in mongo.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out mongo.crt -days 3650 -sha256 -extensions v3_req -extfile mongo.cnf

# 1.4 Create mongo.pem (server cert + key)
cat mongo.crt mongo.key > mongo.pem
```

2. **Create Kubernetes Secrets**

```
oc create namespace mongoce  

oc create secret generic mongo-ca-secret \
  --from-file=ca.crt=ca.crt \
  -n mongoce

oc create secret generic mongo-cert-secret \
  --from-file=mongo.pem=mongo.pem \
  -n mongoce
```

MongoDB requires a shared key file for internal authentication between replica set members when --auth is enabled. The keyFile is used for cluster authentication, not just user authentication.

```
openssl rand -base64 756 > mongo-keyfile
chmod 400 mongo-keyfile
oc create secret generic mongo-keyfile --from-file=mongo-keyfile=mongo-keyfile -n mongoce
```

3. **Deploy MongoDB StatefulSet**


Create a Docker Hub account (free) and create a pull secret to pull the mongo:6.0 image.
```
kubectl create secret docker-registry my-dockerhub-secret \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  --docker-email=<your-email> \
  -n mongoce
```

Apply the statefulset 
```
oc apply -f mongo-statefulset.yaml
```


4. **Initialize the Replica Set** 

After pods are running:

```
oc exec -it mas-mongo-ce-0 -n mongoce -- bash
# Inside the pod:
mongosh --host localhost --tls --tlsCAFile /var/lib/tls/ca/ca.crt
```

In the mongo shell, initialize the replicaset:

```
rs.initiate({
  _id: "mas-mongo-ce",
  members: [
    { _id: 0, host: "mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017" },
    { _id: 1, host: "mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017" },
    { _id: 2, host: "mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017" }
  ]
})
```

Wait for the replica set to be ready, then add the other members and check status:

```
rs.status()
```

You now have a 3-node MongoDB 6.0 replica set with TLS enabled, running in namespace mongoce, StatefulSet mas-mongo-ce.

However since the replicaset has been created it will enforce the "auth" mode, let's create an admin user that we'll use to connect. 

Create an admin user (MongoDB allows full access from localhost before any users exist)
```
use admin
db.createUser({
  user: "admin",
  pwd: "yourStrongPassword",
  roles: [ { role: "root", db: "admin" } ]
})
```

Now you can connect using your credential with either 
- localhost if you are in one of the member of the statefulset
```
mongosh "mongodb://admin:yourStrongPassword@localhost:27017/admin" \
  --tls --tlsCAFile /var/lib/tls/ca/ca.crt
```
- the pod name server from any client that have mongosh 
```
mongosh "mongodb://admin:yourStrongPassword@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/admin"  \
  --tls --tlsCAFile /var/lib/tls/ca/ca.crt
```
- or the complete list of host in the replicaset it will connect you directly to the primary
```
mongosh "mongodb://admin:yourStrongPassword@mas-mongo-ce-0.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-1.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017,mas-mongo-ce-2.mas-mongo-ce-svc.mongoce.svc.cluster.local:27017/admin?replicaSet=mas-mongo-ce" --tls --tlsCAFile=/var/lib/tls/ca/ca.crt
```

Set up this credential in a secret 
```
oc create secret generic mas-mongo-ce-admin-admin --from-literal=password=yourStrongPassword -n mongoce
```

5. **Create some data** 


In the Mongo Shell, Run:
```
// Create mas_dev_catalog with a dummy collection
use mas_dev_catalog
db.dummy.insertOne({test: "catalog"})

// Create mas_dev_core with a dummy collection
use mas_dev_core
db.dummy.insertOne({test: "core"})
```

Verify 
```
show dbs
use mas_dev_catalog
show collections
db.dummy.find()

use mas_dev_core
show collections
db.dummy.find()
```

## Troubleshooting 

To troubleshoot network you can create this mutitool image 

```
oc new-app wbitt/network-multitool:openshift --name multitool-openshift
```

To test a mongodb client you can create a pod that embed the certificate 
```
oc apply -f mongoce-backup.yaml
```