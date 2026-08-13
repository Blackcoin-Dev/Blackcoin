#!/usr/bin/env bash
# These fixture globals are consumed indirectly by sourced contract predicates;
# the single-quoted bash probes intentionally expand only in their child shell.
# shellcheck disable=SC2034,SC2016
export LC_ALL=C
set -Eeuo pipefail
umask 077

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# shellcheck disable=SC1091
source "$root/lib/common.sh"
# shellcheck disable=SC1091
source "$root/lib/typed_contract.sh"
# shellcheck disable=SC1091
source "$root/lib/node30_free_claim_release_contract.sh"

pass=0
fail=0
ok()
{
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$pass" "$1"
}
not_ok()
{
    fail=$((fail + 1))
    printf 'not ok %d - %s\n' "$((pass + fail))" "$1" >&2
}
expect_pass()
{
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}
expect_fail()
{
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then not_ok "$name"; else ok "$name"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/v3015-node30-release-tests.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
hex()
{
    local i
    for ((i=0; i<64; i++)); do
        printf '%s' "$1"
    done
}

SOURCE_SHA=$(hex a | cut -c1-40)
SOURCE_TREE=$(hex b | cut -c1-40)
SOURCE_SIGNING_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'
SOURCE_SIGNATURE_VERIFIED=1
CORE_VERSION_NUMERIC=300105
CORE_SUBVERSION='/Blackcoin:30.1.5/'
CORE_CI_RUN_ID=31710198720
CORE_CI_HEAD_SHA=$SOURCE_SHA
CORE_CI_CONCLUSION=success
CORE_CI_WORKFLOW='.github/workflows/pr-gate.yml'
CANDIDATE_ARTIFACT_NAME='blackcoin-linux-x86_64'
CANDIDATE_ARTIFACT_RUN_ID=31710198720
CANDIDATE_ARTIFACT_RUN_ATTEMPT=1
CANDIDATE_OCI_MANIFEST_SHA256=$(hex c)
CANDIDATE_IMAGE_REF="qqblackcoin/blackcoin-v4-gui@sha256:$CANDIDATE_OCI_MANIFEST_SHA256"
CANDIDATE_IMAGE_ID="sha256:$(hex d)"
CANDIDATE_BUNDLE_SHA256=$(hex e)
CANDIDATE_OCI_ARCHIVE_SHA256=$(hex f)
CANDIDATE_BLACKCOIND_SHA256=$(hex 1)
CANDIDATE_BLACKCOIN_CLI_SHA256=$(hex 2)
CANDIDATE_BLACKCOIN_QT_SHA256=$(hex 3)
CANDIDATE_BLACKCOIN_TX_SHA256=$(hex 4)
CANDIDATE_BLACKCOIN_WALLET_SHA256=$(hex 5)
CANDIDATE_BLACKCOIN_UTIL_SHA256=$(hex 6)
CANDIDATE_TOOLING_SHA256=$(hex 7)
CANDIDATE_MANIFEST_SHA256=$(hex 8)
CANDIDATE_PROVENANCE_SHA256=$(hex 9)
PACKAGE_SHA256SUMS_SHA256=$(hex a)
NODE30_PAUSE_WRAPPER_SHA256=$(hex b)
NODE30_PAUSE_MARKER_SHA256=$(hex c)
NODE30_ORIGINAL_WORKER_SHA256=$(hex d)
NODE30_QUEUE_ITEM_SHA256=$(hex e)
NODE30_AWARDED_SHA256=$(hex f)
NODE30_QUEUE_ITEM_BASENAME='20260804T152846Z-85c28632.json'
NODE30_MIN_PEERS=8
NODE30_MIN_UNLOCK_REMAINING_SECONDS=1800
NODE30_DAILY_CAP=25
NODE30_MAX_ATTEMPTS=20

queue_address='blk1sfixturequantumpayout0000000000000000000000000000000000000000000000'
NODE30_QUEUE_ADDRESS_SHA256=$(v3015_node30_sha256_text "$queue_address")
RELEASE_IDENTITY_JSON="$tmp/release-identity.json"
printf '%s\n' '{"fixture":true}' >"$RELEASE_IDENTITY_JSON"
release_identity_sha=$(v3015_sha256_file "$RELEASE_IDENTITY_JSON")

NODE30_PUBLIC_ARTIFACT_AUTHORITY="$tmp/public.json"
jq -cn --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
  --arg fingerprint "$SOURCE_SIGNING_FINGERPRINT" --argjson ci_run "$CORE_CI_RUN_ID" \
  --arg workflow "$CORE_CI_WORKFLOW" --arg artifact "$CANDIDATE_ARTIFACT_NAME" \
  --argjson artifact_run "$CANDIDATE_ARTIFACT_RUN_ID" \
  --argjson attempt "$CANDIDATE_ARTIFACT_RUN_ATTEMPT" \
  --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
  --arg bundle "$CANDIDATE_BUNDLE_SHA256" --arg archive "$CANDIDATE_OCI_ARCHIVE_SHA256" \
  --arg manifest "$CANDIDATE_OCI_MANIFEST_SHA256" \
  --arg tooling "$CANDIDATE_TOOLING_SHA256" --arg package_manifest "$CANDIDATE_MANIFEST_SHA256" \
  --arg provenance "$CANDIDATE_PROVENANCE_SHA256" \
  --arg blackcoind "$CANDIDATE_BLACKCOIND_SHA256" --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" \
  --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" \
  --arg wallet "$CANDIDATE_BLACKCOIN_WALLET_SHA256" --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" \
  --arg release_identity "$release_identity_sha" '{
    schema:1,kind:"v30.1.5-public-artifact-authority",release:"v30.1.5",
    source_sha:$source,source_tree:$tree,source_signature_verified:true,
    source_signing_fingerprint:$fingerprint,
    core_ci:{run_id:$ci_run,head_sha:$source,conclusion:"success",workflow:$workflow},
    artifact:{name:$artifact,run_id:$artifact_run,run_attempt:$attempt},
    network_version:300105,subversion:"/Blackcoin:30.1.5/",
    candidate_image_ref:$image,candidate_image_id:$image_id,
    candidate_bundle_sha256:$bundle,candidate_oci_archive_sha256:$archive,
    candidate_oci_manifest_sha256:$manifest,candidate_tooling_sha256:$tooling,
    candidate_manifest_sha256:$package_manifest,candidate_provenance_sha256:$provenance,
    binary_sha256s:{blackcoind:$blackcoind,"blackcoin-cli":$cli,"blackcoin-qt":$qt,
      "blackcoin-tx":$tx,"blackcoin-wallet":$wallet,"blackcoin-util":$util},
    release_identity_sha256:$release_identity,public_artifact_authorized:true,
    registry_digest_verified:true,authorized_utc:"2026-08-13T18:00:00Z"}' \
  >"$NODE30_PUBLIC_ARTIFACT_AUTHORITY"
NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256=$(v3015_sha256_file "$NODE30_PUBLIC_ARTIFACT_AUTHORITY")

NODE30_SUCCESSOR_SEMANTICS_RECEIPT="$tmp/semantics.json"
jq -cn --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
  --arg public "$NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256" \
  --arg worker "$NODE30_ORIGINAL_WORKER_SHA256" --arg test_receipt "$(hex 1)" '{
    schema:1,kind:"v30.1.5-node30-free-claim-successor-semantics",release:"v30.1.5",
    source_sha:$source,source_tree:$tree,public_artifact_authority_sha256:$public,
    worker_sha256:$worker,manual_send_uses_typed_gate:true,
    manual_send_and_builtin_share_family_selection:true,
    blocking_wallet_relevant_family_prevents_new_claim:true,
    pure_foreign_audit_history_ignored:true,
    retained_family_priority:["relay_existing","refresh_same_anchor",
      "wait_for_next_tip","wait_for_live"],
    retained_family_preserves_payout_anchor_lineage:true,
    authenticated_lineaged_claim_requires_recovery_fee:false,
    authenticated_lineaged_claim_requires_distinct_utxo:false,
    new_free_claim_requires_fee_input:true,normal_unlock_sufficient:true,
    ordinary_pow_required:false,node30_ordinary_pow_must_remain_disabled:true,
    new_quantum_key_required:false,witness_v16_direct_payout:true,
    worker_fee_cap_enforced:true,worker_queue_result_binds_actual_payout:true,
    product_test_receipt_sha256:$test_receipt,reviewed_utc:"2026-08-13T18:01:00Z"}' \
  >"$NODE30_SUCCESSOR_SEMANTICS_RECEIPT"
NODE30_SUCCESSOR_SEMANTICS_RECEIPT_SHA256=$(v3015_sha256_file "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT")

NODE30_FLEET_RESULT="$tmp/fleet-result.json"
printf '%s\n' '{"schema":1,"result":"passed","pause_preserved":true}' >"$NODE30_FLEET_RESULT"
NODE30_FLEET_RESULT_SHA256=$(v3015_sha256_file "$NODE30_FLEET_RESULT")
NODE30_MAINTENANCE_FINALIZATION_RECEIPT="$tmp/finalization.json"
jq -cn --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" \
  --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
  --arg package "$PACKAGE_SHA256SUMS_SHA256" --arg release_identity "$release_identity_sha" \
  --arg public "$NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256" \
  --arg semantics "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT_SHA256" \
  --arg fleet "$NODE30_FLEET_RESULT_SHA256" --arg marker "$NODE30_PAUSE_MARKER_SHA256" '{
    schema:1,kind:"v30.1.5-node30-free-claim-finalization",release:"v30.1.5",
    source_sha:$source,source_tree:$tree,candidate_image_ref:$image,
    candidate_image_id:$image_id,package_sha256sums_sha256:$package,
    release_identity_sha256:$release_identity,public_artifact_authority_sha256:$public,
    successor_semantics_receipt_sha256:$semantics,fleet_result_sha256:$fleet,
    free_claim_pause_marker_sha256:$marker,maintenance_transaction_state:"complete",
    maintenance_marker_absent:true,free_claim_pause_preserved:true,
    node30_ordinary_pow_disabled:true,node30_staking_active:true,
    fleet_healthy_nodes:32,fleet_pos_active_nodes:32,regular_pow_active_nodes:31,
    data_rewind_used:false,completed_utc:"2026-08-13T18:02:00Z"}' \
  >"$NODE30_MAINTENANCE_FINALIZATION_RECEIPT"
NODE30_MAINTENANCE_FINALIZATION_RECEIPT_SHA256=$(
  v3015_sha256_file "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT")

now=1786648000
release_nonce='11111111111111111111111111111111'
spend_nonce='22222222222222222222222222222222'
NODE30_FEE_SIGN_BROADCAST_AUTHORITY="$tmp/spend.json"
jq -cn --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg public "$NODE30_PUBLIC_ARTIFACT_AUTHORITY_SHA256" \
  --arg semantics "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT_SHA256" \
  --arg finalization "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT_SHA256" \
  --arg worker "$NODE30_ORIGINAL_WORKER_SHA256" --arg queue "$NODE30_QUEUE_ITEM_SHA256" \
  --arg payout "$NODE30_QUEUE_ADDRESS_SHA256" --arg release_nonce "$release_nonce" \
  --arg spend_nonce "$spend_nonce" --argjson before "$((now - 60))" \
  --argjson expires "$((now + 3600))" '{
    schema:1,kind:"v30.1.5-node30-fee-sign-broadcast-authority",source_sha:$source,
    candidate_image_ref:$image,node:30,public_artifact_authority_sha256:$public,
    successor_semantics_receipt_sha256:$semantics,
    finalization_receipt_sha256:$finalization,worker_sha256:$worker,
    queue_item_sha256:$queue,queue_address_sha256:$payout,
    fee_authorized:true,sign_authorized:true,broadcast_authorized:true,
    single_submission_only:true,ordinary_pow_authorized:false,recovery_authorized:false,
    repair_authorized:false,reindex_authorized:false,rewind_authorized:false,
    new_key_authorized:false,max_fee_rate:0.0001,max_total_fee:0.01,
    release_nonce:$release_nonce,spend_nonce:$spend_nonce,
    not_before_epoch:$before,expires_epoch:$expires}' >"$NODE30_FEE_SIGN_BROADCAST_AUTHORITY"
NODE30_FEE_SIGN_BROADCAST_AUTHORITY_SHA256=$(
  v3015_sha256_file "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY")
NODE30_RELEASE_CLEARED="v30.1.5-node30-free-claim-release:${SOURCE_SHA}:${release_nonce}"
NODE30_FEE_SIGN_BROADCAST_CLEARED="v30.1.5-node30-fee-sign-broadcast:${SOURCE_SHA}:${spend_nonce}"

expect_pass 'public artifact authority accepts one exact public successor' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY"
expect_pass 'successor semantics accepts exact Free-Claim product boundary' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT"
expect_pass 'finalization accepts completed maintenance with pause preserved' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT"
expect_pass 'fee/sign/broadcast authority accepts bounded explicit spend authority' \
  v3015_node30_fee_sign_broadcast_authority_is_valid \
    "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" "$now"
expect_pass 'combined authorities accept exact cross-bound identities' \
  v3015_node30_authorities_are_valid "$now"
expect_pass 'two independent explicit confirmation strings are accepted' \
  v3015_node30_release_confirmations_are_valid

mutate_fail()
{
    local name=$1 function_name=$2 source_file=$3 filter=$4 bad="$tmp/bad.json"
    jq "$filter" "$source_file" >"$bad"
    expect_fail "$name" "$function_name" "$bad"
}
fee_file_valid()
{
    v3015_node30_fee_sign_broadcast_authority_is_valid "$1" "$now"
}

mutate_fail 'public authority rejects wrong source' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.source_sha="0"'
mutate_fail 'public authority rejects non-success CI' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.core_ci.conclusion="failure"'
mutate_fail 'public authority rejects wrong CI head' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.core_ci.head_sha="0"'
mutate_fail 'public authority rejects an unverified source signature' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.source_signature_verified=false'
mutate_fail 'public authority rejects mutable image reference' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.candidate_image_ref="tag:latest"'
mutate_fail 'public authority rejects OCI/reference digest mismatch' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.candidate_oci_manifest_sha256=("0"*64)'
mutate_fail 'public authority rejects unverified registry digest' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.registry_digest_verified=false'
mutate_fail 'public authority rejects publication not authorized' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.public_artifact_authorized=false'
mutate_fail 'public authority rejects wrong release-identity binding' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.release_identity_sha256=("0"*64)'
mutate_fail 'public authority rejects an extra key' \
  v3015_node30_public_artifact_authority_is_valid "$NODE30_PUBLIC_ARTIFACT_AUTHORITY" '.extra=true'

mutate_fail 'semantics rejects manual/builtin family-selection divergence' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.manual_send_and_builtin_share_family_selection=false'
mutate_fail 'semantics rejects foreign audit rows as mining authority' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.pure_foreign_audit_history_ignored=false'
mutate_fail 'semantics rejects changed retained-family priority' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.retained_family_priority |= reverse'
mutate_fail 'semantics rejects recovery fee for lineaged claims' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.authenticated_lineaged_claim_requires_recovery_fee=true'
mutate_fail 'semantics rejects distinct UTXO for lineaged claims' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.authenticated_lineaged_claim_requires_distinct_utxo=true'
mutate_fail 'semantics rejects node30 ordinary PoW requirement' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.ordinary_pow_required=true'
mutate_fail 'semantics rejects automatic quantum-key requirement' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.new_quantum_key_required=true'
mutate_fail 'semantics rejects missing worker fee cap' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.worker_fee_cap_enforced=false'
mutate_fail 'semantics rejects unbound queue result' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.worker_queue_result_binds_actual_payout=false'
mutate_fail 'semantics rejects wrong worker identity' \
  v3015_node30_successor_semantics_is_valid "$NODE30_SUCCESSOR_SEMANTICS_RECEIPT" '.worker_sha256=("0"*64)'

mutate_fail 'finalization rejects active maintenance' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.maintenance_marker_absent=false'
mutate_fail 'finalization rejects lost Free-Claim pause' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.free_claim_pause_preserved=false'
mutate_fail 'finalization rejects node30 ordinary PoW' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.node30_ordinary_pow_disabled=false'
mutate_fail 'finalization rejects node30 PoS loss' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.node30_staking_active=false'
mutate_fail 'finalization rejects incomplete fleet' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.fleet_healthy_nodes=31'
mutate_fail 'finalization rejects data rewind' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.data_rewind_used=true'
mutate_fail 'finalization rejects wrong fleet-result identity' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.fleet_result_sha256=("0"*64)'
mutate_fail 'finalization rejects wrong pause-marker identity' \
  v3015_node30_finalization_is_valid "$NODE30_MAINTENANCE_FINALIZATION_RECEIPT" '.free_claim_pause_marker_sha256=("0"*64)'

mutate_fail 'spend authority rejects fee denial' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.fee_authorized=false'
mutate_fail 'spend authority rejects signing denial' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.sign_authorized=false'
mutate_fail 'spend authority rejects broadcast denial' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.broadcast_authorized=false'
mutate_fail 'spend authority rejects ordinary PoW authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.ordinary_pow_authorized=true'
mutate_fail 'spend authority rejects recovery authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.recovery_authorized=true'
mutate_fail 'spend authority rejects repair authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.repair_authorized=true'
mutate_fail 'spend authority rejects reindex authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.reindex_authorized=true'
mutate_fail 'spend authority rejects rewind authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.rewind_authorized=true'
mutate_fail 'spend authority rejects new-key authority' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.new_key_authorized=true'
mutate_fail 'spend authority rejects unbounded fee rate' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.max_fee_rate=0'
mutate_fail 'spend authority rejects unbounded total fee' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.max_total_fee=0'
mutate_fail 'spend authority rejects repeated nonce' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.spend_nonce=.release_nonce'
mutate_fail 'spend authority rejects wrong queue item' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.queue_item_sha256=("0"*64)'
mutate_fail 'spend authority rejects wrong private payout identity' fee_file_valid \
  "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" '.queue_address_sha256=("0"*64)'
expect_fail 'spend authority rejects not-yet-valid receipt' \
  v3015_node30_fee_sign_broadcast_authority_is_valid \
    "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" "$((now - 120))"
expect_fail 'spend authority rejects expired receipt' \
  v3015_node30_fee_sign_broadcast_authority_is_valid \
    "$NODE30_FEE_SIGN_BROADCAST_AUTHORITY" "$((now + 7200))"

saved_confirmation=$NODE30_RELEASE_CLEARED
NODE30_RELEASE_CLEARED='wrong'
expect_fail 'release rejects wrong release confirmation' \
  v3015_node30_release_confirmations_are_valid
NODE30_RELEASE_CLEARED=$saved_confirmation
saved_confirmation=$NODE30_FEE_SIGN_BROADCAST_CLEARED
NODE30_FEE_SIGN_BROADCAST_CLEARED='wrong'
expect_fail 'release rejects wrong spend confirmation' \
  v3015_node30_release_confirmations_are_valid
NODE30_FEE_SIGN_BROADCAST_CLEARED=$saved_confirmation

tip=$(hex c)
zero=$(hex 0)
target_txid=$(hex a)
target_script="76a914$(printf '1%.0s' {1..40})88ac"
witness_program=$(printf '2%.0s' {1..64})
payout_script="6020${witness_program}"

make_recovery()
{
    jq -cn --arg tip "$tip" '{
      active_height:1000,active_tip:$tip,actionable_quarantined_claims:0,
      automatic_actions_in_window:0,automatic_fee_exposure_in_window:0,
      blocking_components:0,blocking_quarantined_claims:0,chain_ready:true,
      claims_recycled:0,component_details:[],components:0,
      confirmed_automatic_resolutions:0,confirmed_manual_resolutions:0,
      confirmed_resolution_fees:0,database_outcome_ambiguous:false,
      indeterminate_quarantined_claims:0,live_claim_objects:0,
      policy:{aggregate_batch_fee_cap:0,automatic_authorized:false,
        automatic_enabled:false,choice_recorded:false,max_actions_per_window:0,
        max_fee_per_resolution:0,minimum_stale_blocks:0,mode:"unset",
        rolling_fee_budget:0,rolling_fee_window_seconds:0,version:1},
      pending_automatic_resolutions:0,pending_manual_resolutions:0,
      policy_authoritative:true,policy_state_detail:"fixture",policy_state_status:"success",
      quarantined_claim_objects:0,raw_claim_objects:0,raw_quarantined_claims:0,
      reconciled_descendant_claims:0,resolved_components:0,
      resolved_on_active_chain_claims:0,retired_claim_objects:0,retired_components:0,
      unanchored_claim_txids:[],wallet_generation:10,
      wallet_processed_height:1000,wallet_processed_tip:$tip,wallet_tip_matches:true}'
}

make_pow()
{
    jq -cn --arg tip "$tip" --arg zero "$zero" --arg fingerprint "$(hex d)" '{
      actionable_quarantined_claims:0,allow_automatic_quantum_key_creation:false,
      autostart:false,blocking_quarantined_claims:0,claim_coins_after_stake_reserve:99,
      claim_inventory_tip:$tip,claim_inventory_wallet_tip_matches:true,
      claim_recovery_database_outcome_ambiguous:false,claims_submitted:0,
      current_height:1000,enabled:false,hashrate:0,live_claims:0,
      mining_gate_action:"create_new_anchor",mining_gate_can_submit:true,
      mining_gate_candidate_state_fingerprint:$fingerprint,mining_gate_coherent:true,
      mining_gate_database_ambiguous:false,mining_gate_eligible_claims:0,
      mining_gate_family_claims:0,mining_gate_lineage_head_txid:$zero,
      mining_gate_live_claims:0,mining_gate_relay_txid:$zero,
      mining_gate_unresolved_components:0,mining_gate_unsafe_claims:0,
      mining_gate_unsafe_components:0,pending_automatic_resolutions:0,
      pending_manual_resolutions:0,state:"disabled"}'
}

make_pos()
{
    jq -cn '{enabled:true,staking:true,worker_running:true,eligible:true,
      staking_state:"searching",weight:1000,autostart_staking:true,
      autostart_staking_source:"autostartstaking",staking_snapshot_current:true,
      staking_snapshot_sequence:1,blocks:1000,active_blocks:1000,weight_cached:true,
      allow_automatic_quantum_key_creation:false}'
}

recovery=$(make_recovery)
pow=$(make_pow)
staking=$(make_pos)
snapshot="$tmp/snapshot.json"
jq -cn --arg tip "$tip" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg image_id "$CANDIDATE_IMAGE_ID" --arg blackcoind "$CANDIDATE_BLACKCOIND_SHA256" \
  --arg cli "$CANDIDATE_BLACKCOIN_CLI_SHA256" --arg qt "$CANDIDATE_BLACKCOIN_QT_SHA256" \
  --arg tx "$CANDIDATE_BLACKCOIN_TX_SHA256" --arg wallet_bin "$CANDIDATE_BLACKCOIN_WALLET_SHA256" \
  --arg util "$CANDIDATE_BLACKCOIN_UTIL_SHA256" --arg target_txid "$target_txid" \
  --arg target_script "$target_script" --arg queue_address "$queue_address" \
  --arg payout_script "$payout_script" --arg witness "$witness_program" \
  --arg queue_sha "$NODE30_QUEUE_ITEM_SHA256" --arg payout_sha "$NODE30_QUEUE_ADDRESS_SHA256" \
  --arg awarded_sha "$NODE30_AWARDED_SHA256" --arg queue_name "$NODE30_QUEUE_ITEM_BASENAME" \
  --argjson recovery "$recovery" --argjson pow "$pow" --argjson staking "$staking" \
  --argjson captured "$now" --argjson locks "$(v3015_node30_lock_paths_json)" '{
    schema:1,captured_epoch:$captured,
    before_chain:{chain:"main",blocks:1000,headers:1000,bestblockhash:$tip,
      initialblockdownload:false,verificationprogress:0.9999999},
    after_chain:{chain:"main",blocks:1000,headers:1000,bestblockhash:$tip,
      initialblockdownload:false,verificationprogress:0.9999999},
    network:{version:300105,subversion:"/Blackcoin:30.1.5/",networkactive:true,
      connections:32},
    wallets:[""],wallet:{walletname:"",unlocked_until:($captured+3600),
      unlocked_staking_only:false,private_keys_enabled:true,scanning:false,
      paytxfee:0.00001,lastprocessedblock:{hash:$tip,height:1000}},
    staking:$staking,pow:$pow,recovery:$recovery,
    selected_utxo:{txid:$target_txid,vout:0,address:"BfixtureLegacyTarget",
      scriptPubKey:$target_script,amount:2,spendable:true,safe:true,
      spendability_state:"spendable_legacy"},
    selected_coin_before:{value:2,scriptPubKey:$target_script},
    selected_coin_after:{value:2,scriptPubKey:$target_script},
    target_address_info:{address:"BfixtureLegacyTarget",ismine:true,iswatchonly:false,
      solvable:true,scriptPubKey:$target_script},
    queue:{basename:$queue_name,sha256:$queue_sha,address_sha256:$payout_sha,
      awarded_sha256:$awarded_sha,files_count:1,other_entries:0,nonregular_entries:0,
      address_already_awarded:false,sponsorships_today:0,daily_cap:25,
      record:{quantum_address:$queue_address,ip:"fixture",submitted:"2026-08-04T15:28:46+00:00",
        attempts:3}},
    address_info:{address:$queue_address,isvalid:true,iswitness:true,witness_version:16,
      witness_program:$witness,scriptPubKey:$payout_script,ismine:false,iswatchonly:false},
    work:{active:true,height:1001,prevhash:$tip,target_bits:10,prefix:"QQSPROOF",
      proof_mode:"pow",proof_mode_byte:0,proof_version:2,claim_outpoint_required:false,
      qqp4_activation_disabled:true,qqp4_activation_height:0,qqp4_active_next_block:false,
      reward_start_height:1,reward_end_height:2000,target_script:$target_script,
      quantum_address:$queue_address,quantum_payout_script:$payout_script,
      claim_txid:null,claim_vout:null},
    goldrush:{active:true,height:1000,pow_jackpot:100,pow_amount:10000000000,
      competing_claim_rule_active_next_block:false,blocks_until_competing_claim_rule:100,
      qqp4_activation_disabled:true,qqp4_activation_height:0,qqp4_active_next_block:false},
    broadcast_count:0,
    container:{name:"blackcoin-v4-gui-30",image_ref:$image,image_id:$image_id,
      running:true,paused:false,restarting:false,dead:false,health:"healthy"},
    binary_sha256s:{blackcoind:$blackcoind,"blackcoin-cli":$cli,"blackcoin-qt":$qt,
      "blackcoin-tx":$tx,"blackcoin-wallet":$wallet_bin,"blackcoin-util":$util},
    lock_paths:$locks}' >"$snapshot"

expect_pass 'runtime preflight accepts exact stable node30 snapshot' \
  v3015_node30_runtime_snapshot_is_valid "$snapshot"
receipt=$(v3015_node30_make_safe_audit_receipt "$snapshot")
expect_pass 'safe audit receipt binds release readiness without raw identity' \
  jq -e '.release_ready == true and .ordinary_pow_enabled == false and
    .blocking_wallet_relevant_families == 0 and .witness_version == 16 and
    .marker_preserved == true and .raw_transaction_exposed == false and
    .payout_address_exposed == false' <<<"$receipt"
expect_fail 'safe audit receipt does not expose the payout address' grep -Fq "$queue_address" <<<"$receipt"
expect_fail 'safe audit receipt does not expose the legacy target address' grep -Fq 'BfixtureLegacyTarget' <<<"$receipt"

snapshot_fail()
{
    local name=$1 filter=$2 bad="$tmp/bad-snapshot.json"
    jq "$filter" "$snapshot" >"$bad"
    expect_fail "$name" v3015_node30_runtime_snapshot_is_valid "$bad"
}

snapshot_fail 'snapshot rejects unstable chain bracket' '.after_chain.bestblockhash=("f"*64)'
snapshot_fail 'snapshot rejects non-main chain' '.before_chain.chain="test" | .after_chain.chain="test"'
snapshot_fail 'snapshot rejects IBD' '.before_chain.initialblockdownload=true | .after_chain.initialblockdownload=true'
snapshot_fail 'snapshot rejects incomplete header sync' '.before_chain.headers=1001 | .after_chain.headers=1001'
snapshot_fail 'snapshot rejects low verification progress' '.before_chain.verificationprogress=.9 | .after_chain.verificationprogress=.9'
snapshot_fail 'snapshot rejects wrong network version' '.network.version=300104'
snapshot_fail 'snapshot rejects wrong subversion' '.network.subversion="/Blackcoin:30.1.4/"'
snapshot_fail 'snapshot rejects inactive network' '.network.networkactive=false'
snapshot_fail 'snapshot rejects too few peers' '.network.connections=7'
snapshot_fail 'snapshot rejects stopped container' '.container.running=false'
snapshot_fail 'snapshot rejects unhealthy container' '.container.health="unhealthy"'
snapshot_fail 'snapshot rejects mutable image reference' '.container.image_ref="tag:latest"'
snapshot_fail 'snapshot rejects wrong image ID' '.container.image_id="sha256:bad"'
snapshot_fail 'snapshot rejects changed CLI binary' '.binary_sha256s["blackcoin-cli"]=("0"*64)'
snapshot_fail 'snapshot rejects zero loaded wallets' '.wallets=[]'
snapshot_fail 'snapshot rejects two loaded wallets' '.wallets=["","other"]'
snapshot_fail 'snapshot rejects wallet-name mismatch' '.wallet.walletname="other"'
snapshot_fail 'snapshot rejects staking-only unlock' '.wallet.unlocked_staking_only=true'
snapshot_fail 'snapshot rejects short unlock horizon' ".wallet.unlocked_until=($now+10)"
snapshot_fail 'snapshot rejects active wallet scan' '.wallet.scanning={duration:1}'
snapshot_fail 'snapshot rejects stale wallet tip' '.wallet.lastprocessedblock.height=999'
snapshot_fail 'snapshot rejects inactive PoS' '.staking.staking=false'
snapshot_fail 'snapshot rejects node30 ordinary PoW enabled' '.pow.enabled=true'
snapshot_fail 'snapshot rejects node30 ordinary PoW hashrate' '.pow.hashrate=1'
snapshot_fail 'snapshot rejects node30 ordinary PoW autostart' '.pow.autostart=true'
snapshot_fail 'snapshot rejects automatic key creation' '.pow.allow_automatic_quantum_key_creation=true'
snapshot_fail 'snapshot rejects unsafe typed family' '.pow.mining_gate_unsafe_components=1'
snapshot_fail 'snapshot rejects unresolved retained family' '.pow.mining_gate_unresolved_components=1'
snapshot_fail 'snapshot rejects relay instead of new-anchor readiness' '.pow.mining_gate_action="relay_existing"'
snapshot_fail 'snapshot rejects non-submit gate' '.pow.mining_gate_can_submit=false'
snapshot_fail 'snapshot rejects stale claim inventory tip' '.pow.claim_inventory_tip=("f"*64)'
snapshot_fail 'snapshot rejects pending manual recovery' '.recovery.pending_manual_resolutions=1'
snapshot_fail 'snapshot rejects automatic recovery authority' '.recovery.policy.automatic_authorized=true'
snapshot_fail 'snapshot rejects unsafe legacy UTXO' '.selected_utxo.safe=false'
snapshot_fail 'snapshot rejects nonlegacy fee UTXO' '.selected_utxo.spendability_state="quantum"'
snapshot_fail 'snapshot rejects spent fee UTXO' '.selected_coin_after=null'
snapshot_fail 'snapshot rejects fee UTXO value drift' '.selected_coin_after.value=1'
snapshot_fail 'snapshot rejects non-owned fee target' '.target_address_info.ismine=false'
snapshot_fail 'snapshot rejects two queue files' '.queue.files_count=2'
snapshot_fail 'snapshot rejects queue side entry' '.queue.other_entries=1'
snapshot_fail 'snapshot rejects queue symlink entry' '.queue.nonregular_entries=1'
snapshot_fail 'snapshot rejects changed queue bytes' '.queue.sha256=("0"*64)'
snapshot_fail 'snapshot rejects changed private payout identity' '.queue.address_sha256=("0"*64)'
snapshot_fail 'snapshot rejects previously awarded payout' '.queue.address_already_awarded=true'
snapshot_fail 'snapshot rejects exhausted queue attempts' '.queue.record.attempts=20'
snapshot_fail 'snapshot rejects reached daily cap' '.queue.sponsorships_today=25'
snapshot_fail 'snapshot rejects in-flight broadcast record' '.broadcast_count=1'
snapshot_fail 'snapshot rejects invalid payout address' '.address_info.isvalid=false'
snapshot_fail 'snapshot rejects non-witness payout' '.address_info.iswitness=false'
snapshot_fail 'snapshot rejects non-v16 payout' '.address_info.witness_version=15'
snapshot_fail 'snapshot rejects malformed v16 program' '.address_info.witness_program="00"'
snapshot_fail 'snapshot rejects node30-owned sponsored payout' '.address_info.ismine=true'
snapshot_fail 'snapshot rejects inactive Gold Rush' '.goldrush.active=false'
snapshot_fail 'snapshot rejects stale Gold Rush height' '.goldrush.height=999'
snapshot_fail 'snapshot rejects zero PoW payout' '.goldrush.pow_amount=0'
snapshot_fail 'snapshot rejects stale work tip' '.work.prevhash=("f"*64)'
snapshot_fail 'snapshot rejects wrong work height' '.work.height=1000'
snapshot_fail 'snapshot rejects wrong proof mode' '.work.proof_mode="pos"'
snapshot_fail 'snapshot rejects payout-script substitution' '.work.quantum_payout_script="6020"+("3"*64)'
snapshot_fail 'snapshot rejects target-script substitution' '.work.target_script="51"'
snapshot_fail 'snapshot rejects unexpected QQP4 outpoint in QQP2' '.work.claim_txid=.selected_utxo.txid | .work.claim_vout=0'
snapshot_fail 'snapshot rejects missing required lock' '.lock_paths |= .[:-1]'
snapshot_fail 'snapshot rejects reordered lock acquisition' '.lock_paths |= reverse'
snapshot_fail 'snapshot rejects extra outer evidence field' '.unexpected=true'

# A purely foreign, unauthenticated audit row may remain in verbose recovery;
# it cannot become mining authority or block a new queue claim.
foreign_claim=$(hex f)
foreign_family=$(hex e)
foreign_recovery=$(jq -cn --argjson r "$recovery" --arg claim "$foreign_claim" \
  --arg family "$foreign_family" --arg zero "$zero" --arg tip "$tip" '
  $r | .blocking_components=1 | .blocking_quarantined_claims=1 |
  .indeterminate_quarantined_claims=1 | .components=1 | .raw_claim_objects=1 |
  .quarantined_claim_objects=1 | .raw_quarantined_claims=1 |
  .unanchored_claim_txids=[$claim] |
  .component_details=[{all_claims_expired_locally_retired:false,
    all_claims_explicitly_provenanced:false,all_claims_quarantined:true,
    all_claims_zero_payment_retirable:false,
    anchor:{amount:0,scriptPubKey:"",txid:("b"*64),vout:0},
    anchor_authenticated:false,anchor_unspent:false,anchor_user_locked:false,
    claim_txids:[$claim],classification:"indeterminate",component_fingerprint:$family,
    descendant_claims:0,generation_fingerprint:$family,
    has_revalidating_unbound_proof:false,minimum_stale_depth:1,
    nodes:[{abandoned:false,active_chain_confirmed:false,authored_metadata_valid:false,
      authored_tip_active_branch_bound:false,claim_descriptor_valid:true,
      disposition:"foreign-audit",exact_authored_carrier_shape:true,expected_shape:true,
      expired_locally_retired:false,in_mempool:false,kind:"claim",
      lineage_family_fingerprint:$family,lineage_metadata_present:false,
      lineage_metadata_valid:false,lineage_ordinal:0,lineage_parent_txid:$zero,
      lineage_root_txid:$zero,proof_evaluation_skipped_resolved_anchor:false,
      proof_input_bound:false,proof_may_revalidate_on_descendant:false,proof_mode:"unknown",
      proof_origin_bound:false,proof_origin_height:-1,
      proof_origin_previous_block_hash:$zero,proof_version:0,provenance:"unknown",
      quarantined:true,relay_expiry_time:0,relay_ttl_expired:false,
      resolution_metadata_valid:false,resolution_relay_authorized:false,
      stale_depth:1,stale_depth_known:true,txid:$claim,wallet_authored:false,
      wallet_from_me:false}],ordinary_or_mixed_txids:[],resolution_txids:[],
    root_claim_txids:[$claim],stale_depth_known:true}]')
foreign_snapshot="$tmp/foreign-snapshot.json"
jq --argjson recovery "$foreign_recovery" '.recovery=$recovery' "$snapshot" >"$foreign_snapshot"
expect_pass 'runtime preflight ignores one exact purely foreign audit-only blocker' \
  v3015_node30_runtime_snapshot_is_valid "$foreign_snapshot"
wallet_relevant_snapshot="$tmp/wallet-relevant-snapshot.json"
jq '.recovery.component_details[0].anchor_authenticated=true |
  .recovery.component_details[0].anchor.amount=1 |
  .recovery.component_details[0].anchor.scriptPubKey="51" |
  .recovery.component_details[0].nodes[0].wallet_authored=true |
  .recovery.component_details[0].nodes[0].wallet_from_me=true |
  .recovery.component_details[0].nodes[0].provenance="explicit_authored"' \
  "$foreign_snapshot" >"$wallet_relevant_snapshot"
expect_fail 'runtime preflight refuses a wallet-relevant blocking retained family' \
  v3015_node30_runtime_snapshot_is_valid "$wallet_relevant_snapshot"

marker_dir="$tmp/marker-dir"
archive_dir="$tmp/archive-dir"
mkdir -p "$marker_dir" "$archive_dir"
marker="$marker_dir/pause"
archive="$archive_dir/pause.released"
printf '%s\n' "$V3015_NODE30_EXPECTED_PAUSE_CONTENT" >"$marker"
marker_sha=$(v3015_sha256_file "$marker")
marker_mockbin="$tmp/marker-mockbin"
mkdir -p "$marker_mockbin"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "$1" == -c && "$2" == "%d" && "$3" == -- ]] || exit 90' \
  'printf "1\\n"' >"$marker_mockbin/stat"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "$1" == -T && "$2" == -- ]] || exit 90' \
  'exec /bin/mv -- "$3" "$4"' >"$marker_mockbin/mv"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$marker_mockbin/sync"
chmod 0755 "$marker_mockbin/stat" "$marker_mockbin/mv" "$marker_mockbin/sync"
expect_pass 'marker release atomically archives rather than deletes exact bytes' \
  env PATH="$marker_mockbin:$PATH" bash -c \
    'source "$1/lib/common.sh"; source "$1/lib/node30_free_claim_release_contract.sh";
     v3015_node30_archive_pause_marker "$2" "$3" "$4"' \
    bash "$root" "$marker" "$archive" "$marker_sha"
expect_pass 'marker archive leaves original path absent and archive exact' \
  bash -c '[[ ! -e "$1" && -f "$2" && "$(sha256sum "$2" | awk '\''{print $1}'\'')" == "$3" ]]' \
    bash "$marker" "$archive" "$marker_sha"
expect_pass 'fail-closed restoration atomically restores exact marker bytes' \
  env PATH="$marker_mockbin:$PATH" bash -c \
    'source "$1/lib/common.sh"; source "$1/lib/node30_free_claim_release_contract.sh";
     v3015_node30_restore_pause_marker "$2" "$3" "$4"' \
    bash "$root" "$archive" "$marker" "$marker_sha"
expect_pass 'restored marker leaves archive absent' \
  bash -c '[[ -f "$1" && ! -e "$2" ]]' bash "$marker" "$archive"
expect_fail 'marker archive rejects wrong expected identity' \
  env PATH="$marker_mockbin:$PATH" bash -c \
    'source "$1/lib/common.sh"; source "$1/lib/node30_free_claim_release_contract.sh";
     v3015_node30_archive_pause_marker "$2" "$3" "$4"' \
    bash "$root" "$marker" "$archive" "$(hex 0)"
printf 'occupied\n' >"$archive"
expect_fail 'marker archive refuses to overwrite prior evidence' \
  env PATH="$marker_mockbin:$PATH" bash -c \
    'source "$1/lib/common.sh"; source "$1/lib/node30_free_claim_release_contract.sh";
     v3015_node30_archive_pause_marker "$2" "$3" "$4"' \
    bash "$root" "$marker" "$archive" "$marker_sha"
rm -f "$archive"
ln -s "$marker" "$archive"
expect_fail 'marker archive refuses a linked evidence destination' \
  env PATH="$marker_mockbin:$PATH" bash -c \
    'source "$1/lib/common.sh"; source "$1/lib/node30_free_claim_release_contract.sh";
     v3015_node30_archive_pause_marker "$2" "$3" "$4"' \
    bash "$root" "$marker" "$archive" "$marker_sha"
rm -f "$archive"

expect_pass 'release script defaults to audit mode' \
  grep -Eq '^mode=audit$' "$root/node30_free_claim_release.sh"
expect_pass 'release script never invokes a mutating wallet RPC' \
  bash -c '! grep -Eq "node30_rpc[^\n]*(sendshadowpowclaim|sendrawtransaction|walletpassphrase|setpowmining|setpowclaimrecovery|resolveallshadowpowclaims|createshadowpowclaimresolution|commitshadowpowclaimresolution|abandontransaction|getnewaddress|getnewquantumaddress|createquantumkey)" "$1"' \
    bash "$root/node30_free_claim_release.sh"
expect_pass 'release script never restarts or recreates node30' \
  bash -c '! grep -Eq "docker[[:space:]]+(restart|start|stop|rm|compose)" "$1"' \
    bash "$root/node30_free_claim_release.sh"
expect_pass 'release script delegates marker transition to archive primitive' \
  grep -Fq 'v3015_node30_archive_pause_marker' "$root/node30_free_claim_release.sh"
expect_pass 'release script has no direct pause-marker deletion' \
  bash -c '! grep -Eq "rm[^\n]*NODE30_PAUSE_MARKER" "$1"' \
    bash "$root/node30_free_claim_release.sh"
expect_pass 'release contract contains exactly seven ordered fleet/worker locks' \
  bash -c 'source "$1/lib/common.sh"; source "$1/lib/typed_contract.sh"; source "$1/lib/node30_free_claim_release_contract.sh"; [[ ${#V3015_NODE30_EXPECTED_LOCKS[@]} -eq 7 ]]' \
    bash "$root"
expect_pass 'release path explicitly preserves node30 ordinary-PoW disabled' \
  grep -Fq 'ordinary_pow_enabled:false' "$root/node30_free_claim_release.sh"
expect_pass 'release path records that it invokes no worker or broadcast' \
  grep -Fq 'worker_invoked_by_release_tool:false,broadcast_invoked_by_release_tool:false' \
    "$root/node30_free_claim_release.sh"
expect_pass 'cleanup clears signal/exit traps before fail-closed marker restoration' \
  grep -Fq 'trap - EXIT HUP INT TERM' "$root/node30_free_claim_release.sh"
expect_pass 'release evidence preserves the bound fleet result and release identity' \
  bash -c 'grep -Fq "FLEET-RESULT.json" "$1" &&
    grep -Fq "RELEASE-IDENTITY.json" "$1"' bash "$root/node30_free_claim_release.sh"
expect_pass 'release environment keeps public artifact authority unresolved' \
  grep -Fq "NODE30_PUBLIC_ARTIFACT_AUTHORITY='__" "$root/rollout.env.example"
expect_pass 'release environment keeps fee/sign/broadcast authority unresolved' \
  grep -Fq "NODE30_FEE_SIGN_BROADCAST_AUTHORITY='__" "$root/rollout.env.example"
expect_pass 'release environment keeps both explicit confirmations unresolved' \
  bash -c 'grep -Fq "NODE30_RELEASE_CLEARED='\''__" "$1" && grep -Fq "NODE30_FEE_SIGN_BROADCAST_CLEARED='\''__" "$1"' \
    bash "$root/rollout.env.example"

total=$((pass + fail))
if ((fail != 0)); then
    printf 'FAIL: %d/%d node30 Free-Claim hostile assertions failed\n' "$fail" "$total" >&2
    exit 1
fi
printf 'PASS: %d node30 Free-Claim hostile assertions\n' "$total"
