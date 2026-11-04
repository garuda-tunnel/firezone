# firezone/kube

## Image

`ghcr.io/garuda-tunnel/garuda-firezone` is **built from vendored source**, not
`FROM firezone/firezone`:

- Source: upstream `firezone/firezone` tag `0.7.36`, commit `dc71329`,
  vendored into `kube/image/src/` (details, allow-list and version table:
  `kube/image/src/UPSTREAM.md`). The `source-guard` CI job diffs it against
  upstream on every change.
- The four former `firezone/*` git dependencies come from public
  `garuda-tunnel` forks, pinned by tag: `openid_connect`, `esaml`, `samly`,
  `cidr-elixir` (see `mix.exs` / `apps/*/mix.exs`).
- Toolchain (erlang/elixir/nodejs) is pinned once in
  `kube/image/src/.tool-versions`; `kube/image/Dockerfile` base images match it
  (enforced by `source-guard.sh`). The wireguardex NIF is compiled from source
  in the builder (`WIREGUARDNIF_BUILD=1`), not downloaded precompiled.
- Accepted vulnerability exceptions: `kube/image/.trivyignore` and
  `kube/image/src/UPSTREAM.md`.

Rebuild locally:

```sh
docker build -t fz-local kube/image
kube/image/compat/check.sh fz-local
```

`kube/image/compat/check.sh <image-ref>` verifies the image against
upstream-0.7.36 fixtures (Cloak ciphertext, argon2 hash), the wireguardex NIF,
the chart's mss-clamp nftables ruleset, and the runtime (non-EOL Alpine).
`make-fixtures.sh` regenerates the fixtures from `firezone/firezone:0.7.36`.
The same checks run in CI (`image-compat` job) against every pushed dev image.

Deploys the Firezone application stack as one multi-container Kubernetes
Deployment with PostgreSQL data on a hostPath volume backed by the YC
data disk attached to the hub VM. The WireGuard server key is a required
input, shipped to the pod in the env Secret and mounted read-only as a
file.

Admin UI is exposed via a Gateway API `HTTPRoute` that attaches to the
parent `Gateway` supplied via `gateway_ref` (typically managed by the
`k8s_gateway_bootstrap` platform module). TLS termination is owned by the
gateway; this module does not create a cert-manager `Certificate`.

The Firezone-managed WireGuard endpoint is exposed as a `hostPort` on
UDP `var.wg_listen_port` (default 51620) on the hub node.

The `ospf` variable is accepted for backward compatibility but is ignored by
the chart (the FRR sidecar was removed in Phase 4+5 Decision #5; Garuda
now injects fabric-level routing via the annotation layer).

## Inputs

| Variable | Required | Description |
|---|---|---|
| `namespace` | yes | Existing namespace, typically `module.garuda_k8s_hub.namespace`. |
| `name` | no | Deployment name. Default `firezone`. |
| `firezone_dir` | yes | Absolute host path that backs the PostgreSQL data (`postgres-data`) via hostPath. Holds nothing else since 2.0.0. |
| `wireguard_private_key` | yes (sensitive) | WireGuard server private key from `wg genkey` (44-char base64 of a clamped 32-byte key, no trailing newline; `trimspace()` a `file()` read). Supply it from the caller's secret store (sops) or a key generated once. Losing it invalidates every issued client config. See [Migrating from 1.x](#migrating-from-1x). |
| `firezone_image` | no | Image reference for the firezone application container. Empty (default) uses the chart's pinned digest. |
| `postgres_image` | no | Default `postgres:15`. |
| `frr_image` | no | Inert (deprecated). Kept for back-compat; ignored by chart. See Phase 4+5 Decision #5. |
| `server_fqdn` | yes | External FQDN; both `EXTERNAL_URL` and IngressRoute Host match. |
| `admin_email` | yes | Initial admin email (`DEFAULT_ADMIN_EMAIL`). |
| `admin_password` | yes (sensitive) | Initial admin password (`DEFAULT_ADMIN_PASSWORD`). |
| `client_subnet` | yes | CIDR for WireGuard clients (`WIREGUARD_IPV4_NETWORK`). |
| `wg_listen_port` | no | UDP port firezone WireGuard listens on. Default `51620`. |
| `gateway_ref` | yes | Parent Gateway reference object (`{name, namespace}`) for the HTTPRoute. Supplied by the platform `k8s_gateway_bootstrap` module. |
| `nic_attach` | no | Default `["backbone", "border"]`. Becomes the Multus annotation. |
| `labels` | no | Extra metadata labels merged into pod/deployment labels. Also propagated to `podLabels` (vanilla-guest contract). |
| `annotations` | no | Pod-template annotations. From `garuda_guest.annotations`; propagated to `podAnnotations`. |
| `configmaps` | no | Extra ConfigMaps created before pod admission. From `garuda_guest.configmaps`. |
| `ospf` | no | Structured OSPF intent. Accepted for backward compatibility; ignored by the chart (FRR sidecar removed). |

### `ospf` object

| Field | Required | Description |
|---|---|---|
| `router_id` | yes | IPv4-formatted OSPF router-id. |
| `area` | no | Default `"0.0.0.0"`. |
| `interfaces` | yes | OSPF-participating interfaces. Typically `["wg-firezone"]`. |
| `passive_interfaces` | no | Marked `ip ospf passive`. |
| `default_originate` | no | Default `false`. |
| `redistribute` | no | Subset of `["connected", "kernel", "static"]`. |
| `extra_frr_conf` | no | Free-form FRR config appended verbatim. |

## Outputs

| Output | Description |
|---|---|
| `deployment_name` | Equals `var.name`. |
| `service_url` | `"https://${var.server_fqdn}"`. Consumed by the in-pod OIDC reconcile sidecar. |
| `wireguard_public_key` | Public key derived from `wireguard_private_key`; this is the server key that client configs embed. |

## Providers

Required providers: `helm`, `kubernetes`, `random` and `OJFord/wireguard`
(derives `wireguard_public_key`; needs no configuration, so it is not passed
via `providers = {}`).

```hcl
module "firezone_kube" {
  source = "git::https://github.com/garuda-tunnel/garuda-firezone.git//kube?ref=v0.2.0"

  providers = {
    helm       = helm.hub
    kubernetes = kubernetes.hub
  }

  namespace           = module.garuda_k8s_hub.namespace
  firezone_dir        = local.firezone_facts.directory
  firezone_image      = var.fz_firezone_image
  server_fqdn         = local.firezone_facts.server_name
  admin_email         = local.firezone_facts.default_admin_email
  admin_password      = local.firezone_facts.admin_password
  client_subnet       = local.firezone_facts.client_subnet

  wireguard_private_key = local.secrets.firezone_wireguard_private_key

  gateway_ref = {
    name      = module.k8s_gateway_bootstrap.gateway_name
    namespace = module.k8s_gateway_bootstrap.gateway_namespace
  }

  ospf = {
    router_id  = "198.51.100.22"
    interfaces = ["wg-firezone"]
  }
}
```

## Migrating from 1.x

In 1.x the server key lived in `<firezone_dir>/firezone-data/private_key`,
generated by Firezone on first start. From 2.0.0 the key is the required input
`wireguard_private_key`; the pod never generates one. Upgrading without
carrying the key over would rotate it and break every issued client config.

1. On the hub node: `sudo cat <firezone_dir>/firezone-data/private_key`.
2. Store the value in the stand's `secrets.sops.yaml`.
3. In one change, bump the module to 2.0.0 and pass the value as
   `wireguard_private_key` (1.x does not accept the input), then apply.
4. Confirm `wireguard_public_key` equals the server public key in an existing
   client config.

`firezone_dir` now holds only `postgres-data`; after a successful migration
the old `firezone-data` subdirectory can be removed.

Generating a fresh key instead invalidates every issued client config. For a
new install, generate one with `wg genkey`. Do not use `openssl rand -base64 32`:
an unclamped key makes Firezone advertise a wrong public key. Keys Firezone
generated in 1.x are already clamped, so the migration above is safe.

## What this module does NOT do

- It does not install cert-manager or manage TLS certificates. TLS is
  terminated at the parent Gateway (`gateway_ref`), typically managed by
  the `k8s_gateway_bootstrap` platform module.
- It does not run Caddy or any other ingress sidecar. Routing is handled
  entirely by the Gateway API `HTTPRoute` rendered by this chart.
- It does not run smtp4dev or autoheal. SMTP fan-out is not part of the
  k8s topology; pod liveness is owned by kubelet readiness/liveness
  probes.
- OIDC provider configuration is applied by the in-pod reconcile sidecar
  (`oidc_reconcile`) bundled in this module's Helm chart.
