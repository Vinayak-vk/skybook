# Runbook: SkyBookErrorBudgetFastBurn / SlowBurn

**SLO:** 99.5% of requests to each service succeed (non-5xx) over 30 days. The
error budget is 0.5% of requests.

**Alerts** (multi-window, multi-burn-rate, as in the Google SRE workbook):

| Alert | Condition | Meaning |
|---|---|---|
| FastBurn | 1h and 5m error ratio > 14.4 x budget | About 2% of the monthly budget gone in an hour; budget exhausted in ~2 days |
| SlowBurn | 6h and 30m error ratio > 6 x budget | A steady leak; budget exhausted in ~5 days |

The short window makes the alert resolve quickly once the problem is fixed.
The long window stops brief spikes from paging anyone.

## Respond

- **FastBurn:** treat it like [high-error-rate](high-error-rate.md). Act now.
- **SlowBurn:** find the steady error source (a failing endpoint or a flaky
  dependency) during working hours:
  ```
  sum by (route, status) (rate(http_request_duration_seconds_count{namespace="skybook-prod", status=~"5.."}[6h]))
  ```
- **Budget exhausted:** pause feature releases and spend the time on
  reliability fixes until the budget recovers. That is the agreement an SLO
  stands for.
