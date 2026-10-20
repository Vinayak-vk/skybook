#!/usr/bin/env bash
#
# bootstrap-wsl.sh: install the SkyBook toolchain on Ubuntu 24.04 (WSL2).
#
#   bash scripts/bootstrap-wsl.sh
#
# Safe to re-run. apt-managed tools come from their vendors' signed repos;
# binary tools are pinned and checksum-verified, and reinstalled only when the
# installed version differs from the pin.
set -euo pipefail

# --- Pinned versions ----------------------------------------------------------
# Bump these on purpose, never by pulling "latest" (see the Trivy note).
KUBECTL_VERSION="v1.37.1"
HELM_VERSION="v4.3.1"
# Trivy 0.69.4-0.69.6 were malicious builds (CVE-2026-33634, March 2026).
TRIVY_VERSION="0.75.0"

ARCH="$(dpkg --print-architecture)"
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

# sha256_check <expected-hash> <file>
sha256_check() {
  if [[ -z "$1" ]]; then
    echo "No checksum found for $2; refusing to install it." >&2
    return 1
  fi
  echo "$1  $2" | sha256sum --check --quiet
}

# --- Preflight ------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root. It calls sudo when it needs to." >&2
  exit 1
fi
grep -qi microsoft /proc/version || warn "This does not look like WSL. Continuing anyway."
sudo -v

# --- Base packages ----------------------------------------------------------------
log "Base packages"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg git jq make unzip pipx python3-venv shellcheck bash-completion

# --- Vendor apt repositories (signed) --------------------------------------------
log "Adding apt repositories: Docker, HashiCorp, GitHub CLI"
sudo install -m 0755 -d /etc/apt/keyrings

sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/hashicorp.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

sudo chmod a+r /etc/apt/keyrings/*

log "Docker Engine, Terraform, GitHub CLI"
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin terraform gh

# --- Docker service ----------------------------------------------------------------
log "Docker: group membership and service"
sudo usermod -aG docker "$USER"
if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
  sudo systemctl enable --now docker
else
  if ! grep -qs '^systemd=true' /etc/wsl.conf; then
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  warn "systemd was off; enabled it in /etc/wsl.conf. Docker starts after 'wsl --shutdown'."
fi

# A k3d cluster runs dozens of file watchers (config reloaders, sidecars, the
# k3d load balancer). Ubuntu's default of 128 inotify instances runs out, and
# then the load balancer crash-loops with "too many open files".
printf 'fs.inotify.max_user_instances = 1024\nfs.inotify.max_user_watches = 524288\n' \
  | sudo tee /etc/sysctl.d/99-skybook.conf >/dev/null
sudo sysctl --quiet --system

# --- Pinned binaries -----------------------------------------------------------------
log "kubectl ${KUBECTL_VERSION}"
if [[ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "$KUBECTL_VERSION" ]]; then
  url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  curl -fsSLo "$TMP/kubectl" "$url"
  sha256_check "$(curl -fsSL "${url}.sha256")" "$TMP/kubectl"
  sudo install -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl
fi

log "Helm ${HELM_VERSION}"
if [[ "$(helm version --template '{{.Version}}' 2>/dev/null)" != "$HELM_VERSION" ]]; then
  file="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSLo "$TMP/$file" "https://get.helm.sh/${file}"
  sha256_check "$(curl -fsSL "https://get.helm.sh/${file}.sha256sum" | awk '{print $1}')" "$TMP/$file"
  tar -xzf "$TMP/$file" -C "$TMP"
  sudo install -m 0755 "$TMP/linux-${ARCH}/helm" /usr/local/bin/helm
fi

log "Trivy ${TRIVY_VERSION}"
if [[ "$(trivy --version 2>/dev/null | awk '/^Version:/ {print $2}')" != "$TRIVY_VERSION" ]]; then
  case "$ARCH" in
    amd64) trivy_arch="Linux-64bit" ;;
    arm64) trivy_arch="Linux-ARM64" ;;
    *) echo "Unsupported architecture for Trivy: $ARCH" >&2; exit 1 ;;
  esac
  base="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
  file="trivy_${TRIVY_VERSION}_${trivy_arch}.tar.gz"
  curl -fsSLo "$TMP/$file" "$base/$file"
  sha256_check "$(curl -fsSL "$base/trivy_${TRIVY_VERSION}_checksums.txt" | awk -v f="$file" '$2 == f {print $1}')" "$TMP/$file"
  tar -xzf "$TMP/$file" -C "$TMP" trivy
  sudo install -m 0755 "$TMP/trivy" /usr/local/bin/trivy
fi

# --- Python CLIs, isolated per tool by pipx ---------------------------------------------
log "Ansible and OCI CLI"
pipx ensurepath >/dev/null
export PATH="$HOME/.local/bin:$PATH"
command -v ansible-playbook >/dev/null || pipx install --include-deps ansible
command -v oci >/dev/null || pipx install oci-cli

# --- Shell niceties ------------------------------------------------------------------------
log "kubectl/helm completion and the 'k' alias"
if ! grep -q '# >>> skybook >>>' ~/.bashrc; then
  cat >> ~/.bashrc <<'EOF'
# >>> skybook >>>
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/skybook.yaml"
source <(kubectl completion bash)
source <(helm completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# <<< skybook <<<
EOF
fi

git config --global init.defaultBranch main
git config --global core.autocrlf input

log "Done"
cat <<'EOF'
Next:
  1. In PowerShell run:   wsl --shutdown
  2. Reopen Ubuntu, then: bash scripts/verify-tools.sh
EOF
