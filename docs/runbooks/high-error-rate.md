# Runbook: SkyBookHighErrorRate

**Alert:** More than 5% of a service's requests returned 5xx for 5 minutes.

**Impact:** Users see failed searches or bookings.

## Diagnose

1. Open Grafana, **SkyBook - Service Overview**, pick the environment. Did
   the error ratio jump at a specific time?
2. Did it coincide with a deploy?
   ```bash
   git log --since="2 hours ago" --oneline -- deploy/envs/
   kubectl -n skybook-prod get rollouts
   ```
3. Read the errors (Grafana Explore, Loki):
   ```
   {namespace="skybook-prod", app="booking-api"} |= "error"
   ```
4. booking-api returns 503 when flight-search is unreachable. Check whether
   the root cause is upstream: look at `skybook_upstream_errors_total` in Explore.

## Mitigate

- **Right after a prod release:** the canary analysis should have caught it.
  If the release had already completed, roll back:
  ```bash
  git revert <deploy(prod) commit> && git push
  ```
  To stop a canary that is still in progress:
  `kubectl -n skybook-prod patch rollout booking-api --subresource=status --type merge -p '{"status":{"abort":true}}'`
  (or `kubectl argo rollouts abort booking-api -n skybook-prod` with the plugin).
- **Database errors:** see [database-down](database-down.md).
- **Afterwards:** write a short postmortem (what happened, impact, detection
  time, fix, follow-ups) in `docs/postmortems/`.
