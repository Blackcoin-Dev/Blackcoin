#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091
source "$package_dir/lib/deployment_rollback_readiness_contract.sh"

usage()
{
    printf 'usage:\n' >&2
    printf '  %s audit REVIEWED_ENV\n' "$0" >&2
    printf '  %s authorize REVIEWED_ENV AUDIT.json LIVE-WAVE-AUTHORITY.json\n' "$0" >&2
    printf '  %s reconcile REVIEWED_ENV AUDIT.json WAVE-AUTHORIZATION.json LIVE-WAVE-AUTHORITY.json WAVE-RESULT.json [AFTER-INDEX.json]\n' "$0" >&2
    printf '  %s terminal REVIEWED_ENV AUDIT.json ROLLOUT-AUTHORITY.json FLEET-RESULT.json TERMINAL-CENSUS.json\n' "$0" >&2
    exit 64
}

[[ $# -ge 2 ]] || usage
mode=$1 env_file=$2
case "$mode:$#" in
    audit:2|authorize:4|reconcile:6|reconcile:7|terminal:6) ;;
    *) usage ;;
esac

v3015_dr_file_is_safe "$env_file" ||
    v3015_die 'offline deployment-readiness environment is unsafe'
# The reviewed environment contains identity and receipt paths only. Each value
# and every referenced file is independently validated below.
# shellcheck disable=SC1090
source "$env_file"
v3015_require_commands awk bash date jq realpath sha256sum sort stat
v3015_dr_validate_common_env

contract_file="$package_dir/lib/deployment_rollback_readiness_contract.sh"
tool_file="$package_dir/deployment_rollback_readiness.sh"
contract_sha=$(v3015_sha256_file "$contract_file")
tool_sha=$(v3015_sha256_file "$tool_file")

for input in "$DR_PUBLIC_ARTIFACT_RECEIPT" "$DR_FLEET_INTEGRATION_RECEIPT" \
  "$DR_NODE30_ONE_SHOT_RECEIPT" "$DR_NODE27_RELAY_RECEIPT" \
  "$DR_POS_RENEWAL_RECEIPT" "$DR_ROLLBACK_PLAN_RECEIPT" \
  "$DR_TOPOLOGY_MAP" "$DR_WAVES_PLAN" "$DR_BEFORE_INDEX"; do
    v3015_dr_file_is_safe "$input" || v3015_die "unsafe reviewed input: $input"
done
v3015_dr_authority_inputs_are_valid "$contract_sha" "$tool_sha" ||
    v3015_die 'offline deployment-readiness authority set failed closed'

if [[ "$mode" == audit ]]; then
    v3015_dr_make_audit_receipt "$contract_sha" "$tool_sha"
    exit 0
fi

audit_file=$3
v3015_dr_file_is_safe "$audit_file" || v3015_die 'audit receipt is unsafe'
audit_sha=$(v3015_sha256_file "$audit_file")
v3015_dr_audit_receipt_is_valid "$audit_file" "$contract_sha" "$tool_sha" ||
    v3015_die 'audit receipt does not bind the exact current readiness inputs'

if [[ "$mode" == authorize ]]; then
    authority_file=$4
    v3015_dr_file_is_safe "$authority_file" || v3015_die 'live wave authority is unsafe'
    authority_sha=$(v3015_sha256_file "$authority_file")
    checked_epoch=$(date -u +%s)
    wave_index=$(jq -er '.authorized_wave_index' "$authority_file") ||
        v3015_die 'live wave authority has no wave index'
    v3015_dr_live_wave_authority_is_valid "$authority_file" "$checked_epoch" \
      "$audit_sha" "$wave_index" || v3015_die 'live wave authority failed closed'
    v3015_dr_make_wave_authorization_receipt "$audit_sha" "$authority_sha" \
      "$authority_file" "$checked_epoch"
    exit 0
fi

if [[ "$mode" == reconcile ]]; then
    authorization_file=$4 authority_file=$5 result_file=$6
    after_file=${7:-}
    for input in "$authorization_file" "$authority_file" "$result_file"; do
        v3015_dr_file_is_safe "$input" || v3015_die "unsafe reconciliation input: $input"
    done
    authorization_sha=$(v3015_sha256_file "$authorization_file")
    authority_sha=$(v3015_sha256_file "$authority_file")
    result_sha=$(v3015_sha256_file "$result_file")
    checked_epoch=$(jq -er '.authority_checked_epoch' "$authorization_file") ||
        v3015_die 'wave authorization check lacks its authority observation time'
    wave_index=$(jq -er '.authorized_wave_index' "$authority_file") ||
        v3015_die 'live wave authority has no wave index'
    v3015_dr_live_wave_authority_is_valid "$authority_file" "$checked_epoch" \
      "$audit_sha" "$wave_index" || v3015_die 'historical live wave authority was invalid'
    v3015_dr_wave_authorization_receipt_is_valid "$authorization_file" "$audit_sha" \
      "$authority_sha" "$authority_file" "$checked_epoch" ||
        v3015_die 'wave authorization check does not bind the exact authority'
    result_state=$(jq -er '.state' "$result_file") || v3015_die 'wave result has no state'
    case "$result_state" in
        pass)
            [[ -n "$after_file" ]] || v3015_die 'pass result requires a bound after index'
            v3015_dr_file_is_safe "$after_file" || v3015_die 'after index is unsafe'
            after_sha=$(v3015_sha256_file "$after_file")
            v3015_dr_after_index_is_valid "$after_file" "$audit_sha" "$authority_sha" \
              "$authority_file" || v3015_die 'after receipts failed stable semantic validation'
            v3015_dr_wave_success_is_valid "$result_file" "$authorization_sha" \
              "$audit_sha" "$authority_sha" "$authority_file" "$after_sha" ||
                v3015_die 'pass result does not bind the exact wave evidence'
            v3015_dr_make_reconciliation_receipt pass "$authorization_sha" "$audit_sha" \
              "$authority_sha" "$result_sha" "$after_sha" "$result_file"
            ;;
        failed-contained)
            [[ -z "$after_file" ]] ||
                v3015_die 'failed-contained result must not smuggle a success after index'
            v3015_dr_containment_is_valid "$result_file" "$authorization_sha" \
              "$audit_sha" "$authority_sha" "$authority_file" ||
                v3015_die 'rollback containment receipt failed closed'
            v3015_dr_make_reconciliation_receipt failed-contained "$authorization_sha" \
              "$audit_sha" "$authority_sha" "$result_sha" '' "$result_file"
            ;;
        *) v3015_die 'wave result state is neither pass nor failed-contained' ;;
    esac
    exit 0
fi

rollout_authority=$4 fleet_result=$5 census=$6
for input in "$rollout_authority" "$fleet_result" "$census"; do
    v3015_dr_file_is_safe "$input" || v3015_die "unsafe terminal input: $input"
done
v3015_dr_terminal_bundle_is_valid "$audit_sha" "$rollout_authority" \
  "$fleet_result" "$census" ||
    v3015_die 'terminal deployment bundle is not semantically pause-preserved'
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg audit "$audit_sha" --arg authority "$(v3015_sha256_file "$rollout_authority")" \
  --arg result "$(v3015_sha256_file "$fleet_result")" \
  --arg census_sha "$(v3015_sha256_file "$census")" '
  {schema:1,kind:"v30.1.5-terminal-deployment-acceptance",release:"v30.1.5",
   source_sha:$source,candidate_image_ref:$image,audit_receipt_sha256:$audit,
   rollout_authority_sha256:$authority,fleet_result_sha256:$result,
   fleet_census_sha256:$census_sha,healthy_nodes:32,pos_active_nodes:32,
   regular_pow_active_nodes:31,node30_ordinary_pow_disabled:true,
   node30_free_claim_paused:true,node30_free_claim_release_accepted:false,
   pause_preserved_terminal_state:true,separate_node30_release_required:true,
   next_action_authorized:false,offline_validation_only:true}
'
