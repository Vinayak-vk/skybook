# ADR 0003: Build images with BuildKit in ephemeral Jenkins pods

- Status: accepted
- Date: 2026-10-19

## Context

Builds run inside Kubernetes, where there is no Docker daemon to borrow
(k3s uses containerd). The common options:

- **Docker-in-Docker:** a full privileged Docker daemon per build.
- **Mounting the node's container socket:** gives every build root on the node.
- **Kaniko:** archived by Google in June 2025, so no longer maintained.
- **BuildKit:** the engine behind `docker build`, usable on its own with
  `buildctl`.

## Decision

- Each build runs in its own pod (`ci/jenkins/build-pod.yaml`) with one
  container per tool: python, node, trivy, buildkit and yq. The pod is
  deleted when the build ends.
- BuildKit builds twice per service:
  1. To an OCI tarball that Trivy scans. A fixable CRITICAL CVE fails the build.
  2. To GHCR, only on `main` and only after the scan passes. This build is
     served from the registry cache, so nothing is rebuilt.
- Trivy also writes a CycloneDX SBOM per image, archived with the build.
- Tool versions are pinned. Trivy in particular is pinned after its March 2026
  supply-chain compromise (CVE-2026-33634).

## Consequences

- **The BuildKit container runs privileged.** That is acceptable on a
  single-tenant cluster where only this repo's pipeline runs. With untrusted
  builds I would switch to rootless BuildKit or isolate builds on a dedicated
  node pool.
- **Every build starts with an empty local cache.** The registry cache
  (`:buildcache` tags on GHCR) keeps rebuilds fast anyway.
