#!/bin/sh
# Commits the edited deploy/envs values files and pushes them to main. Argo CD
# notices the new commit and syncs the cluster; that is the whole deploy.
#
#   gitops-commit.sh "<commit message>"     (expects GH_USER and GH_TOKEN)
#
# Retries with a rebase if main moved since the build checked it out.
set -eu
message="$1"

if git diff --quiet -- deploy/envs; then
  echo "Nothing to deploy: the tags are already up to date."
  exit 0
fi

git config user.name "SkyBook CI"
git config user.email "ci@skybook.invalid"
# The token reaches git through a credential helper at run time; it is never
# written into the remote URL or the repo config.
# Single quotes on purpose: the helper expands the variables when git runs it.
# shellcheck disable=SC2016
git config credential.helper '!f() { echo "username=${GH_USER}"; echo "password=${GH_TOKEN}"; }; f'

# [skip ci] stops this commit from re-running the whole pipeline.
git commit --quiet -m "${message} [skip ci]" -- deploy/envs

attempt=1
while [ "$attempt" -le 3 ]; do
  if git push --quiet origin HEAD:main; then
    echo "Pushed: ${message}"
    exit 0
  fi
  echo "Push rejected (attempt ${attempt}/3); rebasing onto the latest main."
  git pull --quiet --rebase origin main
  attempt=$((attempt + 1))
done

echo "Could not push after 3 attempts." >&2
exit 1
