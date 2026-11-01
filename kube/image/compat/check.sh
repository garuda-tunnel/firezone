#!/usr/bin/env bash
# Compatibility checks for a firezone image (old upstream or our build).
#
# Usage: kube/image/compat/check.sh <image-ref>
#
# Asserts (plan Task 9, Review Focus 1/2/4):
#   1. the upstream-0.7.36 fixture ciphertext decrypts with the fixture key
#      (cloak/cloak_ecto bump keeps old DB ciphertexts readable);
#   2. the upstream-0.7.36 fixture argon2 hash verifies the fixture password
#      (argon2_elixir keeps old password hashes valid);
#   3. Wireguardex.generate_private_key/0 works (rust NIF loads on this runtime);
#   4. the chart's mss-clamp nftables ruleset loads with the image's own nft,
#      and the clamp rules are visible (mss-clamp sidecar reuses this image);
#   5. /etc/os-release is a non-EOL Alpine and /app/bin/server exists.
#
# Exit 0 = all checks pass. Against upstream firezone/firezone:0.7.36 every
# check passes except #5's Alpine-EOL part — that proves the checks bite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fixtures.env
source "$SCRIPT_DIR/fixtures.env"

IMAGE="${1:?usage: check.sh <image-ref>}"

# Lowest non-EOL Alpine as of 2026-11 (3.20 EOL 2026-04-01, 3.21 EOL
# 2026-11-01, 3.22 is supported until 2027-05-01). Bump when versions age out.
MIN_ALPINE_VERSION="3.22"

# Dummy boot env: runtime.exs validates config even under `eval`; nothing
# connects to the DB and SAML certs are throwaway self-signed ones written to a
# mounted /var/firezone. Values mirror make-fixtures.sh.
SKB="Z2FydWRhLWNvbXBhdC1maXh0dXJlLXNlY3JldC1rZXktYmFzZS1sb25nLWVub3VnaC1mb3ItcGhvZW5peC12YWxpZGF0aW9uLWNoZWNr"
SALT="Z2FydWRhLWNvbXBhdC1maXh0dXJlLXNhbHQ="

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failures=0
ok() { echo "ok:   $*"; }
bad() { echo "FAIL: $*" >&2; failures=1; }

# The eval expression travels via the mounted dir (not through shell quoting).
run_expr() {
  printf '%s\n' "$1" >"$workdir/expr.exs"
  docker run --rm \
    -e EXTERNAL_URL="http://localhost:13000" \
    -e DATABASE_HOST="127.0.0.1" \
    -e DATABASE_NAME="firezone_fixture" \
    -e DATABASE_USER="firezone_fixture" \
    -e DATABASE_PASSWORD="fixture" \
    -e DATABASE_ENCRYPTION_KEY="$FIXTURE_DATABASE_ENCRYPTION_KEY" \
    -e GUARDIAN_SECRET_KEY="$FIXTURE_DATABASE_ENCRYPTION_KEY" \
    -e SECRET_KEY_BASE="$SKB" \
    -e LIVE_VIEW_SIGNING_SALT="$SALT" \
    -e COOKIE_SIGNING_SALT="$SALT" \
    -e COOKIE_ENCRYPTION_SALT="$SALT" \
    -e FIXTURE_PLAINTEXT="$FIXTURE_PLAINTEXT" \
    -e FIXTURE_PASSWORD="$FIXTURE_PASSWORD" \
    -e FIXTURE_CIPHERTEXT_B64="$FIXTURE_CIPHERTEXT_B64" \
    -e FIXTURE_ARGON2_HASH="$FIXTURE_ARGON2_HASH" \
    -v "$workdir:/var/firezone" \
    --entrypoint sh \
    "$IMAGE" -c '
      set -e
      [ -f /var/firezone/saml.crt ] || openssl req -x509 -sha256 -nodes -days 365 \
        -newkey rsa:2048 -keyout /var/firezone/saml.key -out /var/firezone/saml.crt \
        -subj "/CN=fixture" >/dev/null 2>&1
      exec /app/bin/firezone eval "$(cat /var/firezone/expr.exs)"
    ' >/dev/null 2>&1
}

echo "== image: $IMAGE"

# ── 1+2+3: vault decrypt, argon2 verify, wireguardex NIF (single VM boot) ──
if run_expr '
{:ok, _pid} = FzHttp.Vault.start_link()
{:ok, plaintext} = FzHttp.Vault.decrypt(Base.decode64!(System.fetch_env!("FIXTURE_CIPHERTEXT_B64")))
true = plaintext == System.fetch_env!("FIXTURE_PLAINTEXT") || exit(:cipher_mismatch)
true = FzHttp.Crypto.equal?(System.fetch_env!("FIXTURE_PASSWORD"), System.fetch_env!("FIXTURE_ARGON2_HASH")) || exit(:hash_mismatch)
key = Wireguardex.generate_private_key()
true = is_binary(key) and byte_size(key) == 44 and match?({:ok, _}, Base.decode64(key)) || exit(:bad_wg_key)
IO.puts("OK")
'; then
  ok "fixture ciphertext decrypts (cloak format compatible)"
  ok "fixture argon2 hash verifies (password hashes valid)"
  ok "Wireguardex.generate_private_key/0 returns a 44-char base64 key (NIF loads)"
else
  bad "eval failed: cipher/hash/NIF checks (see expr in make-fixtures for rerun)"
fi

# ── 4: chart's mss-clamp ruleset loads with the image's nft ─────────────────
CHART_DIR="$SCRIPT_DIR/../../charts/firezone"
VALUES="$SCRIPT_DIR/../../tests/helm/values-default.yaml"
command -v helm >/dev/null || bad "helm not installed (required for nft check)"
command -v yq >/dev/null || bad "yq not installed (required for nft check)"

if command -v helm >/dev/null && command -v yq >/dev/null; then
  rendered="$(helm template firezone "$CHART_DIR" --namespace garuda \
    -f "$VALUES" \
    --set 'mtuPolicy.mssClampEnabled=true' \
    --set 'mtuPolicy.fixedMss=1240')"
  # Extract the mss-clamp sidecar script, then the nft heredoc inside it
  # (same extraction path as kube/tests/mss_clamp_idempotency_test.sh).
  sidecar="$(printf '%s\n' "$rendered" | \
    yq eval-all 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "mss-clamp") | .args[0]' -)"
  ruleset="$(printf '%s\n' "$sidecar" | \
    sed -n "/nft -f - <<'NFTEOF'/,/^NFTEOF\$/p" | sed '1d;$d')"
  if [[ -z "$ruleset" ]]; then
    bad "could not extract firezone_mss ruleset from rendered chart"
  else
    # Assert on nft's exit status and grep only the stdout of
    # `nft list table inet firezone_mss`. nft echoes rule text in its error
    # output too, so merging stderr (or ignoring the exit status) lets a
    # rejected ruleset pass vacuously.
    if printf '%s\n' "$ruleset" | \
      docker run --rm -i --cap-add NET_ADMIN --entrypoint sh "$IMAGE" \
      -c 'nft -f - && nft list table inet firezone_mss' >"$workdir/nft.out"
    then
      if grep -q 'tcp option maxseg size set' "$workdir/nft.out"; then
        ok "chart firezone_mss ruleset loads with the image's nft; clamp rules listed"
      else
        bad "nft check failed: clamp rules absent from 'nft list table inet firezone_mss' stdout"
      fi
    else
      bad "nft check failed: nft exited non-zero (ruleset rejected or table listing failed); see stderr above"
    fi
  fi
fi

# ── 5: non-EOL alpine + /app/bin/server present ─────────────────────────────
os_release="$(docker run --rm --entrypoint cat "$IMAGE" /etc/os-release 2>/dev/null || true)"
os_id="$(sed -n 's/^ID=//p' <<<"$os_release")"
os_ver="$(sed -n 's/^VERSION_ID=//p' <<<"$os_release" | cut -d. -f1,2)"
if [[ "$os_id" == "alpine" ]]; then
  ok "/etc/os-release is alpine (${os_ver})"
else
  bad "/etc/os-release is not alpine (ID=${os_id})"
fi
min_parts=(${MIN_ALPINE_VERSION//./ })
ver_parts=(${os_ver//./ })
if (( ${ver_parts[0]:-0} * 100 + ${ver_parts[1]:-0} >= min_parts[0] * 100 + min_parts[1] )); then
  ok "alpine ${os_ver} >= ${MIN_ALPINE_VERSION} (non-EOL)"
else
  bad "alpine ${os_ver} < ${MIN_ALPINE_VERSION}: EOL runtime"
fi
if docker run --rm --entrypoint sh "$IMAGE" -c 'test -x /app/bin/server' 2>/dev/null; then
  ok "/app/bin/server exists and is executable"
else
  bad "/app/bin/server missing or not executable"
fi

# shellcheck disable=SC2086
if ((failures)); then
  echo "check.sh: FAILED for $IMAGE" >&2
  exit 1
fi
echo "check.sh: PASS for $IMAGE"
