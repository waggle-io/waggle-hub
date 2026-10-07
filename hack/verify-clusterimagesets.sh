#!/usr/bin/env bash
# Checks the generated ClusterImageSets before they reach the hub:
#   - every file is listed in the kustomization and vice versa
#   - every release image is pinned by digest and exists in the registry
#   - exactly one offered ClusterImageSet is the default
# Requires: bash, yq (mikefarah v4), skopeo.
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$ROOT/apps/hive/clusterimagesets"
fail=0

listed=$(yq '.resources[]' "$DIR/kustomization.yaml" | sort)
present=$(cd "$DIR" && ls openshift-*.yaml 2>/dev/null | sort)
if [[ "$listed" != "$present" ]]; then
  echo "kustomization.yaml is out of date; run hack/gen-clusterimagesets.sh" >&2
  diff <(echo "$listed") <(echo "$present") >&2 || true
  fail=1
fi

defaults=0
for f in "$DIR"/openshift-*.yaml; do
  [[ -e "$f" ]] || continue
  name=$(yq '.metadata.name' "$f")
  image=$(yq '.spec.releaseImage' "$f")

  if [[ "$(basename "$f" .yaml)" != "$name" ]]; then
    echo "$f: file name does not match metadata.name $name" >&2
    fail=1
  fi
  if [[ "$image" != *@sha256:* ]]; then
    echo "$name: releaseImage is not pinned by digest: $image" >&2
    fail=1
    continue
  fi
  if [[ "$(yq '.metadata.labels."waggle.io/default"' "$f")" == "true" ]]; then
    defaults=$((defaults + 1))
    if [[ "$(yq '.metadata.labels."waggle.io/offered"' "$f")" != "true" ]]; then
      echo "$name: default ClusterImageSet is not offered" >&2
      fail=1
    fi
  fi
  # Retired versions may legitimately age out of the registry; only check offered ones
  if [[ "$(yq '.metadata.labels."waggle.io/offered"' "$f")" == "true" ]]; then
    if skopeo inspect --raw "docker://$image" >/dev/null; then
      echo "ok   $name"
    else
      echo "$name: cannot inspect $image" >&2
      fail=1
    fi
  fi
done

if (( defaults != 1 )); then
  echo "expected exactly one default ClusterImageSet, found $defaults" >&2
  fail=1
fi

exit "$fail"
