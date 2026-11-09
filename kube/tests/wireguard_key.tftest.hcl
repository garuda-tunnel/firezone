mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  namespace            = "garuda"
  name                 = "firezone"
  database_secret_name = "postgres-app"
  firezone_image       = "ghcr.io/alexmkx/garuda-firezone:latest"
  server_fqdn          = "hub.example.net"
  admin_email          = "admin@example.net"
  admin_password       = "fixture-password"
  client_subnet        = "198.51.100.128/25"
  gateway_ref = {
    name      = "platform-gateway"
    namespace = "gateway-system"
  }
  mtu_policy = {
    site_mtu = 1330
  }
  # RFC 7748 §6.1 Alice key, clamped (public test vector), never a real key.
  wireguard_private_key = "cAdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LGo="
}

run "donor_key_derives_public_key" {
  command = apply

  assert {
    condition     = output.wireguard_public_key == "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo="
    error_message = "wireguard_public_key must be derived from the supplied private key"
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.wireguardPrivateKey == "cAdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LGo="
    error_message = "chart values must carry the supplied private key unchanged"
  }
}

run "malformed_key_rejected" {
  command = plan

  variables {
    wireguard_private_key = "not-a-key"
  }

  expect_failures = [var.wireguard_private_key]
}

run "trailing_newline_rejected" {
  command = plan

  variables {
    wireguard_private_key = "cAdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LGo=\n"
  }

  expect_failures = [var.wireguard_private_key]
}

run "unclamped_key_rejected" {
  command = plan

  variables {
    # RFC 7748 Alice key as published (unclamped): Firezone would advertise a wrong public key.
    wireguard_private_key = "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo="
  }

  expect_failures = [var.wireguard_private_key]
}
