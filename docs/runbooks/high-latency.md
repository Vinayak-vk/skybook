# Runbook: SkyBookHighLatency

**Alert:** A service's 95th-percentile latency has been above 500 ms for 10
minutes.

**Impact:** Slow pages. Not an outage, but it often comes before one.

## Diagnose

- **CPU throttling or saturation:** Grafana's CPU-by-pod panel, and
  `kubectl top pods -n skybook-prod`, `kubectl top node`.
- **Autoscaling:** `kubectl -n skybook-prod get hpa`. Is it already at
  `maxReplicas`?
- **Database:** slow queries or connection limits. Postgres metrics come from
  the `skybook-db` PodMonitor (`cnpg_*` series in Explore).
- **Noisy neighbour:** a Jenkins build running on the same node uses a lot of
  CPU, so latency during builds is expected on a single node.

## Mitigate

- Raise `maxReplicas` or the CPU request in `deploy/envs/prod/values.yaml`,
  then commit and push.
- If it started with a release, roll back as in
  [high-error-rate](high-error-rate.md).
