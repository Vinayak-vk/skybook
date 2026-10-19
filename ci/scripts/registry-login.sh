#!/bin/sh
# Writes a Docker config with GHCR credentials for BuildKit (image push and
# registry cache). Expects GH_USER, GH_TOKEN and DOCKER_CONFIG.
set -eu
umask 077

mkdir -p "$DOCKER_CONFIG"
auth=$(printf '%s:%s' "$GH_USER" "$GH_TOKEN" | base64 | tr -d '\n')
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$auth" > "$DOCKER_CONFIG/config.json"
echo "Registry credentials written for ghcr.io"
