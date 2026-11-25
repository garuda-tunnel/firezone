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

run "generated_path_includes_all_secret_keys" {
  command = apply

  assert {
    condition = alltrue([
      for key in [
        "GUARDIAN_SECRET_KEY",
        "SECRET_KEY_BASE",
        "LIVE_VIEW_SIGNING_SALT",
        "COOKIE_SIGNING_SALT",
        "COOKIE_ENCRYPTION_SALT",
        "DATABASE_ENCRYPTION_KEY",
      ] : contains(keys(kubernetes_secret_v1.credentials.data), key)
    ])
    error_message = "the credentials Secret must include all Firezone encryption secret keys"
  }
}

run "full_override_propagates_literal_values" {
  command = plan

  variables {
    encryption_secrets = {
      guardianSecretKey     = "RESTORED-guardianSecretKey"
      secretKeyBase         = "RESTORED-secretKeyBase"
      liveViewSigningSalt   = "RESTORED-liveViewSigningSalt"
      cookieSigningSalt     = "RESTORED-cookieSigningSalt"
      cookieEncryptionSalt  = "RESTORED-cookieEncryptionSalt"
      databaseEncryptionKey = "RESTORED-databaseEncryptionKey"
    }
  }

  assert {
    condition     = kubernetes_secret_v1.credentials.data["GUARDIAN_SECRET_KEY"] == "RESTORED-guardianSecretKey"
    error_message = "guardianSecretKey must use the override value"
  }

  assert {
    condition     = kubernetes_secret_v1.credentials.data["DATABASE_ENCRYPTION_KEY"] == "RESTORED-databaseEncryptionKey"
    error_message = "databaseEncryptionKey must use the override value"
  }

}

run "partial_override_only_restores_supplied_values" {
  command = apply

  variables {
    encryption_secrets = {
      databaseEncryptionKey = "RESTORED-databaseEncryptionKey"
    }
  }

  assert {
    condition     = kubernetes_secret_v1.credentials.data["DATABASE_ENCRYPTION_KEY"] == "RESTORED-databaseEncryptionKey"
    error_message = "databaseEncryptionKey must use the partial override value"
  }

  assert {
    condition = alltrue([
      for key in [
        "GUARDIAN_SECRET_KEY",
        "SECRET_KEY_BASE",
        "LIVE_VIEW_SIGNING_SALT",
        "COOKIE_SIGNING_SALT",
        "COOKIE_ENCRYPTION_SALT",
      ] : !strcontains(kubernetes_secret_v1.credentials.data[key], "RESTORED")
    ])
    error_message = "unsupplied encryption secret keys must not contain the RESTORED marker"
  }
}
