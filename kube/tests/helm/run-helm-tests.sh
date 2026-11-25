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

# A missing/empty connection Secret name must fail before any workload renders.
for missing in null '""'; do
  if schema_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set-json "databaseSecretName=${missing}" 2>&1)"; then
    echo "FAIL: schema accepted missing/empty databaseSecretName" >&2
    exit 1
  fi
  [[ "${schema_out}" == *databaseSecretName* ]] \
    || { echo "FAIL: render failed for a reason other than databaseSecretName: ${schema_out}" >&2; exit 1; }
done
echo "ok: schema rejects missing/empty databaseSecretName"

# A missing/empty credentials Secret name must fail on the schema: the name
# must come from the Terraform module (kube/main.tf), never from a chart
# default, or the Deployment would reference a Secret nobody owns.
for missing in null '""'; do
  if schema_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set-json "credentialsSecretName=${missing}" 2>&1)"; then
    echo "FAIL: schema accepted missing/empty credentialsSecretName" >&2
    exit 1
  fi
  [[ "${schema_out}" == *credentialsSecretName* ]] \
    || { echo "FAIL: render failed for a reason other than credentialsSecretName: ${schema_out}" >&2; exit 1; }
done
echo "ok: schema rejects missing/empty credentialsSecretName"

# Both the server and OIDC release tooling need the same connection contract.
for scenario in default oidc; do
  db_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-${scenario}.yaml")"
  db_deployment="$(echo "${db_out}" | yq 'select(.kind == "Deployment")')"
  # The non-secret env renders as a ConfigMap (as a Secret, an upgrade would
  # three-way-patch removed stringData keys back as empty strings); it must
  # never be a Secret again.
  db_env="$(echo "${db_out}" | yq 'select(.kind == "ConfigMap" and .metadata.name == "firezone-env")')"
  db_env_secret="$(echo "${db_out}" | yq 'select(.kind == "Secret" and .metadata.name == "firezone-env") | .metadata.name')"
  [[ -n "${db_env}" ]] \
    || { echo "FAIL: firezone-env must render as a ConfigMap" >&2; exit 1; }
  [[ -z "${db_env_secret}" ]] \
    || { echo "FAIL: firezone-env must not render as a Secret (it carries no secret material)" >&2; exit 1; }
  containers=firezone
  [[ "${scenario}" != oidc ]] || containers="firezone oidc-reconcile"
  for container in ${containers}; do
    for pair in HOST:host PORT:port NAME:dbname USER:username PASSWORD:password; do
      actual="$(echo "${db_out}" | yq "select(.kind == \"Deployment\") | .spec.template.spec.containers[] | select(.name == \"${container}\") | .env[] | select(.name == \"DATABASE_${pair%%:*}\") | .valueFrom.secretKeyRef | tojson(0)")"
      [[ "${actual}" == "{\"name\":\"postgres-app\",\"key\":\"${pair#*:}\"}" ]] \
        || { echo "FAIL: ${container} DATABASE_${pair%%:*} must reference postgres-app/${pair#*:}: ${actual}" >&2; exit 1; }
    done
  done
  [[ "$(echo "${db_deployment}" | yq '[.spec.template.spec.containers[] | select(.name == "postgres")] | length')" == 0 ]] \
    || { echo "FAIL: embedded postgres container rendered" >&2; exit 1; }
  [[ "$(echo "${db_deployment}" | yq '[.spec.template.spec.volumes[] | select(.name == "postgres-data")] | length')" == 0 ]] \
    || { echo "FAIL: postgres-data volume rendered" >&2; exit 1; }
  # Secret material moved to the Terraform-owned credentials Secret
  # (kube/main.tf): none of the moved keys may render in the firezone-env
  # ConfigMap.
  [[ "$(echo "${db_env}" | yq '.data | keys | map(select(test("^(DEFAULT_ADMIN_PASSWORD|GUARDIAN_SECRET_KEY|SECRET_KEY_BASE|LIVE_VIEW_SIGNING_SALT|COOKIE_SIGNING_SALT|COOKIE_ENCRYPTION_SALT|DATABASE_ENCRYPTION_KEY|WIREGUARD_PRIVATE_KEY)$"))) | length')" == 0 ]] \
    || { echo "FAIL: secret material leaked into firezone-env" >&2; exit 1; }
  [[ "$(echo "${db_env}" | yq '.data | keys | map(select(test("^(DATABASE_(HOST|PORT|NAME|USER|PASSWORD)|POSTGRES_.*)$"))) | length')" == 0 ]] \
    || { echo "FAIL: connection credentials leaked into firezone-env" >&2; exit 1; }
done
echo "ok: external database Secret contract"

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

# --- Terraform-owned credentials Secret contract (issue #60) ---
# The OIDC sidecar keeps envFrom of the non-secret env ConfigMap AND the
# credentials Secret: its nsenter-launched create-api-token call needs the
# application secrets (see the comment in deployment.yaml). The chart-owned
# firezone-oidc Secret is gone — providers travel in the credentials Secret.
# envFrom order matters: the ConfigMap first, the credentials Secret last so
# its keys win any name collision.
oidc_out="$(helm template firezone "${CHART_DIR}" --namespace garuda -f "${SCRIPT_DIR}/values-oidc.yaml")"
oidc_dep() { echo "${oidc_out}" | yq 'select(.kind == "Deployment")' | yq "$1"; }

sidecar_env="$(oidc_dep '.spec.template.spec.containers[] | select(.name == "oidc-reconcile") | .envFrom | [.[] | to_entries[0] | "\(.key)=\(.value.name)"] | tojson(0)')"
[[ "${sidecar_env}" == '["configMapRef=firezone-env","secretRef=firezone-credentials"]' ]] \
  || { echo "FAIL: oidc-reconcile envFrom must be ConfigMap firezone-env then Secret firezone-credentials: ${sidecar_env}" >&2; exit 1; }

app_env="$(oidc_dep '.spec.template.spec.containers[] | select(.name == "firezone") | .envFrom | [.[] | to_entries[0] | "\(.key)=\(.value.name)"] | tojson(0)')"
[[ "${app_env}" == '["configMapRef=firezone-env","secretRef=firezone-credentials"]' ]] \
  || { echo "FAIL: firezone envFrom must be ConfigMap firezone-env then Secret firezone-credentials: ${app_env}" >&2; exit 1; }

oidc_secret_name="$(echo "${oidc_out}" | yq 'select(.kind == "Secret" and .metadata.name == "firezone-oidc") | .metadata.name')"
[[ -z "${oidc_secret_name}" ]] \
  || { echo "FAIL: a Secret named firezone-oidc still renders" >&2; exit 1; }

# Stakater Reloader rolls the Deployment when the credentials Secret changes:
# the annotation must name it on the Deployment metadata.
reload_ann="$(oidc_dep '.metadata.annotations."secret.reloader.stakater.com/reload"')"
[[ "${reload_ann}" == "firezone-credentials" ]] \
  || { echo "FAIL: Deployment must annotate secret.reloader.stakater.com/reload=firezone-credentials: ${reload_ann}" >&2; exit 1; }

# mssClampEnabled=false must keep the annotation naming the credentials Secret.
off_reload="$(helm template firezone "${CHART_DIR}" --namespace garuda \
  -f "${SCRIPT_DIR}/values-default.yaml" \
  --set mtuPolicy.mssClampEnabled=false \
  | yq 'select(.kind == "Deployment")' | yq '.metadata.annotations."secret.reloader.stakater.com/reload"')"
[[ "${off_reload}" == "firezone-credentials" ]] \
  || { echo "FAIL: reload annotation must render in the default (non-OIDC) scenario too: ${off_reload}" >&2; exit 1; }

echo "ok: credentials Secret contract (envFrom, no oidc Secret, reload annotation)"

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
# Only mssClamp can fail now (no secret values are set at chart level anymore).
schema_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set mssClamp.image='nft:latest' 2>&1 || true)"
echo "${schema_out}" | grep -q 'mssClamp' && echo "${schema_out}" | grep -qi 'pattern\|does not match' \
  && echo "ok: schema rejects floating image tag" \
  || { echo "FAIL: schema did NOT reject floating image tag 'nft:latest'" >&2; exit 1; }

# --- WireGuard server key: file mount from the credentials Secret, disposable firezone-data ---
wg_out="${mss_out}"
dep() { echo "${wg_out}" | yq "select(.kind == \"Deployment\")" | yq "$1"; }

[[ "$(echo "${wg_out}" | yq 'select(.kind == "ConfigMap" and .metadata.name == "firezone-env") | .data.WIREGUARD_PRIVATE_KEY_PATH')" == "/etc/firezone/wg/private_key" ]] \
  || { echo "FAIL: env ConfigMap WIREGUARD_PRIVATE_KEY_PATH missing or wrong" >&2; exit 1; }

[[ "$(dep '.spec.template.spec.volumes[] | select(.name == "wg-key") | .secret.secretName')" == "firezone-credentials" ]] \
  || { echo "FAIL: wg-key volume must come from the credentials Secret firezone-credentials" >&2; exit 1; }
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

# The removed secret-carrying values must fail the schema loud and early: no
# caller may keep passing secret material through Helm (issue #60). WireGuard
# key format validation now lives only at the Terraform level
# (var.wireguard_private_key, wireguard_key.tftest.hcl). Assert only failure
# plus the removed key being named — Helm's error wording differs across
# versions ("additional properties" only appears on 3.20+/4.x).
for removed in adminPassword secrets.wireguardPrivateKey oidc.providers; do
  if schema_out="$(helm template firezone "${CHART_DIR}" -f "${SCRIPT_DIR}/values-default.yaml" --set "${removed}=x" 2>&1)"; then
    echo "FAIL: schema accepted the removed '${removed}' value" >&2
    exit 1
  fi
  [[ "${schema_out}" == *"${removed%%.*}"* ]] \
    || { echo "FAIL: render failed for a reason other than the removed '${removed}' value: ${schema_out}" >&2; exit 1; }
done

echo "ok: wireguard key mount + firezone-data emptyDir + schema"
