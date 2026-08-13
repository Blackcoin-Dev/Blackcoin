#!/usr/bin/env bash
# Fixture globals are consumed indirectly by sourced predicates. Single-quoted
# static probes intentionally expand only inside their child shell.
# shellcheck disable=SC2034,SC2016
export LC_ALL=C
set -Eeuo pipefail
umask 077

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# shellcheck disable=SC1091
source "$root/lib/common.sh"
# shellcheck disable=SC1091
source "$root/lib/deployment_rollback_readiness_contract.sh"

pass=0 fail=0
ok() { pass=$((pass+1)); printf 'ok %d - %s\n' "$pass" "$1"; }
not_ok() { fail=$((fail+1)); printf 'not ok %d - %s\n' "$((pass+fail))" "$1" >&2; }
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
mutate_fail()
{
    local name=$1 function=$2 source=$3 filter=$4 bad="$tmp/bad.json"
    jq "$filter" "$source" >"$bad"
    expect_fail "$name" "$function" "$bad"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/v3015-dr-hostile.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
export V3015_DR_FIXTURE=1
hex()
{
    local c=$1 i
    for ((i=0; i<64; i++)); do printf '%s' "$c"; done
}
git40() { hex "$1" | cut -c1-40; }
sha_file() { v3015_sha256_file "$1"; }

DR_SOURCE_SHA=$(git40 a)
DR_SOURCE_TREE=$(git40 b)
DR_MERGE_SHA=$(git40 c)
DR_MERGE_TREE=$DR_SOURCE_TREE
DR_CANDIDATE_OCI_MANIFEST_SHA256=$(hex d)
DR_CANDIDATE_IMAGE_REF="qqblackcoin/blackcoin-v4-gui@sha256:$DR_CANDIDATE_OCI_MANIFEST_SHA256"
DR_CANDIDATE_IMAGE_ID="sha256:$(hex e)"
DR_CANDIDATE_BUNDLE_SHA256=$(hex f)
DR_CANDIDATE_OCI_ARCHIVE_SHA256=$(hex 1)
DR_CANDIDATE_BLACKCOIND_SHA256=$(hex 2)
DR_CANDIDATE_BLACKCOIN_CLI_SHA256=$(hex 3)
DR_CANDIDATE_BLACKCOIN_QT_SHA256=$(hex 4)
DR_CANDIDATE_BLACKCOIN_TX_SHA256=$(hex 5)
DR_CANDIDATE_BLACKCOIN_WALLET_SHA256=$(hex 6)
DR_CANDIDATE_BLACKCOIN_UTIL_SHA256=$(hex 7)
DR_INSTALLED_V3014_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:v30.1.4-installed'
DR_INSTALLED_V3014_IMAGE_ID="sha256:$(hex 8)"
DR_INSTALLED_V3014_BLACKCOIND_SHA256=$(hex 9)
DR_INSTALLED_V3014_BLACKCOIN_CLI_SHA256=$(hex a)
DR_INSTALLED_V3014_BLACKCOIN_QT_SHA256=$(hex b)
DR_INSTALLED_V3014_BLACKCOIN_TX_SHA256=$(hex c)
DR_INSTALLED_V3014_BLACKCOIN_WALLET_SHA256=$(hex d)
DR_INSTALLED_V3014_BLACKCOIN_UTIL_SHA256=$(hex e)
DR_FLEET_INTEGRATION_COMMIT=$(git40 f)
DR_FLEET_INTEGRATION_TREE=$(git40 1)
DR_PACKAGE_SHA256SUMS_SHA256=$(hex 2)
DR_MIN_PEERS=8

DR_TOPOLOGY_MAP="$tmp/topology.map"
cp "$root/topology.map" "$DR_TOPOLOGY_MAP"
DR_TOPOLOGY_SHA256=$(sha_file "$DR_TOPOLOGY_MAP")
DR_WAVES_PLAN="$tmp/waves.txt"
cp "$root/waves.txt" "$DR_WAVES_PLAN"
DR_WAVES_SHA256=$(sha_file "$DR_WAVES_PLAN")

candidate_bins=$(v3015_dr_binary_json candidate)
installed_bins=$(v3015_dr_binary_json installed)
DR_PUBLIC_ARTIFACT_RECEIPT="$tmp/public.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg tree "$DR_SOURCE_TREE" \
  --arg merge "$DR_MERGE_SHA" --arg fingerprint "$V3015_DR_SIGNING_FINGERPRINT" \
  --arg image "$DR_CANDIDATE_IMAGE_REF" --arg image_id "$DR_CANDIDATE_IMAGE_ID" \
  --arg manifest "$DR_CANDIDATE_OCI_MANIFEST_SHA256" \
  --arg bundle "$DR_CANDIDATE_BUNDLE_SHA256" --arg archive "$DR_CANDIDATE_OCI_ARCHIVE_SHA256" \
  --argjson bins "$candidate_bins" --arg api "$(hex 3)" '{
    schema:1,kind:"v30.1.5-public-artifact-completion",release:"v30.1.5",
    source_sha:$source,source_tree:$tree,source_signature_verified:true,
    source_signing_fingerprint:$fingerprint,merge_commit:$merge,merge_tree:$tree,
    merge_signature_verified:true,
    ci:{run_id:31710198720,head_sha:$source,conclusion:"success",
      workflow:".github/workflows/pr-gate.yml",required_green:16,total_required:16},
    artifact:{name:"blackcoin-linux-x86_64",run_id:31710198720,run_attempt:1,
      api_sha256:$api},candidate_image_ref:$image,candidate_image_id:$image_id,
    candidate_bundle_sha256:$bundle,candidate_oci_archive_sha256:$archive,
    candidate_oci_manifest_sha256:$manifest,binary_sha256s:$bins,
    registry_digest_verified:true,public_artifact_complete:true,
    completed_utc:"2026-08-13T20:00:00Z"}' >"$DR_PUBLIC_ARTIFACT_RECEIPT"
DR_PUBLIC_ARTIFACT_RECEIPT_SHA256=$(sha_file "$DR_PUBLIC_ARTIFACT_RECEIPT")

DR_NODE30_ONE_SHOT_RECEIPT="$tmp/node30.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg worker "$(hex 4)" --arg tests "$(hex 5)" '{
    schema:1,kind:"v30.1.5-node30-one-shot-release-product",release:"v30.1.5",
    source_sha:$source,public_artifact_receipt_sha256:$public,node:30,
    two_phase_audit_authority_release:true,authority_binds_audit_sha:true,
    authority_binds_tip:true,authority_binds_height:true,
    authority_binds_wallet_identity:true,authority_binds_wallet_generation:true,
    authority_binds_fee_outpoint:true,authority_binds_work:true,
    authority_binds_queue:true,authority_binds_payout:true,authority_binds_fee_caps:true,
    worker_mode:"one-shot",external_recurring_worker_authoritative:false,
    single_submission_only:true,broadcast_count_exactly_one:true,fee_cap_enforced:true,
    queue_result_binds_raw_hash_and_txid:true,
    queue_result_binds_witness_v16_payout:true,repauses_before_lock_release:true,
    ordinary_pow_required:false,ordinary_pow_stays_disabled:true,
    recovery_authorized:false,new_key_authorized:false,worker_sha256:$worker,
    product_test_receipt_sha256:$tests}' >"$DR_NODE30_ONE_SHOT_RECEIPT"
DR_NODE30_ONE_SHOT_RECEIPT_SHA256=$(sha_file "$DR_NODE30_ONE_SHOT_RECEIPT")

DR_NODE27_RELAY_RECEIPT="$tmp/node27.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg tests "$(hex 6)" '{schema:1,kind:"v30.1.5-node27-relay-product",
    release:"v30.1.5",source_sha:$source,public_artifact_receipt_sha256:$public,node:27,
    stable_chain_bracket:true,active_tip_bound:true,height_bound:true,
    wallet_generation_bound:true,wallet_processed_tip_bound:true,
    component_fingerprint_bound:true,plan_id_bound:true,txid_bound:true,raw_hash_bound:true,
    testmempoolaccept_bound:true,current_recovery_rechecked:true,
    commit_result_binds_acknowledged_plan:true,product_test_receipt_sha256:$tests}' \
  >"$DR_NODE27_RELAY_RECEIPT"
DR_NODE27_RELAY_RECEIPT_SHA256=$(sha_file "$DR_NODE27_RELAY_RECEIPT")

DR_POS_RENEWAL_RECEIPT="$tmp/renewal.json"
jq -cn --arg integration "$DR_FLEET_INTEGRATION_COMMIT" --arg tests "$(hex 7)" '{
    schema:1,kind:"v30.1.5-pos-renewal-lock-contract",fleet_integration_commit:$integration,
    lock_paths:["/var/run/blackcoin-v3015-rollout.lock",
      "/run/blackcoin-endpoint-guard.lock",
      "/var/run/blackcoin-wallet-runtime-guard.lock",
      "/var/run/blackcoin-free-claim-pause-transition.lock"],normal_unlock_only:true,
    unlock_during_cutover_forbidden:true,node30_release_lock_included:true,
    ordinary_pow_mutation_forbidden:true,wallet_transaction_forbidden:true,
    hostile_test_receipt_sha256:$tests}' >"$DR_POS_RENEWAL_RECEIPT"
DR_POS_RENEWAL_RECEIPT_SHA256=$(sha_file "$DR_POS_RENEWAL_RECEIPT")

contract_sha=$(sha_file "$root/lib/deployment_rollback_readiness_contract.sh")
tool_sha=$(sha_file "$root/deployment_rollback_readiness.sh")
DR_FLEET_INTEGRATION_RECEIPT="$tmp/integration.json"
jq -cn --arg commit "$DR_FLEET_INTEGRATION_COMMIT" \
  --arg tree "$DR_FLEET_INTEGRATION_TREE" --arg base "$V3015_DR_DURABILITY_BASE" \
  --arg preseal "$V3015_DR_NODE30_PRESEAL" --arg fingerprint "$V3015_DR_SIGNING_FINGERPRINT" \
  --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg package "$DR_PACKAGE_SHA256SUMS_SHA256" --arg topology "$DR_TOPOLOGY_SHA256" \
  --arg waves "$DR_WAVES_SHA256" --arg contract "$contract_sha" --arg tool "$tool_sha" \
  --arg node30 "$DR_NODE30_ONE_SHOT_RECEIPT_SHA256" \
  --arg node27 "$DR_NODE27_RELAY_RECEIPT_SHA256" \
  --arg renewal "$DR_POS_RENEWAL_RECEIPT_SHA256" --arg full "$(hex 8)" \
  --arg hostile "$(hex 9)" '{schema:1,kind:"v30.1.5-signed-fleet-integration",
    release:"v30.1.5",fleet_integration_commit:$commit,fleet_integration_tree:$tree,
    durability_topology_base_commit:$base,node30_semantic_preseal_commit:$preseal,
    signature_verified:true,signing_fingerprint:$fingerprint,
    github_signature_verified:true,github_signature_reason:"valid",
    public_artifact_receipt_sha256:$public,package_sha256sums_sha256:$package,
    topology_sha256:$topology,waves_sha256:$waves,deployment_contract_sha256:$contract,
    deployment_tool_sha256:$tool,node30_one_shot_product_receipt_sha256:$node30,
    node27_relay_product_receipt_sha256:$node27,pos_renewal_lock_receipt_sha256:$renewal,
    node30_semantic_preseal_deployable:false,combined_integration:true,
    deployable_package:true,package_full_suite_receipt_sha256:$full,
    hostile_test_receipt_sha256:$hostile,created_utc:"2026-08-13T20:01:00Z"}' \
  >"$DR_FLEET_INTEGRATION_RECEIPT"
DR_FLEET_INTEGRATION_RECEIPT_SHA256=$(sha_file "$DR_FLEET_INTEGRATION_RECEIPT")

DR_ROLLBACK_PLAN_RECEIPT="$tmp/rollback.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg installed "$DR_INSTALLED_V3014_IMAGE_REF" \
  --arg installed_id "$DR_INSTALLED_V3014_IMAGE_ID" --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg integration "$DR_FLEET_INTEGRATION_RECEIPT_SHA256" \
  --arg topology "$DR_TOPOLOGY_SHA256" --arg waves "$DR_WAVES_SHA256" \
  --argjson candidate "$candidate_bins" --argjson old "$installed_bins" '{
    schema:1,kind:"v30.1.5-rollback-containment-plan",release:"v30.1.5",
    source_sha:$source,candidate_image_ref:$image,candidate_image_id:$image_id,
    candidate_binary_sha256s:$candidate,installed_v3014_image_ref:$installed,
    installed_v3014_image_id:$installed_id,installed_v3014_binary_sha256s:$old,
    public_artifact_receipt_sha256:$public,package_integration_receipt_sha256:$integration,
    topology_sha256:$topology,waves_sha256:$waves,max_inflight_nodes:4,
    containment_timeout_seconds:120,stop_on_first_failure:true,
    failed_wave_action:"contain-candidate-preserve-data",installed_v3014_image_retained:true,
    prestart_config_restore_only:true,post_candidate_v3014_restart_authorized:false,
    data_rewind_authorized:false,reindex_authorized:false,repair_authorized:false,
    wallet_restore_authorized:false,bootstrap_authorized:false,
    recovery_transaction_authorized:false,new_key_authorized:false,
    maintenance_pause_retained_on_failure:true,node30_ordinary_pow_stays_disabled:true,
    node30_free_claim_stays_paused:true}' >"$DR_ROLLBACK_PLAN_RECEIPT"
DR_ROLLBACK_PLAN_RECEIPT_SHA256=$(sha_file "$DR_ROLLBACK_PLAN_RECEIPT")

tip=$(hex a) chainwork=$(hex b)
before_dir="$tmp/before"
mkdir -p "$before_dir"
index_rows='[]'
for node in {1..32}; do
    row=$(v3015_topology_lookup "$DR_TOPOLOGY_MAP" "$node")
    IFS=$'\t' read -r service container <<<"$row"
    if ((node==30)); then role=free_claim; free=true; pow=false; else role=regular; free=false; pow=true; fi
    receipt="$before_dir/node-${node}.json"
    jq -cn --argjson node "$node" --arg role "$role" --arg service "$service" \
      --arg container "$container" --arg topology "$DR_TOPOLOGY_SHA256" \
      --arg tip "$tip" --arg chainwork "$chainwork" --arg image "$DR_INSTALLED_V3014_IMAGE_REF" \
      --arg image_id "$DR_INSTALLED_V3014_IMAGE_ID" --argjson bins "$installed_bins" \
      --arg wallet "$(printf 'wallet-%02d' "$node" | sha256sum | awk '{print $1}')" \
      --arg dataset "$(printf 'dataset-%02d' "$node" | sha256sum | awk '{print $1}')" \
      --arg storage "$(printf 'storage-%02d' "$node" | sha256sum | awk '{print $1}')" \
      --argjson free "$free" --argjson pow "$pow" '{schema:1,
        kind:"v30.1.5-node-before-receipt",node:$node,role:$role,
        compose_service:$service,container_name:$container,topology_sha256:$topology,
        captured_epoch:1786652000,core_bracket:{before:{chain:"main",blocks:1000,headers:1000,
          bestblockhash:$tip,chainwork:$chainwork,initialblockdownload:false},after:{chain:"main",
          blocks:1000,headers:1000,bestblockhash:$tip,chainwork:$chainwork,
          initialblockdownload:false}},network:{networkactive:true,connections:16},
        runtime:{version:300104,subversion:"/Blackcoin:30.1.4/",image_ref:$image,
          image_id:$image_id,binary_sha256s:$bins,running:true,paused:false,
          restarting:false,dead:false},wallet:{loaded_wallets:1,identity_sha256:$wallet,
          generation:10,processed_tip:$tip,processed_height:1000,private_keys_enabled:true,
          scanning:false},storage:{dataset_identity_sha256:$dataset,
          wallet_storage_identity_sha256:$storage,installed_v3014_image_retained:true,
          candidate_bytes_started:false,bootstrap_used:false,reindex_used:false,
          repair_used:false,rewind_used:false,wallet_replaced:false},
        intent:{pos_enabled:true,ordinary_pow_enabled:$pow,ordinary_pow_autostart:$pow,
          free_claim_role:$free,free_claim_paused:$free,
          automatic_recovery_authorized:false,automatic_quantum_key_creation:false}}' >"$receipt"
    sha=$(sha_file "$receipt")
    index_rows=$(jq -cn --argjson rows "$index_rows" --argjson node "$node" \
      --arg path "$receipt" --arg sha "$sha" '$rows+[{node:$node,path:$path,sha256:$sha}]')
done
DR_BEFORE_INDEX="$tmp/before-index.json"
jq -cn --arg topology "$DR_TOPOLOGY_SHA256" --arg capture "$(hex c)" \
  --argjson receipts "$index_rows" '{schema:1,kind:"v30.1.5-before-receipt-index",
    capture_id:$capture,topology_sha256:$topology,receipts:$receipts}' >"$DR_BEFORE_INDEX"
DR_BEFORE_INDEX_SHA256=$(sha_file "$DR_BEFORE_INDEX")

expect_pass 'common env accepts exact immutable identities and future combined integration' \
  v3015_dr_validate_common_env
expect_pass 'topology and canary-first/node30-last bounded waves are exact' \
  v3015_dr_topology_and_waves_are_valid "$DR_TOPOLOGY_MAP" "$DR_WAVES_PLAN"
expect_pass 'public artifact completion accepts exact immutable artifact' \
  v3015_dr_public_artifact_is_valid "$DR_PUBLIC_ARTIFACT_RECEIPT"
expect_pass 'node30 requires true two-phase one-shot bounded-fee release product' \
  v3015_dr_node30_one_shot_is_valid "$DR_NODE30_ONE_SHOT_RECEIPT"
expect_pass 'node27 relay product binds stable bracket, wallet, family, plan and raw transaction' \
  v3015_dr_node27_relay_is_valid "$DR_NODE27_RELAY_RECEIPT"
expect_pass 'PoS renewal shares rollout/endpoint/wallet/node30 release lock order' \
  v3015_dr_pos_renewal_is_valid "$DR_POS_RENEWAL_RECEIPT"
expect_pass 'signed combined fleet integration rejects semantic preseal as deployable' \
  v3015_dr_integration_is_valid "$DR_FLEET_INTEGRATION_RECEIPT" "$contract_sha" "$tool_sha"
expect_pass 'rollback plan preserves installed v30.1.4 and forbids post-start rollback' \
  v3015_dr_rollback_plan_is_valid "$DR_ROLLBACK_PLAN_RECEIPT"
expect_pass '32 before receipts bind exact installed v30.1.4 roles and storage' \
  v3015_dr_before_index_is_valid "$DR_BEFORE_INDEX"
expect_pass 'complete readiness authority set cross-binds every reviewed receipt' \
  v3015_dr_authority_inputs_are_valid "$contract_sha" "$tool_sha"

mutate_fail 'public artifact rejects non-terminal CI' v3015_dr_public_artifact_is_valid \
  "$DR_PUBLIC_ARTIFACT_RECEIPT" '.ci.conclusion="failure"'
mutate_fail 'public artifact rejects OCI digest mismatch' v3015_dr_public_artifact_is_valid \
  "$DR_PUBLIC_ARTIFACT_RECEIPT" '.candidate_oci_manifest_sha256=("0"*64)'
mutate_fail 'node30 rejects marker-only recurring worker authority' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.external_recurring_worker_authoritative=true'
mutate_fail 'node30 rejects missing audit binding' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.authority_binds_audit_sha=false'
mutate_fail 'node30 rejects missing fee cap' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.fee_cap_enforced=false'
mutate_fail 'node30 rejects unbound exact fee outpoint' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.authority_binds_fee_outpoint=false'
mutate_fail 'node30 rejects a worker without single-submission enforcement' \
  v3015_dr_node30_one_shot_is_valid "$DR_NODE30_ONE_SHOT_RECEIPT" \
  '.single_submission_only=false'
mutate_fail 'node30 rejects missing exact payout binding' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.queue_result_binds_witness_v16_payout=false'
mutate_fail 'node30 rejects no re-pause proof' v3015_dr_node30_one_shot_is_valid \
  "$DR_NODE30_ONE_SHOT_RECEIPT" '.repauses_before_lock_release=false'
mutate_fail 'node27 rejects unstable relay bracket' v3015_dr_node27_relay_is_valid \
  "$DR_NODE27_RELAY_RECEIPT" '.stable_chain_bracket=false'
mutate_fail 'node27 rejects unbound plan id' v3015_dr_node27_relay_is_valid \
  "$DR_NODE27_RELAY_RECEIPT" '.plan_id_bound=false'
mutate_fail 'node27 rejects a commit result detached from the acknowledged plan' \
  v3015_dr_node27_relay_is_valid "$DR_NODE27_RELAY_RECEIPT" \
  '.commit_result_binds_acknowledged_plan=false'
mutate_fail 'PoS renewal rejects reordered locks' v3015_dr_pos_renewal_is_valid \
  "$DR_POS_RENEWAL_RECEIPT" '.lock_paths|=reverse'
mutate_fail 'PoS renewal rejects unlock during rollout cutover' \
  v3015_dr_pos_renewal_is_valid "$DR_POS_RENEWAL_RECEIPT" \
  '.unlock_during_cutover_forbidden=false'
integration_valid_wrapper()
{
    v3015_dr_integration_is_valid "$1" "$contract_sha" "$tool_sha"
}
mutate_fail 'integration rejects node30 semantic preseal as deployable' \
  integration_valid_wrapper "$DR_FLEET_INTEGRATION_RECEIPT" \
  '.fleet_integration_commit="d1d1aa335f8ede310ac24fb1557700a5c2ca7c4a"'

saved_commit=$DR_FLEET_INTEGRATION_COMMIT
DR_FLEET_INTEGRATION_COMMIT=$V3015_DR_NODE30_PRESEAL
expect_fail 'common env rejects node30 semantic preseal as combined integration' \
  v3015_dr_validate_common_env
DR_FLEET_INTEGRATION_COMMIT=$saved_commit

mutate_fail 'rollback refuses removal of installed v30.1.4 image' v3015_dr_rollback_plan_is_valid \
  "$DR_ROLLBACK_PLAN_RECEIPT" '.installed_v3014_image_retained=false'
mutate_fail 'rollback refuses candidate-started v30.1.4 restart authority' \
  v3015_dr_rollback_plan_is_valid "$DR_ROLLBACK_PLAN_RECEIPT" \
  '.post_candidate_v3014_restart_authorized=true'
mutate_fail 'rollback refuses data rewind' v3015_dr_rollback_plan_is_valid \
  "$DR_ROLLBACK_PLAN_RECEIPT" '.data_rewind_authorized=true'

audit="$tmp/audit.json"
v3015_dr_make_audit_receipt "$contract_sha" "$tool_sha" >"$audit"
audit_sha=$(sha_file "$audit")
audit_valid_wrapper() { v3015_dr_audit_receipt_is_valid "$1" "$contract_sha" "$tool_sha"; }
expect_pass 'audit receipt is an exact identity-only projection' \
  v3015_dr_audit_receipt_is_valid "$audit" "$contract_sha" "$tool_sha"
expect_pass 'audit receipt states that no candidate bytes or live execution occurred' \
  jq -e '.candidate_bytes_started==false and .deployment_authorized==false and
    .live_execution_performed==false and .node30_free_claim_paused==true and
    .node30_semantic_preseal_deployable==false' "$audit"
mutate_fail 'audit rejects false deployment authorization' audit_valid_wrapper "$audit" \
  '.deployment_authorized=true'

now=1786653000
authority="$tmp/live-authority.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
  --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg integration "$DR_FLEET_INTEGRATION_RECEIPT_SHA256" \
  --arg topology "$DR_TOPOLOGY_SHA256" --arg waves "$DR_WAVES_SHA256" \
  --arg before "$DR_BEFORE_INDEX_SHA256" --arg rollback "$DR_ROLLBACK_PLAN_RECEIPT_SHA256" \
  --arg nonce '11111111111111111111111111111111' --argjson before_epoch "$((now-10))" \
  --argjson expires "$((now+600))" '{schema:1,kind:"v30.1.5-live-wave-authority",
    release:"v30.1.5",source_sha:$source,candidate_image_ref:$image,candidate_image_id:$image_id,
    audit_receipt_sha256:$audit,public_artifact_receipt_sha256:$public,
    fleet_integration_receipt_sha256:$integration,topology_sha256:$topology,
    waves_sha256:$waves,before_receipt_index_sha256:$before,
    rollback_plan_receipt_sha256:$rollback,authorized_wave_index:1,
    authorized_nodes:[27],wave_role:"regular",nonce:$nonce,
    not_before_epoch:$before_epoch,expires_epoch:$expires,max_inflight_nodes:4,
    stop_on_first_failure:true,next_wave_authorized:false,wallet_transaction_authorized:false,
    recovery_transaction_authorized:false,new_key_authorized:false,bootstrap_authorized:false,
    reindex_authorized:false,repair_authorized:false,data_rewind_authorized:false,
    installed_v3014_removal_authorized:false,v3014_post_candidate_restart_authorized:false,
    node30_ordinary_pow_authorized:false,node30_free_claim_release_authorized:false}' >"$authority"
authority_sha=$(sha_file "$authority")
expect_pass 'short-lived live authority binds exact audit and first canary only' \
  v3015_dr_live_wave_authority_is_valid "$authority" "$now" "$audit_sha" 1

authority_valid_wrapper() { v3015_dr_live_wave_authority_is_valid "$1" "$now" "$audit_sha" 1; }
mutate_fail 'wave authority rejects node substitution' authority_valid_wrapper "$authority" \
  '.authorized_nodes=[16]'
mutate_fail 'wave authority rejects next-wave authorization' authority_valid_wrapper "$authority" \
  '.next_wave_authorized=true'
mutate_fail 'wave authority rejects wallet transaction authority' authority_valid_wrapper "$authority" \
  '.wallet_transaction_authorized=true'
mutate_fail 'wave authority rejects v30.1.4 restart authority' authority_valid_wrapper "$authority" \
  '.v3014_post_candidate_restart_authorized=true'
expect_fail 'wave authority rejects expiry' v3015_dr_live_wave_authority_is_valid \
  "$authority" "$((now+601))" "$audit_sha" 1

authorization="$tmp/authorization.json"
v3015_dr_make_wave_authorization_receipt "$audit_sha" "$authority_sha" "$authority" "$now" \
  >"$authorization"
authorization_sha=$(sha_file "$authorization")
expect_pass 'phase-two authorization receipt binds exact audit, authority and observation time' \
  v3015_dr_wave_authorization_receipt_is_valid "$authorization" "$audit_sha" \
    "$authority_sha" "$authority" "$now"

before27=$(jq -r '.receipts[]|select(.node==27)|.path' "$DR_BEFORE_INDEX")
before27_sha=$(sha_file "$before27")
wallet27=$(jq -r '.wallet.identity_sha256' "$before27")
dataset27=$(jq -r '.storage.dataset_identity_sha256' "$before27")
storage27=$(jq -r '.storage.wallet_storage_identity_sha256' "$before27")
row=$(v3015_topology_lookup "$DR_TOPOLOGY_MAP" 27)
IFS=$'\t' read -r service27 container27 <<<"$row"
after27="$tmp/after27.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg image_id "$DR_CANDIDATE_IMAGE_ID" --argjson bins "$candidate_bins" \
  --arg tip "$tip" --arg chainwork "$chainwork" --arg topology "$DR_TOPOLOGY_SHA256" \
  --arg service "$service27" --arg container "$container27" --arg before "$before27_sha" \
  --arg audit "$audit_sha" --arg authority "$authority_sha" \
  --arg nonce '11111111111111111111111111111111' --arg wallet "$wallet27" \
  --arg dataset "$dataset27" --arg storage "$storage27" '{schema:1,
    kind:"v30.1.5-node-after-receipt",node:27,role:"regular",compose_service:$service,
    container_name:$container,topology_sha256:$topology,before_receipt_sha256:$before,
    audit_receipt_sha256:$audit,live_wave_authority_sha256:$authority,nonce:$nonce,wave_index:1,
    captured_epoch:1786653050,core_bracket:{before:{chain:"main",blocks:1001,headers:1001,
      bestblockhash:$tip,chainwork:$chainwork,initialblockdownload:false},after:{chain:"main",
      blocks:1001,headers:1001,bestblockhash:$tip,chainwork:$chainwork,initialblockdownload:false}},
    network:{networkactive:true,connections:16},runtime:{version:300105,
      subversion:"/Blackcoin:30.1.5/",source_sha:$source,image_ref:$image,image_id:$image_id,
      binary_sha256s:$bins,running:true,paused:false,restarting:false,dead:false,
      health:"healthy"},wallet:{loaded_wallets:1,identity_sha256:$wallet,generation:11,
      processed_tip:$tip,processed_height:1001,private_keys_enabled:true,scanning:false},
    storage:{dataset_identity_sha256:$dataset,wallet_storage_identity_sha256:$storage,
      installed_v3014_image_retained:true,bootstrap_used:false,reindex_used:false,
      repair_used:false,rewind_used:false,wallet_replaced:false},intent:{pos_enabled:true,
      pos_active:true,ordinary_pow_enabled:true,ordinary_pow_autostart:true,
      ordinary_pow_active:true,free_claim_role:false,free_claim_paused:false,
      automatic_recovery_authorized:false,automatic_quantum_key_creation:false},
    transition:{before_tip_is_ancestor:true,height_not_rewound:true,
      wallet_transactions_created:0,wallet_fees_paid:0,wallet_keys_created:0,
      wallet_migration_performed:false,v3014_restart_authorized:false,
      node30_one_shot_invoked:false}}' >"$after27"
after27_sha=$(sha_file "$after27")
after_index="$tmp/after-index.json"
jq -cn --arg topology "$DR_TOPOLOGY_SHA256" --arg audit "$audit_sha" \
  --arg authority "$authority_sha" --arg nonce '11111111111111111111111111111111' \
  --arg path "$after27" --arg sha "$after27_sha" '{schema:1,
    kind:"v30.1.5-after-receipt-index",topology_sha256:$topology,
    audit_receipt_sha256:$audit,live_wave_authority_sha256:$authority,nonce:$nonce,
    wave_index:1,receipts:[{node:27,path:$path,sha256:$sha}]}' >"$after_index"
after_index_sha=$(sha_file "$after_index")
expect_pass 'candidate after receipt preserves storage and exact regular PoW/PoS role' \
  v3015_dr_after_receipt_is_valid "$after27" 27 "$before27" "$before27_sha" \
    "$audit_sha" "$authority_sha" '11111111111111111111111111111111' 1
expect_pass 'after index binds exactly the authorized wave receipt set' \
  v3015_dr_after_index_is_valid "$after_index" "$audit_sha" "$authority_sha" "$authority"

after_valid_wrapper()
{
    v3015_dr_after_receipt_is_valid "$1" 27 "$before27" "$before27_sha" \
      "$audit_sha" "$authority_sha" '11111111111111111111111111111111' 1
}
mutate_fail 'after receipt rejects wallet identity drift' after_valid_wrapper "$after27" \
  '.wallet.identity_sha256=("0"*64)'
mutate_fail 'after receipt rejects data rewind' after_valid_wrapper "$after27" \
  '.storage.rewind_used=true'
mutate_fail 'after receipt rejects an actual height regression despite a true flag' \
  after_valid_wrapper "$after27" \
  '.core_bracket.before.blocks=999 | .core_bracket.after.blocks=999 |
   .wallet.processed_height=999'
mutate_fail 'after receipt rejects v30.1.4 restart authority' after_valid_wrapper "$after27" \
  '.transition.v3014_restart_authorized=true'
mutate_fail 'after receipt rejects unreviewed transition fields' after_valid_wrapper \
  "$after27" '.transition.unreviewed=true'

wave_result="$tmp/wave-result.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg authorization "$authorization_sha" --arg audit "$audit_sha" \
  --arg authority "$authority_sha" --arg after "$after_index_sha" \
  --arg nonce '11111111111111111111111111111111' '{schema:1,
    kind:"v30.1.5-wave-result",release:"v30.1.5",state:"pass",source_sha:$source,
    candidate_image_ref:$image,wave_authorization_receipt_sha256:$authorization,
    audit_receipt_sha256:$audit,live_wave_authority_sha256:$authority,
    after_receipt_index_sha256:$after,nonce:$nonce,wave_index:1,authorized_nodes:[27],
    completed_nodes:[27],candidate_processes_running:1,containment_invoked:false,
    rollout_halted:false,next_wave_authorized:false,installed_v3014_image_retained:true,
    maintenance_pause_retained:true,node30_ordinary_pow_disabled:true,
    node30_free_claim_paused:true,data_rewind_used:false}' >"$wave_result"
expect_pass 'wave pass result binds exact audit/authority/after receipts and no next wave' \
  v3015_dr_wave_success_is_valid "$wave_result" "$authorization_sha" "$audit_sha" \
    "$authority_sha" "$authority" "$after_index_sha"

containment="$tmp/containment.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg authorization "$authorization_sha" --arg audit "$audit_sha" \
  --arg authority "$authority_sha" --arg nonce '11111111111111111111111111111111' '{
    schema:1,kind:"v30.1.5-wave-containment-result",release:"v30.1.5",
    state:"failed-contained",source_sha:$source,candidate_image_ref:$image,
    wave_authorization_receipt_sha256:$authorization,audit_receipt_sha256:$audit,
    live_wave_authority_sha256:$authority,nonce:$nonce,wave_index:1,
    attempted_nodes:[27],failed_nodes:[27],contained_nodes:[27],
    containment_completed:true,candidate_processes_running:0,rollout_halted:true,
    next_wave_authorized:false,installed_v3014_image_retained:true,
    maintenance_pause_retained:true,node30_ordinary_pow_disabled:true,
    node30_free_claim_paused:true,v3014_restart_attempted:false,data_rewind_used:false,
    reindex_used:false,repair_used:false,wallet_restore_used:false,
    recovery_transaction_created:false,new_key_created:false}' >"$containment"
expect_pass 'failed wave containment stops candidate without unsafe rollback actions' \
  v3015_dr_containment_is_valid "$containment" "$authorization_sha" "$audit_sha" \
    "$authority_sha" "$authority"
containment_valid_wrapper()
{
    v3015_dr_containment_is_valid "$1" "$authorization_sha" "$audit_sha" \
      "$authority_sha" "$authority"
}
mutate_fail 'containment rejects v30.1.4 restart attempt' containment_valid_wrapper \
  "$containment" '.v3014_restart_attempted=true'
mutate_fail 'containment rejects wallet restore' containment_valid_wrapper \
  "$containment" '.wallet_restore_used=true'
mutate_fail 'containment rejects a surviving candidate process' containment_valid_wrapper \
  "$containment" '.candidate_processes_running=1'
mutate_fail 'containment rejects authority leakage to the next wave' containment_valid_wrapper \
  "$containment" '.next_wave_authorized=true'

rollout_authority="$tmp/rollout-authority.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
  --arg public "$DR_PUBLIC_ARTIFACT_RECEIPT_SHA256" \
  --arg integration "$DR_FLEET_INTEGRATION_RECEIPT_SHA256" \
  --arg before "$DR_BEFORE_INDEX_SHA256" --arg topology "$DR_TOPOLOGY_SHA256" \
  --arg waves "$DR_WAVES_SHA256" --arg nonce '22222222222222222222222222222222' '{
    schema:1,kind:"v30.1.5-rollout-authority",release:"v30.1.5",source_sha:$source,
    candidate_image_ref:$image,candidate_image_id:$image_id,audit_receipt_sha256:$audit,
    public_artifact_receipt_sha256:$public,fleet_integration_receipt_sha256:$integration,
    before_receipt_index_sha256:$before,topology_sha256:$topology,waves_sha256:$waves,
    nonce:$nonce,node30_ordinary_pow_authorized:false,
    node30_free_claim_release_authorized:false,node30_free_claim_stays_paused:true}' \
  >"$rollout_authority"
rollout_authority_sha=$(sha_file "$rollout_authority")
rollout_authority_wrapper()
{
    v3015_dr_rollout_authority_is_valid "$1" "$audit_sha"
}
mutate_fail 'rollout authority cannot accept node30 release during deployment' \
  rollout_authority_wrapper "$rollout_authority" \
  '.node30_free_claim_release_authorized=true'

census="$tmp/census.json"
nodes='[]'
for node in {1..32}; do
    if ((node==30)); then free=true; enabled=false; active=false; else free=false; enabled=true; active=true; fi
    nodes=$(jq -cn --argjson rows "$nodes" --argjson node "$node" \
      --arg image "$DR_CANDIDATE_IMAGE_REF" --arg image_id "$DR_CANDIDATE_IMAGE_ID" \
      --argjson free "$free" --argjson enabled "$enabled" --argjson active "$active" \
      '$rows+[{node:$node,container_image_ref:$image,container_image_id:$image_id,
        healthy:true,ibd:false,peers:16,pos_active:true,wallet_tip_matches:true,
        ordinary_pow_enabled:$enabled,ordinary_pow_active:$active,free_claim_paused:$free}]')
done
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg image_id "$DR_CANDIDATE_IMAGE_ID" --arg audit "$audit_sha" \
  --arg authority "$rollout_authority_sha" --arg topology "$DR_TOPOLOGY_SHA256" \
  --argjson nodes "$nodes" '{schema:1,kind:"v30.1.5-terminal-fleet-census",
    release:"v30.1.5",source_sha:$source,candidate_image_ref:$image,
    candidate_image_id:$image_id,audit_receipt_sha256:$audit,
    rollout_authority_sha256:$authority,topology_sha256:$topology,nodes:$nodes}' >"$census"
census_sha=$(sha_file "$census")
fleet_result="$tmp/fleet-result.json"
jq -cn --arg source "$DR_SOURCE_SHA" --arg image "$DR_CANDIDATE_IMAGE_REF" \
  --arg audit "$audit_sha" --arg authority "$rollout_authority_sha" \
  --arg census "$census_sha" --arg topology "$DR_TOPOLOGY_SHA256" \
  --arg waves "$DR_WAVES_SHA256" '{schema:1,kind:"v30.1.5-fleet-deployment-result",
    release:"v30.1.5",state:"pass-pause-preserved",source_sha:$source,
    candidate_image_ref:$image,audit_receipt_sha256:$audit,
    rollout_authority_sha256:$authority,fleet_census_sha256:$census,
    topology_sha256:$topology,waves_sha256:$waves,healthy_nodes:32,pos_active_nodes:32,
    regular_pow_active_nodes:31,node30_ordinary_pow_enabled:false,
    node30_ordinary_pow_active:false,node30_free_claim_paused:true,
    node30_free_claim_release_accepted:false,
    maintenance_finalization_state:"complete-pause-preserved",data_rewind_used:false}' \
  >"$fleet_result"

expect_pass 'terminal bundle semantically validates authority, census and pause-preserved result' \
  v3015_dr_terminal_bundle_is_valid "$audit_sha" "$rollout_authority" \
    "$fleet_result" "$census"
terminal_wrapper()
{
    v3015_dr_terminal_bundle_is_valid "$audit_sha" "$rollout_authority" "$1" "$census"
}
mutate_fail 'terminal result rejects node30 release during deployment' terminal_wrapper \
  "$fleet_result" '.node30_free_claim_release_accepted=true'
census_wrapper()
{
    v3015_dr_fleet_census_is_valid "$1" "$audit_sha" "$rollout_authority_sha"
}
mutate_fail 'terminal census rejects missing PoS node' census_wrapper "$census" \
  '.nodes[0].pos_active=false'
mutate_fail 'terminal census rejects node30 ordinary PoW leakage' census_wrapper "$census" \
  '.nodes[29].ordinary_pow_enabled=true'
mutate_fail 'terminal census rejects a wallet detached from the active tip' census_wrapper \
  "$census" '.nodes[0].wallet_tip_matches=false'

# Exercise every offline driver mode against the same exact identity set. The
# driver is still forbidden to contact or mutate a runtime; these fixtures only
# prove that its orchestration agrees with the pure receipt predicates above.
reviewed_env="$tmp/reviewed.env"
while IFS= read -r name; do
    declare -p "$name" | sed 's/^declare -- /export /'
done < <(compgen -A variable DR_ | sort) >"$reviewed_env"
chmod 600 "$reviewed_env"

driver_audit_wrapper()
{
    V3015_DR_FIXTURE=1 "$root/deployment_rollback_readiness.sh" audit \
      "$reviewed_env" | cmp -s - "$audit"
}
expect_pass 'driver audit reproduces the exact identity-only receipt' \
  driver_audit_wrapper

driver_now=$(date -u +%s)
driver_authority="$tmp/driver-live-authority.json"
jq --argjson not_before "$((driver_now-5))" --argjson expires "$((driver_now+300))" \
  '.not_before_epoch=$not_before | .expires_epoch=$expires' "$authority" \
  >"$driver_authority"
driver_authorization="$tmp/driver-authorization.json"
driver_authorize_wrapper()
{
    V3015_DR_FIXTURE=1 "$root/deployment_rollback_readiness.sh" authorize \
      "$reviewed_env" "$audit" "$driver_authority" >"$driver_authorization" &&
      jq -e --arg audit "$audit_sha" \
        '.kind=="v30.1.5-wave-authorization-check" and
         .audit_receipt_sha256==$audit and .live_execution_performed==false and
         .node30_free_claim_release_authorized==false' "$driver_authorization" >/dev/null
}
expect_pass 'driver authorize accepts only a current exact-wave nonce authority' \
  driver_authorize_wrapper

driver_reconcile_pass_wrapper()
{
    V3015_DR_FIXTURE=1 "$root/deployment_rollback_readiness.sh" reconcile \
      "$reviewed_env" "$audit" "$authorization" "$authority" "$wave_result" \
      "$after_index" | jq -e '.state=="pass" and .next_wave_authorized==false and
        .offline_validation_only==true' >/dev/null
}
expect_pass 'driver reconcile accepts a receipt-bound successful wave offline' \
  driver_reconcile_pass_wrapper

driver_reconcile_containment_wrapper()
{
    V3015_DR_FIXTURE=1 "$root/deployment_rollback_readiness.sh" reconcile \
      "$reviewed_env" "$audit" "$authorization" "$authority" "$containment" | \
      jq -e '.state=="failed-contained" and .next_wave_authorized==false and
        .after_receipt_index_sha256==null' >/dev/null
}
expect_pass 'driver reconcile accepts only a safely contained failed wave offline' \
  driver_reconcile_containment_wrapper

driver_terminal_wrapper()
{
    V3015_DR_FIXTURE=1 "$root/deployment_rollback_readiness.sh" terminal \
      "$reviewed_env" "$audit" "$rollout_authority" "$fleet_result" "$census" | \
      jq -e '.pause_preserved_terminal_state==true and
        .node30_free_claim_release_accepted==false and
        .separate_node30_release_required==true and .next_action_authorized==false' \
        >/dev/null
}
expect_pass 'driver terminal accepts deployment only in pause-preserved state' \
  driver_terminal_wrapper

expect_pass 'driver contains no Docker, SSH, image pull/build, or live RPC execution' \
  bash -c '! grep -Eq "(^|[^[:alnum:]_])(docker|ssh|scp|rsync|blackcoin-cli)([^[:alnum:]_]|$)" "$1"' \
    bash "$root/deployment_rollback_readiness.sh"
expect_pass 'driver exposes offline audit/authorize/reconcile/terminal modes only' \
  grep -Fq 'audit:2|authorize:4|reconcile:6|reconcile:7|terminal:6' \
    "$root/deployment_rollback_readiness.sh"
expect_pass 'env leaves every release identity and live authority unresolved' \
  bash -c 'grep -Fq "DR_PUBLIC_ARTIFACT_RECEIPT='\''__" "$1" &&
    grep -Fq "DR_FLEET_INTEGRATION_COMMIT='\''__" "$1" &&
    grep -Fq "DR_LIVE_WAVE_AUTHORITY='\''__" "$1"' \
    bash "$root/deployment_rollback_readiness.env.example"

total=$((pass+fail))
if ((fail!=0)); then
    printf 'FAIL: %d/%d deployment/rollback readiness hostile assertions failed\n' \
      "$fail" "$total" >&2
    exit 1
fi
printf 'PASS: %d deployment/rollback readiness hostile assertions\n' "$total"
