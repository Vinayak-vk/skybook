# Setup guide: from a Windows laptop to a live HTTPS URL

Total: about 2-3 hours of hands-on work, plus waiting for installs. Every
step is free. Commands marked **PowerShell** run in Windows; everything else
runs in Ubuntu (WSL).

| Step | What you get |
|---|---|
| 1. Dev machine | Ubuntu on WSL2 with Docker, Terraform, Ansible, kubectl, Helm, Trivy, OCI CLI |
| 2. Accounts | GitHub token, DuckDNS domain, Oracle Cloud API key, (optional) Discord webhook |
| 3. Repo | Placeholders replaced, pushed to your public GitHub repo |
| 4. Terraform | The Oracle Cloud VM and its network |
| 5. Ansible | Hardened VM running k3s, with Argo CD installing the rest |
| 6. Pipeline | First build, staging deploy, production promotion |

---

## 1. Dev machine (WSL2)

**PowerShell:**

```powershell
wsl --install -d Ubuntu-24.04
```

Pick a Linux username and password when asked. Then, in the Ubuntu window:

```bash
cd /mnt/c/Users/<your-windows-user>/devops/skybook
bash scripts/bootstrap-wsl.sh
```

When it finishes, restart WSL (**PowerShell:** `wsl --shutdown`), reopen
Ubuntu, and check:

```bash
cd /mnt/c/Users/<your-windows-user>/devops/skybook
bash scripts/verify-tools.sh
```

Optional: test the app locally with `docker compose up --build`, then open
http://localhost:8080.

## 2. Accounts and tokens

### GitHub

```bash
ssh-keygen -t ed25519 -C "<your email>"          # press Enter for the defaults
gh auth login                                     # GitHub.com > SSH > upload the key > browser
git config --global user.name  "<Your Name>"
git config --global user.email "<id>+<username>@users.noreply.github.com"   # Settings > Emails
```

Create a **classic** personal access token for Jenkins: GitHub > Settings >
Developer settings > Personal access tokens > Tokens (classic). Scopes:
`repo` and `write:packages`. Expiry: 90 days. Fine-grained tokens cannot push
to GHCR, so this one has to be classic. Keep it for step 5.

### DuckDNS

Sign in at https://www.duckdns.org with GitHub, add a sub-domain (for example
`skybook-yourname`) and copy your **token**. Your domain is
`skybook-yourname.duckdns.org`. Any IP is fine for now; Ansible keeps it
pointed at the VM.

### Discord (optional, for alerts)

In any Discord server: Server settings > Integrations > Webhooks > New
webhook > Copy webhook URL.

### Oracle Cloud

1. Sign up at https://signup.cloud.oracle.com. A card is needed for
   verification; a small temporary hold may appear and is reversed.
   - **Home region:** the closest one (in India: Mumbai or Hyderabad). It
     cannot be changed later.
   - Stay on Free Tier. **Do not** upgrade to Pay As You Go.
2. Create an API key for the CLI and Terraform:
   ```bash
   oci setup config
   ```
   - User OCID: Console > profile icon > My profile.
   - Tenancy OCID: profile icon > Tenancy.
   - Region: e.g. `ap-hyderabad-1`.
   - Generate a new key pair: `Y`.

   Then upload the public key: Console > My profile > API keys > Add API key
   > Paste a public key, and paste the contents of
   `~/.oci/oci_api_key_public.pem`. Test it:
   ```bash
   oci iam region list --output table
   ```
3. Create the bucket for Terraform state:
   ```bash
   oci os ns get                                    # prints your namespace
   oci os bucket create --name skybook-tfstate \
     --compartment-id <tenancy-ocid> --versioning Enabled
   ```

## 3. Personalise the repo and push it

```bash
cd /mnt/c/Users/<your-windows-user>/devops/skybook
bash scripts/set-identity.sh <github-username> <name>.duckdns.org

git init
git config core.fileMode false
git add .
git add --chmod=+x scripts/*.sh ci/scripts/*.sh
git commit -m "feat: SkyBook platform"
gh repo create skybook --public --source . --remote origin --push
```

The repo must be **public**: Argo CD reads it without credentials, and
recruiters can browse it.

## 4. Infrastructure (Terraform)

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars    # fill it in
cp backend.hcl.example backend.hcl              # fill in your namespace and region
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

This creates the network, the VM, a budget alert, and
`infra/ansible/inventory/hosts.ini`. For `admin_cidr`, use your public IP:
`curl -s https://ifconfig.me` and append `/32`.

> **"Out of host capacity"?** Free Arm capacity in your region is temporarily
> used up. Run `terraform apply` again later; early morning often works.

## 5. Cluster (Ansible)

```bash
cd ../ansible
cp group_vars/all/vault.example.yml group_vars/all/vault.yml   # fill it in
ansible-vault encrypt group_vars/all/vault.yml                  # choose a vault password
export ANSIBLE_CONFIG=ansible.cfg   # Ansible ignores it under /mnt/c otherwise
ansible-playbook site.yml --ask-vault-pass
```

It takes about 10 minutes. It hardens the OS, installs k3s, points DuckDNS
at the VM, creates the secrets, installs Argo CD and hands everything else to
it. Then:

```bash
export KUBECONFIG=~/.kube/skybook.yaml
kubectl get nodes
kubectl -n argocd get applications -w      # wait for Synced / Healthy, ~15-20 min
```

Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

> Until the first pipeline run, `skybook-staging` and `skybook-prod` show
> `ImagePullBackOff`: their tags are still `bootstrap` and no images exist
> yet. That is expected.

## 6. First pipeline run

1. Open `https://jenkins.<domain>` and sign in as `admin` with the password
   from your vault. The `skybook` job scans the repo and builds `main`.
2. Add a GitHub webhook so pushes trigger builds right away: repo > Settings >
   Webhooks > Add webhook.
   - Payload URL: `https://jenkins.<domain>/github-webhook/`
   - Content type: `application/json`
   - Events: **Pushes** and **Pull requests**

   Optional: a second webhook to `https://argocd.<domain>/api/webhook` (push
   events) makes Argo CD sync instantly instead of within about 2 minutes.
3. Watch the build: tests, scans, images, the staging commit, then the
   staging check. Open `https://staging.<domain>`.
4. Ship to production: Jenkins > **skybook-promote** > Build Now > approve.
   Watch the canary:
   ```bash
   kubectl -n skybook-prod get rollouts -w
   ```
   Then open `https://<domain>`. That is the link for your resume.

## 7. Check the rest

- **Grafana** (`https://grafana.<domain>`): the "SkyBook - Service Overview"
  dashboard is public and read-only. Sign in as admin to edit.
- **Alerts:** send a test alert to Discord:
  ```bash
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093 &
  curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
    -d '[{"labels":{"alertname":"SkyBookTestAlert","severity":"warning"},"annotations":{"summary":"Test alert from SkyBook"}}]'
  ```
- **Policies:** `kubectl get policyreport -A` lists Kyverno audit findings.

## Troubleshooting

| Problem | Check |
|---|---|
| Certificates stay `False` | `kubectl get certificate,challenge -A`. Does `dig +short <domain>` show the VM's IP? Are ports 80/443 open? |
| SSH or kubectl stopped working | Your home IP changed. Update `admin_cidr` in `terraform.tfvars` and run `terraform apply`. |
| Jenkins takes long to start | The first start downloads plugins: `kubectl -n jenkins logs jenkins-0 -c init -f` |
| An Argo CD app is `Degraded` | Open it in the Argo CD UI; the failing resource and its events are shown there. |
| Build fails at "Source scan" or the image scan | A real CRITICAL CVE: bump the dependency or base image named in the log. |
| Pods `Pending` | The node is full: `kubectl describe node skybook`, then lower requests or scale staging down. |

## Costs and teardown

Everything stays inside Oracle's Always Free limits. The Terraform budget
alert emails you if any spend at all appears. To remove everything:

```bash
cd infra/terraform && terraform destroy
```

The state bucket is kept; delete it in the Console if you want.
