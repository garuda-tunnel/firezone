#!/usr/bin/env bash
# Helm-level tests for modules/firezone/kube.
# helm lint + helm template diffed against tests/golden/*.yaml.
# Update goldens with: REGEN_GOLDEN=1 ./run-helm-tests.sh
# Needs mikefarah yq >= 4.43 (tojson(0) indent argument), plus helm.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/../.."
CHART_DIR="${MODULE_DIR}/charts/firezone"
GOLDEN_DIR="${SCRIPT_DIR}/../golden"

yq_ver="$(yq --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+' | head -1 | tr -d v || true)"
[[ -n "${yq_ver}" && "$(printf '%s\n4.43\n' "${yq_ver}" | sort -V | head -1)" == "4.43" ]] \
  || { echo "FAIL: mikefarah yq >= 4.43 required (found: '$(yq --version 2>&1 || true)')" >&2; exit 1; }

# Resolve chart dependencies (if any) from OCI. Without this step
# `helm template` fails with "no cached repo found" on a clean checkout.
# The Terraform Helm provider performs the equivalent step automatically
# via `dependency_update = true` on helm_release.
helm dependency update "${CHART_DIR}"

for scenario in default with-ospf oidc; do
  values_file="${SCRIPT_DIR}/values-${scenario}.yaml"
  helm lint "${CHART_DIR}" -f "${values_file}"

  out="$(helm template firezone "${CHART_DIR}" --namespace garuda -f "${values_file}")"
  golden="${GOLDEN_DIR}/${scenario}.yaml"

  if [[ "${REGEN_GOLDEN:-0}" == "1" ]]; then
    printf '%s\n' "${out}" > "${golden}"
    echo "regenerated ${golden}"
    continue
  fi

  if ! diff -u "${golden}" <(printf '%s\n' "${out}"); then
    echo "golden mismatch for ${scenario}" >&2
    exit 1
  fi

  echo "ok: ${scenario}"
done

# --- MSS clamp assertions (TDD gate) ---
# Default render must include the mss-clamp sidecar with BOTH directions and readiness gating.
mss_out="$(helm template firezone "${CHART_DIR}" --namespace garuda -f "${SCRIPT_DIR}/values-default.yaml")"

echo "${mss_out}" | grep -q 'firezone_mss' \
  || { echo "FAIL: firezone_mss table missing from default render" >&2; exit 1; }

echo "${mss_out}" | grep -q 'oifname "wg-firezone" tcp flags syn tcp option maxseg size set rt mtu' \
  || { echo "FAIL: oifname (load-bearing return) clamp missing" >&2; exit 1; }

echo "${mss_out}" | grep -q 'iifname "wg-firezone" tcp flags syn tcp option maxseg size set 1240' \
  || { echo "FAIL: iifname (defense) clamp missing" >&2; exit 1; }

echo "${mss_out}" | grep -q '/var/lib/clamp/ready' \
  || { echo "FAIL: readiness flag path /var/lib/clamp/ready missing" >&2; exit 1; }

# AC8 negative: no ICMP drop/reject rules.
echo "${mss_out}" | grep -qiE 'icmp.*(drop|reject)|(drop|reject).*icmp' \
  && { echo "FAIL: ICMP drop/reject found in render" >&2; exit 1; }

echo "ok: mss-clamp assertions"

# Disabled-inbound: mtuPolicy.mssClampEnabled=false must:
#   - still render the mss-clamp sidecar and table (route-PMTU remains)
#   - omit the iifname fixed-MSS rule
off_out="$(helm template firezone "${CHART_DIR}" --namespace garuda \
  -f "${SCRIPT_DIR}/values-default.yaml" \
  --set mtuPolicy.mssClampEnabled=false)"

echo "${off_out}" | grep -q 'firezone_mss' \
  || { echo "FAIL: mssClampEnabled=false must still render firezone_mss table (route-PMTU)" >&2; exit 1; }

echo "${off_out}" | grep -q 'oifname "wg-firezone" tcp flags syn tcp option maxseg size set rt mtu' \
  || { echo "FAIL: mssClampEnabled=false must still render oifname route-PMTU rule" >&2; exit 1; }

iif_count=$(echo "${off_out}" | grep -c 'iifname "wg-firezone"' || true)
[[ "${iif_count}" -eq 0 ]] \
  || { echo "FAIL: mssClampEnabled=false must NOT render iifname fixed-MSS rule (count=${iif_count})" >&2; exit 1; }

echo "ok: mssClamp disabled-inbound: route-PMTU remains, iifname rule absent"

# SF3: floating image tag must be rejected by the schema.
# values-default.yaml supplies a valid wireguardPrivateKey, so only mssClamp can fail.
schema_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set mssClamp.image='nft:latest' 2>&1 || true)"
echo "${schema_out}" | grep -q 'mssClamp' && echo "${schema_out}" | grep -qi 'pattern\|does not match' \
  && echo "ok: schema rejects floating image tag" \
  || { echo "FAIL: schema did NOT reject floating image tag 'nft:latest'" >&2; exit 1; }

# --- WireGuard server key: file mount from the env Secret, disposable firezone-data ---
wg_out="${mss_out}"
dep() { echo "${wg_out}" | yq "select(.kind == \"Deployment\")" | yq "$1"; }

[[ "$(echo "${wg_out}" | yq 'select(.kind == "Secret" and .metadata.name == "firezone-env") | .stringData.WIREGUARD_PRIVATE_KEY_PATH')" == "/etc/firezone/wg/private_key" ]] \
  || { echo "FAIL: env Secret WIREGUARD_PRIVATE_KEY_PATH missing or wrong" >&2; exit 1; }

[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "wg-key") | .secret.secretName')" == "firezone-env" ]] \
  || { echo "FAIL: wg-key volume must come from secret firezone-env" >&2; exit 1; }
[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "wg-key") | .secret.items | tojson(0)')" == '[{"key":"WIREGUARD_PRIVATE_KEY","path":"private_key"}]' ]] \
  || { echo "FAIL: wg-key volume must project only WIREGUARD_PRIVATE_KEY as private_key" >&2; exit 1; }
[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "wg-key") | .secret.defaultMode')" == "0400" ]] \
  || { echo "FAIL: wg-key volume defaultMode must be 0400" >&2; exit 1; }
[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "wg-key") | .secret | has("optional")')" == "false" ]] \
  || { echo "FAIL: wg-key volume must not be optional" >&2; exit 1; }

[[ "$(dep '.spec.template.spec.containers[] | select(.name == "firezone") | .volumeMounts[] | select(.name == "wg-key") | "\(.mountPath) \(.readOnly)"')" == "/etc/firezone/wg true" ]] \
  || { echo "FAIL: firezone container must mount wg-key read-only at /etc/firezone/wg" >&2; exit 1; }
[[ "$(dep '[.spec.template.spec.containers[] | select(.volumeMounts[]?.name == "wg-key") | .name] | join(",")')" == "firezone" ]] \
  || { echo "FAIL: wg-key must be mounted in the firezone container only" >&2; exit 1; }

[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "firezone-data") | .emptyDir | tojson(0)')" == "{}" ]] \
  || { echo "FAIL: firezone-data must be emptyDir: {}" >&2; exit 1; }
[[ "$(dep '[.spec.template.spec.volumes[] | select(.name == "firezone-data" and has("hostPath"))] | length')" == "0" ]] \
  || { echo "FAIL: firezone-data must not be a hostPath" >&2; exit 1; }

# Rejected: unclamped (Firezone would advertise a wrong public key), non-canonical last char, trailing junk.
for bad in "" "not-a-key" "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=" "cAdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LGp=" "cAdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LGo=x"; do
  bad_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set "secrets.wireguardPrivateKey=${bad}" 2>&1 || true)"
  echo "${bad_out}" | grep -qi 'wireguardPrivateKey' && echo "${bad_out}" | grep -qi 'minLength\|pattern\|does not match\|length' \
    || { echo "FAIL: schema did NOT reject wireguardPrivateKey='${bad}'" >&2; exit 1; }
done

echo "ok: wireguard key mount + firezone-data emptyDir + schema"
