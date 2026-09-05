#!/bin/sh
# Run one warp benchmark against one endpoint and print a single-line summary.
#
#   ./run-bench.sh <put|get|mixed> <endpoint-url> <label>
#
# Deliberately minimal: it patches the s3-target Secret, deletes any previous
# job (a Job's pod template is immutable, so re-running requires a delete),
# waits for completion and greps the report. Everything else -- object size,
# concurrency, duration -- comes from the warp-params ConfigMap, so two runs
# with different labels differ only in the endpoint.
set -e
BENCH=$1
ENDPOINT=$2
LABEL=$3
case "$BENCH" in
  put)   MANIFEST=../05-warp-put.yaml   ; JOB=warp-put   ;;
  get)   MANIFEST=../06-warp-get.yaml   ; JOB=warp-get   ;;
  mixed) MANIFEST=../07-warp-mixed.yaml ; JOB=warp-mixed ;;
  *) echo "usage: $0 <put|get|mixed> <endpoint> <label>" >&2; exit 1 ;;
esac

kubectl -n warp patch secret s3-target --type merge \
  -p "{\"stringData\":{\"S3_ENDPOINT\":\"$ENDPOINT\"}}" >/dev/null
kubectl -n warp delete job "$JOB" --ignore-not-found >/dev/null 2>&1

# WARP_NODE pins the warp pod to a node. This matters enormously for GET: a
# read served from the page cache of the node the server runs on is not a
# network measurement (the main tutorial saw 2718 MiB/s same-node against
# 1359 MiB/s cross-node). Pin it, or the scheduler silently picks which
# experiment you ran.
RENDER="cat $MANIFEST"
if [ -n "$WARP_NODE" ]; then
  RENDER="$RENDER | sed 's|^      restartPolicy: Never|      nodeSelector: { kubernetes.io/hostname: $WARP_NODE }\n      restartPolicy: Never|'"
fi
# WARP_CPU raises the warp pod's own CPU limit. warp generates random data and
# checksums it, so it is CPU bound before it is network bound: if a number does
# not move when you raise this, the endpoint is the limit and not the client.
if [ -n "$WARP_CPU" ]; then
  RENDER="$RENDER | sed 's|^              cpu: \"2\"|              cpu: \"$WARP_CPU\"|'"
fi
eval "$RENDER" | kubectl apply -f - >/dev/null
kubectl -n warp wait --for=condition=complete "job/$JOB" --timeout=900s >/dev/null 2>&1 || true

POD=$(kubectl -n warp get pods -l job-name="$JOB" \
        --field-selector=status.phase=Succeeded \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "$LABEL: FAILED -- no succeeded pod"
  kubectl -n warp get pods -l job-name="$JOB" \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers
  kubectl -n warp logs "job/$JOB" 2>&1 | tail -20
  exit 1
fi

echo "----- $LABEL ($BENCH) -----"
kubectl -n warp logs "$POD" 2>&1 | grep -E "measured from|^Report:|Average:|Reqs:|TTFB:|Fastest:|Median:|Slowest:|errors|ERROR"
