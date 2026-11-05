# Operator runbook — Firezone MSS clamp

Firezone part of the garuda MTU / TCP-MSS defense-in-depth. The cross-cutting
rollout order and the other layers (WireGuard, ipt-server, border-router,
RouterOS) live in the
[garuda MTU/MSS runbook](https://github.com/garuda-tunnel/garuda/blob/main/docs/operations/operator-runbook-mtu-mss-clamping.md).
In that rollout firezone is the **last** step: it is the riskiest layer (adds a
`NET_ADMIN` sidecar and a readiness gate that blocks the pod until the clamp is
installed). Validate every earlier layer first.

## What the chart installs

The chart-owned `mss-clamp` sidecar (idempotent, readiness-gated, `NET_ADMIN`)
installs, in its own `table inet firezone_mss` (it never edits `table inet firezone`):

- `oifname wg-firezone` clamp-to-pmtu (WG MTU 1280 gives MSS 1240) — the
  load-bearing return clamp for Firezone clients; internet-to-client return
  traffic bypasses ipt-server and is clamped here.
- `iifname wg-firezone` fixed MSS 1240 — inbound-initiated flows; gated on
  `mtuPolicy.mssClampEnabled`.

## Verification

Run on the hub kubeconfig, after every deploy wave:

```bash
# Rules present; counters non-zero after some TCP traffic through the tunnel
kubectl -n garuda exec deploy/firezone -c mss-clamp -- nft list table inet firezone_mss

# Readiness gate: the ready flag exists and the firezone pod is Ready
kubectl -n garuda exec deploy/firezone -c mss-clamp -- test -f /var/lib/clamp/ready && echo READY-FLAG-OK
kubectl -n garuda get pod -l app.kubernetes.io/name=firezone -o wide
```

## Rollback

`--set mtuPolicy.mssClampEnabled=false` removes the `iifname` fixed-MSS rule;
the `oifname` route-PMTU clamp, the sidecar and the readiness gate stay (they
are always rendered). For a full revert, pin the module and chart back to the
pre-clamp version and apply.
