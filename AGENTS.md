# AGENTS.md

Security and contribution rules for garuda-firezone.

## Security

- Never commit or use real public IP addresses. Use RFC5737 (TEST-NET) / RFC1918 / CGNAT ranges only.
- Never commit or use domains other than well-known examples or `example.net`.
- Never commit secrets, tokens, private keys, or customer data.

## FRR sidecar reuse — architectural rule

This module consumes the `frr-sidecar` library Helm chart from OCI
(`oci://ghcr.io/garuda-tunnel/charts/frr-sidecar`, published by the external repo
`garuda-tunnel/garuda-frr-sidecar`). The consumer chart `kube/charts/firezone/Chart.yaml`
declares it via `dependencies:` with `repository: "oci://ghcr.io/garuda-tunnel/charts"`
and a pinned `version`. The Terraform `helm_release` sets `dependency_update = true`
so Helm resolves the OCI dependency at apply time (unauthenticated for the public
ghcr package).

Anti-patterns (do NOT do this):
- Use `file://` form — it is OBSOLETE.
- Pin to a non-immutable tag (e.g. `latest`) — always pin to a specific semver version.
- Vendor the chart by copying it into consumer `charts/` directories.
- Inline copy of `frr-sidecar` container spec in consumer `deployment.yaml`.
- Local `<workload>.frrConf` helper duplicating `frr-sidecar.frrConf` rendering logic.

## Naming

This repo is `garuda-firezone`; its image is `ghcr.io/garuda-tunnel/garuda-firezone`;
its chart is `oci://ghcr.io/garuda-tunnel/charts/firezone`. The chart `version` in
`kube/charts/firezone/Chart.yaml` MUST equal the git tag.
