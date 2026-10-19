# ADR 0004: A laptop profile that reuses the cloud configuration

- Status: accepted
- Date: 2026-10-19

## Context

The cloud environment ([ADR 0001](0001-oracle-always-free-single-node-k3s.md))
needs an Oracle account, and Oracle only accepts Visa, Mastercard or Amex
cards. Until one is available, the platform has to run on a laptop: Windows
with WSL2, 11.7 GB of RAM, and no inbound connectivity. Keeping a second copy
of the configuration for the laptop would drift from the cloud version.

## Decision

- **Same Kubernetes:** k3d runs the same k3s release as the cloud node, inside
  Docker in WSL2. One script, `scripts/local.sh`, does what Ansible's
  `platform` role does in the cloud: secrets, Argo CD, and the root app.
- **Same hostnames:** DuckDNS points the domain at `127.0.0.1`, so every
  `*.domain` URL in the repo (ingresses, Jenkins, Grafana, Argo CD) works
  unchanged in the laptop's browser.
- **In-cluster DNS rewrite** (`deploy/platform/cluster`): pods resolve
  `*.domain` to Traefik's ClusterIP. On the laptop, `127.0.0.1` would
  otherwise point a pod at itself. In the cloud, it avoids hair-pinning through
  the public IP. Both profiles use it.
- **The profile is the root app.** `root-local.yaml` points at the same app
  folder and excludes only cert-manager (Let's Encrypt cannot validate a name
  that resolves to `127.0.0.1`) and Kyverno (about 400 MB of RAM).
- **No webhooks reach a laptop.** Jenkins polls GitHub every 2 minutes, and
  Argo CD polls on its usual interval in both profiles.

## Consequences

- The links work only on the laptop and only while it runs. A public demo
  needs the cloud profile, or a temporary tunnel.
- Browsers warn about the self-signed default certificate. The pipeline's
  staging and prod checks use HTTP, so they don't depend on certificates.
- Images are built for amd64 on the laptop and for arm64 in the cloud; moving
  means one pipeline run to rebuild them.
- Moving to the cloud requires no repository changes.
