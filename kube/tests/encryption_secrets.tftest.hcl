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
}

run "generated_path_includes_all_secret_keys" {
  command = apply

  assert {
    condition = alltrue([
      for key in [
        "guardianSecretKey",
        "secretKeyBase",
        "liveViewSigningSalt",
        "cookieSigningSalt",
        "cookieEncryptionSalt",
        "databaseEncryptionKey",
        "databasePassword",
      ] : contains(keys(yamldecode(helm_release.firezone.values[0]).secrets), key)
    ])
    error_message = "generated values must include all Firezone encryption secret keys"
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
      databasePassword      = "RESTORED-databasePassword"
    }
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.guardianSecretKey == "RESTORED-guardianSecretKey"
    error_message = "guardianSecretKey must use the override value"
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.databaseEncryptionKey == "RESTORED-databaseEncryptionKey"
    error_message = "databaseEncryptionKey must use the override value"
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.databasePassword == "RESTORED-databasePassword"
    error_message = "databasePassword must use the override value"
  }
}

run "partial_override_only_restores_supplied_values" {
  command = apply

  variables {
    encryption_secrets = {
      databaseEncryptionKey = "RESTORED-databaseEncryptionKey"
      databasePassword      = "RESTORED-databasePassword"
    }
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.databaseEncryptionKey == "RESTORED-databaseEncryptionKey"
    error_message = "databaseEncryptionKey must use the partial override value"
  }

  assert {
    condition     = yamldecode(helm_release.firezone.values[0]).secrets.databasePassword == "RESTORED-databasePassword"
    error_message = "databasePassword must use the partial override value"
  }

  assert {
    condition = alltrue([
      for key in [
        "guardianSecretKey",
        "secretKeyBase",
        "liveViewSigningSalt",
        "cookieSigningSalt",
        "cookieEncryptionSalt",
      ] : !strcontains(yamldecode(helm_release.firezone.values[0]).secrets[key], "RESTORED")
    ])
    error_message = "unsupplied encryption_secrets fields must not contain the RESTORED marker"
  }
}
