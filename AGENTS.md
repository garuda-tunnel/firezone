# AGENTS.md

Security and contribution rules for garuda-firezone.

## Security

- Never commit or use real public IP addresses. Use RFC5737 (TEST-NET) / RFC1918 / CGNAT ranges only.
- Never commit or use domains other than well-known examples or `example.net`.
- Never commit secrets, tokens, private keys, or customer data.

## Garuda platform rules

This repo is part of garuda-tunnel. Platform rules (annotation-layer design, MAP/VAP
injection engine, `garuda_guest` contract, vanilla guest contract, bootstrap timing,
Multus attach-race fix, anti-patterns):

**See: https://github.com/garuda-tunnel/garuda/blob/main/docs/AGENTS-platform.md**
Local path: `../garuda/docs/AGENTS-platform.md`

## Naming

This repo is `garuda-firezone`; its image is `ghcr.io/garuda-tunnel/garuda-firezone`;
its chart is `oci://ghcr.io/garuda-tunnel/charts/firezone`. The chart `version` in
`kube/charts/firezone/Chart.yaml` MUST equal the git tag.

## Firezone-specific notes

- PostgreSQL is a hard dependency. The chart always deploys postgres:15 as a subchart.
  The `oidcReconcile` literal in `values.yaml` must not be templated or made optional —
  it is a Firezone API invariant.
- `NET_ADMIN` and `SYS_MODULE` capabilities are app-intrinsic (Firezone loads the
  WireGuard kernel module). These stay in the guest chart's own `securityContext` and are
  NOT injected by garuda's MAP.
- The dedicated `mss-clamp` sidecar and `nft table firezone_mss` are workload-native MSS
  enforcement — stay in this chart, not injected by garuda.
- This module is a **vanilla guest**: accepts `annotations`, `labels`, `configmaps` map
  inputs and has zero garuda knowledge. See platform rules for the full contract.
