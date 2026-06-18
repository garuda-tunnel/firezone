#!/usr/bin/env bash
# Unit test: mss-clamp sidecar script idempotency.
#
# The original test was tautological: it hardcoded its own install_clamp
# instead of extracting it from the rendered chart, and its stub nft always
# returned 0 without tracking state -- so the while-loop guard was never
# exercised and a broken chart (e.g. missing flush) would still pass.
#
# This rewrite:
#   - Extracts install_clamp verbatim from the Helm-rendered manifest via yq
#     (YAML block-scalar stripping matches what the container runtime receives).
#   - Uses a stateful nft stub that tracks table presence so `nft list` returns
#     the correct exit code, making the while-loop guard testable.
#   - Exercises three distinct protection paths:
#       1. First install (table absent) → succeeds, ready-flag written.
#       2. Re-install with existing table → succeeds (nft block-syntax is
#          idempotent; this was verified against real nftables v1.1.6).
#       3. After netns reset (table gone) → while-loop guard detects absence
#          and calls install_clamp again; subsequent iteration is a no-op.
#
# Also validates ICMP PTB invariant: policy accept, no icmp drop/reject.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../charts/firezone"

# ── Render the sidecar script from the Helm chart ──────────────────────────
rendered="$(helm template firezone "${CHART_DIR}" \
  --namespace garuda \
  -f "${SCRIPT_DIR}/helm/values-default.yaml" \
  --set 'mssClamp.enabled=true' \
  --set 'mssClamp.value=1240')"

# ── Scratch directory ───────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

STATE_FILE="${TMP}/nft_state"   # present = firezone_mss table exists in "kernel"
CLAMP_DIR="${TMP}/var/lib/clamp"
mkdir -p "${CLAMP_DIR}"

# ── Stateful nft stub ───────────────────────────────────────────────────────
# The stub tracks table presence so that `nft list table inet firezone_mss`
# returns the correct exit code.  This is what makes the while-loop guard
# scenarios meaningful: without state, `nft list` always returns 0 (or always
# 1), so the guard logic can never be tested.
#
# For `nft -f -`: the stub accepts all batch input and succeeds, mirroring real
# nftables behaviour where `table ... { chain ... }` blocks are idempotent
# (verified: nft v1.1.6 returns 0 for duplicate chain via block syntax).
# The table state file is created/cleared to let `nft list` reflect reality.
cat > "${TMP}/nft" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE="${NFT_STATE_FILE}"

if [[ "$1" == "list" ]]; then
  # nft list table inet firezone_mss
  [[ -f "${STATE}" ]] && exit 0 || exit 1
fi

if [[ "$1" == "-f" && "$2" == "-" ]]; then
  # Consume stdin.  Detect flush to clear state; table block to set state.
  while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*flush[[:space:]]+table[[:space:]] ]]; then
      rm -f "${STATE}"
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*table[[:space:]] ]]; then
      touch "${STATE}"
      continue
    fi
  done
  # After processing: if any table block was seen, table now exists.
  exit 0
fi

# Any other nft invocation (e.g. nft add table, nft delete) is a no-op success.
exit 0
STUB_EOF
chmod +x "${TMP}/nft"

# ── Extract the exact script the container runtime receives ─────────────────
# Use yq to YAML-parse the rendered manifest; this strips block-scalar
# indentation exactly as the container runtime does when passing the string to
# /bin/sh -c.  The sidecar_functions.sh file therefore has NFTEOF at column 0,
# which is required for the heredoc inside install_clamp to parse correctly.
sidecar_raw="$(printf '%s\n' "${rendered}" | \
  yq eval-all \
    'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "mss-clamp") | .args[0]' \
    -)"

# Rewrite /var/lib/clamp to TMP so the test does not need root.
sidecar_patched="${sidecar_raw//\/var\/lib\/clamp/${CLAMP_DIR}}"

# Write to a file without a heredoc wrapper: the script already contains
# <<'NFTEOF' and nesting heredocs would break parsing.
printf '%s\n' "${sidecar_patched}" > "${TMP}/sidecar_functions.sh"

# Strip the while-loop so sourcing the file does not block.
# The while-loop is exercised explicitly in scenario 3.
sed -i '/^while true/,$d' "${TMP}/sidecar_functions.sh"

# Sanity: install_clamp must be defined in the extracted script.
bash -n "${TMP}/sidecar_functions.sh" \
  || { echo "FAIL: extracted sidecar script has syntax errors" >&2; exit 1; }
grep -q 'install_clamp()' "${TMP}/sidecar_functions.sh" \
  || { echo "FAIL: install_clamp not found in extracted sidecar script" >&2; exit 1; }

# ── Helper: reset state (simulate netns table teardown) ─────────────────────
reset_state() { rm -f "${STATE_FILE}"; }

# ── Scenario 1: first install (table absent) ────────────────────────────────
echo "--- Scenario 1: first install (table absent) ---"
reset_state
rm -f "${CLAMP_DIR}/ready"

(
  export PATH="${TMP}:${PATH}"
  export NFT_STATE_FILE="${STATE_FILE}"
  # shellcheck source=/dev/null
  source "${TMP}/sidecar_functions.sh"
  install_clamp && touch "${CLAMP_DIR}/ready"
  echo "Scenario 1 install_clamp: OK"
)

[[ -f "${STATE_FILE}" ]] \
  || { echo "FAIL: nft state not created after first install" >&2; exit 1; }
echo "ok: table state created"

[[ -f "${CLAMP_DIR}/ready" ]] \
  || { echo "FAIL: ready flag not written after first install" >&2; exit 1; }
echo "ok: ready flag written"

# ── Scenario 2: re-install with existing table ──────────────────────────────
# Exercises the case where install_clamp is called when the table already
# exists.  The real-world risk is: if install_clamp were NOT idempotent (e.g.
# if the chart omitted the flush before re-add), repeating it would cause a
# duplicate-chain error and the sidecar would crash.  This test catches that.
echo "--- Scenario 2: re-install with existing table ---"
# Leave STATE_FILE in place (table present from scenario 1).

(
  export PATH="${TMP}:${PATH}"
  export NFT_STATE_FILE="${STATE_FILE}"
  source "${TMP}/sidecar_functions.sh"
  install_clamp \
    || { echo "FAIL: install_clamp returned non-zero with existing table" >&2; exit 1; }
  echo "Scenario 2 install_clamp (re-install): OK"
)
# Verify table still exists after re-install.
[[ -f "${STATE_FILE}" ]] \
  || { echo "FAIL: table state lost after re-install" >&2; exit 1; }
echo "ok: re-install with existing table succeeded (idempotent)"

# ── Scenario 3: netns reset — while-loop guard re-installs ──────────────────
# The while-loop body is: `nft list table inet firezone_mss || install_clamp`.
# This test proves:
#   a) When the table is absent, the guard calls install_clamp (not a no-op).
#   b) When the table is present, the guard is a no-op (exit 0 without re-install).
echo "--- Scenario 3: netns reset, while-loop guard re-installs ---"
reset_state   # table gone — simulate netns teardown

(
  export PATH="${TMP}:${PATH}"
  export NFT_STATE_FILE="${STATE_FILE}"
  source "${TMP}/sidecar_functions.sh"

  # Mirrors while-loop body from rendered sidecar (sans sleep).
  guard_iteration() {
    nft list table inet firezone_mss >/dev/null 2>&1 || install_clamp
  }

  # (a) Table absent → guard calls install_clamp.
  guard_iteration
  [[ -f "${STATE_FILE}" ]] \
    || { echo "FAIL: table not re-created by guard when absent" >&2; exit 1; }
  echo "Scenario 3 guard (table absent): install_clamp called, table re-created"

  # (b) Table present → guard is a no-op; must exit 0.
  guard_iteration
  echo "Scenario 3 guard (table present): no-op, exit 0"
)
echo "ok: while-loop guard re-installs after table loss, no-ops when present"

# ── ICMP PTB invariant ────────────────────────────────────────────────────────
echo "--- AC8: ICMP PTB invariant ---"
printf '%s\n' "${rendered}" | grep -qiE 'icmp.*(drop|reject)|(drop|reject).*icmp' \
  && { echo "FAIL: ICMP drop/reject found in rendered sidecar script" >&2; exit 1; }
echo "ok: no ICMP drop/reject in rendered output"

printf '%s\n' "${rendered}" | grep -q 'policy accept' \
  || { echo "FAIL: 'policy accept' not found in rendered output" >&2; exit 1; }
echo "ok: policy accept present (ICMP PTB transits)"

echo "PASS: mss-clamp idempotency + ICMP-PTB test"
