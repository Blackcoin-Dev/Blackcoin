#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
# shellcheck disable=SC1091 # Resolved from the package under test.
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091 # Resolved from the package under test.
source "$package_dir/lib/typed_contract.sh"

tests=0
failures=0
ok()
{
    tests=$((tests + 1))
    printf 'ok %03d - %s\n' "$tests" "$1"
}
not_ok()
{
    tests=$((tests + 1))
    failures=$((failures + 1))
    printf 'not ok %03d - %s\n' "$tests" "$1"
}
expect_pass()
{
    local name=$1 output
    shift
    if output=$("$@" 2>&1); then
        ok "$name"
    else
        not_ok "$name"
        [[ -z "$output" ]] || printf '# %s\n' "$output"
    fi
}
expect_fail()
{
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then not_ok "$name"; else ok "$name"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/v3015-rollout-tests.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
zero=$(printf '0%.0s' {1..64})
head_tx=$(printf 'a%.0s' {1..64})
relay_tx=$(printf 'b%.0s' {1..64})

make_pow()
{
    local action=$1 fingerprint=$2 hashrate=${3:-0.0} claims=${4:-0}
    local can=false state=claim_in_flight unresolved=1 live=0 eligible=0 family=1
    local head=$head_tx relay=$zero
    case "$action" in
        create_new_anchor)
            can=true; state=hashing; unresolved=0; family=0; head=$zero
            ;;
        refresh_same_anchor)
            can=true; state=hashing
            ;;
        wait_for_live)
            live=1
            ;;
        wait_for_next_tip)
            can=true
            ;;
        relay_existing)
            eligible=1; relay=$relay_tx
            ;;
        *) return 1 ;;
    esac
    jq -cn --arg action "$action" --arg fingerprint "$fingerprint" \
      --arg head "$head" --arg relay "$relay" --arg state "$state" \
      --argjson can "$can" --argjson unresolved "$unresolved" \
      --argjson live "$live" --argjson eligible "$eligible" \
      --argjson family "$family" --argjson hashrate "$hashrate" \
      --argjson claims "$claims" '{
        accrued_jackpot:0,actionable_quarantined_claims:0,
        allow_automatic_quantum_key_creation:false,autostart:true,
        blocking_quarantined_claims:0,blocks_remaining:100,
        claim_coins_after_stake_reserve:1,claim_components:$unresolved,
        claim_inventory_tip:("c"*64),claim_inventory_wallet_tip_matches:true,
        claim_recovery_database_outcome_ambiguous:false,mining_gate_coherent:true,
        claims_auto_resolved:0,claims_recycled:0,claims_submitted:$claims,
        configured_stake_reserve_coins:0,cpu_percent:1,cumulative_resolution_fees:0,
        current_height:1000,enabled:true,epoch_active:true,hashrate:$hashrate,
        indeterminate_quarantined_claims:0,last_stake_coin_guard:true,live_claims:$live,
        mature_stakeable_legacy_coins:1,mature_stakeable_legacy_weight:1000,
        mining_gate_database_ambiguous:false,mining_gate_action:$action,
        mining_gate_can_submit:$can,mining_gate_unsafe_claims:0,
        mining_gate_unsafe_components:0,mining_gate_unresolved_components:$unresolved,
        mining_gate_live_claims:$live,mining_gate_eligible_claims:$eligible,
        mining_gate_family_claims:$family,mining_gate_relay_txid:$relay,
        mining_gate_lineage_head_txid:$head,
        mining_gate_candidate_state_fingerprint:$fingerprint,
        next_claim_amount:1,next_claim_payout:1,payout_address:"qq-payout",
        pending_automatic_resolutions:0,pending_manual_resolutions:0,
        quarantined_claims:0,raw_quarantined_claims:0,reserved_stake_coins:0,
        reserved_stake_weight:0,resolved_on_active_chain_claims:0,
        shadow_reward_end_height:2000,shadow_reward_next_height:1001,
        shadow_reward_start_height:1,stake_reserve_snapshot_available:true,
        state:$state,threads:1,unresolved_claims:$unresolved}'
}

make_pos()
{
    jq -cn '{enabled:true,staking:true,worker_running:true,eligible:true,
      staking_state:"searching",weight:1000,autostart_staking:true,
      autostart_staking_source:"autostartstaking",staking_snapshot_current:true,
      staking_snapshot_sequence:1,blocks:1000,active_blocks:1000,weight_cached:true,
      allow_automatic_quantum_key_creation:false}'
}

make_samples()
{
    local action=${1:-wait_for_next_tip} samples='[]' i fingerprint pow sample
    for i in 1 2 3 4; do
        fingerprint=$(printf '%064x' "$i")
        if [[ "$action" == create_new_anchor || "$action" == refresh_same_anchor ]]; then
            pow=$(make_pow "$action" "$fingerprint" 0.1 0)
        else
            pow=$(make_pow "$action" "$fingerprint" 0 0)
        fi
        sample=$(jq -cn --arg tip "$(printf '%064x' $((100 + i)))" \
          --argjson height $((1000 + i)) --argjson pow "$pow" --argjson staking "$(make_pos)" \
          '($pow | .current_height=$height | .claim_inventory_tip=$tip) as $current_pow |
            ($staking | .blocks=$height | .active_blocks=$height) as $current_staking |
            {tip:$tip,height:$height,blocks:$height,headers:$height,ibd:false,
            peers_out:8,wallet_normal_unlocked:true,wallet_generation:$height,
            wallet_processed_tip:$tip,wallet_tip_matches:true,
            staking:$current_staking,pow:$current_pow}')
        samples=$(jq -cn --argjson old "$samples" --argjson sample "$sample" '$old + [$sample]')
    done
    printf '%s\n' "$samples"
}

make_locked()
{
    jq -cn '{wallet_locked:true,normal_unlock_called:false,pos_intent_retained:true,
      pow_intent_retained:true,staking:{enabled:true,autostart_staking:true,
        worker_running:true,staking:false,eligible:false,staking_state:"locked"},
      pow:{enabled:true,autostart:true,threads:1,
        cpu_percent:1,hashrate:0,claims_submitted:0,state:"wallet_locked_or_staking_only"}}'
}

make_recovery()
{
    local generation=${1:-10} tip=${2:-}
    [[ -n "$tip" ]] || tip=$(printf 'd%.0s' {1..64})
    jq -cn --arg tip "$tip" --argjson generation "$generation" '{
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
      unanchored_claim_txids:[],wallet_generation:$generation,
      wallet_processed_height:1000,wallet_processed_tip:$tip,wallet_tip_matches:true}'
}

make_wallet_state()
{
    local recovery=$1 txid=${2:-} txcount=${3:-0} transactions='[]'
    [[ -z "$txid" ]] || transactions=$(jq -cn --arg txid "$txid" \
      '[{txid:$txid,category:"receive",abandoned:false}]')
    jq -cn --argjson recovery "$recovery" --argjson transactions "$transactions" \
      --argjson txcount "$txcount" '{wallet:{walletname:"",private_keys_enabled:true,
        quantum_keys:1,keypoolsize:100,keypoolsize_hd_internal:100,txcount:$txcount,
        unlocked_until:9999999999},loaded_wallets:[""],recovery:$recovery,
        transactions:$transactions,quantum_inventory:{count:1},payout:"qq-payout",
        chain:{bestblockhash:$recovery.active_tip,blocks:$recovery.active_height,
          headers:$recovery.active_height,initialblockdownload:false}}'
}

make_delta()
{
    local recovery before after
    recovery=$(make_recovery)
    before=$(make_wallet_state "$recovery")
    after=$(make_wallet_state "$recovery")
    v3015_make_wallet_audit "$before" "$after"
}

make_claim_delta()
{
    local tip claim anchor family zero before_recovery after_recovery before after
    tip=$(printf 'd%.0s' {1..64}); claim=$(printf 'a%.0s' {1..64})
    anchor=$(printf 'b%.0s' {1..64}); family=$(printf 'c%.0s' {1..64})
    zero=$(printf '0%.0s' {1..64})
    before_recovery=$(make_recovery 10 "$tip")
    after_recovery=$(jq -cn --argjson r "$before_recovery" --arg claim "$claim" \
      --arg anchor "$anchor" --arg family "$family" --arg zero "$zero" --arg tip "$tip" '
      $r | .actionable_quarantined_claims=1 | .blocking_components=1 |
      .blocking_quarantined_claims=1 | .components=1 | .raw_claim_objects=1 |
      .quarantined_claim_objects=1 | .raw_quarantined_claims=1 |
      .component_details=[{all_claims_expired_locally_retired:false,
        all_claims_explicitly_provenanced:true,all_claims_quarantined:true,
        all_claims_zero_payment_retirable:false,
        anchor:{amount:1000,scriptPubKey:"51",txid:$anchor,vout:0},
        anchor_authenticated:true,anchor_unspent:true,claim_txids:[$claim],
        classification:"current_branch_ineligible",component_fingerprint:$family,
        descendant_claims:0,generation_fingerprint:$family,
        has_revalidating_unbound_proof:false,minimum_stale_depth:1,
        nodes:[{abandoned:false,active_chain_confirmed:false,authored_metadata_valid:true,
          authored_tip_active_branch_bound:true,claim_descriptor_valid:true,
          disposition:"origin-expired",exact_authored_carrier_shape:true,expected_shape:true,
          expired_locally_retired:false,in_mempool:false,kind:"claim",
          lineage_family_fingerprint:$family,lineage_metadata_present:true,
          lineage_metadata_valid:true,lineage_ordinal:0,lineage_parent_txid:$zero,
          lineage_root_txid:$claim,proof_evaluation_skipped_resolved_anchor:false,
          proof_input_bound:true,proof_may_revalidate_on_descendant:false,proof_mode:"pow",
          proof_origin_bound:true,proof_origin_height:999,
          proof_origin_previous_block_hash:$tip,proof_version:2,
          provenance:"explicit_authored",quarantined:true,relay_expiry_time:0,
          relay_ttl_expired:false,resolution_metadata_valid:false,
          resolution_relay_authorized:false,stale_depth:1,stale_depth_known:true,
          txid:$claim,wallet_authored:true,wallet_from_me:true}],
        ordinary_or_mixed_txids:[],resolution_txids:[],root_claim_txids:[$claim],
        stale_depth_known:true}]')
    before=$(make_wallet_state "$before_recovery")
    after=$(make_wallet_state "$after_recovery" "$claim" 1)
    v3015_make_wallet_audit "$before" "$after"
}

make_sibling_claim_delta()
{
    local base before after sibling
    sibling=$(printf 'e%.0s' {1..64})
    base=$(make_claim_delta)
    before=$(jq -c '.before' <<<"$base")
    after=$(jq -c --arg sibling "$sibling" '
      .after |
      (.recovery.component_details[0].nodes[0] |
        .txid=$sibling | .lineage_ordinal=1 |
        .lineage_parent_txid=.lineage_root_txid) as $sibling_node |
      .recovery.component_details[0].nodes += [$sibling_node] |
      .recovery.component_details[0].claim_txids += [$sibling] |
      .recovery.component_details[0].root_claim_txids += [$sibling] |
      .recovery.raw_claim_objects=2 | .recovery.quarantined_claim_objects=2 |
      .transactions += [{txid:$sibling,category:"receive",abandoned:false}] |
      .wallet.txcount=2' <<<"$base")
    v3015_make_wallet_audit "$before" "$after"
}

for action in create_new_anchor refresh_same_anchor wait_for_live wait_for_next_tip relay_existing; do
    fp=$(printf '%064x' 10)
    if [[ "$action" == create_new_anchor || "$action" == refresh_same_anchor ]]; then
        pow=$(make_pow "$action" "$fp" 0.1 0)
    else
        pow=$(make_pow "$action" "$fp" 0 0)
    fi
    expect_pass "typed gate accepts $action" v3015_pow_json_is_typed_safe "$pow"
done

pow=$(make_pow wait_for_live "$(printf '%064x' 11)" 0 0 | jq '.mining_gate_unsafe_claims=1')
expect_fail 'typed gate rejects unsafe claim' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow relay_existing "$(printf '%064x' 12)" 0 0 | jq 'del(.mining_gate_coherent)')
expect_fail 'typed gate rejects partial schema' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow relay_existing "$(printf '%064x' 12)" 0 0 | jq '.unexpected_field=true')
expect_fail 'typed gate rejects unexpected schema field' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow create_new_anchor "$(printf '%064x' 12)" 0.1 0 | jq '.allow_automatic_quantum_key_creation=true')
expect_fail 'typed gate rejects automatic key authority' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow refresh_same_anchor "$(printf '%064x' 13)" 0.1 0 | jq '.mining_gate_database_ambiguous=true')
expect_fail 'typed gate rejects database ambiguity' v3015_pow_json_is_typed_safe "$pow"
expect_pass 'four-tip wait series is live' v3015_pow_series_is_live "$(make_samples wait_for_next_tip)"
stale=$(make_samples wait_for_next_tip | jq '.[].pow.mining_gate_candidate_state_fingerprint = ("f"*64)')
expect_fail 'unchanged wait fingerprint across tip change fails' v3015_pow_series_is_live "$stale"
no_work=$(make_samples create_new_anchor | jq '.[].pow.hashrate=0 | .[].pow.claims_submitted=0')
expect_fail 'create action requires bounded work or submission progress' v3015_pow_series_is_live "$no_work"
one_old_hash=$(make_samples create_new_anchor | jq '.[1:] |= map(.pow.hashrate=0)')
expect_fail 'one old hash sample cannot satisfy later create intervals' \
  v3015_pow_series_is_live "$one_old_hash"
count_progress=$(make_samples refresh_same_anchor | jq \
  '.[].pow.hashrate=0 | to_entries | map(.value.pow.claims_submitted=.key | .value)')
expect_pass 'strict submission-count increase satisfies each refresh interval' \
  v3015_pow_series_is_live "$count_progress"
expect_pass 'create action accepts bounded hashrate evidence' v3015_pow_series_is_live "$(make_samples create_new_anchor)"
bad_sample=$(make_samples wait_for_live | jq '.[2].wallet_processed_tip = ("f"*64)')
expect_fail 'sample series rejects stale wallet generation tip' v3015_pow_series_is_live "$bad_sample"

expect_pass 'active legacy PoS contract passes' v3015_pos_json_is_active "$(make_pos)"
bad_pos=$(make_pos | jq '.weight=0')
expect_fail 'zero legacy weight fails PoS contract' v3015_pos_json_is_active "$bad_pos"
expect_pass 'locked restart retains both worker intents' v3015_locked_restart_json_is_valid "$(make_locked)"
bad_locked=$(make_locked | jq '.normal_unlock_called=true')
expect_fail 'pre-proof unlock fails locked restart contract' v3015_locked_restart_json_is_valid "$bad_locked"
bad_locked=$(make_locked | jq '.pow.claims_submitted=1')
expect_fail 'locked restart rejects a submitted claim' v3015_locked_restart_json_is_valid "$bad_locked"
expect_pass 'empty wallet delta is safe' v3015_wallet_delta_is_safe "$(make_delta)"
claim_delta=$(make_claim_delta)
expect_pass 'authenticated unspent same-anchor claim delta is safe' \
  v3015_wallet_delta_is_safe "$claim_delta"
expect_pass 'same-input sibling roots preserve authenticated lineage topology' \
  v3015_wallet_delta_is_safe "$(make_sibling_claim_delta)"
bad_delta=$(make_delta | jq '.after.recovery.confirmed_resolution_fees=0.01')
expect_fail 'recovery fee delta fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.quantum_inventory.count=2')
expect_fail 'new key fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.recovery.automatic_fee_exposure_in_window=0.01')
expect_fail 'automatic recovery fee exposure fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.delta.removed_txids=[("a"*64)]')
expect_fail 'declared removed txid mismatch fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.wallet.txcount=1')
expect_fail 'incomplete transaction inventory fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.recovery.policy.mode="pause_and_ask"')
expect_fail 'recovery policy drift fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.delta.transactions=[{txid:("a"*64),
  authenticated_same_anchor_claim:true,normal_coinstake:true,
  authenticated_synthetic_payout:false,exactly_one_allowed_class:true,
  per_tx_abandoned:false,cleanup:false,recovery:false,resolution:false,recovery_fee:0}]')
expect_fail 'fabricated or multiply classified transaction fails wallet contract' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].anchor_unspent=false' <<<"$claim_delta")
expect_fail 'spent claim anchor fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].proof_origin_bound=false' \
  <<<"$claim_delta")
expect_fail 'origin-unbound claim fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].proof_input_bound=false' \
  <<<"$claim_delta")
expect_fail 'input-unbound claim fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.transactions[0].abandoned=true' <<<"$claim_delta")
expect_fail 'per-transaction abandonment fails wallet contract' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.transactions[0].qq_synthetic_goldrush_payout="1" |
  .after.transactions[0].blockhash=("e"*64)' <<<"$claim_delta")
expect_fail 'one transaction cannot claim two allowed classes' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.unexpected_schema_key=true' <<<"$claim_delta")
expect_fail 'unexpected recovery schema key fails wallet contract' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].lineage_family_fingerprint=("f"*64)' \
  <<<"$claim_delta")
expect_fail 'claim lineage family must equal component generation' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].lineage_root_txid=("f"*64)' \
  <<<"$claim_delta")
expect_fail 'claim lineage root must be an authenticated component root' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].root_claim_txids=[]' <<<"$claim_delta")
expect_fail 'claim component cannot omit its lineage root' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].lineage_ordinal=7' \
  <<<"$claim_delta")
expect_fail 'root claim ordinal must be zero' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].nodes[0].lineage_parent_txid=("f"*64)' \
  <<<"$claim_delta")
expect_fail 'root claim parent must be the null txid' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.raw_claim_objects=2' <<<"$claim_delta")
expect_fail 'raw claim summary must equal typed claim nodes' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.quarantined_claim_objects=0' <<<"$claim_delta")
expect_fail 'quarantined claim summary must equal typed node flags' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.live_claim_objects=1' <<<"$claim_delta")
expect_fail 'live claim summary must equal typed mempool flags' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.blocking_components=0' <<<"$claim_delta")
expect_fail 'blocking summary must equal typed component classifications' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.retired_components=1 | .after.recovery.retired_claim_objects=1' \
  <<<"$claim_delta")
expect_fail 'retired summaries must equal typed component classifications' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.resolved_components=1' <<<"$claim_delta")
expect_fail 'resolved summary must equal typed component classifications' \
  v3015_wallet_delta_is_safe "$bad_delta"

image="qqblackcoin/blackcoin-v4-gui@sha256:$(printf '1%.0s' {1..64})"
image_id="sha256:$(printf '2%.0s' {1..64})"
expect_pass 'regular Compose overlay renders' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes='1 31' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q -- '- -powmining=1'"
expect_pass 'Free Claim overlay hard-disables regular PoW' bash -c \
  "awk -v image_ref='$image' -v role=free_claim -v nodes=30 -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q -- '- -powmining=0'"
expect_pass 'Compose wrapper body has reviewed exact hash' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes=1 -f '$package_dir/render_compose_runtime.awk' /dev/null | awk '/- \|/{body=1;next} /      - node1-v3015-rollout/{exit} body{sub(/^          /,\"\");print}' | sed 's/[$][$]/$/g' | sha256sum | grep -q '^753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4'"
expect_fail 'Compose overlay rejects mutable tag' awk -v image_ref=example:latest -v role=regular -v nodes=1 -f "$package_dir/render_compose_runtime.awk" /dev/null
expect_fail 'Compose overlay rejects node outside fleet' awk -v image_ref="$image" -v role=regular -v nodes=33 -f "$package_dir/render_compose_runtime.awk" /dev/null

policy_in="$tmp/policy.json"
jq -cn 'reduce range(1;33) as $n ({schema:1,images:{},nodes:{}};
  .nodes[(if $n < 10 then "0" + ($n|tostring) else ($n|tostring) end)] = "old")' >"$policy_in"
expect_pass 'policy renderer assigns regular role' "$package_dir/render_policy.sh" "$policy_in" "$tmp/policy-out.json" "$image" "$image_id" regular 1 2
expect_fail 'policy renderer rejects node30 as regular' "$package_dir/render_policy.sh" "$policy_in" "$tmp/bad-policy.json" "$image" "$image_id" regular 30

guard_runtime="$tmp/runtime.guard"
guard_endpoint="$tmp/endpoint.guard"
printf '%s\n' '#!/usr/bin/env bash' 'STATE_DIR=/tmp/v3015-test-state' \
  'exec 7>/tmp/v3015-test-runtime.lock' 'flock -n 7 || exit 1' 'exit 0' >"$guard_runtime"
runtime_guard_sha=$(sha256sum "$guard_runtime" | awk '{print $1}')
printf '%s\n' '#!/usr/bin/env bash' 'STATE_DIR=/tmp/v3015-test-state' \
  "EXPECTED_RUNTIME_GUARD_SHA='$runtime_guard_sha'" \
  'exec 9>/tmp/v3015-test-endpoint.lock' 'flock -n 9 || exit 0' 'exit 0' >"$guard_endpoint"
endpoint_guard_sha=$(sha256sum "$guard_endpoint" | awk '{print $1}')
guard_env="$tmp/guard.env"
printf "EXPECTED_RUNTIME_GUARD_SHA256='%s'\nEXPECTED_ENDPOINT_GUARD_SHA256='%s'\n" \
  "$runtime_guard_sha" "$endpoint_guard_sha" >"$guard_env"
expect_pass 'guard renderer inserts exact inhibitor and updates endpoint pin' \
  "$package_dir/install_runtime_guard_3015_compat.sh" render "$guard_env" \
  "$guard_runtime" "$guard_endpoint" "$tmp/rendered-guards"
expect_pass 'rendered endpoint pins rendered runtime bytes' bash -c \
  "sha=\$(sha256sum '$tmp/rendered-guards/runtime.guard' | awk '{print \$1}'); grep -Fqx \"EXPECTED_RUNTIME_GUARD_SHA='\$sha'\" '$tmp/rendered-guards/endpoint.guard'"
bad_runtime="$tmp/runtime-no-anchor.guard"
printf '%s\n' '#!/usr/bin/env bash' 'STATE_DIR=/tmp/v3015-test-state' 'exit 0' >"$bad_runtime"
bad_runtime_sha=$(sha256sum "$bad_runtime" | awk '{print $1}')
bad_guard_env="$tmp/bad-guard.env"
printf "EXPECTED_RUNTIME_GUARD_SHA256='%s'\nEXPECTED_ENDPOINT_GUARD_SHA256='%s'\n" \
  "$bad_runtime_sha" "$endpoint_guard_sha" >"$bad_guard_env"
expect_fail 'guard renderer rejects missing exact lock anchor' \
  "$package_dir/install_runtime_guard_3015_compat.sh" render "$bad_guard_env" \
  "$bad_runtime" "$guard_endpoint" "$tmp/bad-rendered-guards"

partial_compose_is_contained()
{
    local harness="$tmp/partial-compose-harness.sh" marker="$tmp/partial-contained"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' \
          "container='blackcoin-v4-gui-1'" "node=1" 'candidate_started=0' 'contained=0' \
          "COMPOSE_FILE=/fixture/compose" "overlay=/fixture/overlay" 'service=node1'
        # shellcheck disable=SC2016 # Literal body is evaluated by the child harness.
        printf '%s\n' "v3015_contain_container(){ printf contained >'$marker'; }" \
          'docker(){ [[ "$1" == compose ]] && return 73; return 1; }'
        sed -n '/^contain_on_failure()/,/^}/p' "$package_dir/native_restart_durability.sh"
        sed -n '/^start_candidate_recreate()/,/^}/p' "$package_dir/native_restart_durability.sh"
        printf '%s\n' 'trap contain_on_failure EXIT' 'start_candidate_recreate'
    } >"$harness"
    chmod +x "$harness"
    if bash "$harness" >/dev/null 2>&1; then return 1; fi
    [[ "$(<"$marker")" == contained ]]
}
expect_pass 'partial Compose failure is owned and contained by child' partial_compose_is_contained
expect_pass 'parent records containment ownership before invoking child' bash -c \
  "awk '/touched[+]={[}]?/{next} /touched[+]=[(]\"[$]node\"[)]/{t=NR} /native_restart_durability[.]sh/{if(t && t<NR) ok=1} END{exit !ok}' '$package_dir/fleet_rollout.sh'"

authority_publish_contract()
{
    local mockbin="$tmp/authority-mockbin" authority="$tmp/AUTHORITY-PUBLISH"
    mkdir -p "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mockbin/sync"
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "%s:%s:600:1\n" "$EUID" "$(id -g)"' >"$mockbin/stat"
    chmod +x "$mockbin/sync" "$mockbin/stat"
    PATH="$mockbin:$PATH" v3015_publish_authority_noclobber "$authority" <<<'first' || return 1
    [[ "$(<"$authority")" == first ]] || return 1
    if PATH="$mockbin:$PATH" v3015_publish_authority_noclobber "$authority" <<<'second'; then
        return 1
    fi
    [[ "$(<"$authority")" == first ]]
}
expect_pass 'authority publish is same-directory no-clobber' authority_publish_contract

authority_race_does_not_clobber()
{
    local mockbin="$tmp/race-mockbin" authority="$tmp/AUTHORITY-RACE"
    mkdir -p "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mockbin/sync"
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' 'target=${!#}' \
      'printf "raced\n" >"$target"' 'exec /bin/ln "$@"' >"$mockbin/ln"
    chmod +x "$mockbin/sync" "$mockbin/ln"
    if PATH="$mockbin:$PATH" v3015_publish_authority_noclobber "$authority" <<<'ours'; then
        return 1
    fi
    [[ "$(<"$authority")" == raced ]]
}
expect_pass 'authority publication race preserves preexisting winner' authority_race_does_not_clobber

authority_removal_rejects_foreign_bytes()
{
    local mockbin="$tmp/removal-mockbin" authority="$tmp/AUTHORITY-REMOVE" expected
    mkdir -p "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mockbin/sync"
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "%s:%s:600:1\n" "$EUID" "$(id -g)"' >"$mockbin/stat"
    chmod +x "$mockbin/sync" "$mockbin/stat"
    PATH="$mockbin:$PATH" v3015_publish_authority_noclobber "$authority" <<<'owned' || return 1
    expected=$(v3015_sha256_file "$authority")
    printf 'foreign\n' >"$authority"
    if PATH="$mockbin:$PATH" v3015_remove_owned_authority "$authority" "$expected"; then return 1; fi
    [[ -f "$authority" && "$(<"$authority")" == foreign ]]
}
expect_pass 'authority removal refuses changed ownership bytes' authority_removal_rejects_foreign_bytes

authority_partial_fsync_fails_closed()
{
    local mockbin="$tmp/fsync-mockbin" authority="$tmp/AUTHORITY-FSYNC"
    mkdir -p "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$mockbin/sync"
    chmod +x "$mockbin/sync"
    ! PATH="$mockbin:$PATH" v3015_publish_authority_noclobber "$authority" <<<'partial'
}
expect_pass 'authority partial fsync failure does not authorize rollout' authority_partial_fsync_fails_closed

make_vfat_authority_mockbin()
{
    local mockbin=$1
    mkdir -p "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mockbin/sync"
    # shellcheck disable=SC2016 # Literal bodies are evaluated by the mock executables.
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "%s:%s:600:1\n" "$EUID" "$(id -g)"' >"$mockbin/stat"
    # Model GNU mv -nT: an existing destination is preserved and the source
    # remains present, while a successful no-replace move consumes the source.
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' 'set -e' \
      'src=${*: -2:1}' 'dst=${*: -1}' \
      '[[ ! -e "$dst" && ! -L "$dst" ]] || exit 0' \
      'exec /bin/mv "$src" "$dst"' >"$mockbin/mv"
    # A VFAT marker path must never call the hard-link publisher.
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' \
      'printf "called\n" >"${V3015_LN_SENTINEL:?}"' 'exit 97' >"$mockbin/ln"
    chmod +x "$mockbin/sync" "$mockbin/stat" "$mockbin/mv" "$mockbin/ln"
}

vfat_authority_avoids_hardlinks()
{
    local mockbin="$tmp/vfat-publish-mockbin" marker="$tmp/VFAT-MARKER" ln_called="$tmp/vfat-ln-called"
    make_vfat_authority_mockbin "$mockbin"
    V3015_LN_SENTINEL="$ln_called" PATH="$mockbin:$PATH" \
      v3015_publish_vfat_authority_noclobber "$marker" <<<'vfat' || return 1
    [[ "$(<"$marker")" == vfat && ! -e "$ln_called" ]]
}
expect_pass 'VFAT maintenance publication never enters the hard-link path' vfat_authority_avoids_hardlinks

vfat_preexisting_authority_is_preserved()
{
    local mockbin="$tmp/vfat-preexisting-mockbin" marker="$tmp/VFAT-PREEXISTING" ln_called="$tmp/vfat-preexisting-ln"
    make_vfat_authority_mockbin "$mockbin"
    printf 'existing\n' >"$marker"
    if V3015_LN_SENTINEL="$ln_called" PATH="$mockbin:$PATH" \
      v3015_publish_vfat_authority_noclobber "$marker" <<<'ours'; then
        return 1
    fi
    [[ "$(<"$marker")" == existing && ! -e "$ln_called" ]]
}
expect_pass 'VFAT maintenance publication refuses a preexisting marker' vfat_preexisting_authority_is_preserved

vfat_authority_race_is_preserved()
{
    local mockbin="$tmp/vfat-race-mockbin" marker="$tmp/VFAT-RACE" ln_called="$tmp/vfat-race-ln"
    make_vfat_authority_mockbin "$mockbin"
    # Simulate a winner appearing between the absence check and mv -nT.
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' 'dst=${*: -1}' \
      'printf "raced\n" >"$dst"' 'exit 0' >"$mockbin/mv"
    chmod +x "$mockbin/mv"
    if V3015_LN_SENTINEL="$ln_called" PATH="$mockbin:$PATH" \
      v3015_publish_vfat_authority_noclobber "$marker" <<<'ours'; then
        return 1
    fi
    [[ "$(<"$marker")" == raced && ! -e "$ln_called" ]]
}
expect_pass 'VFAT maintenance publication race preserves the winner' vfat_authority_race_is_preserved

vfat_partial_fsync_fails_closed()
{
    local mockbin="$tmp/vfat-fsync-mockbin" marker="$tmp/VFAT-FSYNC" ln_called="$tmp/vfat-fsync-ln"
    local sync_count="$tmp/vfat-sync-count"
    make_vfat_authority_mockbin "$mockbin"
    # The temporary file sync succeeds; the committed destination sync fails.
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' 'count=0' \
      '[[ ! -f "${V3015_SYNC_COUNTER:?}" ]] || read -r count <"$V3015_SYNC_COUNTER"' \
      'count=$((count + 1))' 'printf "%s\n" "$count" >"$V3015_SYNC_COUNTER"' \
      '((count == 1))' >"$mockbin/sync"
    chmod +x "$mockbin/sync"
    if V3015_LN_SENTINEL="$ln_called" V3015_SYNC_COUNTER="$sync_count" \
      PATH="$mockbin:$PATH" v3015_publish_vfat_authority_noclobber "$marker" <<<'partial'; then
        return 1
    fi
    [[ "$(<"$marker")" == partial && "$(<"$sync_count")" == 2 && ! -e "$ln_called" ]]
}
expect_pass 'VFAT partial durability cannot authorize rollout' vfat_partial_fsync_fails_closed

make_probe_security_mockbin()
{
    local mockbin=$1 stat_value=${2:-0:0:700:1}
    mkdir -p "$mockbin"
    # shellcheck disable=SC2016 # Literal bodies are evaluated by mock executables.
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${*: -1}"' >"$mockbin/realpath"
    printf '%s\n' '#!/usr/bin/env bash' \
      "case \"\$2\" in '%u:%g:%a:%h') printf '%s\\n' '$stat_value';;" \
      "'%u:%g:%a') printf '%s\\n' '0:0:700';;" \
      "'%u:%g') printf '%s\\n' '0:0';; '%a') printf '%s\\n' '755';; esac" \
      >"$mockbin/stat"
    chmod +x "$mockbin/realpath" "$mockbin/stat"
}

probe_root_executable_contract()
{
    local mockbin="$tmp/probe-secure-mockbin" probe="$tmp/node30-probe-secure"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$probe"
    chmod 700 "$probe"
    make_probe_security_mockbin "$mockbin"
    PATH="$mockbin:$PATH" v3015_secure_root_executable "$probe"
}
expect_pass 'node30 probe requires exact root executable contract' probe_root_executable_contract

probe_wrong_mode_owner_or_link_fails()
{
    local mockbin="$tmp/probe-wrong-mode-mockbin" probe="$tmp/node30-probe-wrong-mode"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$probe"
    chmod 700 "$probe"
    make_probe_security_mockbin "$mockbin" '1:0:755:2'
    ! PATH="$mockbin:$PATH" v3015_secure_root_executable "$probe"
}
expect_pass 'node30 probe rejects wrong owner mode or link count' probe_wrong_mode_owner_or_link_fails

probe_symlink_fails()
{
    local mockbin="$tmp/probe-symlink-mockbin" target="$tmp/node30-probe-target"
    local probe="$tmp/node30-probe-link"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$target"
    chmod 700 "$target"
    ln -s "$target" "$probe"
    make_probe_security_mockbin "$mockbin"
    ! PATH="$mockbin:$PATH" v3015_secure_root_executable "$probe"
}
expect_pass 'node30 probe rejects a symlink' probe_symlink_fails

probe_writable_ancestry_fails()
{
    local mockbin="$tmp/probe-ancestry-mockbin" probe="$tmp/node30-probe-ancestry"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$probe"
    chmod 700 "$probe"
    make_probe_security_mockbin "$mockbin"
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' \
      'case "$2" in "%u:%g") printf "0:0\n";; "%a") printf "777\n";; esac' \
      >"$mockbin/stat"
    chmod +x "$mockbin/stat"
    ! PATH="$mockbin:$PATH" v3015_secure_ancestry "$probe"
}
expect_pass 'node30 probe rejects writable ancestry' probe_writable_ancestry_fails

probe_copy_drift_fails_closed()
{
    local mockbin="$tmp/probe-copy-drift-mockbin" source="$tmp/node30-probe-source"
    local outdir="$tmp/probe-pinned-dir" output="$tmp/probe-pinned-dir/probe" expected
    mkdir "$outdir"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$source"
    chmod 700 "$source"
    expected=$(v3015_sha256_file "$source")
    make_probe_security_mockbin "$mockbin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$mockbin/sync"
    # A source replacement during the copy must be caught by the copied-byte rehash.
    # shellcheck disable=SC2016 # Literal body is evaluated by the mock executable.
    printf '%s\n' '#!/usr/bin/env bash' 'dst=${*: -1}' \
      'printf "drifted\n" >"$dst"' 'chmod 700 "$dst"' >"$mockbin/install"
    chmod +x "$mockbin/sync" "$mockbin/install"
    if PATH="$mockbin:$PATH" v3015_stage_root_executable_copy \
      "$source" "$expected" "$output"; then
        return 1
    fi
    [[ ! -e "$output" && ! -L "$output" ]]
}
expect_pass 'node30 pinned probe copy rejects TOCTOU byte drift' probe_copy_drift_fails_closed

env_file="$tmp/reviewed.env"
fixture_source='0123456789abcdef0123456789abcdef01234567'
fixture_tree='89abcdef0123456789abcdef0123456789abcdef'
hex3=$(printf '3%.0s' {1..64}); hex4=$(printf '4%.0s' {1..64}); hex5=$(printf '5%.0s' {1..64})
hex6=$(printf '6%.0s' {1..64}); hex7=$(printf '7%.0s' {1..64}); hex8=$(printf '8%.0s' {1..64})
hex9=$(printf '9%.0s' {1..64}); hexa=$(printf 'a%.0s' {1..64}); hexb=$(printf 'b%.0s' {1..64})
policy_receipt="$tmp/runtime-policy-handoff-receipt.json"
compose_receipt="$tmp/persistent-compose-handoff-receipt.json"
reconcile_proof="$tmp/post-compose-reconcile-identity.json"
receipt_nonce='fedcba9876543210fedcba9876543210'
jq -cn --arg source "$fixture_source" --arg image "$image" --arg image_id "$image_id" \
  --arg compose "$hex8" --arg policy "$hex7" '{schema:1,
  kind:"post-compose-candidate-identity",source_sha:$source,candidate_image_ref:$image,
  candidate_image_id:$image_id,network_version:300105,subversion:"/Blackcoin:30.1.5/",
  final_compose_sha256:$compose,final_image_policy_sha256:$policy,
  regular_nodes:([range(1;30)]+[31,32]),node30_role:"free_claim",
  verified_utc:"2026-08-10T00:00:00Z"}' >"$reconcile_proof"
reconcile_sha=$(sha256sum "$reconcile_proof" | awk '{print $1}')
jq -cn --arg source "$fixture_source" --arg image "$image" --arg image_id "$image_id" \
  --arg before "$hex6" --arg after "$hex7" --arg runtime "$hex9" --arg endpoint "$hexa" \
  --arg reconcile_path "$reconcile_proof" --arg reconcile "$reconcile_sha" \
  --arg nonce "$receipt_nonce" '{schema:1,
  kind:"runtime-policy-handoff",source_sha:$source,candidate_image_ref:$image,
  candidate_image_id:$image_id,network_version:300105,subversion:"/Blackcoin:30.1.5/",
  image_policy_path:"/boot/config/plugins/blackcoin-quantum-nodes/fleet-image-policy.json",
  image_policy_before_sha256:$before,image_policy_after_sha256:$after,
  runtime_guard_path:"/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_wallet_runtime_guard.sh",
  runtime_guard_sha256:$runtime,
  endpoint_guard_path:"/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_endpoint_guard.sh",
  endpoint_guard_sha256:$endpoint,regular_nodes:([range(1;30)]+[31,32]),
  node30_role:"free_claim",semantic_300105_accepted:true,atomic_install:true,
  durable_parent_fsync:true,post_reconcile_candidate_identity_path:$reconcile_path,
  post_reconcile_candidate_identity_sha256:$reconcile,
  receipt_nonce:$nonce}' >"$policy_receipt"
policy_receipt_sha=$(sha256sum "$policy_receipt" | awk '{print $1}')
jq -cn --arg source "$fixture_source" --arg image "$image" --arg image_id "$image_id" \
  --arg before "$hex6" --arg after "$hex8" --arg policy "$hex7" \
  --arg policy_receipt "$policy_receipt_sha" --arg runtime "$hex9" --arg endpoint "$hexa" \
  --arg reconcile_path "$reconcile_proof" --arg reconcile "$reconcile_sha" \
  --arg nonce "$receipt_nonce" '{schema:1,
  kind:"persistent-compose-handoff",source_sha:$source,candidate_image_ref:$image,
  candidate_image_id:$image_id,network_version:300105,subversion:"/Blackcoin:30.1.5/",
  compose_path:"/boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml",
  compose_before_sha256:$before,compose_after_sha256:$after,
  image_policy_path:"/boot/config/plugins/blackcoin-quantum-nodes/fleet-image-policy.json",
  image_policy_after_sha256:$policy,runtime_policy_receipt_sha256:$policy_receipt,
  runtime_guard_path:"/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_wallet_runtime_guard.sh",
  runtime_guard_sha256:$runtime,
  endpoint_guard_path:"/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_endpoint_guard.sh",
  endpoint_guard_sha256:$endpoint,regular_nodes:([range(1;30)]+[31,32]),
  node30_role:"free_claim",semantic_300105_accepted:true,atomic_install:true,
  durable_parent_fsync:true,post_reconcile_candidate_identity_path:$reconcile_path,
  post_reconcile_candidate_identity_sha256:$reconcile,
  receipt_nonce:$nonce}' >"$compose_receipt"
compose_receipt_sha=$(sha256sum "$compose_receipt" | awk '{print $1}')
{
    printf "SOURCE_SHA='%s'\n" "$fixture_source"
    printf "SOURCE_TREE='%s'\n" "$fixture_tree"
    printf "SOURCE_SIGNING_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'\nSOURCE_SIGNATURE_VERIFIED='1'\n"
    printf "CORE_VERSION_NUMERIC='300105'\nCORE_SUBVERSION='/Blackcoin:30.1.5/'\n"
    printf "RUNTIME_ENTRYPOINT_BODY_SHA256='753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4'\n"
    printf "CORE_CI_RUN_ID='999999'\nCORE_CI_HEAD_SHA='%s'\nCORE_CI_CONCLUSION='success'\n" "$fixture_source"
    printf "CORE_CI_WORKFLOW='critical-protocol-safety-fixture'\n"
    printf "CANDIDATE_ARTIFACT_NAME='v3015-linux-x86_64-fixture'\nCANDIDATE_ARTIFACT_RUN_ID='888888'\nCANDIDATE_ARTIFACT_RUN_ATTEMPT='1'\n"
    printf "CANDIDATE_IMAGE_REF='%s'\nCANDIDATE_IMAGE_ID='%s'\n" "$image" "$image_id"
    printf "CANDIDATE_BUNDLE_SHA256='%s'\nCANDIDATE_OCI_ARCHIVE_SHA256='%s'\n" "$hex3" "$hex4"
    printf "CANDIDATE_OCI_MANIFEST_SHA256='%s'\nCANDIDATE_BLACKCOIND_SHA256='%s'\n" "$hex5" "$hex6"
    printf "CANDIDATE_BLACKCOIN_CLI_SHA256='%s'\nCANDIDATE_BLACKCOIN_QT_SHA256='%s'\n" "$hex7" "$hex8"
    printf "CANDIDATE_BLACKCOIN_TX_SHA256='%s'\nCANDIDATE_BLACKCOIN_WALLET_SHA256='%s'\nCANDIDATE_BLACKCOIN_UTIL_SHA256='%s'\n" "$hex7" "$hex8" "$hex9"
    printf "CANDIDATE_TOOLING_SHA256='%s'\nPHASE_B_RESULT_SHA256='%s'\n" "$hex9" "$hexa"
    printf "CANDIDATE_MANIFEST_SHA256='%s'\nCANDIDATE_PROVENANCE_SHA256='%s'\n" "$hex5" "$hex6"
    printf "PHASE_B_PROMOTION_MARKER_SHA256='%s'\nNINE_PATH_CANARY_SEAL_SHA256='%s'\n" "$hexb" "$hex3"
    printf "PHASE_A_RESULT_SHA256='%s'\nNINE_PATH_TOOLING_COMMIT='%s'\n" "$hex4" "$fixture_source"
    printf "NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256='%s'\nNINE_PATH_PHASE_B_SCRIPT_SHA256='%s'\n" "$hex5" "$hex6"
    printf "NINE_PATH_VERIFIER_SHA256='%s'\nNINE_PATH_TYPED_CONTRACT_SHA256='%s'\n" "$hex7" "$hex8"
    printf "PACKAGE_SHA256SUMS_SHA256='%s'\n" "$hex4"
    printf "PHASE_B_RESULT='/fixture/phase-b/RESULT.json'\nPHASE_B_PROMOTION_MARKER='/fixture/phase-b/PROMOTED_NO_REWIND'\n"
    printf "NINE_PATH_CANARY_SHA256SUMS='/fixture/phase-b/NINE_PATH_SHA256SUMS'\n"
    printf "PACKAGE_SHA256SUMS='/fixture/package/SHA256SUMS'\nRELEASE_IDENTITY_JSON='/fixture/release-identity.json'\n"
    printf "NODE30_FREE_CLAIM_PROBE='/fixture/node30-probe'\nNODE30_FREE_CLAIM_PROBE_SHA256='%s'\n" "$hex5"
    printf "EXPECTED_COMPOSE_SHA256='%s'\nEXPECTED_RUNTIME_GUARD_SHA256='%s'\n" "$hex6" "$hex7"
    printf "EXPECTED_ENDPOINT_GUARD_SHA256='%s'\nRENDERED_RUNTIME_GUARD_SHA256='%s'\n" "$hex8" "$hex9"
    printf "RENDERED_ENDPOINT_GUARD_SHA256='%s'\n" "$hexa"
    printf "IMAGE_POLICY_PATH='/boot/config/plugins/blackcoin-quantum-nodes/fleet-image-policy.json'\n"
    printf "EXPECTED_IMAGE_POLICY_SHA256='%s'\nFINAL_IMAGE_POLICY_SHA256='%s'\n" "$hex6" "$hex7"
    printf "FINAL_COMPOSE_SHA256='%s'\nPOST_COMPOSE_RECONCILE_IDENTITY_PROOF='%s'\n" "$hex8" "$reconcile_proof"
    printf "POST_COMPOSE_RECONCILE_IDENTITY_SHA256='%s'\n" "$reconcile_sha"
    printf "RUNTIME_POLICY_HANDOFF_RECEIPT='%s'\nRUNTIME_POLICY_HANDOFF_RECEIPT_SHA256='%s'\n" "$policy_receipt" "$policy_receipt_sha"
    printf "PERSISTENT_COMPOSE_HANDOFF_RECEIPT='%s'\nPERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256='%s'\n" "$compose_receipt" "$compose_receipt_sha"
    printf "NORMAL_UNLOCK_HELPER_SHA256='acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1'\n"
    printf "COMPOSE_FILE='/boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml'\n"
    printf "EVIDENCE_ROOT='/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.5-rollout'\n"
    printf "STATE_DIR='/boot/config/plugins/blackcoin-quantum-nodes'\n"
    printf "RUNTIME_GUARD_PATH='/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_wallet_runtime_guard.sh'\n"
    printf "ENDPOINT_GUARD_PATH='/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_endpoint_guard.sh'\n"
    printf "NORMAL_UNLOCK_HELPER='/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh'\n"
    printf "PHASE_B_STATUS='PASS'\nPHASE_B_NO_REWIND='1'\nROLLOUT_IDENTITY_RECONCILED='1'\n"
    printf "LIVE_EXECUTION_CLEARED='v30.1.5:%s:0123456789abcdef0123456789abcdef'\n" "$fixture_source"
    printf "NATIVE_RESTART_CLEARED='v30.1.5-native-restart:%s:0123456789abcdef0123456789abcdef'\n" "$fixture_source"
} >"$env_file"

# shellcheck disable=SC1090 # Synthetic reviewed environment for predicates.
source "$env_file"
phase_b_fixture="$tmp/phase-b"
mkdir "$phase_b_fixture"
jq -cn --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg image_id "$CANDIDATE_IMAGE_ID" --arg manifest "${CANDIDATE_IMAGE_REF##*@}" \
  --arg phase_a "$PHASE_A_RESULT_SHA256" --arg package "$NINE_PATH_CANARY_SEAL_SHA256" \
  --arg tooling_commit "$NINE_PATH_TOOLING_COMMIT" \
  --arg tooling "$NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256" \
  --arg script "$NINE_PATH_PHASE_B_SCRIPT_SHA256" --arg verifier "$NINE_PATH_VERIFIER_SHA256" \
  --arg contract "$NINE_PATH_TYPED_CONTRACT_SHA256" '{schema:1,state:"PROMOTED_NO_REWIND",node:27,
  candidate_source_sha:$source,candidate_image_ref:$image,candidate_image_id:$image_id,
  candidate_manifest_digest:$manifest,created_utc:"2026-08-10T00:00:00Z",
  data_rewind_permanently_prohibited:true,marker_fsync_verified:true,
  package_sha256sums_sha256:$package,parent_directory_fsync_verified:true,
  phase_a_authority_receipt_sha256:("1"*64),phase_a_evidence_sha256sums_sha256:("2"*64),
  phase_a_result_sha256:$phase_a,phase_a_rewind_safe_sha256:("3"*64),
  phase_a_run_nonce:("1"*32),phase_b_script_sha256:$script,
  phase_b_tooling_identity_sha256:$tooling,promotion_nonce:("2"*32),reread_verified:true,
  snapshots_absent_before_marker:true,storage_absence_sha256:("4"*64),
  tooling_commit:$tooling_commit,typed_contract_sha256:$contract,verifier_sha256:$verifier}' \
  >"$phase_b_fixture/PROMOTED_NO_REWIND"
phase_b_marker_sha=$(sha256sum "$phase_b_fixture/PROMOTED_NO_REWIND" | awk '{print $1}')
jq -cn --arg source "$SOURCE_SHA" --arg marker "$phase_b_marker_sha" \
  --arg phase_a "$PHASE_A_RESULT_SHA256" --arg package "$NINE_PATH_CANARY_SEAL_SHA256" \
  --arg tooling_commit "$NINE_PATH_TOOLING_COMMIT" \
  --arg tooling "$NINE_PATH_PHASE_B_TOOLING_IDENTITY_SHA256" \
  --arg script "$NINE_PATH_PHASE_B_SCRIPT_SHA256" --arg verifier "$NINE_PATH_VERIFIER_SHA256" \
  --arg contract "$NINE_PATH_TYPED_CONTRACT_SHA256" '{schema:2,phase:"B",node:27,
  result:"passed",candidate_source_sha:$source,baseline_automatic_fee_exposure_in_window:0,
  baseline_confirmed_resolution_fees:0,baseline_health_gate_passed:true,
  baseline_pending_automatic_resolutions:0,baseline_pending_manual_resolutions:0,
  baseline_precondition_sha256:("1"*64),baseline_cutover_stop_sha256:("2"*64),
  baseline_recovery_metrics_sha256:("3"*64),baseline_recovery_policy_sha256:("4"*64),
  promoted_no_rewind_marker_verified:true,marker_sha256:$marker,
  snapshots_absent_before_launch:true,datasets_preserved:true,candidate_running:true,
  final_container_identity_stable:true,final_container_sha256:("5"*64),
  final_envelope_sha256:("6"*64),invocation_sha256:("7"*64),
  live_dataset_identity_sha256:("8"*64),
  wallet_chain_synchronized_before_unlock:true,normal_unlock_completed:true,pos_active:true,
  pos_explicitly_enabled:true,pow_policy_restored:true,p2p_ready:true,typed_gate_safe:true,
  payout_unchanged:true,package_sha256sums_sha256:$package,phase_a_result_sha256:$phase_a,
  phase_b_progress_sha256:("9"*64),phase_b_script_sha256:$script,
  phase_b_tooling_identity_sha256:$tooling,pre_result_manifest_sha256:("a"*64),
  quantum_keys_unchanged:true,recovery_fees_unchanged:true,resolution_txids_unchanged:true,
  recovery_counters_unchanged:true,recovery_policy_unchanged:true,
  wallet_delta_fully_classified:true,only_allowed_wallet_delta_classes_added:true,
  failure_policy:"contain-stop-preserve",old_core_autostarted:false,
  data_rewind_performed:false,storage_absence_recheck_sha256:("b"*64),
  tooling_commit:$tooling_commit,typed_contract_sha256:$contract,verifier_sha256:$verifier,
  wallet_delta_raw_sha256:("c"*64),wallet_delta_sha256:("d"*64)}' \
  >"$phase_b_fixture/RESULT.json"
expect_pass 'completed no-rewind Phase-B contract passes' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-bad.json"
jq '.data_rewind_performed=true' "$phase_b_fixture/RESULT-bad.json" \
  >"$phase_b_fixture/change" && mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-bad.json"
expect_fail 'Phase-B contract rejects data rewind' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT-bad.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-mixed.json"
jq '.phase_a_result_sha256=("f"*64)' "$phase_b_fixture/RESULT-mixed.json" \
  >"$phase_b_fixture/change" && mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-mixed.json"
expect_fail 'Phase-B contract rejects mixed Phase-A run' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT-mixed.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-package.json"
jq '.package_sha256sums_sha256=("f"*64)' "$phase_b_fixture/RESULT-package.json" \
  >"$phase_b_fixture/change" && mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-package.json"
expect_fail 'Phase-B contract rejects mixed nine-path package' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT-package.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-tooling.json"
jq '.typed_contract_sha256=("f"*64)' "$phase_b_fixture/RESULT-tooling.json" \
  >"$phase_b_fixture/change" && mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-tooling.json"
expect_fail 'Phase-B contract rejects mixed tooling identity' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT-tooling.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-extra-key.json"
jq '.unexpected=true' "$phase_b_fixture/RESULT-extra-key.json" \
  >"$phase_b_fixture/change" && mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-extra-key.json"
expect_fail 'Phase-B contract rejects extra result key' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT-extra-key.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
evidence="$tmp/evidence"
mkdir "$evidence"
jq -cn --arg source "$SOURCE_SHA" --arg tree "$SOURCE_TREE" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg image_id "$CANDIDATE_IMAGE_ID" --arg bundle "$CANDIDATE_BUNDLE_SHA256" \
  --arg oci "$CANDIDATE_OCI_ARCHIVE_SHA256" --arg oci_manifest "$CANDIDATE_OCI_MANIFEST_SHA256" \
  --arg tooling "$CANDIDATE_TOOLING_SHA256" \
  --arg node30_probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg phase_b "$PHASE_B_RESULT_SHA256" --arg marker "$PHASE_B_PROMOTION_MARKER_SHA256" \
  --arg canary "$NINE_PATH_CANARY_SEAL_SHA256" '{schema:1,release:"v30.1.5",
    source_sha:$source,source_tree:$tree,source_signature_verified:true,
    source_signing_fingerprint:"SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70",
    core_ci:{run_id:999999,head_sha:$source,conclusion:"success",workflow:"critical-protocol-safety-fixture"},
    artifact:{name:"v3015-linux-x86_64-fixture",run_id:888888,run_attempt:1},
    network_version:300105,subversion:"/Blackcoin:30.1.5/",
    candidate_image_ref:$image,candidate_image_id:$image_id,
    candidate_bundle_sha256:$bundle,candidate_oci_archive_sha256:$oci,
    candidate_oci_manifest_sha256:$oci_manifest,candidate_tooling_sha256:$tooling,
    phase_b_result_sha256:$phase_b,
    candidate_manifest_sha256:("5"*64),candidate_provenance_sha256:("6"*64),
    binary_sha256s:{blackcoind:("6"*64),"blackcoin-cli":("7"*64),
      "blackcoin-qt":("8"*64),"blackcoin-tx":("7"*64),
      "blackcoin-wallet":("8"*64),"blackcoin-util":("9"*64)},
    node30_probe_tool_sha256:$node30_probe_tool,
    phase_b_promotion_marker_sha256:$marker,nine_path_canary_seal_sha256:$canary,
    phase_b_status:"PASS",phase_b_no_rewind:true}' >"$evidence/release-identity.json"

samples=$(make_samples wait_for_next_tip)
locked=$(make_locked)
delta=$(make_delta)
for node in $(seq 1 29) 31 32; do
    jq -cn --argjson node "$node" --arg source "$SOURCE_SHA" --argjson locked "$locked" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --argjson samples "$samples" --argjson delta "$delta" '{schema:1,node:$node,
      source_sha:$source,network_version:300105,subversion:"/Blackcoin:30.1.5/",
      container_id_before:("d"*64),container_id_after_recreate:("e"*64),
      restart_performed:true,container_recreated:true,normal_unlock_only:true,
      repair_rpcs:[],data_rewind_used:false,containment_only_on_failure:true,
      invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
        entrypoint_body_sha256:"753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4",
        runtime_argv_sha256:("c"*64),config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
          "-powminingthreads=1","-powminingcpu=1"]},
      locked_restart:$locked,samples:$samples,wallet_audit:$delta}' \
      >"$(printf '%s/node-%02d.json' "$evidence" "$node")"
done
node30_samples=$(jq -c 'map({tip,height,blocks,headers,ibd,peers_out,
  wallet_normal_unlocked:true,free_claim_healthy:true,free_claim_paused:false,
  pos:.staking,regular_pow:{enabled:false,hashrate:0,state:"disabled"}})' <<<"$samples")
node30_audit=$(make_delta)
node30_payload=$(jq -cn --argjson samples "$node30_samples" '{node:30,healthy:true,paused:false,
  wallet_normal_unlocked:true,free_claim_intent_retained:true,
  locked_restart:{free_claim_intent_retained:true},samples:$samples}')
jq -cn --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --argjson payload "$node30_payload" \
  '{schema:1,observation:"initial",probe_tool_sha256:$tool,payload:$payload}' \
  >"$evidence/node-30-free-claim-probe.raw.json"
jq -cn --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --argjson payload "$node30_payload" \
  '{schema:1,observation:"terminal",probe_tool_sha256:$tool,payload:$payload}' \
  >"$evidence/node-30-free-claim-terminal-probe.raw.json"
node30_probe_sha=$(sha256sum "$evidence/node-30-free-claim-probe.raw.json" | awk '{print $1}')
node30_terminal_probe_sha=$(sha256sum \
  "$evidence/node-30-free-claim-terminal-probe.raw.json" | awk '{print $1}')
jq -cn --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg image_id "$CANDIDATE_IMAGE_ID" --arg raw_sha "$node30_probe_sha" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --argjson samples "$node30_samples" --argjson audit "$node30_audit" '{schema:1,node:30,
  source_sha:$source,network_version:300105,subversion:"/Blackcoin:30.1.5/",
  role:"free_claim",regular_pow_enabled:false,raw_probe_sha256:$raw_sha,healthy:true,
  probe_tool_sha256:$probe_tool,
  paused:false,wallet_normal_unlocked:true,container_recreated:true,restart_performed:true,
  normal_unlock_only:true,repair_rpcs:[],data_rewind_used:false,
  containment_only_on_failure:true,
  invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
    entrypoint_body_sha256:"753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4",
    runtime_argv_sha256:("e"*64),
    config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=0"]},
  free_claim_intent_retained:true,locked_restart:{wallet_locked:true,
    normal_unlock_called:false,pos_intent_retained:true,regular_pow_disabled:true,
    free_claim_intent_retained:true,staking:{enabled:true,autostart_staking:true,
      worker_running:true,staking:false,eligible:false,staking_state:"locked"},
    regular_pow:{enabled:false,hashrate:0,state:"disabled"}},
  samples:$samples,wallet_audit:$audit,
  no_recovery_or_resolution_transaction:true,recovery_fee_delta:0}' \
  >"$evidence/node-30-free-claim.json"
cp "$policy_receipt" "$evidence/runtime-policy-handoff-receipt.json"
cp "$compose_receipt" "$evidence/persistent-compose-handoff-receipt.json"
cp "$reconcile_proof" "$evidence/post-compose-reconcile-identity.json"
terminal_nodes='[]'
for node in $(seq 1 32); do
    probe_tool=''
    if [[ "$node" == 30 ]]; then
        result_file="$evidence/node-30-free-claim.json"
        role=free_claim
        terminal_pow=$(jq -cn '{enabled:false,autostart:false,hashrate:0,state:"disabled"}')
        healthy=true; paused=false; probe_sha=$node30_terminal_probe_sha
        probe_tool=$NODE30_FREE_CLAIM_PROBE_SHA256
    else
        result_file=$(printf '%s/node-%02d.json' "$evidence" "$node")
        role=regular
        terminal_pow=$(jq -c '.[-1].pow' <<<"$samples")
        healthy=false; paused=false; probe_sha=''
    fi
    result_sha=$(sha256sum "$result_file" | awk '{print $1}')
    terminal_pos=$(jq -c '.[-1].staking' <<<"$samples")
    terminal_height=$(jq -r '.[-1].height' <<<"$samples")
    terminal_tip=$(jq -r '.[-1].tip' <<<"$samples")
    row=$(jq -cn --argjson node "$node" --arg role "$role" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg tip "$terminal_tip" --argjson height "$terminal_height" \
      --argjson staking "$terminal_pos" --argjson pow "$terminal_pow" \
      --arg result_sha "$result_sha" --argjson healthy "$healthy" --argjson paused "$paused" \
      --arg probe "$probe_sha" --arg probe_tool "$probe_tool" \
      '{node:$node,role:$role,source_sha:$source,network_version:300105,
      subversion:"/Blackcoin:30.1.5/",container_image_ref:$image,container_image_id:$image_id,
      chain:{bestblockhash:$tip,blocks:$height,headers:$height,initialblockdownload:false},
      network:{connections_out:8},wallet:{walletname:"",private_keys_enabled:true,
        unlocked_until:9999999999},staking:$staking,pow:$pow,pos_contract_passed:true,
      pow_contract_passed:($role == "regular"),free_claim_healthy:$healthy,
      free_claim_paused:$paused,free_claim_probe_output_sha256:
        (if $role == "free_claim" then $probe else null end),node_result_sha256:$result_sha}')
    row=$(jq -c --arg tool "$probe_tool" \
      '.free_claim_probe_tool_sha256=(if .role == "free_claim" then $tool else null end)' \
      <<<"$row")
    terminal_nodes=$(jq -cn --argjson old "$terminal_nodes" --argjson row "$row" '$old+[$row]')
done
jq -cn --arg source "$SOURCE_SHA" --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$node30_terminal_probe_sha" --argjson nodes "$terminal_nodes" '{schema:1,
  source_sha:$source,captured_utc:"2026-08-10T00:00:00Z",nodes:$nodes,
  pos_active_nodes:[$nodes[]|select(.pos_contract_passed)|.node],
  pos_active_count:([$nodes[]|select(.pos_contract_passed)]|length),
  regular_pow_nodes:[$nodes[]|select(.role=="regular" and .pow_contract_passed)|.node],
  regular_pow_operational_count:([$nodes[]|select(.role=="regular" and
    .pow_contract_passed)]|length),node30_free_claim_healthy:$nodes[29].free_claim_healthy,
  node30_free_claim_paused:$nodes[29].free_claim_paused,
  node30_free_claim_probe_tool_sha256:$tool,
  node30_terminal_probe_sha256:$terminal_probe}' \
  >"$evidence/terminal-fleet-census.json"
terminal_census_sha=$(sha256sum "$evidence/terminal-fleet-census.json" | awk '{print $1}')
jq -cn --arg source "$SOURCE_SHA" --arg census "$terminal_census_sha" \
  --arg policy_receipt "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" \
  --arg compose_receipt "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" \
  --arg compose_sha "$FINAL_COMPOSE_SHA256" --arg policy_sha "$FINAL_IMAGE_POLICY_SHA256" \
  --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
  --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$node30_terminal_probe_sha" \
  '{schema:1,transaction:"v30.1.5-fleet-rollout",
  source_sha:$source,status:"PASS",terminal_census_sha256:$census,
  pos_active:32,pos_active_nodes:[range(1;33)],regular_pow_operational:31,
  regular_pow_nodes:([range(1;30)] + [31,32]),node30_role:"free_claim",
  node30_free_claim_healthy:true,node30_free_claim_paused:false,data_rewind_used:false,
  node30_free_claim_probe_tool_sha256:$tool,node30_terminal_probe_sha256:$terminal_probe,
  runtime_policy_handoff_receipt_sha256:$policy_receipt,
  persistent_compose_handoff_receipt_sha256:$compose_receipt,
  final_compose_sha256:$compose_sha,final_image_policy_sha256:$policy_sha,
  post_compose_reconcile_identity_sha256:$reconcile,
  recovery_transactions_created:false,recovery_fees_delta:0,
  containment_only_failure_policy:true}' >"$evidence/fleet-result.json"
jq -cn --arg source "$SOURCE_SHA" --arg phase_b "$PHASE_B_RESULT_SHA256" \
  --arg package "$PACKAGE_SHA256SUMS_SHA256" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" '{schema:1,source_sha:$source,
  phase_b_result_sha256:$phase_b,package_sha256sums_sha256:$package,
  node30_probe_tool_sha256:$probe_tool,
  nonce:"0123456789abcdef0123456789abcdef",
  live_execution_confirmation:("v30.1.5:"+$source+":0123456789abcdef0123456789abcdef"),
  native_restart_confirmation:("v30.1.5-native-restart:"+$source+":0123456789abcdef0123456789abcdef")}' \
  >"$evidence/rollout-authority.json"
make_manifest()
{
    local dir=$1 file
    (
        cd "$dir" || exit
        : >SHA256SUMS
        for file in $(find . -maxdepth 1 -type f ! -name SHA256SUMS -exec basename {} \; | sort); do
            sha256sum "$file" >>SHA256SUMS
        done
    )
}
make_manifest "$evidence"

expect_pass 'full 32-node evidence verifies' "$package_dir/verify-evidence.sh" --fixture "$env_file" "$evidence"
expect_pass 'reviewed canonical candidate digest identity is accepted' \
  v3015_release_identity_is_valid "$evidence/release-identity.json"

old_hotfix_candidate_name_is_rejected()
{
    local old_image old_release="$tmp/release-old-hotfix-name.json"
    old_image="example.invalid/blackcoin-v30.1.5-hotfix-candidate@sha256:$(printf '1%.0s' {1..64})"
    jq --arg image "$old_image" '.candidate_image_ref=$image' \
      "$evidence/release-identity.json" >"$old_release"
    CANDIDATE_IMAGE_REF="$old_image" v3015_release_identity_is_valid "$old_release"
}
expect_fail 'historical hotfix-candidate image naming cannot authorize v30.1.5' \
  old_hotfix_candidate_name_is_rejected

mutate_fixture()
{
    local name=$1 expression=$2 file=$3
    local copy="$tmp/direct-$name.json" node
    jq "$expression" "$evidence/$file" >"$copy"
    case "$file" in
        fleet-result.json)
            v3015_fleet_result_is_valid "$copy" "$terminal_census_sha" \
              "$node30_terminal_probe_sha"
            ;;
        terminal-fleet-census.json)
            v3015_terminal_census_is_valid "$copy" "$evidence"
            ;;
        node-30-free-claim.json)
            v3015_node30_result_is_valid "$copy" \
              "$evidence/node-30-free-claim-probe.raw.json"
            ;;
        node-30-free-claim-probe.raw.json)
            v3015_node30_result_is_valid "$evidence/node-30-free-claim.json" "$copy"
            ;;
        node-30-free-claim-terminal-probe.raw.json)
            v3015_node30_probe_output_is_valid "$copy" terminal
            ;;
        node-[0-9][0-9].json)
            node=${file#node-}; node=${node%.json}; node=$((10#$node))
            v3015_node_result_is_valid "$copy" "$node"
            ;;
        release-identity.json)
            v3015_release_identity_is_valid "$copy"
            ;;
        rollout-authority.json)
            v3015_rollout_authority_is_valid "$copy"
            ;;
        post-compose-reconcile-identity.json)
            [[ "$(v3015_sha256_file "$copy")" == "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" ]]
            ;;
        *) return 2 ;;
    esac
}
expect_fail 'verifier rejects paused Free Claim' mutate_fixture paused '.paused=true' node-30-free-claim.json
expect_fail 'verifier rejects false PoS count' mutate_fixture pos31 '.pos_active=31' fleet-result.json
expect_fail 'verifier rejects recovery transaction claim' mutate_fixture recovery '.recovery_transactions_created=true' fleet-result.json
expect_fail 'verifier rejects unsafe node gate' mutate_fixture unsafe '.samples[1].pow.mining_gate_unsafe_components=1' node-01.json
expect_fail 'verifier rejects repair RPC evidence' mutate_fixture repair '.repair_rpcs=["worker-enable"]' node-02.json
expect_fail 'verifier rejects wallet recovery fee' mutate_fixture fee \
  '.wallet_audit.after.recovery.confirmed_resolution_fees=1' node-03.json
expect_fail 'verifier rejects stale wait fingerprint' mutate_fixture stale '.samples[].pow.mining_gate_candidate_state_fingerprint = ("f"*64)' node-04.json
expect_fail 'verifier rejects release tooling identity mismatch' mutate_fixture tooling \
  '.candidate_tooling_sha256 = ("0"*64)' release-identity.json
expect_fail 'verifier rejects authority nonce mismatch' mutate_fixture nonce \
  '.nonce = ("f"*32)' rollout-authority.json
expect_fail 'regular node schema rejects an extra outer field' mutate_fixture nodeextra \
  '.unexpected=true' node-01.json
expect_fail 'regular node schema rejects a contradictory shadow field' mutate_fixture nodeshadow \
  '.old_core_autostarted=true' node-01.json
expect_fail 'regular node schema rejects an extra invocation field' mutate_fixture invocationextra \
  '.invocation.unexpected=true' node-01.json
expect_fail 'regular locked-restart wrapper rejects an extra field' mutate_fixture lockedextra \
  '.locked_restart.unexpected=true' node-01.json
expect_fail 'regular node requires a real container recreation identity change' mutate_fixture samecontainer \
  '.container_id_after_recreate=.container_id_before' node-01.json
expect_fail 'fleet result schema rejects an extra outer field' mutate_fixture fleetextra \
  '.unexpected=true' fleet-result.json
expect_fail 'rollout authority schema rejects an extra outer field' mutate_fixture authorityextra \
  '.unexpected=true' rollout-authority.json
expect_fail 'verifier rejects node30 regular-PoW leakage' mutate_fixture node30pow \
  '.locked_restart.regular_pow.enabled = true' node-30-free-claim.json
expect_fail 'verifier rejects locked submitted claim' mutate_fixture lockedsubmit \
  '.locked_restart.pow.claims_submitted=1' node-05.json
expect_fail 'verifier rejects terminal census omission' mutate_fixture censusomit \
  '.nodes |= map(select(.node != 22))' terminal-fleet-census.json
expect_fail 'verifier rejects terminal census forged count' mutate_fixture censuscount \
  '.regular_pow_operational_count=30' terminal-fleet-census.json
expect_fail 'terminal census rejects post-probe node30 PoS loss' mutate_fixture terminalposloss \
  '.nodes[29].staking.weight=0' terminal-fleet-census.json
expect_fail 'terminal census rejects node30 staking-only unlock' mutate_fixture terminalstakingonly \
  '.nodes[29].wallet.unlocked_staking_only=true' terminal-fleet-census.json
expect_fail 'terminal census rejects regular-node staking-only unlock' mutate_fixture regularstakingonly \
  '.nodes[0].wallet.unlocked_staking_only=true' terminal-fleet-census.json

swapped="$tmp/swapped"
cp -R "$evidence" "$swapped"
mv "$swapped/node-01.json" "$swapped/node-swap.json"
mv "$swapped/node-02.json" "$swapped/node-01.json"
mv "$swapped/node-swap.json" "$swapped/node-02.json"
make_manifest "$swapped"
expect_fail 'verifier binds each filename to its expected node' \
  "$package_dir/verify-evidence.sh" --fixture "$env_file" "$swapped"
duplicate_node="$tmp/duplicate-node"
cp -R "$evidence" "$duplicate_node"
cp "$duplicate_node/node-01.json" "$duplicate_node/node-02.json"
make_manifest "$duplicate_node"
expect_fail 'verifier rejects duplicated node identity under another filename' \
  "$package_dir/verify-evidence.sh" --fixture "$env_file" "$duplicate_node"
node30_regular="$tmp/node30-regular"
cp -R "$evidence" "$node30_regular"
jq '.node=30' "$node30_regular/node-29.json" >"$node30_regular/change" &&
  mv "$node30_regular/change" "$node30_regular/node-29.json"
make_manifest "$node30_regular"
expect_fail 'regular evidence cannot claim node30' \
  "$package_dir/verify-evidence.sh" --fixture "$env_file" "$node30_regular"
expect_fail 'node30 result is bound to raw probe bytes' mutate_fixture rawprobe \
  '.payload.healthy=false' node-30-free-claim-probe.raw.json
expect_fail 'node30 initial probe is bound to the reviewed tool bytes' mutate_fixture initialtool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim-probe.raw.json
expect_fail 'node30 result records the reviewed probe tool separately' mutate_fixture resulttool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim.json
expect_fail 'terminal node30 probe is independently healthy and unpaused' mutate_fixture terminalpause \
  '.payload.paused=true' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe is bound to the reviewed tool bytes' mutate_fixture terminaltool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects contradictory recovery payload fields' \
  mutate_fixture terminalextra '.payload.recovery_transaction_created=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects contradictory regular-PoW payload fields' \
  mutate_fixture terminalpow '.payload.regular_pow_enabled=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects duplicate-tip samples' mutate_fixture terminalstale \
  '.payload.samples[1].tip=.payload.samples[0].tip' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects unsafe PoS samples' mutate_fixture terminalunsafe \
  '.payload.samples[2].pos.weight=0' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe requires normal wallet unlock' mutate_fixture terminallocked \
  '.payload.wallet_normal_unlocked=false' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal census binds the node30 probe tool' mutate_fixture censustool \
  '.node30_free_claim_probe_tool_sha256=("f"*64)' terminal-fleet-census.json
expect_fail 'fleet result binds the node30 probe tool' mutate_fixture fleettool \
  '.node30_free_claim_probe_tool_sha256=("f"*64)' fleet-result.json
expect_fail 'rollout authority binds the node30 probe tool' mutate_fixture authoritytool \
  '.node30_probe_tool_sha256=("f"*64)' rollout-authority.json
expect_fail 'release identity binds the node30 probe tool' mutate_fixture releasetool \
  '.node30_probe_tool_sha256=("f"*64)' release-identity.json
expect_fail 'node30 independent payout comparison rejects drift' mutate_fixture node30payout \
  '.wallet_audit.after.payout="qq-other"' node-30-free-claim.json
expect_fail 'node30 independent recovery policy rejects drift' mutate_fixture node30policy \
  '.wallet_audit.after.recovery.policy.mode="pause_and_ask"' node-30-free-claim.json
expect_fail 'node30 independent txid comparison rejects addition' mutate_fixture node30tx \
  '.wallet_audit.delta.added_txids=[("f"*64)]' node-30-free-claim.json
expect_fail 'evidence rejects mixed post-Compose identity proof' mutate_fixture reconcilemix \
  '.source_sha=("f"*40)' post-compose-reconcile-identity.json

terminal_drift="$tmp/terminal-drift"
cp -R "$evidence" "$terminal_drift"
jq '.payload.paused=true' "$terminal_drift/node-30-free-claim-terminal-probe.raw.json" \
  >"$terminal_drift/change" &&
  mv "$terminal_drift/change" "$terminal_drift/node-30-free-claim-terminal-probe.raw.json"
make_manifest "$terminal_drift"
expect_fail 'fresh terminal probe catches a pause after initial node30 acceptance' \
  "$package_dir/verify-evidence.sh" --fixture "$env_file" "$terminal_drift"

extra="$tmp/extra"
cp -R "$evidence" "$extra"
printf 'unexpected\n' >"$extra/EXTRA"
make_manifest "$extra"
expect_fail 'verifier rejects extra evidence file' "$package_dir/verify-evidence.sh" --fixture "$env_file" "$extra"
missing="$tmp/missing"
cp -R "$evidence" "$missing"
rm "$missing/node-31.json"
make_manifest "$missing"
expect_fail 'verifier rejects missing node evidence' "$package_dir/verify-evidence.sh" --fixture "$env_file" "$missing"
tamper="$tmp/tamper"
cp -R "$evidence" "$tamper"
printf '\n' >>"$tamper/node-01.json"
expect_fail 'verifier rejects manifest tamper' "$package_dir/verify-evidence.sh" --fixture "$env_file" "$tamper"

placeholder_env="$tmp/placeholder.env"
cp "$env_file" "$placeholder_env"
printf "CORE_CI_CONCLUSION='__PENDING__'\n" >>"$placeholder_env"
expect_fail 'pending exact-SHA CI fails closed' bash -c \
  "source '$package_dir/lib/common.sh'; source '$placeholder_env'; v3015_validate_release_env"
expect_pass 'template pins the provisional signed H, tree, run, and workflow' bash -c \
  "source '$package_dir/rollout.env.example'; [[ \"\$SOURCE_SHA\" == a0695f22740e111d0487a194fb46f1bae05952c5 && \"\$SOURCE_TREE\" == 86df040ae5eb8e819e940dd08364bcc177a72195 && \"\$SOURCE_SIGNATURE_VERIFIED\" == 1 && \"\$CORE_CI_RUN_ID\" == 31336502539 && \"\$CORE_CI_HEAD_SHA\" == \"\$SOURCE_SHA\" && \"\$CORE_CI_CONCLUSION\" == __PENDING_EXACT_SHA_CI_SUCCESS__ && \"\$CORE_CI_WORKFLOW\" == .github/workflows/pr-gate.yml ]]"
expect_fail 'provisional exact-H CI run remains fail-closed while in progress' bash -c \
  "source '$package_dir/lib/common.sh'; source '$package_dir/rollout.env.example'; v3015_validate_release_env"
mixed_probe_env="$tmp/mixed-probe-tool.env"
cp "$env_file" "$mixed_probe_env"
printf "NODE30_FREE_CLAIM_PROBE_SHA256='%064d'\n" 0 >>"$mixed_probe_env"
expect_fail 'reviewed environment cannot switch node30 probe tool after evidence capture' \
  "$package_dir/verify-evidence.sh" --fixture "$mixed_probe_env" "$evidence"
helper_drift_env="$tmp/helper-drift.env"
cp "$env_file" "$helper_drift_env"
printf "NORMAL_UNLOCK_HELPER_SHA256='%064d'\n" 0 >>"$helper_drift_env"
expect_fail 'reviewed unlock-only helper identity cannot drift' bash -c \
  "source '$package_dir/lib/common.sh'; source '$helper_drift_env'; v3015_validate_release_env"
handoff_env="$tmp/handoff-pending.env"
cp "$env_file" "$handoff_env"
printf "RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256='%064d'\n" 0 >>"$handoff_env"
expect_fail 'runtime-policy handoff receipt hash mismatch fails closed' bash -c \
  "source '$package_dir/lib/common.sh'; source '$handoff_env'; v3015_validate_release_env"
boolean_only_env="$tmp/handoff-boolean-only.env"
cp "$env_file" "$boolean_only_env"
printf "RUNTIME_POLICY_HANDOFF_RECEIPT='__UNRESOLVED__'\nRUNTIME_POLICY_HANDOFF_REVIEWED='1'\nPERSISTENT_COMPOSE_HANDOFF_REVIEWED='1'\n" \
  >>"$boolean_only_env"
expect_fail 'bare handoff booleans cannot replace exact receipts' bash -c \
  "source '$package_dir/lib/common.sh'; source '$boolean_only_env'; v3015_validate_release_env"
stale_receipt="$tmp/stale-compose-receipt.json"
jq '.compose_after_sha256=("0"*64)' "$compose_receipt" >"$stale_receipt"
stale_receipt_sha=$(sha256sum "$stale_receipt" | awk '{print $1}')
stale_env="$tmp/stale-compose.env"
cp "$env_file" "$stale_env"
printf "PERSISTENT_COMPOSE_HANDOFF_RECEIPT='%s'\nPERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256='%s'\n" \
  "$stale_receipt" "$stale_receipt_sha" >>"$stale_env"
expect_fail 'stale post-handoff Compose receipt fails closed' bash -c \
  "source '$package_dir/lib/common.sh'; source '$stale_env'; v3015_validate_release_env"

expect_pass 'wave file contains 31 regular nodes' bash -c \
  "awk '\$1==\"regular\"{for(i=2;i<=NF;i++) print \$i}' '$package_dir/waves.txt' | sort -n | uniq | wc -l | grep -q '31'"
expect_pass 'wave file isolates node30' bash -c \
  "awk '\$1==\"free_claim\"{print \$2}' '$package_dir/waves.txt' | grep -qx '30'"
expect_pass 'live scripts contain no data rewind command' bash -c \
  "! grep -ERiq 'zfs[[:space:]]+(rollback|clone)' '$package_dir' --include='*.sh'"
expect_pass 'live scripts contain no fee-paying resolution RPC' bash -c \
  "! grep -Eiq 'createshadowpowclaimresolution' '$package_dir/fleet_rollout.sh' '$package_dir/native_restart_durability.sh'"
expect_pass 'durability scripts contain no recovery or rebroadcast RPC' bash -c \
  "! grep -Eiq '(createshadowpowclaimresolution|commitshadowpowclaimresolution|resolveshadowpowclaims|sendrawtransaction|resendwallettransactions|abandontransaction|setpowclaimrecovery)' '$package_dir/fleet_rollout.sh' '$package_dir/native_restart_durability.sh'"
expect_pass 'native proof contains no worker-enable repair RPC' bash -c \
  "! grep -Eiq 'setpowmining[[:space:]]+true|staking[[:space:]]+true' '$package_dir/native_restart_durability.sh'"
expect_pass 'v30.1.5 package does not source v30.1.4 libraries' bash -c \
  "! grep -Eq 'source .*v30[.]1[.]4' '$package_dir/fleet_rollout.sh' '$package_dir/native_restart_durability.sh' '$package_dir/verify-evidence.sh'"
expect_pass 'package contains exactly fifteen authorized paths' bash -c \
  "find '$package_dir' -type f | wc -l | grep -q '15'"
expect_pass 'maintenance include declares Bash for standalone ShellCheck' bash -c \
  "head -n 1 '$package_dir/guard_rollout_maintenance_block.sh.inc' | grep -Fqx '# shellcheck shell=bash' && shellcheck -x '$package_dir/guard_rollout_maintenance_block.sh.inc'"
expect_pass 'maintenance guard exact-checks rollout authority schema' bash -c \
  "grep -Fq '(keys | sort) ==' '$package_dir/guard_rollout_maintenance_block.sh.inc' && grep -Fq 'node30_probe_tool_sha256' '$package_dir/guard_rollout_maintenance_block.sh.inc'"
expect_pass 'terminal node30 Core sample is captured after the multi-tip probe' bash -c \
  "awk '/capture_node30_probe_evidence .*terminal/{p=NR} p && !s && /staking=.*getstakinginfo/{s=NR} p && s && !v && /v3015_pos_json_is_active/{v=NR} END{exit !(p && p<s && s<v)}' '$package_dir/fleet_rollout.sh'"
expect_pass 'runtime invocation binds actual container image identity' bash -c \
  "grep -Fq '.[0].Image == \$image_id' '$package_dir/native_restart_durability.sh' && grep -Fq '.[0].Image == \$image_id' '$package_dir/fleet_rollout.sh' && grep -Fq \"docker inspect -f '{{.Image}}'\" '$package_dir/fleet_rollout.sh'"
# The single-quoted body is intentionally evaluated by the child Bash.
# shellcheck disable=SC2016
expect_pass 'provisional source/CI-bound seal covers the exact fourteen payloads' bash -c '
  set -euo pipefail
  package_dir=$1
  actual=$(cd "$package_dir" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
  listed=$(cd "$package_dir" && awk "{print \$2}" SHA256SUMS | LC_ALL=C sort)
  test "$actual" = "$listed"
  test "$(printf "%s\n" "$listed" | uniq | wc -l | tr -d " ")" = 14
  ! grep -Eq "UNSEALED|PLACEHOLDER|__" "$package_dir/SHA256SUMS"
  (cd "$package_dir" && sha256sum --strict -c SHA256SUMS >/dev/null)
' bash "$package_dir"

printf '1..%d\n' "$tests"
if ((failures != 0)); then
    printf '%d/%d tests failed\n' "$failures" "$tests" >&2
    exit 1
fi
printf '%d/%d tests passed\n' "$tests" "$tests"
