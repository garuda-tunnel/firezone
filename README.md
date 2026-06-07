# garuda-firezone

Terraform module + Helm chart + image for the Firezone VPN server in the Garuda topology.

- Terraform module: `kube/` — consume via `git::https://github.com/garuda-tunnel/garuda-firezone.git//kube?ref=vX.Y.Z`.
- Helm chart: `oci://ghcr.io/garuda-tunnel/charts/firezone` (published on tag push).
- Image: `ghcr.io/garuda-tunnel/garuda-firezone` (semver + `:latest` + `:sha-...`).

See `kube/README.md` for module inputs/outputs and `AGENTS.md` for the FRR-sidecar reuse rule.
