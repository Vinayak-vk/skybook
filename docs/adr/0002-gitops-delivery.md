# ADR 0002: GitOps delivery: Jenkins builds, Argo CD deploys

- Status: accepted
- Date: 2026-10-19

## Context

CI must build and test every change. Deployments must be repeatable,
auditable and easy to roll back, and the cluster's credentials should not
live in the CI system.

## Decision

- **Jenkins never touches the cluster.** It builds, tests, scans and pushes
  images. To deploy, it commits new image tags to `deploy/envs/<env>/values.yaml`.
- **Argo CD** watches the repo and reconciles the cluster to it. The whole
  platform, including Argo CD itself, is declared under `deploy/argocd/apps`
  (app-of-apps) and ordered with sync waves.
- **Image tags are the git commit SHA.** They are immutable, so "what is
  running" is always answerable from git, and Kyverno flags `:latest`.
- **Promotion copies what was tested.** On a green `main` build, staging gets
  the new tags automatically, and Jenkins waits until all three services
  report that version. Production changes only through the `skybook-promote`
  job, which shows the tag diff, waits for approval and then copies staging's
  tags to prod.
- **Production releases are canaries** (Argo Rollouts): 50% of pods, a pause,
  then a Prometheus analysis of the 5xx ratio. If the analysis fails, the
  rollout is aborted and rolled back automatically.
- **Monorepo.** App, infrastructure and deployment config live together so the
  project reads as one story. Commits made by the pipeline carry `[skip ci]`,
  and the pipeline stops early on them to avoid a build loop.

## Consequences

- **Rollback** is `git revert` of the deploy commit (or a re-run of the promote
  job), and the change is reviewed and recorded like any other.
- **Drift is corrected:** `selfHeal` reverts manual `kubectl` edits to what git says.
- **Deploys lag a push by up to Argo CD's poll interval** (about 2 minutes). An
  optional GitHub webhook to Argo CD makes it near-instant.
- **The deploy commits add noise to `main`'s history.** A separate GitOps repo
  would avoid that; at this size, one repo is easier to follow.
