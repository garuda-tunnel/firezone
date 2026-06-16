mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  namespace           = "garuda"
  name                = "firezone"
  firezone_dir        = "/opt/garuda/firezone"
  firezone_image      = "ghcr.io/alexmkx/garuda-firezone:latest"
  server_fqdn         = "hub.example.net"
  admin_email         = "admin@example.net"
  admin_password      = "fixture-password"
  client_subnet       = "198.51.100.128/25"
  gateway_ref = {
    name      = "platform-gateway"
    namespace = "gateway-system"
  }
  encryption_secrets = {
    guardianSecretKey     = "fixture-guardian"
    secretKeyBase         = "fixture-secret-key-base"
    liveViewSigningSalt   = "fixture-live-view"
    cookieSigningSalt     = "fixture-sign"
    cookieEncryptionSalt  = "fixture-encrypt"
    databaseEncryptionKey = "fixture-database-encryption"
    databasePassword      = "fixture-database-password"
  }
}

run "chart_resolves_from_oci" {
  command = plan

  assert {
    condition     = helm_release.firezone.repository == "oci://ghcr.io/garuda-tunnel/charts"
    error_message = "helm_release.repository must be the garuda OCI charts registry"
  }
  assert {
    condition     = helm_release.firezone.chart == "firezone"
    error_message = "helm_release.chart must be the OCI chart name 'firezone'"
  }
  assert {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", helm_release.firezone.version))
    error_message = "helm_release.version must be an exact semver from var.chart_version"
  }
}

# OpenTofu's yamlencode emits quoted block-style YAML ("key": "value"),
# so substrings below match that form. See modules/garuda_k8s/tests for
# the precedent.
run "values_include_firezone_dir_and_server_fqdn" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"firezoneDir\": \"/opt/garuda/firezone\"")
    error_message = "rendered values must include firezoneDir"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"serverFqdn\": \"hub.example.net\"")
    error_message = "rendered values must include serverFqdn"
  }
}

run "gateway_ref_propagates" {
  command = plan

  assert {
    condition = (
      strcontains(helm_release.firezone.values[0], "\"gatewayRef\":") &&
      strcontains(helm_release.firezone.values[0], "\"name\": \"platform-gateway\"") &&
      strcontains(helm_release.firezone.values[0], "\"namespace\": \"gateway-system\"")
    )
    error_message = "rendered values must include gatewayRef with name and namespace"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"wgListenPort\": 51620")
    error_message = "rendered values must include wgListenPort default 51620"
  }
}

run "values_include_admin_email_and_client_subnet" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"adminEmail\": \"admin@example.net\"")
    error_message = "rendered values must include adminEmail"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"clientSubnet\": \"198.51.100.128/25\"")
    error_message = "rendered values must include clientSubnet"
  }
}

run "values_exclude_conntrack_log_image" {
  command = plan

  assert {
    condition     = !strcontains(helm_release.firezone.values[0], "conntrackLog")
    error_message = "rendered values must NOT include images.conntrackLog after audit split"
  }
}

run "values_include_firezone_secret_contract" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"wireguardIpv4Address\": \"198.51.100.129\"")
    error_message = "rendered values must include WIREGUARD_IPV4_ADDRESS as the first client subnet host"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"wireguardIpv4Masquerade\": false")
    error_message = "rendered values must disable Firezone built-in IPv4 masquerade by default"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"guardianSecretKey\":")
    error_message = "rendered values must include GUARDIAN_SECRET_KEY material"
  }
}

run "default_ospf_is_null" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"ospf\": null")
    error_message = "with default var.ospf=null, rendered values must contain 'ospf: null'"
  }
}

run "ospf_set_propagates_router_id_and_interfaces" {
  command = plan

  variables {
    ospf = {
      router_id  = "198.51.100.22"
      interfaces = ["wg-firezone"]
    }
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"router_id\": \"198.51.100.22\"")
    error_message = "rendered values must contain ospf.router_id"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "- \"wg-firezone\"")
    error_message = "rendered values must contain ospf.interfaces entry"
  }
}

run "nic_attach_default_is_backbone_and_border" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "- \"backbone\"")
    error_message = "default nic_attach must include backbone"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "- \"border\"")
    error_message = "default nic_attach must include border"
  }
}

run "outputs_match_inputs" {
  command = plan

  assert {
    condition     = output.deployment_name == "firezone"
    error_message = "output.deployment_name must equal var.name"
  }

  assert {
    condition     = output.service_url == "https://hub.example.net"
    error_message = "output.service_url must be https://${var.server_fqdn}"
  }
}

run "reject_relative_firezone_dir" {
  command = plan

  variables {
    firezone_dir = "relative/path"
  }

  expect_failures = [var.firezone_dir]
}

run "reject_invalid_admin_email" {
  command = plan

  variables {
    admin_email = "not-an-email"
  }

  expect_failures = [var.admin_email]
}

run "reject_invalid_client_subnet" {
  command = plan

  variables {
    client_subnet = "not-a-cidr"
  }

  expect_failures = [var.client_subnet]
}

run "reject_invalid_ospf_router_id" {
  command = plan

  variables {
    ospf = {
      router_id  = "not-an-ip"
      interfaces = ["wg-firezone"]
    }
  }

  expect_failures = [var.ospf]
}

run "reject_empty_gateway_ref" {
  command = plan
  variables {
    gateway_ref = {
      name      = ""
      namespace = ""
    }
  }
  expect_failures = [var.gateway_ref]
}

run "oidc_disabled_by_default_renders_no_oidc_block" {
  command = plan

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"oidc\":")
    error_message = "rendered values must always include an oidc key"
  }
  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"providers\": {}")
    error_message = "with default var.oidc_providers={}, rendered oidc.providers must be empty"
  }
  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"managed\": \"merge\"")
    error_message = "default oidc.managed must be 'merge'"
  }
}

run "oidc_providers_propagate" {
  command = plan

  variables {
    oidc_reconcile_image = "python:3.12-slim-bookworm"
    oidc_providers = {
      google = {
        client_id     = "fixture-client-id"
        client_secret = "fixture-client-secret"
        label         = "Google"
      }
    }
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"oidcReconcile\": \"python:3.12-slim-bookworm\"")
    error_message = "rendered values must include images.oidcReconcile"
  }
  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"client_id\": \"fixture-client-id\"")
    error_message = "rendered values must include the provider client_id"
  }
}

run "reject_invalid_oidc_managed" {
  command = plan
  variables {
    oidc_managed = "bogus"
  }
  expect_failures = [var.oidc_managed]
}

# Regression: when firezone_image and frr_image are both empty, first-party
# keys must be omitted from images override so the chart's pinned digest wins.
# External keys (postgres, oidcReconcile) must always be present.
run "empty_firstparty_images_omit_keys" {
  command = plan

  variables {
    firezone_image       = ""
    frr_image            = ""
    postgres_image       = "postgres:15"
    oidc_reconcile_image = "python:3.12-slim-bookworm"
  }

  assert {
    condition     = !strcontains(helm_release.firezone.values[0], "garuda-firezone@sha256:")
    error_message = "rendered values must NOT contain a garuda-firezone digest override when firezone_image is empty"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"postgres\":")
    error_message = "rendered values must always contain the external postgres key"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "\"oidcReconcile\":")
    error_message = "rendered values must always contain the external oidcReconcile key"
  }

  assert {
    condition     = !strcontains(helm_release.firezone.values[0], "\"frr\":")
    error_message = "rendered values must NOT contain the frr key when frr_image is empty"
  }
}

# Regression: when firezone_image is non-empty it must appear in the override,
# and frr_image empty means the frr key must remain absent.
run "nonempty_firezone_image_overrides" {
  command = plan

  variables {
    firezone_image       = "ghcr.io/garuda-tunnel/garuda-firezone@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    frr_image            = ""
    postgres_image       = "postgres:15"
    oidc_reconcile_image = "python:3.12-slim-bookworm"
  }

  assert {
    condition     = strcontains(helm_release.firezone.values[0], "garuda-firezone@sha256:2222222222222222222222222222222222222222222222222222222222222222")
    error_message = "rendered values must include the non-empty firezone image digest override"
  }

  assert {
    condition     = !strcontains(helm_release.firezone.values[0], "\"frr\":")
    error_message = "rendered values must NOT contain the frr key when frr_image is empty"
  }
}
