locals {
  effective_mtu = var.mtu_policy.site_mtu != null ? var.mtu_policy.site_mtu : var.mtu_policy.effective_mtu
  # policy_fixed_mss: base MSS from the policy before applying the Firezone inner cap.
  # In site mode: site_mtu - 40. In explicit mode: the caller-supplied fixed_mss.
  policy_fixed_mss  = var.mtu_policy.site_mtu != null ? var.mtu_policy.site_mtu - 40 : var.mtu_policy.fixed_mss
  # fixed_mss: cap policy_fixed_mss to firezone_client_mtu - 40. Firezone manages
  # wg-firezone at a fixed MTU (default 1280) that Garuda cannot change, so the
  # inbound MSS clamp must not exceed that interface's capacity.
  fixed_mss         = min(local.policy_fixed_mss, var.firezone_client_mtu - 40)
  # mss_clamp_enabled defaults to true via optional(bool, true) in the policy type.
  mss_clamp_enabled = var.mtu_policy.mss_clamp_enabled

  ospf_values = var.ospf == null ? null : {
    router_id          = var.ospf.router_id
    interfaces         = var.ospf.interfaces
    passive_interfaces = var.ospf.passive_interfaces
    default_originate  = var.ospf.default_originate
    redistribute       = var.ospf.redistribute
    transit_provider   = var.ospf.transit_provider
  }

  # External images (postgres, oidcReconcile) are always present so the chart
  # default can still be overridden by the module. First-party images (firezone,
  # frr) are conditionally omitted when empty so the chart's pinned digest wins.
  images_override = merge(
    {
      postgres      = var.postgres_image
      oidcReconcile = var.oidc_reconcile_image
    },
    var.firezone_image == "" ? {} : { firezone = var.firezone_image },
    var.frr_image == "" ? {} : { frr = var.frr_image },
  )

  firezone_secrets = {
    guardianSecretKey     = coalesce(try(var.encryption_secrets.guardianSecretKey, null), random_bytes.guardian_secret_key.base64)
    secretKeyBase         = coalesce(try(var.encryption_secrets.secretKeyBase, null), random_bytes.secret_key_base.base64)
    liveViewSigningSalt   = coalesce(try(var.encryption_secrets.liveViewSigningSalt, null), random_bytes.live_view_signing_salt.base64)
    cookieSigningSalt     = coalesce(try(var.encryption_secrets.cookieSigningSalt, null), random_bytes.cookie_signing_salt.base64)
    cookieEncryptionSalt  = coalesce(try(var.encryption_secrets.cookieEncryptionSalt, null), random_bytes.cookie_encryption_salt.base64)
    databaseEncryptionKey = coalesce(try(var.encryption_secrets.databaseEncryptionKey, null), random_bytes.database_encryption_key.base64)
    databasePassword      = coalesce(try(var.encryption_secrets.databasePassword, null), random_bytes.database_password.base64)
  }
}

resource "random_bytes" "guardian_secret_key" { length = 48 }
resource "random_bytes" "secret_key_base" { length = 48 }
resource "random_bytes" "live_view_signing_salt" { length = 24 }
resource "random_bytes" "cookie_signing_salt" { length = 6 }
resource "random_bytes" "cookie_encryption_salt" { length = 6 }
resource "random_bytes" "database_encryption_key" { length = 32 }
resource "random_bytes" "database_password" { length = 12 }

resource "helm_release" "firezone" {
  name             = var.name
  namespace        = var.namespace
  create_namespace = false
  # Consume the published chart from OCI by an exact pinned version.
  # Source stays in kube/charts/firezone for release-please / CI / local dev.
  repository = "oci://ghcr.io/garuda-tunnel/charts"
  chart      = "firezone"
  version    = var.chart_version

  # No-op for the OCI path (dependency is vendored in the published tgz);
  # kept so the local-path dev/hotfix escape hatch still resolves frr-sidecar.
  dependency_update = true

  values = [
    yamlencode({
      namespace               = var.namespace
      name                    = var.name
      firezoneDir             = var.firezone_dir
      serverFqdn              = var.server_fqdn
      clientSubnet            = var.client_subnet
      wireguardIpv4Address    = cidrhost(var.client_subnet, 1)
      wireguardIpv4Masquerade = var.wireguard_ipv4_masquerade
      wireguardIpv6Masquerade = var.wireguard_ipv6_masquerade
      wgListenPort            = var.wg_listen_port
      gatewayRef = {
        name      = var.gateway_ref.name
        namespace = var.gateway_ref.namespace
      }
      nicAttach = var.nic_attach
      labels    = var.labels
      images    = local.images_override
      oidc = {
        managed   = var.oidc_managed
        providers = var.oidc_providers
      }
      adminEmail    = var.admin_email
      adminPassword = var.admin_password
      secrets       = local.firezone_secrets
      ospf          = local.ospf_values
      transit = {
        interfaces = var.transit.interfaces
      }
      mtuPolicy = {
        fixedMss        = local.fixed_mss
        mssClampEnabled = local.mss_clamp_enabled
      }
    })
  ]
}
