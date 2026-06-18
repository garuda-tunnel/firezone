#!/usr/bin/env bash
# Helm-level tests for modules/firezone/kube.
# helm lint + helm template diffed against tests/golden/*.yaml.
# Update goldens with: REGEN_GOLDEN=1 ./run-helm-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="${SCRIPT_DIR}/../.."
CHART_DIR="${MODULE_DIR}/charts/firezone"
GOLDEN_DIR="${SCRIPT_DIR}/../golden"

# Resolve the frr-sidecar library dependency from OCI (Chart.yaml lists
# it via `oci://ghcr.io/alexmkx/charts`). Without this step `helm template`
# fails with "no cached repo found" on a clean checkout. The Terraform Helm
# provider performs the equivalent step automatically via
# `dependency_update = true` on helm_release.
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

# Off-switch: mssClamp.enabled=false must produce zero occurrences of firezone_mss.
off_out="$(helm template firezone "${CHART_DIR}" --namespace garuda \
  -f "${SCRIPT_DIR}/values-default.yaml" \
  --set mssClamp.enabled=false)"
count=$(echo "${off_out}" | grep -c 'firezone_mss' || true)
[[ "${count}" -eq 0 ]] \
  || { echo "FAIL: mssClamp.enabled=false still renders firezone_mss (count=${count})" >&2; exit 1; }
echo "ok: mssClamp off-switch"

# SF3: floating image tag must be rejected by the schema.
schema_out="$(helm template firezone "${CHART_DIR}" --set mssClamp.image='nft:latest' 2>&1 || true)"
echo "${schema_out}" | grep -qi 'pattern\|does not match' \
  && echo "ok: schema rejects floating image tag" \
  || { echo "FAIL: schema did NOT reject floating image tag 'nft:latest'" >&2; exit 1; }
