#!/usr/bin/env bash
#
# local.sh: run the whole SkyBook platform on this laptop (WSL2 + Docker).
#
# k3d runs k3s (the same Kubernetes as the cloud node) inside Docker. After
# the bootstrap, Argo CD installs everything else from GitHub, exactly as in
# the cloud, minus the two apps listed in deploy/argocd/root-local.yaml.
#
#   bash scripts/local.sh up       create the cluster and bootstrap it (safe to re-run)
#   bash scripts/local.sh status   URLs, logins and the health of every Argo CD app
#   bash scripts/local.sh stop     stop the cluster to free memory (keeps all data)
#   bash scripts/local.sh start    start it again
#   bash scripts/local.sh delete   delete the cluster and all its data
#
# Secrets are asked for once and kept in ~/.skybook/secrets.env (outside the
# repo, readable only by you).
set -euo pipefail

CLUSTER="skybook"
K3D_VERSION="v5.9.0"
# Same k3s release as the cloud node (infra/ansible/group_vars/all/main.yml).
K3S_IMAGE="rancher/k3s:v1.36.5-k3s1"
# Keep equal to targetRevision in deploy/argocd/apps/argocd.yaml.
ARGOCD_CHART_VERSION="10.10.3"

SECRETS_FILE="$HOME/.skybook/secrets.env"
KUBECONFIG_FILE="$HOME/.kube/skybook.yaml"
export KUBECONFIG="$KUBECONFIG_FILE"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS_FILE="$ROOT/infra/ansible/group_vars/all/main.yml"
DOMAIN="$(awk -F'"' '/^domain:/ {print $2}' "$VARS_FILE")"
GH_USER="$(awk -F'"' '/^github_user:/ {print $2}' "$VARS_FILE" | tr '[:upper:]' '[:lower:]')"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Checks ---------------------------------------------------------------------

preflight() {
  [[ "$DOMAIN" == *.duckdns.org ]] || die "No domain set. Run scripts/set-identity.sh first."
  docker info >/dev/null 2>&1 || die "Docker is not running. Run 'wsl --shutdown' in PowerShell, reopen Ubuntu 24.04 and try again."

  local mem_gb
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if (( mem_gb < 7 )); then
    warn "Ubuntu only has ${mem_gb} GB of memory; SkyBook needs about 7 GB."
    warn "Give WSL more memory (see docs/LOCAL.md, step 1), or expect some pods to stay Pending."
  fi

  # Argo CD deploys from GitHub, not from this folder, so local changes must be pushed.
  git -C "$ROOT" fetch --quiet origin main 2>/dev/null || warn "Could not reach GitHub to compare with origin/main."
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]] \
     || [[ "$(git -C "$ROOT" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" != 0 ]]; then
    die "You have changes that are not on GitHub yet, and Argo CD deploys from GitHub. Run:
    git add -A && git commit -m \"chore: update\" && git push
then run this script again."
  fi
}

install_k3d() {
  if [[ "$(k3d version 2>/dev/null | awk '/^k3d version/ {print $3}')" == "$K3D_VERSION" ]]; then
    return
  fi
  log "Installing k3d ${K3D_VERSION}"
  local tmp base file="k3d-linux-amd64"
  tmp="$(mktemp -d)"
  base="https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}"
  curl -fsSLo "$tmp/$file" "$base/$file"
  local expected
  expected="$(curl -fsSL "$base/checksums.txt" | awk -v f="$file" '$2 ~ ("(^|/)" f "$") {print $1}')"
  [[ -n "$expected" ]] || die "No checksum published for $file; refusing to install it."
  echo "$expected  $tmp/$file" | sha256sum --check --quiet
  sudo install -m 0755 "$tmp/$file" /usr/local/bin/k3d
  rm -rf "$tmp"
  ok "k3d $(k3d version | awk '/^k3d version/ {print $3}')"
}

# --- Secrets -------------------------------------------------------------------------

# ask <VAR> <prompt> [optional]: reads a value without echoing it.
ask() {
  local var="$1" prompt="$2" optional="${3:-}" value=""
  while [[ -z "$value" ]]; do
    read -rsp "  $prompt: " value
    echo
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    [[ -n "$value" || -z "$optional" ]] || break
    [[ -n "$value" ]] || echo "  (this one is required)"
  done
  printf -v "$var" '%s' "$value"
}

load_secrets() {
  log "Secrets"
  mkdir -p "$(dirname "$SECRETS_FILE")"
  chmod 700 "$(dirname "$SECRETS_FILE")"
  # shellcheck disable=SC1090
  [[ -f "$SECRETS_FILE" ]] && source "$SECRETS_FILE"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "  Paste each value and press Enter. Nothing is shown while you paste; that's normal."
    ask GITHUB_TOKEN "GitHub token (starts with ghp_)"
  fi
  [[ -n "${DUCKDNS_TOKEN:-}" ]] || ask DUCKDNS_TOKEN "DuckDNS token"
  if [[ -z "${DISCORD_WEBHOOK_URL+set}" ]]; then
    ask DISCORD_WEBHOOK_URL "Discord webhook URL for alerts (optional, just press Enter to skip)" optional
  fi
  [[ -n "${JENKINS_ADMIN_PASSWORD:-}" ]] || JENKINS_ADMIN_PASSWORD="$(openssl rand -hex 10)"
  [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] || GRAFANA_ADMIN_PASSWORD="$(openssl rand -hex 10)"

  # Check the GitHub token before anything depends on it. The token goes to
  # curl on stdin, so it never shows up in the process list.
  local scopes
  scopes="$(curl -sS -D - -o /dev/null --config - <<<"header = \"Authorization: token ${GITHUB_TOKEN}\"
url = \"https://api.github.com/user\"" | tr -d '\r' | awk -F': ' 'tolower($1) == "x-oauth-scopes" {print $2}')"
  if [[ -z "$scopes" ]]; then
    # Forget the bad token so the next run asks for a new one.
    [[ -f "$SECRETS_FILE" ]] && sed -i '/^GITHUB_TOKEN=/d' "$SECRETS_FILE"
    die "GitHub did not accept that token (wrong or expired). Create a new classic token (docs/LOCAL.md) and run this again."
  fi
  [[ "$scopes" == *repo* && "$scopes" == *write:packages* ]] \
    || die "The GitHub token needs the 'repo' and 'write:packages' scopes (it has: $scopes)."
  ok "GitHub token works (scopes: $scopes)"

  ( umask 077
    {
      printf 'GITHUB_TOKEN=%q\n' "$GITHUB_TOKEN"
      printf 'DUCKDNS_TOKEN=%q\n' "$DUCKDNS_TOKEN"
      printf 'DISCORD_WEBHOOK_URL=%q\n' "$DISCORD_WEBHOOK_URL"
      printf 'JENKINS_ADMIN_PASSWORD=%q\n' "$JENKINS_ADMIN_PASSWORD"
      printf 'GRAFANA_ADMIN_PASSWORD=%q\n' "$GRAFANA_ADMIN_PASSWORD"
    } > "$SECRETS_FILE" )
  ok "Saved in $SECRETS_FILE"
}

# --- DNS -------------------------------------------------------------------------------

point_domain_here() {
  log "Pointing ${DOMAIN} (and *.${DOMAIN}) at this laptop (127.0.0.1)"
  local sub="${DOMAIN%.duckdns.org}" answer
  answer="$(curl -fsS --config - <<<"url = \"https://www.duckdns.org/update?domains=${sub}&token=${DUCKDNS_TOKEN}&ip=127.0.0.1\"")"
  [[ "$answer" == "OK" ]] || die "DuckDNS refused the update (answer: '$answer'). Check the DuckDNS token in $SECRETS_FILE."
  ok "DuckDNS updated (it can take a minute to apply)"
}

# --- Cluster -------------------------------------------------------------------------

cluster_exists() { k3d cluster list -o json | jq -e --arg c "$CLUSTER" 'any(.[]; .name == $c)' >/dev/null; }

create_cluster() {
  if cluster_exists; then
    log "Cluster '${CLUSTER}' already exists; starting it if needed"
    k3d cluster start "$CLUSTER" >/dev/null
  else
    log "Creating the k3d cluster '${CLUSTER}' (first time: a few minutes)"
    k3d cluster create "$CLUSTER" \
      --image "$K3S_IMAGE" \
      --servers 1 --agents 0 \
      --port "80:80@loadbalancer" \
      --port "443:443@loadbalancer" \
      --k3s-arg "--secrets-encryption@server:0" \
      --kubeconfig-update-default=false \
      --wait --timeout 300s
  fi
  mkdir -p "$(dirname "$KUBECONFIG_FILE")"
  ( umask 077; k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG_FILE" )
  kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
  ok "Kubernetes is up: $(kubectl get nodes --no-headers | awk '{print $1, $2, $5}')"
}

apply_quiet() { kubectl apply --server-side --force-conflicts --field-manager=skybook-local -f - >/dev/null; }

# secret <namespace> <name>: the secret's KEY=VALUE lines come on stdin.
secret() {
  kubectl -n "$1" create secret generic "$2" --from-env-file=/dev/stdin --dry-run=client -o yaml | apply_quiet
}

bootstrap() {
  log "Namespaces and secrets"
  for ns in argocd jenkins monitoring skybook-staging skybook-prod; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | apply_quiet
  done

  printf 'jenkins-admin-user=admin\njenkins-admin-password=%s\n' "$JENKINS_ADMIN_PASSWORD" | secret jenkins jenkins-admin
  printf 'github-username=%s\ngithub-token=%s\n' "$GH_USER" "$GITHUB_TOKEN" | secret jenkins jenkins-credentials
  printf 'admin-user=admin\nadmin-password=%s\n' "$GRAFANA_ADMIN_PASSWORD" | secret monitoring grafana-admin
  printf 'webhook-url=%s\n' "${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/0/disabled}" | secret monitoring alertmanager-discord

  local dockercfg
  dockercfg="$(GHU="$GH_USER" GHT="$GITHUB_TOKEN" jq -cn \
    '{auths: {"ghcr.io": {username: env.GHU, password: env.GHT, auth: ((env.GHU + ":" + env.GHT) | @base64)}}}')"
  for ns in skybook-staging skybook-prod; do
    printf '%s' "$dockercfg" | kubectl -n "$ns" create secret generic ghcr-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o yaml | apply_quiet
  done
  ok "Secrets created"

  if helm status argocd -n argocd >/dev/null 2>&1; then
    ok "Argo CD already installed (it upgrades itself from git from now on)"
  else
    log "Installing Argo CD ${ARGOCD_CHART_VERSION} (2-5 minutes)"
    helm upgrade --install argocd argo-cd \
      --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
      --namespace argocd -f "$ROOT/deploy/platform/argocd/values.yaml" \
      --wait --timeout 10m >/dev/null
    ok "Argo CD installed"
  fi

  log "Handing over to Argo CD (laptop profile)"
  kubectl apply -f "$ROOT/deploy/argocd/root-local.yaml" >/dev/null
  ok "Argo CD now installs everything else from GitHub (15-25 minutes)"
}

# --- Info --------------------------------------------------------------------------------

show_info() {
  # shellcheck disable=SC1090
  [[ -f "$SECRETS_FILE" ]] && source "$SECRETS_FILE"
  local argocd_pw
  argocd_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

  cat <<EOF

  Open these in Chrome or Edge. The first time, the browser warns about the
  certificate: click "Advanced" and then "Proceed" (see docs/LOCAL.md).

    Argo CD   https://argocd.${DOMAIN}     admin / ${argocd_pw:-<not ready yet>}
    Jenkins   https://jenkins.${DOMAIN}    admin / ${JENKINS_ADMIN_PASSWORD:-?}
    Grafana   https://grafana.${DOMAIN}    admin / ${GRAFANA_ADMIN_PASSWORD:-?}
    Staging   https://staging.${DOMAIN}
    Prod      https://${DOMAIN}

EOF
}

show_apps() {
  log "Argo CD applications (all should end up Synced + Healthy)"
  kubectl -n argocd get applications \
    -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null \
    || warn "Argo CD is not running yet."
}

# --- Main --------------------------------------------------------------------------------

case "${1:-}" in
  up)
    preflight
    install_k3d
    load_secrets
    point_domain_here
    create_cluster
    bootstrap
    show_info
    echo "  Watch progress with:  bash scripts/local.sh status"
    ;;
  status)
    show_info
    show_apps
    ;;
  stop)
    k3d cluster stop "$CLUSTER"
    ok "Stopped. Start it again with: bash scripts/local.sh start"
    ;;
  start)
    k3d cluster start "$CLUSTER"
    ( umask 077; k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG_FILE" )
    ok "Started. Pods take a few minutes to become ready: bash scripts/local.sh status"
    ;;
  delete)
    read -rp "Delete the local cluster and ALL its data? Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || { echo "Cancelled."; exit 0; }
    k3d cluster delete "$CLUSTER"
    ;;
  *)
    sed -n '3,15p' "$0"
    exit 1
    ;;
esac
