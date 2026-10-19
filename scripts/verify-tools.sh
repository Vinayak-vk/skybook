#!/usr/bin/env bash
#
# verify-tools.sh: print the version of every tool SkyBook needs and check that
# Docker works without sudo. Exits non-zero if anything is missing.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

failed=0

# check <label> <command...>: prints the first line of the command's output.
check() {
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    printf '  %-11s %s\n' "$label" "${out%%$'\n'*}"
  else
    printf '  %-11s \033[31mMISSING\033[0m\n' "$label"
    failed=1
  fi
}

echo "Tools:"
check git        git --version
check docker     docker --version
check compose    docker compose version
check buildx     docker buildx version
check terraform  terraform version
check kubectl    kubectl version --client
check helm       helm version --short
check trivy      trivy --version
check ansible    ansible --version
check oci        oci --version
check gh         gh --version
check jq         jq --version
check shellcheck bash -c "shellcheck --version | grep '^version'"

echo
echo "Docker daemon (no sudo):"
if docker run --rm hello-world >/dev/null 2>&1; then
  echo "  OK: containers run as $(id -un)"
else
  echo "  FAILED: run 'wsl --shutdown' in PowerShell, reopen Ubuntu and try again."
  failed=1
fi

exit "$failed"
