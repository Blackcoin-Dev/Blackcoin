#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/typed_contract.sh"

fixture=0
if [[ "${1:-}" == --fixture ]]; then
    fixture=1
    shift
fi
[[ $# == 2 ]] || {
    printf 'usage: %s [--fixture] REVIEWED_ENV EVIDENCE_DIR\n' "$0" >&2
    exit 64
}
env_file=$1 evidence=$2

if ((fixture == 0)); then
    [[ $EUID == 0 ]] || v3015_die 'direct verification requires root'
    v3015_load_reviewed_env "$env_file"
    v3015_assert_flat_secure_evidence "$evidence"
else
    # Tests use a plain temporary file and never authorize live execution.
    # shellcheck disable=SC1090
    source "$env_file"
    [[ -d "$evidence" && ! -L "$evidence" ]] || v3015_die 'fixture evidence missing'
fi
v3015_validate_release_env
v3015_require_commands jq sha256sum find sort realpath stat sed wc python3
if ((fixture == 0)); then
    v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
fi

manifest="$evidence/SHA256SUMS"
[[ -f "$manifest" && ! -L "$manifest" ]] || v3015_die 'evidence SHA256SUMS missing'
v3015_verify_manifest "$evidence" "$manifest" || v3015_die 'evidence manifest mismatch'

actual=()
while IFS= read -r file; do actual+=("$file"); done < <(
    find "$evidence" -mindepth 1 -maxdepth 1 -type f \
      ! -name SHA256SUMS -exec basename {} \; | sort)
listed=()
while IFS= read -r file; do listed+=("$file"); done < <(
    awk '{print $2}' "$manifest" | sed 's#^\*\?##; s#^\./##' | sort)
[[ "${actual[*]}" == "${listed[*]}" ]] || v3015_die 'manifest is not an exact flat inventory'

v3015_release_identity_is_valid "$evidence/release-identity.json" ||
    v3015_die 'release identity is invalid'
v3015_rollout_authority_is_valid "$evidence/rollout-authority.json" ||
    v3015_die 'rollout authority is invalid'
terminal_census_sha=$(v3015_sha256_file "$evidence/terminal-fleet-census.json")
terminal_probe_sha=$(v3015_sha256_file \
  "$evidence/node-30-free-claim-terminal-probe.raw.json")
v3015_fleet_result_is_valid "$evidence/fleet-result.json" "$terminal_census_sha" \
  "$terminal_probe_sha" "$evidence/rollout-authority.json" ||
    v3015_die 'fleet result is invalid'

[[ "$(v3015_sha256_file "$evidence/runtime-policy-handoff-receipt.json")" == \
   "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" &&
   "$(v3015_sha256_file "$evidence/persistent-compose-handoff-receipt.json")" == \
   "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" &&
   "$(v3015_sha256_file "$evidence/post-compose-reconcile-identity.json")" == \
   "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" ]] ||
    v3015_die 'handoff receipt copies do not match reviewed exact bytes'
v3015_terminal_census_is_valid "$evidence/terminal-fleet-census.json" "$evidence" \
  "$evidence/rollout-authority.json" ||
    v3015_die 'terminal 32-node census is invalid'

expected_names=(fleet-result.json node-30-free-claim.json
  node-30-free-claim-probe.raw.json node-30-free-claim-terminal-probe.raw.json
  persistent-compose-handoff-receipt.json
  post-compose-reconcile-identity.json release-identity.json rollout-authority.json
  runtime-policy-handoff-receipt.json
  terminal-fleet-census.json)
for node in $(seq 1 29) 31 32; do
    file=$(printf 'node-%02d.json' "$node")
    expected_names+=("$file")
    v3015_node_result_is_valid "$evidence/$file" "$node" \
      "$evidence/rollout-authority.json" ||
        v3015_die "node durability result is invalid: $node"
done
v3015_node30_result_is_valid "$evidence/node-30-free-claim.json" \
  "$evidence/node-30-free-claim-probe.raw.json" \
  "$evidence/rollout-authority.json" ||
    v3015_die 'node30 Free Claim result is invalid'

expected_sorted=()
while IFS= read -r file; do expected_sorted+=("$file"); done < <(
    printf '%s\n' "${expected_names[@]}" | sort)
[[ "${actual[*]}" == "${expected_sorted[*]}" ]] ||
    v3015_die 'unexpected or missing evidence files'

printf 'v30.1.5 rollout evidence verified: PoS 32/32, regular PoW 31/31, node30 Free Claim healthy\n'
