"""Behavior tests for the firezone OIDC reconcile script."""


def test_extract_jwt_ignores_leading_warnings(mod):
    out = (
        "warning: noisy OTP line\n"
        "at File.foo.bar (line 12)\n"
        "Iex[1]> result.was.here\n"
        "header.payload.sig\n"
    )
    assert mod.extract_jwt(out) == "header.payload.sig"


def test_extract_jwt_raises_when_absent(mod):
    import pytest

    with pytest.raises(ValueError):
        mod.extract_jwt("no token here\nstill nothing\n")


def test_decode_token_id_reads_api_claim(mod):
    import base64
    import json

    payload = (
        base64.urlsafe_b64encode(json.dumps({"api": "tok-123"}).encode())
        .rstrip(b"=")
        .decode()
    )
    jwt = f"h.{payload}.s"
    assert mod.decode_token_id(jwt) == "tok-123"


def test_build_desired_provider_defaults(mod):
    providers = {"google": {"client_id": "cid", "client_secret": "sec"}}
    desired = mod.build_desired(providers, server_url="https://hub.example.net")
    g = desired[0]
    assert g["id"] == "google"
    assert g["label"] == "google"
    assert g["client_id"] == "cid"
    assert g["client_secret"] == "sec"
    assert g["redirect_uri"] == "https://hub.example.net/auth/oidc/google/callback"
    assert g["response_type"] == "code"
    assert g["scope"] == "openid email profile"
    assert g["auto_create_users"] is True
    assert (
        g["discovery_document_uri"]
        == "https://accounts.google.com/.well-known/openid-configuration"
    )


def test_build_desired_null_optional_fields_use_defaults(mod):
    """Null optional fields (from Terraform optional() serialising as JSON null)
    must fall back to defaults, not propagate null to the Firezone PATCH body."""
    providers = {
        "google": {
            "client_id": "cid",
            "client_secret": "sec",
            "auto_create_users": None,
            "discovery_document_uri": None,
            "redirect_uri": None,
            "response_type": None,
            "scope": None,
            "label": None,
        }
    }
    desired = mod.build_desired(providers, server_url="https://hub.example.net")
    g = desired[0]
    assert g["auto_create_users"] is True
    assert g["discovery_document_uri"] == "https://accounts.google.com/.well-known/openid-configuration"
    assert g["redirect_uri"] == "https://hub.example.net/auth/oidc/google/callback"
    assert g["response_type"] == "code"
    assert g["scope"] == "openid email profile"
    assert g["label"] == "google"


def test_merge_keeps_unmanaged_providers(mod):
    existing = [{"id": "okta", "client_id": "x"}, {"id": "google", "client_id": "old"}]
    desired = [{"id": "google", "client_id": "new"}]
    merged = mod.merge_providers(existing, desired, mode="merge")
    by_id = {p["id"]: p for p in merged}
    assert by_id["okta"]["client_id"] == "x"
    assert by_id["google"]["client_id"] == "new"


def test_replace_drops_unmanaged_providers(mod):
    existing = [{"id": "okta", "client_id": "x"}, {"id": "google", "client_id": "old"}]
    desired = [{"id": "google", "client_id": "new"}]
    merged = mod.merge_providers(existing, desired, mode="replace")
    assert [p["id"] for p in merged] == ["google"]
