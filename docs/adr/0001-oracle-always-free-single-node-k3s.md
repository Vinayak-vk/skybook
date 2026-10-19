# ADR 0001: Run production on one Oracle Cloud Always Free VM with k3s

- Status: accepted
- Date: 2026-10-19

## Context

SkyBook has to run publicly, 24/7, on a budget of zero. Constraints:

- **Laptop:** 11.7 GB RAM and 4 cores, and not reachable from the internet.
- **AWS:** the free plan for accounts created after July 2025 is credit-based
  and expires after six months, and an EKS control plane is never free.
- **Oracle Cloud Always Free:** halved its Ampere A1 allowance in June 2026, to
  2 OCPUs and 12 GB RAM in total. It has no time limit and includes 200 GB of
  block storage, one flexible load balancer and 10 TB of egress a month.

## Decision

- One `VM.Standard.A1.Flex` instance (2 OCPU, 12 GB, Ubuntu 24.04 arm64,
  100 GB boot volume), created with Terraform.
- **k3s** as a single-node Kubernetes. It is a CNCF-certified distribution
  with a much smaller footprint than kubeadm (one process, SQLite instead of
  etcd), and it bundles Traefik, CoreDNS, metrics-server, a local-path
  provisioner and a NetworkPolicy controller.
- **No OCI load balancer.** Traefik binds 80/443 on the node through k3s's
  ServiceLB. The free flexible LB only stays free with one exact shape
  (10 Mbps), so a stray `Service type: LoadBalancer` could create a paid one.
- **DuckDNS** for a free domain. Every `*.<name>.duckdns.org` resolves to the
  VM, so one name covers the app, staging, Argo CD, Jenkins and Grafana.
- **Environments:** `dev` is Docker Compose on the laptop. `staging` and
  `prod` are namespaces on the cluster.
- **Images are built natively for arm64** on the node itself, so builds need
  no QEMU emulation.

### Memory budget (requests and limits are set on every component)

| Component | Approx. working set |
|---|---|
| OS + k3s (Traefik, CoreDNS, metrics-server) | 1.0 GB |
| Argo CD + Argo Rollouts | 0.8 GB |
| Jenkins controller + one build pod while building | 2.5 GB |
| Prometheus, Grafana, Alertmanager, exporters | 2.0 GB |
| Loki + Alloy | 0.5 GB |
| cert-manager, CloudNativePG, Kyverno | 0.8 GB |
| SkyBook staging + prod (services and Postgres) | 1.5 GB |
| **Headroom** | **~3 GB** |

## Consequences

- **No high availability.** A node failure is a full outage. We accept that
  for a demo and keep recovery automated instead: `terraform apply` +
  `ansible-playbook site.yml` rebuild everything from git.
- **Capacity:** A1 capacity is sometimes exhausted in a region ("Out of host
  capacity"); retrying later works.
- **Reclamation:** Oracle reclaims Always Free VMs that sit below 20% CPU,
  network and memory for 7 days. A running cluster stays above the memory
  threshold.
- **Everything is arm64.** Every image we run must be multi-arch, which all
  of the chosen upstream images are.
- **Upgrade path:** on a paid account the same Terraform and Ansible would add
  worker nodes. Switching to OKE or EKS would replace only the
  infrastructure layer; everything from Argo CD upwards stays the same.
