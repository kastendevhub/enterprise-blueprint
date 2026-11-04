# Air-gapped Kasten: copying images to a private registry (Nexus) with k10tools

This guide shows how to move the Kasten (K10) images into a private registry
with `k10tools image copy`. The registry is Sonatype Nexus, a common choice at
customers. The guide also explains the `manifest unknown` error you get when
the k10tools version doesn't match the images.

All of it was tested on 2026-11-04 with k10tools **8.0.1**, Nexus Repository
Community Edition **3.98.0** (and **3.40.1**), deployed on OpenShift 4.18.

References:
- [Air-gapped install](https://docs.kasten.io/latest/install/offline.html)
- [k10tools](https://docs.kasten.io/latest/operating/k10tools.html), with binaries at
  [kastenhq/external-tools releases](https://github.com/kastenhq/external-tools/releases)

## TL;DR: the k10tools version decides the tag

`k10tools image copy` has a `--src-image-tag` flag, and its **default is the
version of the k10tools binary itself**:

```
$ k10tools -v
k10tools version 8.0.1
$ k10tools image copy --help | grep src-image-tag
      --src-image-tag string     The source tag of the image to copy (default "8.0.1")
```

The image list (`k10tools image list`) also comes from the binary. The docs
say it plainly: *the k10tools version must match the Kasten version you
install*.

A local folder made with `--dst-path` is a set of OCI layouts, one per image.
The `index.json` files **store no tag** (they have no
`org.opencontainers.image.ref.name` annotation). So when you push from a
folder, the binary's version sets the tag. The folder name doesn't, and
neither do the images in it.

As a result, if you push an `images-8.0.1` folder with a **7.5.10** binary:
- the push **succeeds** (exit 0),
- the registry stores the 8.0.1 content under the tag **`:7.5.10`**,
- anything that later asks for `:8.0.1` (Helm install with
  `global.airgapped.repository`, `docker pull`, `crane`, …) gets:

```json
{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown","detail":[{"Name":"catalog"},{"Tag":"8.0.1"}]}]}
```

We reproduced exactly this. See [Test 2](#test-2--version-mismatch-reproduces-manifest-unknown).

## Quick diagnosis for "manifest unknown"

Run these on the machine that does the push:

```bash
which -a k10tools          # more than one binary on the PATH?
k10tools -v                # must print the target Kasten version, e.g. 8.0.1
k10tools image copy --help | grep src-image-tag   # default must be that version too
```

k10tools cannot tell you which version is **inside a folder**. The folder
stores no tag, and its folder name is just a name. The images themselves do
record it: every K10 image config has a `release` label set to the Kasten
version (for example `"release": "8.0.1"` or `"release": "7.5.10"`). That label
is in the folder's blobs, so
[k10-folder-version.sh](k10-folder-version.sh) can read it offline (needs `jq`):

```bash
$ ./k10-folder-version.sh ./images-8.0.1
aggregatedapis         8.0.1
auth                   8.0.1
...
```

Every line must show the version that `k10tools -v` prints. Otherwise, the
folder and the binary don't match.

For an image already in the registry, read the same label with
`docker buildx imagetools inspect <registry>/catalog:<tag> --format '{{json (index .Image "linux/amd64").Config.Labels.release}}'`.

Then check which tags actually landed in the registry:

```bash
curl -u USER:PASS https://<registry>/v2/_catalog
curl -u USER:PASS https://<registry>/v2/catalog/tags/list   # expect ["8.0.1"]
```

If the tag is wrong, use the matching k10tools to download and push again.
Another way is the container image, which pins the version by its tag:
`docker run --rm gcr.io/kasten-images/k10tools:8.0.1 ...`.

> Note: in verbose mode (`-v`), a **successful** run logs many
> `HEAD /v2/<image>/manifests/<tag> 404` lines, 161 in our run. They are the
> normal "does this tag already exist?" checks before each push, and Nexus
> answers them with a `MANIFEST_UNKNOWN` body. They are **not** errors.
> Only the final `Error:` line and the exit code count.

## Procedure

### 1. Install k10tools at the target Kasten version (internet side)

```bash
VERSION=8.0.1
OS=macOS ARCH=arm64            # linux/amd64, linux/arm64, linux/ppc64le, windows/... are also available
gh release download $VERSION -R kastenhq/external-tools \
  -p "k10tools_${VERSION}_${OS}_${ARCH}.tar.gz" -p checksums.txt
grep "${OS}_${ARCH}" checksums.txt | shasum -a 256 -c
tar xzf k10tools_${VERSION}_${OS}_${ARCH}.tar.gz
sudo cp k10tools /usr/local/bin/k10tools
k10tools -v                    # k10tools version 8.0.1
```

You can also download the asset from the GitHub releases page in a browser.

### 2. Download the images to a dedicated, empty folder (internet side)

```bash
k10tools image list                         # 31 images for 8.0.1, all :8.0.1
k10tools image copy --dst-path ./images-8.0.1
```

- This took about 3 minutes and **12 GB**: every platform (amd64, arm64,
  ppc64le) plus attestation manifests. Add `--platform linux/amd64` if you only
  need one platform.
- Always use an **empty folder per version**. Copying an old folder's content
  into a folder with a new name changes nothing, because the content stays
  the old version.

Move the folder **and the same k10tools binary** to the air-gapped side.

### 3. Push to the private registry (air-gapped side)

```bash
k10tools image copy \
  --src-path ./images-8.0.1 \
  --dst-registry <registry-host>[:port][/path] \
  --dst-username USERNAME \
  --dst-password PASSWORD
```

For Nexus, `--dst-registry` must point to the **Docker connector port of a
hosted repository**. Don't use the Nexus UI port, and don't use a group
repository (see [Test 3](#test-3--common-nexus-mistakes)).

### 4. Install Kasten from the private registry

```bash
helm install k10 k10-8.0.1.tgz --namespace kasten-io \
  --set global.airgapped.repository=<registry-host>[:port][/path]
```

Use the same value that you passed to `--dst-registry`.

## Lab setup: Nexus on OpenShift

[nexus.yaml](nexus.yaml) deploys Nexus CE with a 50Gi PVC. It creates three
edge routes: the UI (8081), the hosted Docker repo `k10` (8082), and an
optional group repo `k10-group` (8083, used only for the negative test).

```bash
oc apply -f nexus.yaml
oc -n nexus rollout status deploy/nexus

NX=https://$(oc -n nexus get route nexus -o jsonpath='{.spec.host}')
REG=$(oc -n nexus get route nexus-docker -o jsonpath='{.spec.host}')
ADMIN_PW=$(oc -n nexus exec deploy/nexus -- cat /nexus-data/admin.password)

# recent Nexus CE (3.98 here): the EULA must be accepted, or every docker call returns 403
DISC=$(curl -s -u admin:$ADMIN_PW $NX/service/rest/v1/system/eula | jq -r .disclaimer)
curl -u admin:$ADMIN_PW -H 'Content-Type: application/json' -X POST \
  $NX/service/rest/v1/system/eula -d "$(jq -n --arg d "$DISC" '{accepted:true,disclaimer:$d}')"

# hosted docker repo on the 8082 connector
curl -u admin:$ADMIN_PW -H 'Content-Type: application/json' -X POST \
  $NX/service/rest/v1/repositories/docker/hosted -d '{
   "name":"k10","online":true,
   "storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"allow"},
   "docker":{"v1Enabled":false,"forceBasicAuth":true,"httpPort":8082}}'

# Docker Bearer Token realm (required for docker login / push)
curl -u admin:$ADMIN_PW -H 'Content-Type: application/json' -X PUT \
  $NX/service/rest/v1/security/realms/active -d '["NexusAuthenticatingRealm","DockerToken"]'

# push user (lab credentials, change them)
curl -u admin:$ADMIN_PW -H 'Content-Type: application/json' -X POST \
  $NX/service/rest/v1/security/roles -d '{"id":"k10-pusher","name":"k10-pusher","description":"push to k10","privileges":["nx-repository-view-docker-k10-*"],"roles":[]}'
curl -u admin:$ADMIN_PW -H 'Content-Type: application/json' -X POST \
  $NX/service/rest/v1/security/users -d '{"userId":"k10push","firstName":"k10","lastName":"push","emailAddress":"k10push@example.com","password":"K10push-Test1","status":"active","roles":["k10-pusher"]}'

curl -u k10push:K10push-Test1 https://$REG/v2/     # expect 200
```

The routes use edge TLS with the cluster's ingress certificate, which is
publicly trusted in our lab, so no `--dst-registry-insecure` was needed. With
a self-signed certificate, trust the CA on the client, or test with
`--dst-registry-insecure` over plain HTTP.

## Test results

### Test 1: happy path (matching versions)

```bash
$ k10tools -v
k10tools version 8.0.1
$ k10tools image copy --src-path ./images-8.0.1 \
    --dst-registry nexus-docker-nexus.apps.kasten-se-lab.selab.kastendemo.com \
    --dst-username k10push --dst-password K10push-Test1
.../dex:8.0.1
.../catalog:8.0.1
...
.../datamover:8.0.1
EXIT=0   (31 images, ~10 min over the router)
```

Verification:

```bash
$ curl -u k10push:K10push-Test1 https://$REG/v2/_catalog
{"repositories":["aggregatedapis","auth","bloblifecyclemanager","catalog", ... ,"vbrintegrationapi"]}   # 31 repos
$ curl -u k10push:K10push-Test1 https://$REG/v2/catalog/tags/list
{"name":"catalog","tags":["8.0.1"]}
$ curl -I -u k10push:K10push-Test1 -H 'Accept: application/vnd.oci.image.index.v1+json' \
    https://$REG/v2/catalog/manifests/8.0.1
HTTP/1.1 200 OK
docker-content-digest: sha256:b1544349b7d7a1c2d8616659fc73a0e5ff5898e3d02772a1c7d1fcfdacc24745
$ docker buildx imagetools inspect gcr.io/kasten-images/catalog:8.0.1 | grep Digest
Digest:    sha256:b1544349b7d7a1c2d8616659fc73a0e5ff5898e3d02772a1c7d1fcfdacc24745
```

The digest in Nexus is identical to the one on gcr.io, so the push is
bit-for-bit faithful (multi-arch OCI index included).

The same push to **Nexus 3.40.1** (2022, OrientDB-based) also succeeded. Old
Nexus versions handle the K10 multi-arch OCI indexes with attestation
manifests without trouble.

### Test 2: version mismatch reproduces "manifest unknown"

Same `images-8.0.1` folder, pushed with other k10tools binaries:

| Binary | Flags | Result | Tag in Nexus |
|---|---|---|---|
| 7.5.10 | none | exit 0, **silent** | `:7.5.10` (8.0.1 content!) |
| 7.5.10 | `--src-image-tag 8.0.1` | exit 0 | `:8.0.1` |
| 8.5.12 | none | partial push as `:8.5.12`, then `Error: stat images-8.0.1/frsession/index.json: no such file or directory` | `:8.5.12` |
| 8.0.1 | none | exit 0 | `:8.0.1` ✅ |

After the 7.5.10 push:

```bash
$ curl -u k10push:K10push-Test1 https://$REG/v2/v7510/catalog/tags/list
{"name":"v7510/catalog","tags":["7.5.10"]}
$ curl -u k10push:K10push-Test1 https://$REG/v2/v7510/catalog/manifests/8.0.1
{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown","detail":[{"Name":"v7510/catalog"},{"Tag":"8.0.1"}]}]}
```

What this means:
- When the push output shows **7.5.10** although the folder holds 8.0.1, a
  7.5.10 binary is running. Check `which -a k10tools` and `k10tools -v`.
- A newer binary than the folder fails on images that don't exist in the
  older version (here `frsession`). The images it pushed before failing carry
  the wrong tag.
- `--src-image-tag` can work around it, but the right fix is to use the
  matching binary, because the binary also decides **which images** are
  copied.

### Test 3: common Nexus mistakes

These were tested to rule them out. Neither produces "manifest unknown", so
each is easy to tell apart:

| Mistake | Error |
|---|---|
| `--dst-registry` set to the Nexus **UI** port/host | `Error: GET https://<nexus>/v2/: unexpected status code 404 Not Found` (HTML page) |
| `--dst-registry` set to a **docker group** repo port | `Error: PUT .../manifests/<tag>: DENIED: Deploying to groups is a PRO-licensed feature` (on CE) |
| Recent Nexus CE (3.98) with the EULA not accepted | `403` with `You must accept the End User License Agreement` |

Note: pushing to a group repo looks like it succeeds when every tag already
exists in the member hosted repo, because k10tools skips existing tags. It
fails as soon as a real write is needed.

## Cleanup

```bash
rm -rf ./images-8.0.1
oc delete -f nexus.yaml        # deletes the namespace, the PVC and the pushed images
```
