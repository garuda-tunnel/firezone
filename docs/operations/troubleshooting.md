# Firezone troubleshooting

| Symptom | First command |
|---|---|
| OIDC not reconciled / sidecar not Ready | `kubectl -n garuda logs <firezone-pod> -c oidc-reconcile` — expect "reconcile applied" → "minted token deleted" → "idling"; if the pod is not Ready, `/tmp/oidc-reconcile-ok` was not written |
| API or web UI not responding | `kubectl -n garuda logs <firezone-pod> -c firezone`; check the `fz_admin` credentials |
| Client cannot reach the hub through the tunnel | [Stale client handshake](operator-runbook-fz-client-handshake.md) |
| Traffic stalls on large transfers | [MSS clamp](operator-runbook-mss-clamp.md) |
