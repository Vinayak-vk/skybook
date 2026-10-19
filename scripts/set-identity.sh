#!/usr/bin/env bash
#
# set-identity.sh: replace the __GH_USER__ and __DOMAIN__ placeholders across
# the repo with your GitHub username and DuckDNS domain. Run it once, before
# your first commit.
#
#   bash scripts/set-identity.sh <github-username> <name>.duckdns.org
#
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <github-username> <name>.duckdns.org" >&2
  exit 1
fi

# Container image names on GHCR must be lowercase.
gh_user="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
domain="$(tr '[:upper:]' '[:lower:]' <<<"$2")"

if [[ ! "$gh_user" =~ ^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$ ]]; then
  echo "Not a valid GitHub username: $1" >&2
  exit 1
fi
if [[ ! "$domain" =~ ^[a-z0-9-]+\.duckdns\.org$ ]]; then
  echo "The domain should look like <name>.duckdns.org, got: $2" >&2
  exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

mapfile -t files < <(grep -rlE '__GH_USER__|__DOMAIN__' . \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.terraform \
  --exclude=set-identity.sh)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No placeholders left; nothing to do."
  exit 0
fi

sed -i -e "s/__GH_USER__/${gh_user}/g" -e "s/__DOMAIN__/${domain}/g" "${files[@]}"

printf 'Updated %d files:\n' "${#files[@]}"
printf '  %s\n' "${files[@]}"
echo
echo "GitHub user: ${gh_user}"
echo "Domain:      ${domain}  (also staging., argocd., jenkins., grafana.)"
