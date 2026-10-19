# infra/ansible

Turns the VM that Terraform created into the SkyBook cluster, then hands it to Argo CD.
It uses only `ansible.builtin` modules, so there are no collections to install.

## Before you run it

- `ansible-core` 2.17 or newer on Linux, macOS or WSL (Ansible doesn't run on Windows itself).
- `terraform apply` has written `inventory/hosts.ini` (see `inventory/hosts.ini.example`).
- `scripts/set-identity.sh` has replaced the domain and GitHub-user placeholders.
- `deploy/platform/argocd/values.yaml` and `deploy/argocd/root.yaml` exist in the repo.

## Run

```bash
cd infra/ansible
cp group_vars/all/vault.example.yml group_vars/all/vault.yml   # fill it in
ansible-vault encrypt group_vars/all/vault.yml                  # choose a vault password
ansible-playbook site.yml --ask-vault-pass
```

`vault.yml` is git-ignored. Change it with `ansible-vault edit group_vars/all/vault.yml` and
re-run the playbook to update the secrets in the cluster.

> **Running from `/mnt/c/...` in WSL?** Windows folders look world-writable in WSL, so Ansible
> ignores `ansible.cfg` there ("ignoring it as an ansible.cfg source"). Without it Ansible loses
> the inventory and SSH settings. Point to the file explicitly:
> `export ANSIBLE_CONFIG=$PWD/ansible.cfg` (or prefix the command with `ANSIBLE_CONFIG=ansible.cfg`).

The first run takes about 10 minutes. It ends by printing the URLs and the command that reads
the Argo CD admin password. Your kubeconfig is written to `~/.kube/skybook.yaml`:

```bash
export KUBECONFIG=~/.kube/skybook.yaml
kubectl get nodes
kubectl -n argocd get applications -w
```

## What the roles do

| Role | What it does |
|---|---|
| `common` | Waits for cloud-init, runs `apt dist-upgrade` + autoremove, installs curl/jq/fail2ban/unattended-upgrades and enables them, reboots if an upgrade needs it. Sets timezone UTC, caps the journal at 500 MB, raises the inotify limits. Adds an SSH drop-in (keys only, no root login, `MaxAuthTries 3`), validates it with `sshd -t`, and checks that it is really in effect. |
| `firewall` | Replaces Oracle's `/etc/iptables/rules.v4` (it REJECTs forwarded traffic and breaks pod networking) with accept-all rules, persisted with iptables-persistent. The OCI security list is the real firewall; k3s owns the host chains. The reload is atomic with ACCEPT policies, so SSH never drops. |
| `k3s` | Writes `/etc/rancher/k3s/config.yaml` (secrets encryption, TLS SANs for the public IP and domain), installs k3s at the pinned version, waits for the node to be Ready, and copies the kubeconfig to your machine (server = public IP, context `skybook`). |
| `duckdns` | Installs `/usr/local/bin/duckdns-update.sh` (root only; holds the token), runs it every 5 minutes from cron and once immediately. Logs: `journalctl -t duckdns`. |
| `platform` | Installs Helm (checksum-verified). Creates the namespaces and the bootstrap secrets (`jenkins-admin`, `jenkins-credentials`, `grafana-admin`, `alertmanager-discord`, `ghcr-pull`). Installs Argo CD once and applies the app-of-apps root. Everything else comes from git. |

Secrets go to `kubectl` on stdin with server-side apply, so they never show up in process
arguments, temp files, the `last-applied-configuration` annotation or Ansible's output (`no_log`).

## Re-running

Re-running is idempotent: on an unchanged system every task reports `ok`. Re-run the playbook
after you change the vault (secrets are updated), `group_vars`, or your public IP (Terraform
rewrites the inventory). To run a single role: `--tags platform` (also `common`, `firewall`,
`k3s`, `duckdns`).

Some things are deliberately done once:

- **Argo CD** is installed by Helm only if no release exists yet. After that the `argocd`
  Application in `deploy/argocd/apps/argocd.yaml` upgrades it from git. Keep
  `argocd_chart_version` in sync with it for fresh installs.
- **k3s** is installed only if `/usr/local/bin/k3s` is missing. To upgrade, set the new
  `k3s_version` in `group_vars/all/main.yml`, then run the installer on the VM:
  `sudo INSTALL_K3S_VERSION=<version> /usr/local/bin/k3s-install.sh`.
