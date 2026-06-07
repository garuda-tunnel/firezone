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
