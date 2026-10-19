# Run SkyBook on your laptop

The whole platform (Argo CD, Jenkins, Prometheus, Grafana, Loki, Postgres,
Argo Rollouts and the app in staging and prod) runs on your laptop inside
WSL2, using **k3d**: the same k3s Kubernetes as the cloud, running in Docker.
No cloud account and no card are needed.

| | Laptop (this guide) | Cloud ([SETUP.md](SETUP.md)) |
|---|---|---|
| Kubernetes | k3d (k3s in Docker) | k3s on an Oracle VM |
| Who can open the links | only you, on this laptop | anyone |
| HTTPS certificate | self-signed (browser warns once) | Let's Encrypt (trusted) |
| How Jenkins sees pushes | checks GitHub every 2 minutes | GitHub webhook (instant) |
| Left out | cert-manager, Kyverno ([why](../deploy/argocd/root-local.yaml)) | nothing |

The trick that makes the same config work in both places: your DuckDNS name
points at `127.0.0.1` while you run locally, so `https://grafana.<your-domain>`
opens the Grafana on your own laptop. Later, Ansible points it at the cloud VM
instead.

---

## 1. Give WSL more memory (once)

The platform needs about 7 GB; by default WSL gets half of your RAM.
**PowerShell:**

```powershell
Set-Content -Path "$env:USERPROFILE\.wslconfig" -Value "[wsl2]`r`nmemory=7GB`r`nswap=6GB"
wsl --shutdown
```

Then open **Ubuntu 24.04 LTS** again. While SkyBook runs, close apps you don't
need; the laptop will be slower.

## 2. Make sure GitHub has your latest code

Argo CD installs from GitHub, not from your folder:

```bash
cd /mnt/c/Users/pkpav/devops/skybook
git add -A
git commit -m "chore: update"
git push
```

(If git says "nothing to commit", that's fine.)

## 3. Start everything

```bash
bash scripts/local.sh up
```

The first time, it asks for:

- your **GitHub token** (`ghp_...`)
- your **DuckDNS token**
- a **Discord webhook** (optional; press Enter to skip)

Nothing shows on screen while you paste; that's normal. It creates the
cluster, stores the secrets, installs Argo CD, and prints your URLs and
logins. Takes about 5-10 minutes.

## 4. Wait for Argo CD to install the rest (15-25 minutes)

```bash
bash scripts/local.sh status
```

Run it every few minutes. You are done when the apps show **Synced** and
**Healthy**, except `skybook-staging` and `skybook-prod`. Those stay
**Degraded** until the first pipeline run has built your images.

## 5. Open the dashboards

`bash scripts/local.sh status` prints the links and passwords. The browser
warns "Your connection is not private" the first time for each address.
Click **Advanced**, then **Proceed to ... (unsafe)**. It's safe: the
certificate is self-signed because Let's Encrypt can't reach a laptop.

## 6. Run the pipeline

1. Open Jenkins and log in as `admin` with the password from `status`.
2. Within about 2 minutes the **skybook** job finds your repo and builds
   `main`: tests, scans, images to GHCR, then staging.
3. When it's green, open `https://staging.<your-domain>`.
4. Ship to production: **skybook-promote**, then **Build Now**, then
   **Promote**. Watch the canary with
   `kubectl -n skybook-prod get rollouts -w`.

## Everyday use

| To | Run |
|---|---|
| See links, passwords, app health | `bash scripts/local.sh status` |
| Free the memory when you're done | `bash scripts/local.sh stop` |
| Start again later | `bash scripts/local.sh start` |
| Start over from scratch | `bash scripts/local.sh delete`, then `up` |

Keep one Ubuntu window open while you use SkyBook: when every Ubuntu window
is closed, Windows may shut WSL down, and the cluster with it.

## Troubleshooting

| Problem | Fix |
|---|---|
| Browser: "site can't be reached" | In PowerShell, run `Resolve-DnsName <your-domain>`. If it doesn't say `127.0.0.1`, your router blocks it; use the hosts-file fix below. |
| Pods stuck in `Pending` | Not enough memory: check step 1, close other apps, or `stop` and `start`. |
| `local.sh` says you have changes not on GitHub | Do step 2, then run `up` again. |
| GitHub token rejected | Make a new classic token with `repo` + `write:packages`; `up` asks for it again. |

**Hosts-file fix:** open Notepad **as administrator**, open
`C:\Windows\System32\drivers\etc\hosts`, add these lines (with your domain),
and save:

```
127.0.0.1 skybook-vinayak.duckdns.org
127.0.0.1 staging.skybook-vinayak.duckdns.org
127.0.0.1 argocd.skybook-vinayak.duckdns.org
127.0.0.1 jenkins.skybook-vinayak.duckdns.org
127.0.0.1 grafana.skybook-vinayak.duckdns.org
```

## Moving to the cloud later

Follow [SETUP.md](SETUP.md) from the Oracle Cloud part. Nothing in the repo
changes: Ansible points DuckDNS at the VM, Let's Encrypt issues real
certificates, and the links work for everyone.
