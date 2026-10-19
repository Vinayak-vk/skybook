# How SkyBook works: a study guide

This guide walks through the project layer by layer: what each piece does,
where it lives in the repo, and the questions interviewers usually ask about
it. Read it with the code open next to it.

---

## 1. The two flows to know by heart

### A request (a user books a flight)

```
browser ── HTTPS ──> Traefik (k3s ingress, TLS cert from cert-manager)
                       └─> frontend pod (nginx)
                             ├─ /            static HTML/JS
                             ├─ /api/flights/* ──> flight-search (Node.js)
                             └─ /api/bookings* ──> booking-api (FastAPI)
                                                     ├─> flight-search (validate the flight)
                                                     └─> Postgres (CloudNativePG)
```

### A change (you push a commit)

```
git push ─> GitHub webhook ─> Jenkins multibranch job
  Prepare ─> Unit tests ─> Source scan ─> Build & scan images
  (main only) ─> Publish images (GHCR) ─> commit new tags to deploy/envs/staging
             ─> Argo CD sees the commit and syncs skybook-staging
             ─> Jenkins polls staging until all 3 services report the new version
Later: "skybook-promote" job ─> approve ─> commit tags to deploy/envs/prod
             ─> Argo CD syncs ─> Argo Rollouts canary (50% ─> analysis ─> 100%)
```

**One-liner for interviews:** "Jenkins does CI and only writes to git; Argo
CD does CD by pulling from git. Production releases are canaries that roll
back automatically if the error rate rises."

---

## 2. Mapping to what you already know (OpenShift / ROSA)

| In your job (OpenShift) | In SkyBook | Notes |
|---|---|---|
| OpenShift GitOps operator | Argo CD | Same product; here you install and configure it yourself |
| OpenShift monitoring stack | kube-prometheus-stack | Same components: Prometheus, Alertmanager, Grafana |
| OpenShift Logging (Loki) | Loki + Grafana Alloy | Alloy plays the collector role (like Vector in OpenShift Logging) |
| Route | Ingress (Traefik) | Ingress is the portable Kubernetes API; Routes are OpenShift-only |
| BuildConfig / S2I | Jenkins + BuildKit | Builds run as pods in both cases |
| SecurityContextConstraints | securityContext + Kyverno policies | SCCs are OpenShift's; Kyverno is policy-as-code for any cluster |
| ROSA (managed control plane) | k3s on a VM | You own the control plane here |
| `oc` | `kubectl` | Same API; `oc` is a superset |

That's your strongest story: *"I support this stack in production at work,
and I built it end to end myself."*

---

## 3. Layer by layer

### 3.1 Services (`services/`)

- **frontend:** static site on `nginx-unprivileged`. Its nginx config is a
  template, rendered at startup from env vars (`FLIGHT_SEARCH_URL`, ...), so the
  same image works in Compose and in Kubernetes. That's the twelve-factor
  idea of "config in the environment".
- **flight-search:** Node.js/Express. It generates flights deterministically
  from a seed, so it is stateless and scales horizontally.
- **booking-api:** Python/FastAPI + SQLAlchemy + Postgres. It calls
  flight-search to validate a flight, which shows service-to-service calls and
  failure handling (it returns 503 if the upstream is down).
- **All three expose** `/healthz` (liveness), `/readyz` (readiness) and
  `/metrics` (Prometheus), and log JSON to stdout.

**Interview questions**
- *Liveness vs readiness vs startup probes?* Liveness failing means restart
  the container. Readiness failing means take it out of the Service endpoints
  (no traffic), without a restart. Startup means don't run liveness until the
  app has booted; booking-api uses it while waiting for Postgres.
- *Why JSON logs?* They are machine-parseable, so Loki can filter by field
  without regex guesswork.

### 3.2 Containers (`services/*/Dockerfile`)

- **Multi-stage builds:** dependencies are installed in one stage and only the
  result is copied into a slim runtime stage, so no compilers or caches ship.
- **Non-root numeric user** (`USER 1000`, `10001`, `101`): Kubernetes'
  `runAsNonRoot` can only verify numeric UIDs.
- **Read-only root filesystem** at runtime: only `/tmp` (and nginx's conf
  dir) are writable `emptyDir`s, so an attacker can't drop files.
- **`ARG VERSION`** becomes `APP_VERSION`, which is how the pipeline can verify
  exactly which build is live.

**Interview questions**
- *How do you make an image smaller and safer?* Slim or distroless base,
  multi-stage builds, a `.dockerignore`, a non-root user, pinned versions, and
  scanning (Trivy).
- *CMD vs ENTRYPOINT?* ENTRYPOINT is the executable; CMD supplies default
  arguments, or the whole command when there is no ENTRYPOINT.

### 3.3 Infrastructure (`infra/terraform/`)

- **Provider `oracle/oci`**, authenticating with the API key from `oci setup config`.
- **Remote state in OCI Object Storage** (native `oci` backend) with
  locking. State in a bucket means it isn't lost with your laptop, and two
  `apply`s can't run at once.
- **Resources:** compartment, VCN, internet gateway, route table, security
  list (the firewall), subnet, the A1 VM, and a budget alert.
- **`local_file`** writes the Ansible inventory, so Terraform's output feeds
  straight into Ansible.

**Interview questions**
- *What is Terraform state and why remote?* It maps your code to real
  resource IDs. Remote state allows team use and locking, and is backed up
  (the bucket is versioned).
- *`plan` vs `apply`? Drift?* `plan` diffs code against the real world; drift
  is a manual change that `plan` will show and `apply` will revert.
- *How do you avoid recreating a VM when a new image appears?*
  `lifecycle { ignore_changes = [source_details[0].source_id] }`.

### 3.4 Configuration (`infra/ansible/`)

Roles run in order:

1. `common`: upgrades, fail2ban, SSH hardening (keys only, no root).
2. `firewall`: replaces Oracle's default iptables rules, which break k3s pod
   networking.
3. `k3s`: installs k3s and copies the kubeconfig to your laptop.
4. `duckdns`: points the domain at the VM.
5. `platform`: creates the secrets, installs Argo CD and applies the root app.

- **Secrets** come from Ansible Vault (encrypted file) and are passed to
  `kubectl` on stdin, so they never appear in process lists or logs (`no_log`).
- **Idempotent:** re-running changes nothing if everything is already in place.

**Interview questions**
- *Terraform vs Ansible?* Terraform provisions infrastructure (declarative,
  stateful). Ansible configures what runs on it (procedural tasks, made
  idempotent by its modules).
- *What is idempotency?* Running the same playbook twice gives the same
  result; the second run reports no changes.

### 3.5 Kubernetes and the Helm chart (`deploy/charts/skybook/`)

- **One chart, two environments:** `values.yaml` holds the defaults;
  `deploy/envs/staging|prod/values.yaml` override them.
- **`services:` is a map**, and the templates loop over it, so adding a service
  means adding values, not copying YAML.
- **Prod switches `Deployment` to an Argo `Rollout`** (`rollout.enabled`).
  The pod template is shared through `_helpers.tpl`.
- **Also in the chart:** HPA (CPU-based), PDBs, NetworkPolicies, a
  ServiceMonitor, a PodMonitor, PrometheusRules, an AnalysisTemplate and a
  CNPG `Cluster`.
- **Requests and limits everywhere:** requests drive scheduling (and HPA
  percentages); the memory limit caps a leak. There are no CPU limits on
  platform pods, to avoid throttling.

**Interview questions**
- *What happens during a rolling update?* `maxSurge: 1, maxUnavailable: 0`:
  start one new pod, wait until it's Ready, remove an old one, repeat. Zero
  downtime if readiness probes are right.
- *Requests vs limits?* Requests are what the scheduler reserves; limits are
  the hard cap. Exceeding the memory limit gets the container OOMKilled;
  exceeding a CPU limit gets it throttled.
- *What is a PDB?* It limits voluntary disruptions (like node drains) so at
  least N pods stay up.
- *How does the HPA work?* It compares average CPU usage to the target
  percentage of requests and scales between min and max. It needs
  metrics-server.

### 3.6 GitOps (`deploy/argocd/`, `deploy/platform/`)

- **App-of-apps:** `root.yaml` points at `deploy/argocd/apps/`, where every
  file is an Argo CD `Application` (cert-manager, monitoring, Jenkins, ... and
  Argo CD itself).
- **Sync waves** (`argocd.argoproj.io/sync-wave`) order the install: operators
  and CRDs first, then things that use those CRDs, the app last. A small Lua
  health check in `argocd/values.yaml` makes waves wait for each child app
  to be healthy.
- **`selfHeal: true`** means manual `kubectl` edits get reverted to git;
  **`prune: true`** means anything deleted from git is deleted from the cluster.
- **AppProject `skybook`** restricts the app to its two namespaces and
  forbids cluster-scoped resources (least privilege).

**Interview questions**
- *Push vs pull deployment?* With push, CI runs `kubectl` or `helm` and holds
  cluster credentials. With pull (GitOps), an agent inside the cluster pulls
  from git, so no credentials leave the cluster and git is the audit log.
- *How do you roll back?* `git revert` the deploy commit; Argo CD syncs the
  old tags.
- *What is drift?* The live state differing from git. Argo CD shows it as
  OutOfSync, and selfHeal fixes it.

### 3.7 CI (`Jenkinsfile`, `ci/`, `deploy/platform/jenkins/values.yaml`)

- **Jenkins configured as code (JCasC):** credentials, both jobs (Job DSL) and
  settings live in values.yaml. Delete the Jenkins pod and it comes back
  identical.
- **Ephemeral pod agents:** each build gets a fresh pod with one container per
  tool (python, node, trivy, buildkit, yq), defined in
  `ci/jenkins/build-pod.yaml`. There are no long-lived build servers to
  patch, and builds don't share state.
- **BuildKit instead of Docker-in-Docker** (Kaniko was archived in 2025).
  Each image is built to a tarball, scanned, and only then pushed; the
  registry cache makes the second build instant.
- **Image tag = commit SHA.** It is immutable and traceable.
- **The `[skip ci]` guard:** the pipeline's own deploy commits would otherwise
  trigger it again, forever.
- **`disableConcurrentBuilds()`** queues builds instead of aborting them,
  because the deploy commit triggers a build while the current one is still
  verifying staging.

**Interview questions**
- *Declarative vs scripted pipeline?* Declarative has a fixed structure
  (stages, when, post) and is validated up front; scripted is free-form
  Groovy. `script {}` blocks allow Groovy inside declarative.
- *How do you keep secrets out of logs?* `withCredentials` masks them, the
  token goes to git through a credential helper, and nothing is `echo`ed.
- *How would you speed the pipeline up?* Build only the services that
  changed, cache dependencies (pip/npm) on a PVC, and run more stages in
  parallel.

### 3.8 Security (DevSecOps)

| Control | Where | Stops |
|---|---|---|
| Trivy `fs` (vulns + secrets), gate on CRITICAL | Jenkinsfile, "Source scan" | Vulnerable dependencies, committed secrets |
| Trivy `config`, report only | Jenkinsfile | Misconfigured Dockerfile/Helm/Terraform |
| Trivy image scan before push + SBOM | Jenkinsfile, "Build & scan images" | Shipping a CVE; "what's in this image?" |
| Pinned tool versions | `build-pod.yaml`, `bootstrap-wsl.sh` | Supply-chain attacks (e.g. the Trivy compromise in March 2026) |
| Non-root, read-only FS, drop ALL caps, seccomp | Helm chart | Container breakout and persistence |
| NetworkPolicies, default deny | Helm chart | Lateral movement between pods |
| Kyverno (Audit) | `deploy/platform/kyverno-policies` | `:latest` tags, missing limits, root pods, unknown registries |
| Ansible Vault, k3s secrets encryption at rest | Ansible, k3s config | Plain-text secrets on disk |
| SSH keys only, fail2ban, security list | Ansible, Terraform | Brute force, exposed ports |

**Interview question:** *Shift-left?* Find problems as early (as far left in
the pipeline) as possible: scanning in CI is cheaper than an incident in prod.

### 3.9 Observability (`deploy/platform/monitoring/`)

- **Metrics:** apps expose `/metrics`; ServiceMonitors tell Prometheus what to
  scrape.
  - The RED method per service: **R**ate, **E**rrors, **D**uration
    (`http_request_duration_seconds` histogram).
  - Recording rules (`skybook:http_errors:ratio_rate5m`) precompute
    expensive queries.
- **Logs:** Alloy reads every pod's logs through the Kubernetes API and pushes
  them to Loki, labelled with namespace, pod and app. In Grafana, query with
  LogQL: `{namespace="skybook-prod", app="booking-api"} |= "error"`.
- **SLO:** 99.5% of requests succeed, so the error budget is 0.5%.
  Burn-rate alerts fire when the budget is being used up too fast; each one
  uses a long and a short window, which removes flapping.
- **Alerting:** PrometheusRule, then Alertmanager (grouping, inhibition,
  routing), then Discord. Every alert has a `runbook_url`.

**Interview questions**
- *Monitoring vs observability?* Monitoring answers known questions
  (dashboards, alerts); observability lets you ask new ones (rich metrics,
  logs and traces).
- *Why alert on SLO burn rate rather than "CPU > 80%"?* It alerts on user
  pain, not causes, so you get fewer, more meaningful pages.
- *What is a histogram and why p95?* Buckets of latencies; p95 means 95% of
  requests were faster than this. Averages hide the slow tail.

### 3.10 Progressive delivery (Argo Rollouts)

Prod uses a canary:

1. `setWeight: 50` brings up the new pods.
2. A 2-minute pause.
3. The `skybook-error-ratio` AnalysisTemplate runs four checks of the 5xx
   ratio from Prometheus, 30 s apart. Two failures abort the release and
   roll back.
4. `setWeight: 100`.

Without a service mesh, the weight is approximated by pod counts.

**Interview question:** *Canary vs blue-green?* A canary shifts traffic
gradually, which limits the blast radius. Blue-green runs two full stacks and
switches all at once, which gives the fastest rollback but costs twice the
capacity.

---

## 4. Things to be honest about (and how to say them)

- **Single node, no HA:** *"Deliberate, because of the free-tier budget
  (ADR 0001). Recovery is automated instead: Terraform plus Ansible rebuild
  it, and Argo CD restores the workloads."*
- **No database backups yet:** *"The next step is CNPG Barman backups to
  Object Storage."*
- **BuildKit runs privileged:** *"Acceptable for a single-tenant cluster.
  For untrusted builds I'd use rootless BuildKit or a dedicated node."*
- **No SonarQube stage:** *"The SonarScanner CLI image is amd64-only and the
  cluster is arm64. I used ruff and Trivy, and could add SonarQube Cloud's
  automatic analysis."*

Saying the trade-offs out loud reads as experience, not weakness.

---

## 5. Resume bullets (use them once it's live)

- Built and operate **SkyBook**, a 3-service flight-booking platform
  (Node.js, FastAPI, Postgres) on **Kubernetes (k3s)** in **Oracle Cloud**,
  provisioned with **Terraform** (remote state, budget alerts) and configured
  with **Ansible** (SSH hardening, fail2ban, Vault-managed secrets). Live at
  `https://<your-domain>`.
- Designed a **Jenkins** CI pipeline (JCasC, Job DSL, ephemeral Kubernetes pod
  agents) with **Trivy** dependency, secret and image scanning, SBOM
  generation, and **BuildKit** image builds pushed to GHCR with immutable SHA
  tags.
- Implemented **GitOps** delivery with **Argo CD** (app-of-apps, sync waves,
  self-managed) and **Helm**, with automated staging deploys, approval-gated
  production promotion, and **Argo Rollouts** canary releases with
  Prometheus-based automatic rollback.
- Set up observability with **Prometheus, Grafana, Loki and Alertmanager**:
  RED dashboards, a 99.5% SLO with multi-window burn-rate alerts routed to
  Discord, and runbooks for every alert.
- Hardened the platform with **Kyverno** policies, default-deny
  **NetworkPolicies**, non-root read-only containers and **cert-manager**
  TLS, all within a ₹0 cloud budget.

Only list what you can explain. Go through sections 3.1-3.10 first.

---

## 6. Two-week study plan (after it's deployed)

| Days | Do this |
|---|---|
| 1-2 | Break things on purpose: delete a pod, scale to 0, watch Argo CD heal it. Read 3.5 and 3.6. |
| 3-4 | Change the app (e.g. add a field), push, follow every Jenkins stage. Read 3.7. |
| 5 | Introduce a 500 error in booking-api, promote it, watch the canary roll back. Read 3.10. |
| 6-7 | Grafana: build one panel yourself; write a LogQL query; fire a test alert. Read 3.9. |
| 8-9 | `terraform plan` after changing the security list; read the Terraform and Ansible code line by line. Read 3.3 and 3.4. |
| 10 | `kubectl get policyreport -A`; switch one Kyverno policy to Enforce and test it. Read 3.8. |
| 11-12 | Explain the whole project out loud in 2 minutes, then in 10 minutes. |
| 13-14 | Mock interview using every "Interview questions" item above. |
