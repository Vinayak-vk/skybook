# Runbook: SkyBookDatabaseDown

**Alert:** The CloudNativePG instance `skybook-db` has not been scrapeable
for 2 minutes.

**Impact:** booking-api's readiness probe fails, so new bookings and lookups
fail. Flight search keeps working.

## Diagnose

```bash
NS=skybook-prod
kubectl -n $NS get cluster skybook-db          # CNPG's view: phase, ready instances
kubectl -n $NS get pods -l cnpg.io/cluster=skybook-db
kubectl -n $NS logs skybook-db-1 --tail=100
kubectl -n $NS get pvc
df -h /var/lib/rancher                         # on the VM: is the disk full?
```

## Mitigate

- **Pod crash-looping on a full volume:** expand the PVC in the chart values
  (`database.storage`) and push. local-path volumes live on the boot disk, so
  check free space first.
- **Operator issue:** `kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg`.
- **Data loss:** this demo runs one instance with no backups (see ADR 0001).
  The next step is CNPG's Barman backups to OCI Object Storage, which is S3
  compatible and has 20 GB free.
