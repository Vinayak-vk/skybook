# Runbook: SkyBookServiceDown

**Alert:** Prometheus has not been able to scrape `flight-search` or
`booking-api` in an environment for 2 minutes.

**Impact:** Searches (flight-search) or bookings (booking-api) fail. In prod
this is a full outage of that feature.

## Diagnose

```bash
NS=skybook-prod   # or skybook-staging
kubectl -n $NS get pods -o wide
kubectl -n $NS describe pod -l app.kubernetes.io/name=booking-api
kubectl -n $NS logs -l app.kubernetes.io/name=booking-api --tail=100
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -20
```

What to look for:

| Symptom | Likely cause |
|---|---|
| `ImagePullBackOff` | Tag not pushed, or the `ghcr-pull` secret expired with the GitHub PAT |
| `CrashLoopBackOff`, DB errors in the logs | Postgres down; see [database-down](database-down.md) |
| `OOMKilled` | Memory limit too low for the load; check the Grafana memory panel |
| Pods `Pending` | Node out of memory or CPU: `kubectl describe node skybook` |

Logs are also in Grafana: **SkyBook - Service Overview**, Logs panel, or Explore
with `{namespace="skybook-prod", app="booking-api"}`.

## Mitigate

- **Bad release:** roll back by reverting the deploy commit, and Argo CD
  syncs the previous tags:
  ```bash
  git log --oneline -- deploy/envs/prod/values.yaml | head -3
  git revert <deploy-commit> && git push
  ```
- **Expired registry credentials:** update `vault_github_token`, then re-run
  `ansible-playbook site.yml --ask-vault-pass`.
- **Node pressure:** scale down staging temporarily:
  `kubectl -n argocd patch app skybook-staging --type merge -p '{"spec":{"syncPolicy":null}}'`
  then `kubectl -n skybook-staging scale deploy --all --replicas=0`.
