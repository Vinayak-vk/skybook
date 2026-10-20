#!/bin/sh
# Builds one service image with BuildKit (runs inside the buildkit container).
#
#   build-image.sh <service> tar    build to .ci/<service>.tar for scanning
#   build-image.sh <service> push   build and push $REGISTRY/skybook-<service>:$TAG
#
# Both modes share a registry cache, so the push after a successful scan
# rebuilds nothing. Expects REGISTRY, TAG and DOCKER_CONFIG.
set -eu

service="$1"
mode="$2"
image="${REGISTRY}/skybook-${service}"
cache="type=registry,ref=${image}:buildcache"

case "$mode" in
  tar)
    mkdir -p .ci
    # Docker archive format: Trivy reads it as a file, while an OCI layout
    # would have to be unpacked into a directory first.
    output="type=docker,dest=.ci/${service}.tar"
    ;;
  push)
    output="type=image,name=${image}:${TAG},push=true"
    ;;
  *)
    echo "usage: $0 <service> tar|push" >&2
    exit 2
    ;;
esac

set -- buildctl build \
  --frontend dockerfile.v0 \
  --local context="services/${service}" \
  --local dockerfile="services/${service}" \
  --opt build-arg:VERSION="${TAG}" \
  --opt label:org.opencontainers.image.revision="${GIT_COMMIT:-unknown}" \
  --import-cache "$cache" \
  --output "$output"

if [ "$mode" = push ]; then
  set -- "$@" --export-cache "${cache},mode=max,image-manifest=true,oci-mediatypes=true"
fi

echo "Building ${image}:${TAG} (${mode})"
"$@"
