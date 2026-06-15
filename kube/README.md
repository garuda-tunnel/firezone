# firezone/kube

Deploys the Firezone application stack as one multi-container Kubernetes
Deployment with persistent state on a hostPath volume backed by the YC
data disk attached to the hub VM.

Admin UI is exposed via a Gateway API `HTTPRoute` that attaches to the
parent `Gateway` supplied via `gateway_ref` (typically managed by the
`k8s_gateway_bootstrap` platform module). TLS termination is owned by the
gateway; this module does not create a cert-manager `Certificate`.

The Firezone-managed WireGuard endpoint is exposed as a `hostPort` on
UDP `var.wg_listen_port` (default 51620) on the hub node.

When `ospf` is set, an FRR sidecar runs in the same pod's network
namespace and speaks OSPF on the interfaces declared in `ospf.interfaces`
(typically `wg-firezone`, the kernel interface the Firezone server
creates inside the pod netns).

## Inputs

| Variable | Required | Description |
|---|---|---|
| `namespace` | yes | Existing namespace, typically `module.garuda_k8s_hub.namespace`. |
| `name` | no | Deployment name. Default `firezone`. |
| `firezone_dir` | yes | Absolute host path that backs Firezone runtime state via hostPath. |
| `firezone_image` | no | Image reference for the firezone application container. Empty (default) uses the chart's pinned digest. |
| `postgres_image` | no | Default `postgres:15`. |
| `frr_image` | when `ospf != null` | Image for the optional frr-sidecar. |
| `server_fqdn` | yes | External FQDN; both `EXTERNAL_URL` and IngressRoute Host match. |
| `admin_email` | yes | Initial admin email (`DEFAULT_ADMIN_EMAIL`). |
| `admin_password` | yes (sensitive) | Initial admin password (`DEFAULT_ADMIN_PASSWORD`). |
| `client_subnet` | yes | CIDR for WireGuard clients (`WIREGUARD_IPV4_NETWORK`). |
| `wg_listen_port` | no | UDP port firezone WireGuard listens on. Default `51620`. |
| `gateway_ref` | yes | Parent Gateway reference object (`{name, namespace}`) for the HTTPRoute. Supplied by the platform `k8s_gateway_bootstrap` module. |
| `nic_attach` | no | Default `["backbone", "border"]`. Becomes the Multus annotation. |
| `labels` | no | Extra metadata labels merged into pod/deployment labels. |
| `ospf` | no | Structured OSPF intent. When `null`, no FRR sidecar is rendered. |

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

## Providers

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
