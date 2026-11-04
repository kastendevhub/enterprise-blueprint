#!/usr/bin/env bash
# Print the Kasten release of every image in a `k10tools image copy --dst-path` folder.
# Usage: ./k10-folder-version.sh ./images-8.0.1     (needs jq)
DIR=${1:-./images}
for img in "$DIR"/*/; do
  img=${img%/}
  blob() { cat "$img/blobs/${1/://}"; }   # sha256:abc -> blobs/sha256/abc
  # first non-attestation manifest in the index
  m=$(jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest' "$img/index.json")
  # it can itself be an index (nested layout): descend once more
  if blob "$m" | jq -e '.manifests' >/dev/null 2>&1; then
    m=$(blob "$m" | jq -r '[.manifests[] | select(.platform.os != "unknown")][0].digest')
  fi
  cfg=$(blob "$m" | jq -r '.config.digest')
  printf '%-22s %s\n' "$(basename "$img")" "$(blob "$cfg" | jq -r '.config.Labels.release // "?"')"
done
