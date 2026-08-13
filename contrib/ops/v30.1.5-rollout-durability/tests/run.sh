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
    local action=${1:-wait_for_next_tip} count=${2:-5} wallet_name=${3:-}
    local progress_mode=${4:-progress} samples='[]' i fingerprint pow sample
    local started finished freshness target current_head current_relay ordinal parent
    local progressed_head second_progressed_head family current_family current_root
    fingerprint=$(printf '%064x' 777)
    progressed_head=$(printf 'd%.0s' {1..64})
    second_progressed_head=$(printf 'c%.0s' {1..64})
    family=$(printf 'e%.0s' {1..64})
    for ((i=1; i<=count; i++)); do
        if [[ "$action" == create_new_anchor ]]; then
            pow=$(make_pow "$action" "$fingerprint" 0.1 0)
            freshness='null'
        else
            if [[ "$action" == refresh_same_anchor ]]; then
                pow=$(make_pow "$action" "$fingerprint" 0.1 0)
            else
                pow=$(make_pow "$action" "$fingerprint" 0 0)
            fi
            current_head=$head_tx
            current_relay=$(jq -r '.mining_gate_relay_txid' <<<"$pow")
            ordinal=0
            parent=$zero
            current_family=$family
            current_root=$head_tx
            if [[ "$action" == relay_existing ]]; then
                current_root=$current_relay
                current_head=$current_relay
            fi
            if [[ "$progress_mode" == progress && "$i" -ge 3 ]]; then
                current_head=$progressed_head
                if [[ "$action" == relay_existing ]]; then
                    current_relay=$progressed_head
                    ordinal=1
                    parent=$relay_tx
                else
                    ordinal=1
                    parent=$head_tx
                fi
            fi
            if [[ "$progress_mode" == progress && "$i" -ge 5 ]]; then
                current_head=$second_progressed_head
                if [[ "$action" == relay_existing ]]; then
                    current_relay=$second_progressed_head
                    ordinal=2
                    parent=$progressed_head
                else
                    ordinal=2
                    parent=$progressed_head
                fi
            fi
            pow=$(jq -c --arg head "$current_head" --arg relay "$current_relay" \
              '.mining_gate_lineage_head_txid=$head | .mining_gate_relay_txid=$relay' <<<"$pow")
            finished=$((1700000000000 + i * 1000 + 100))
            if [[ "$action" == relay_existing ]]; then target=$current_relay; else target=$current_head; fi
            freshness=$(jq -cn --arg action "$action" \
              --arg tip "$(printf '%064x' $((100 + i)))" --arg fp "$fingerprint" \
              --arg head "$current_head" --arg relay "$current_relay" \
              --arg target "$target" --arg family "$current_family" --arg root "$current_root" \
              --arg parent "$parent" --arg zero "$zero" --argjson ordinal "$ordinal" \
              --argjson observed "$finished" '
              def claim($txid;$root_txid;$parent_txid;$lineage_ordinal;$live;$expiry):
                {txid:$txid,kind:"claim",provenance:"explicit_authored",
                 disposition:(if $live then "eligible"
                   elif $action == "relay_existing" and $txid == $target then "eligible"
                   else "origin_expired" end),
                 proof_may_revalidate_on_descendant:false,active_chain_confirmed:false,
                 in_mempool:$live,quarantined:($live | not),expected_shape:true,
                 wallet_authored:true,wallet_from_me:true,authored_metadata_valid:true,
                 authored_tip_active_branch_bound:true,claim_descriptor_valid:true,
                 proof_evaluation_skipped_resolved_anchor:false,proof_version:4,
                 proof_mode:"pow",proof_origin_bound:true,proof_origin_height:900,
                 proof_origin_previous_block_hash:("1"*64),proof_input_bound:true,
                 exact_authored_carrier_shape:true,relay_ttl_expired:false,
                 relay_expiry_time:$expiry,lineage_metadata_present:true,
                 lineage_metadata_valid:true,lineage_family_fingerprint:$family,
                 lineage_root_txid:$root_txid,lineage_parent_txid:$parent_txid,
                 lineage_ordinal:$lineage_ordinal,abandoned:false,
                 expired_locally_retired:false,stale_depth:0,stale_depth_known:true,
                 resolution_metadata_valid:false,resolution_relay_authorized:false};
              ($action == "wait_for_live") as $is_live |
              (if $action == "relay_existing" then (($observed/1000|floor)+3600)
               else 0 end) as $expiry |
              (if $ordinal == 0 then
                 [claim($target;$root;$zero;0;$is_live;$expiry)]
               elif $ordinal == 1 then
                 [claim($root;$root;$zero;0;false;0),
                  claim($target;$root;$root;1;$is_live;$expiry)]
               else
                 [claim($root;$root;$zero;0;false;0),
                  claim($parent;$root;$root;1;false;0),
                  claim($target;$root;$parent;2;$is_live;$expiry)]
               end) as $claims |
              ([$claims[] | select(.txid == $target)] |
                if length == 1 then .[0] else error("fixture target") end) as $selected |
              ([$claims[].txid] | sort) as $claim_txids |
              (reduce ($claims[] | select(.in_mempool == true)) as $live
                ({}; .[$live.txid]={time:(($observed/1000|floor)-10)})) as $raw_mempool |
              {all_claims_expired_locally_retired:false,
               all_claims_explicitly_provenanced:true,
               all_claims_quarantined:all($claims[];.quarantined == true),
               all_claims_zero_payment_retirable:false,
               anchor:{txid:("8"*64),vout:0,amount:10,scriptPubKey:"51"},
               anchor_authenticated:true,anchor_unspent:true,anchor_user_locked:false,
               claim_txids:$claim_txids,
               classification:(if any($claims[];.in_mempool) then "live"
                 else "current_branch_ineligible" end),
               component_fingerprint:("7"*64),descendant_claims:0,
               generation_fingerprint:$family,has_revalidating_unbound_proof:false,
               minimum_stale_depth:0,nodes:($claims | sort_by(.txid)),
               ordinary_or_mixed_txids:[],resolution_txids:[],
               root_claim_txids:$claim_txids,stale_depth_known:true} as $component |
              {action:$action,tip:$tip,observed_unix_ms:$observed,
               candidate_state_fingerprint:$fp,lineage_head_txid:$head,relay_txid:$relay,
               raw_mempool:$raw_mempool,
               recovery_node:$selected,recovery_component:$component,
               recovery_component_claims:$claims,
               recovery_component_claim_txids:$claim_txids,
               recovery_component_root_claim_txids:$claim_txids,
               mempool_entry_present:$is_live,
               mempool_entry:(if $is_live then $raw_mempool[$target] else null end),
               mempool_entry_time:(if $is_live then (($observed/1000|floor)-10) else null end),
               live_members:([$claims[] | select(.in_mempool == true) |
                 {recovery_node:.,mempool_entry:$raw_mempool[.txid],
                  mempool_entry_time:(($observed/1000|floor)-10)}] |
                 sort_by(.recovery_node.txid))}')
            pow=$(jq -c \
              --argjson family "$(jq '.recovery_component_claims | length' <<<"$freshness")" \
              --argjson live "$(jq '[.recovery_component_claims[] |
                select(.in_mempool == true)] | length' <<<"$freshness")" \
              --argjson eligible "$(jq '[.recovery_component_claims[] |
                select(.disposition == "eligible")] | length' <<<"$freshness")" '
              .mining_gate_family_claims=$family |
              .mining_gate_live_claims=$live | .live_claims=$live |
              .mining_gate_eligible_claims=$eligible |
              .unresolved_claims=$family' <<<"$pow")
        fi
        started=$((1700000000000 + i * 1000))
        finished=$((started + 100))
        sample=$(jq -cn --arg tip "$(printf '%064x' $((100 + i)))" \
          --arg work "$(printf '%064x' $((5000 + i)))" \
          --argjson height $((1000 + i)) --argjson pow "$pow" --argjson staking "$(make_pos)" \
          --arg walletname "$wallet_name" --argjson started "$started" \
          --argjson finished "$finished" --argjson freshness "$freshness" \
          '($pow | .current_height=$height | .claim_inventory_tip=$tip) as $current_pow |
            ($staking | .blocks=$height | .active_blocks=$height) as $current_staking |
            {tip:$tip,height:$height,blocks:$height,headers:$height,ibd:false,
            chain_before:{bestblockhash:$tip,blocks:$height,headers:$height,
              chainwork:$work,initialblockdownload:false},
            chain_after:{bestblockhash:$tip,blocks:$height,headers:$height,
              chainwork:$work,initialblockdownload:false},
            qqp4_activation:{bestblock:$tip,height:$height,
              qqp4_activation_disabled:true,qqp4_activation_height:0,
              qqp4_active:false,qqp4_active_next_block:false},
            peers_out:8,sample_started_unix_ms:$started,sample_finished_unix_ms:$finished,
            walletname:$walletname,loaded_wallets:[$walletname],wallet_normal_unlocked:true,
            wallet_generation:$height,
            wallet_processed_tip:$tip,wallet_tip_matches:true,
            action_freshness:$freshness,staking:$current_staking,pow:$current_pow}')
        samples=$(jq -cn --argjson old "$samples" --argjson sample "$sample" '$old + [$sample]')
    done
    printf '%s\n' "$samples"
}

make_familyless_wait_samples()
{
    local count=${1:-5} wallet_name=${2:-}
    make_samples create_new_anchor "$count" "$wallet_name" | jq --arg zero "$zero" '
      .[] |= (
        .pow.mining_gate_action="wait_for_next_tip" |
        .pow.mining_gate_can_submit=true |
        .pow.mining_gate_unresolved_components=0 |
        .pow.mining_gate_live_claims=0 |
        .pow.mining_gate_eligible_claims=0 |
        .pow.mining_gate_family_claims=0 |
        .pow.mining_gate_lineage_head_txid=$zero |
        .pow.mining_gate_relay_txid=$zero |
        .pow.hashrate=0 | .pow.state="claim_in_flight" |
        .action_freshness=null)'
}

rebind_sample_cut()
{
    local target=$1 source=$2
    jq -cn --argjson target "$target" --argjson source "$source" '
      $target |
      .tip=$source.tip | .height=$source.height | .blocks=$source.blocks |
      .headers=$source.headers | .ibd=$source.ibd |
      .chain_before=$source.chain_before | .chain_after=$source.chain_after |
      .qqp4_activation=$source.qqp4_activation |
      .pow.current_height=$source.height | .pow.claim_inventory_tip=$source.tip |
      .staking.blocks=$source.height | .staking.active_blocks=$source.height |
      .wallet_generation=$source.wallet_generation |
      .wallet_processed_tip=$source.tip |
      if .action_freshness == null then .
      else .action_freshness.tip=$source.tip end'
}

collapse_series_to_first_cut()
{
    local samples=$1
    jq -cn --argjson samples "$samples" '
      $samples[0] as $cut | $samples |
      .[1:] |= map(
        .tip=$cut.tip | .height=$cut.height | .blocks=$cut.blocks |
        .headers=$cut.headers | .ibd=$cut.ibd |
        .chain_before=$cut.chain_before | .chain_after=$cut.chain_after |
        .qqp4_activation=$cut.qqp4_activation |
        .pow.current_height=$cut.height | .pow.claim_inventory_tip=$cut.tip |
        .staking.blocks=$cut.height | .staking.active_blocks=$cut.height |
        .wallet_generation=$cut.wallet_generation |
        .wallet_processed_tip=$cut.tip |
        if .action_freshness == null then .
        else .action_freshness.tip=$cut.tip end)'
}

rebind_sample_family()
{
    local target=$1 source=$2
    jq -cn --argjson target "$target" --argjson source "$source" '
      $target as $t |
      ($source.action_freshness |
        .tip=$t.tip |
        .observed_unix_ms=$t.sample_finished_unix_ms |
        .candidate_state_fingerprint=$t.pow.mining_gate_candidate_state_fingerprint) as $f |
      $t |
      .action_freshness=$f |
      .pow.mining_gate_action=$source.pow.mining_gate_action |
      .pow.mining_gate_can_submit=$source.pow.mining_gate_can_submit |
      .pow.state=$source.pow.state |
      .pow.mining_gate_lineage_head_txid=$f.lineage_head_txid |
      .pow.mining_gate_relay_txid=$f.relay_txid |
      .pow.mining_gate_family_claims=($f.recovery_component_claims | length) |
      .pow.unresolved_claims=($f.recovery_component_claims | length) |
      .pow.mining_gate_live_claims=
        ([$f.recovery_component_claims[] | select(.in_mempool == true)] | length) |
      .pow.live_claims=.pow.mining_gate_live_claims |
      .pow.mining_gate_eligible_claims=
        ([$f.recovery_component_claims[] | select(.disposition == "eligible")] | length)'
}

mark_selected_component_live()
{
    local samples=$1
    jq -c '
      .[] |= (. as $sample |
        .action_freshness.recovery_node.txid as $selected_txid |
        (($sample.sample_finished_unix_ms/1000|floor)-10) as $entry_time |
        (.action_freshness.recovery_component_claims |
          map(if .txid == $selected_txid then
                .in_mempool=true | .quarantined=false | .disposition="eligible"
              else .in_mempool=false | .quarantined=true end)) as $claims |
        ([$claims[] | select(.txid == $selected_txid)] | first) as $selected |
        {time:$entry_time} as $entry |
        .action_freshness.recovery_component_claims=$claims |
        .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
        .action_freshness.recovery_component.classification="live" |
        .action_freshness.recovery_component.all_claims_quarantined=false |
        .action_freshness.recovery_node=$selected |
        .action_freshness.raw_mempool={($selected_txid):$entry} |
        .action_freshness.live_members=[{recovery_node:$selected,
          mempool_entry:$entry,mempool_entry_time:$entry_time}] |
        .action_freshness.mempool_entry_present=true |
        .action_freshness.mempool_entry=$entry |
        .action_freshness.mempool_entry_time=$entry_time |
        .pow.mining_gate_live_claims=1 | .pow.live_claims=1 |
        .pow.mining_gate_eligible_claims=
          ([$claims[] | select(.disposition == "eligible")] | length))' \
      <<<"$samples"
}

make_interleaved_samples()
{
    make_samples wait_for_next_tip 4 | jq \
      --arg root "$(printf '5%.0s' {1..64})" \
      --arg family "$(printf '6%.0s' {1..64})" '
      .[1] |= (.action_freshness.recovery_component_claims[0] as $old |
        ($old | .txid=$root | .lineage_family_fingerprint=$family |
          .lineage_root_txid=$root | .lineage_parent_txid=("0"*64) |
          .lineage_ordinal=0) as $node |
        .pow.mining_gate_lineage_head_txid=$root |
        .action_freshness.lineage_head_txid=$root |
        .action_freshness.recovery_component.anchor.txid=("4"*64) |
        .action_freshness.recovery_component.anchor.vout=1 |
        .action_freshness.recovery_component.generation_fingerprint=$family |
        .action_freshness.recovery_component.claim_txids=[$root] |
        .action_freshness.recovery_component.root_claim_txids=[$root] |
        .action_freshness.recovery_component.nodes=[$node] |
        .action_freshness.recovery_component_claims=[$node] |
        .action_freshness.recovery_component_claim_txids=[$root] |
        .action_freshness.recovery_component_root_claim_txids=[$root] |
        .action_freshness.recovery_node=$node)'
}

make_unseen_family_samples()
{
    make_samples wait_for_next_tip 4 '' no_progress | jq --arg zero "$zero" '
      ["1","2","3","4"] as $roots |
      ["a","b","c","d"] as $families |
      ["5","6","7","8"] as $anchors |
      to_entries | map(.key as $i | .value |
        ($roots[$i] * 64) as $root |
        ($families[$i] * 64) as $family |
        ($anchors[$i] * 64) as $anchor |
        .action_freshness.recovery_component_claims[0] as $base |
        ($base | .txid=$root | .lineage_family_fingerprint=$family |
          .lineage_root_txid=$root | .lineage_parent_txid=$zero |
          .lineage_ordinal=0) as $node |
        .pow.mining_gate_lineage_head_txid=$root |
        .pow.mining_gate_family_claims=1 |
        .pow.mining_gate_live_claims=0 | .pow.mining_gate_eligible_claims=0 |
        .pow.live_claims=0 | .pow.unresolved_claims=1 |
        .action_freshness.lineage_head_txid=$root |
        .action_freshness.recovery_component.anchor.txid=$anchor |
        .action_freshness.recovery_component.anchor.vout=$i |
        .action_freshness.recovery_component.generation_fingerprint=$family |
        .action_freshness.recovery_component.claim_txids=[$root] |
        .action_freshness.recovery_component.root_claim_txids=[$root] |
        .action_freshness.recovery_component.descendant_claims=0 |
        .action_freshness.recovery_component.nodes=[$node] |
        .action_freshness.recovery_component_claims=[$node] |
        .action_freshness.recovery_component_claim_txids=[$root] |
        .action_freshness.recovery_component_root_claim_txids=[$root] |
        .action_freshness.recovery_node=$node)'
}

make_graph_descendant_samples()
{
    make_samples refresh_same_anchor 4 | jq \
      --arg root_a "$(printf '1%.0s' {1..64})" \
      --arg child_a "$(printf '2%.0s' {1..64})" \
      --arg root_b "$(printf '3%.0s' {1..64})" \
      --arg child_b "$(printf '4%.0s' {1..64})" \
      --arg zero "$zero" '
      def member($base;$txid;$root;$parent;$ordinal):
        $base | .txid=$txid | .disposition="origin_expired" |
        .in_mempool=false | .quarantined=true | .relay_expiry_time=0 |
        .lineage_metadata_present=true | .lineage_metadata_valid=true |
        .lineage_root_txid=$root | .lineage_parent_txid=$parent |
        .lineage_ordinal=$ordinal;
      .[] |= (
        .action_freshness.recovery_component_claims[0] as $base |
        member($base;$root_a;$root_a;$zero;0) as $n0 |
        member($base;$child_a;$root_a;$root_a;1) as $n1 |
        member($base;$root_b;$root_a;$child_a;2) as $n2 |
        member($base;$child_b;$root_a;$root_b;3) as $n3 |
        [$n0,$n1,$n2,$n3] as $claims |
        ([$claims[].txid] | sort) as $claim_txids |
        ([$root_a,$root_b] | sort) as $graph_roots |
        .pow.mining_gate_lineage_head_txid=$child_b |
        .pow.mining_gate_family_claims=4 | .pow.mining_gate_live_claims=0 |
        .pow.mining_gate_eligible_claims=0 | .pow.live_claims=0 |
        .pow.unresolved_claims=4 |
        .action_freshness.lineage_head_txid=$child_b |
        .action_freshness.recovery_node=$n3 |
        .action_freshness.recovery_component_claims=$claims |
        .action_freshness.recovery_component_claim_txids=$claim_txids |
        .action_freshness.recovery_component_root_claim_txids=$graph_roots |
        .action_freshness.recovery_component |= (
          .claim_txids=$claim_txids | .root_claim_txids=$graph_roots |
          .descendant_claims=2 | .nodes=($claims | sort_by(.txid)) |
          .classification="current_branch_ineligible" |
          .all_claims_quarantined=true) |
        .action_freshness.raw_mempool={} | .action_freshness.live_members=[] |
        .action_freshness.mempool_entry_present=false |
        .action_freshness.mempool_entry=null |
        .action_freshness.mempool_entry_time=null)'
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
    local recovery=$1 txid=${2:-} txcount=${3:-0} wallet_name=${4:-} transactions='[]'
    local unlocked_until=${5:-9999999999} transaction_evidence='{}'
    if [[ -n "$txid" ]]; then
        transactions=$(jq -cn --arg txid "$txid" \
          '[{txid:$txid,category:"receive",abandoned:false}]')
        transaction_evidence=$(jq -cn --arg txid "$txid" '{($txid):{kind:"base_transaction",
          transaction:{txid:$txid,hex:"00",amount:1,confirmations:0,
            decoded:{txid:$txid,vout:[{scriptPubKey:{asm:""}}]},
            details:[{category:"receive",amount:1,abandoned:false}]},
          active_header:null,active_block:null,active_chain_hash:null}}')
    fi
    jq -cn --argjson recovery "$recovery" --argjson transactions "$transactions" \
      --argjson transaction_evidence "$transaction_evidence" \
      --arg walletname "$wallet_name" --argjson txcount "$txcount" \
      --argjson unlocked_until "$unlocked_until" \
      '{wallet:{walletname:$walletname,private_keys_enabled:true,
        quantum_keys:1,keypoolsize:100,keypoolsize_hd_internal:100,txcount:$txcount,
        unlocked_until:$unlocked_until},loaded_wallets:[$walletname],recovery:$recovery,
        transactions:$transactions,transaction_evidence:$transaction_evidence,
        quantum_inventory:{count:1,keys:[{address:"qq-payout",stored_in_wallet:true,
          label:"Gold Rush PoW"}]},automatic_key_creation_allowed:false,
        payout:"qq-payout",payout_address_info:{address:"qq-payout",ismine:true,
          iswatchonly:false,isquantummigration:true,
          labels:[{name:"Gold Rush PoW",purpose:"receive"}]},
        labeled_addresses:[{address:"qq-payout",label:"Gold Rush PoW",purpose:"receive"}],
        chain:{bestblockhash:$recovery.active_tip,blocks:$recovery.active_height,
          headers:$recovery.active_height,initialblockdownload:false}}'
}

make_preunlock_migration()
{
    local wallet_name=${1:-} old_recovery candidate_recovery before after
    old_recovery=$(make_recovery 7 | jq '
      .raw_quarantined_claims=11 | .blocking_quarantined_claims=6 |
      .actionable_quarantined_claims=4 | .indeterminate_quarantined_claims=2 |
      .raw_claim_objects=19 | .quarantined_claim_objects=8 |
      .retired_claim_objects=5 | .retired_components=3')
    candidate_recovery=$(make_recovery 42)
    before=$(make_wallet_state "$old_recovery" '' 0 "$wallet_name")
    after=$(make_wallet_state "$candidate_recovery" '' 0 "$wallet_name" 0)
    v3015_make_preunlock_migration_audit "$before" "$after"
}

make_delta()
{
    local wallet_name=${1:-} recovery before after
    recovery=$(make_recovery)
    before=$(make_wallet_state "$recovery" '' 0 "$wallet_name")
    after=$(make_wallet_state "$recovery" '' 0 "$wallet_name")
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
        anchor_authenticated:true,anchor_unspent:true,anchor_user_locked:false,
        claim_txids:[$claim],
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
          proof_origin_previous_block_hash:$tip,proof_version:4,
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

make_foreign_receive_delta()
{
    local base before after
    base=$(make_claim_delta)
    before=$(jq -c '.before' <<<"$base")
    after=$(jq -c '
      .after |
      .recovery.component_details[0] |= (
        .anchor.amount=0 | .anchor.scriptPubKey="" |
        .anchor_authenticated=false | .anchor_unspent=false |
        .anchor_user_locked=false | .classification="indeterminate" |
        .all_claims_explicitly_provenanced=false |
        .nodes |= map(.provenance="unknown" | .wallet_authored=false |
          .wallet_from_me=false | .authored_metadata_valid=false |
          .authored_tip_active_branch_bound=false)) |
      .recovery.unanchored_claim_txids=
        .recovery.component_details[0].claim_txids |
      .transactions |= map(.amount=1 | .confirmations=0) |
      .recovery.component_details[0].claim_txids[0] as $claim |
      .transaction_evidence[$claim].transaction.decoded.vout=
        [{scriptPubKey:{asm:"OP_RETURN 51515350524f4f4600"}}]' <<<"$base")
    v3015_make_wallet_audit "$before" "$after"
}

make_foreign_receive_migration()
{
    local base foreign component evidence claim after
    base=$(make_preunlock_migration)
    foreign=$(make_foreign_receive_delta)
    component=$(jq -c '.after.recovery.component_details[0]' <<<"$foreign")
    claim=$(jq -r '.claim_txids[0]' <<<"$component")
    evidence=$(jq -c --arg claim "$claim" '.after.transaction_evidence[$claim]' <<<"$foreign")
    after=$(jq -c --argjson component "$component" --argjson evidence "$evidence" \
      --arg claim "$claim" '
      .after |
      .recovery |= (
        .component_details=[$component] | .components=1 |
        .blocking_components=1 | .raw_claim_objects=1 |
        .quarantined_claim_objects=1 | .raw_quarantined_claims=1 |
        .unanchored_claim_txids=[$claim]) |
      .transactions=[{txid:$claim,category:"receive",amount:1,
        confirmations:0,abandoned:false}] |
      .transaction_evidence={($claim):$evidence} |
      .wallet.txcount=1' <<<"$base")
    v3015_make_preunlock_migration_audit "$(jq -c '.before' <<<"$base")" "$after"
}

make_ordinary_receive_delta()
{
    local recovery before after txid
    txid=$(printf '6%.0s' {1..64})
    recovery=$(make_recovery)
    before=$(make_wallet_state "$recovery")
    after=$(make_wallet_state "$recovery" "$txid" 1)
    after=$(jq -c '.transactions[0] |= (.amount=1 | .confirmations=0)' <<<"$after")
    v3015_make_wallet_audit "$before" "$after"
}

make_confirmed_receive_delta()
{
    local base before after txid blockhash
    base=$(make_ordinary_receive_delta)
    before=$(jq -c '.before' <<<"$base")
    txid=$(jq -r '.after.transactions[0].txid' <<<"$base")
    blockhash=$(jq -r '.after.chain.bestblockhash' <<<"$base")
    after=$(jq -c --arg txid "$txid" --arg blockhash "$blockhash" '
      .after |
      .transactions[0].confirmations=1 |
      .transaction_evidence[$txid] |= (
        .transaction.confirmations=1 |
        .transaction.blockhash=$blockhash |
        .transaction.blockheight=1000 | .transaction.blockindex=1 |
        .active_header={hash:$blockhash,height:1000,confirmations:1} |
        .active_block={hash:$blockhash,height:1000,confirmations:1,tx:[$txid]} |
        .active_chain_hash=$blockhash)' <<<"$base")
    v3015_make_wallet_audit "$before" "$after"
}

make_recovery_absent_confirmed_authored_claim_delta()
{
    local version=${1:-4} magic context created_tip inclusion_parent blockhash
    local input family payout target payload payload_bytes carrier_script
    local carrier_bytes raw txid before_recovery after_recovery before after
    created_tip=$(printf 'd%.0s' {1..64})
    inclusion_parent=$(printf 'c%.0s' {1..64})
    blockhash=$(printf 'e%.0s' {1..64})
    input=$(printf 'a%.0s' {1..64})
    family=$(printf 'b%.0s' {1..64})
    payout="6020$(printf '9%.0s' {1..64})"
    target="76a914$(printf '8%.0s' {1..40})88ac"
    case "$version" in
        2) magic=51515032; context='' ;;
        3) magic=51515033; context="e8030000${created_tip}" ;;
        4) magic=51515034; context="e8030000${created_tip}${input}00000000" ;;
        *) return 1 ;;
    esac
    payload="51515350524f4f46${magic}000100000000000000${context}"
    payload+="1900${target}2200${payout}"
    payload_bytes=$((${#payload} / 2))
    printf -v carrier_script '6a4c%02x%s' "$payload_bytes" "$payload"
    carrier_bytes=$((${#carrier_script} / 2))
    raw="0200000001${input}0000000000fdffffff02"
    raw+="a08601000000000019${target}"
    printf -v raw '%s0000000000000000%02x%s00000000' \
      "$raw" "$carrier_bytes" "$carrier_script"
    txid=$(v3015_txid_from_raw_hex "$raw") || return 1
    before_recovery=$(make_recovery 10 "$created_tip" | jq '
      .active_height=999 | .wallet_processed_height=999')
    after_recovery=$(make_recovery 11 "$blockhash" | jq '
      .active_height=1001 | .wallet_processed_height=1001')
    before=$(make_wallet_state "$before_recovery" '' 0 default_wallet)
    after=$(make_wallet_state "$after_recovery" '' 0 default_wallet)
    after=$(jq -c --arg txid "$txid" --arg raw "$raw" --arg input "$input" \
      --arg family "$family" --arg target "$target" --arg payload "$payload" \
      --arg carrier "$carrier_script" --arg created_tip "$created_tip" \
      --arg inclusion_parent "$inclusion_parent" --arg blockhash "$blockhash" '
      .transactions=[{txid:$txid,category:"send",amount:0,label:"PoW Claim",
        vout:0,fee:-0.00001,confirmations:1,blockhash:$blockhash,
        abandoned:false,comment:"PoW Claim",qq_shadow_pow_authored:"1",
        qq_shadow_pow_created_height:"1000",qq_shadow_pow_created_tip:$created_tip,
        qq_shadow_pow_lineage_schema:"1",qq_shadow_pow_lineage_family:$family,
        qq_shadow_pow_lineage_root:$txid,qq_shadow_pow_lineage_ordinal:"0"}] |
      .wallet.txcount=1 |
      .transaction_evidence={($txid):{
        kind:"base_transaction",
        transaction:{txid:$txid,hex:$raw,amount:0,fee:-0.00001,
          confirmations:1,blockhash:$blockhash,blockheight:1001,blockindex:1,
          comment:"PoW Claim",qq_shadow_pow_authored:"1",
          qq_shadow_pow_created_height:"1000",qq_shadow_pow_created_tip:$created_tip,
          qq_shadow_pow_lineage_schema:"1",qq_shadow_pow_lineage_family:$family,
          qq_shadow_pow_lineage_root:$txid,qq_shadow_pow_lineage_ordinal:"0",
          decoded:{txid:$txid,
            vin:[{txid:$input,vout:0,sequence:4294967293}],
            vout:[{n:0,value:0.001,
                scriptPubKey:{asm:"OP_DUP OP_HASH160 8888888888888888888888888888888888888888 OP_EQUALVERIFY OP_CHECKSIG",
                  hex:$target,type:"pubkeyhash"}},
              {n:1,value:0,scriptPubKey:{asm:("OP_RETURN " + $payload),
                  hex:$carrier,type:"nulldata"}}]},
          details:[{category:"send",amount:0,label:"PoW Claim",vout:0,
            fee:-0.00001,abandoned:false}]},
        active_header:{hash:$blockhash,height:1001,confirmations:1,
          previousblockhash:$inclusion_parent},
        active_block:{hash:$blockhash,height:1001,confirmations:1,
          tx:[("f"*64),$txid]},
        active_chain_hash:$blockhash,
        created_tip_header:{hash:$created_tip,height:999,confirmations:3},
        created_tip_active_chain_hash:$created_tip}}' <<<"$after") || return 1
    v3015_make_wallet_audit "$before" "$after"
}

rewrite_recovery_absent_claim_carrier()
{
    local audit=$1 search=$2 replacement=$3 before after old_txid old_raw
    local old_script new_script new_payload new_raw new_txid evidence
    [[ ${#search} -eq ${#replacement} && "$search" != "$replacement" ]] || return 1
    before=$(jq -ce '.before' <<<"$audit") || return 1
    after=$(jq -ce '.after' <<<"$audit") || return 1
    old_txid=$(jq -er '.transactions[-1].txid' <<<"$after") || return 1
    evidence=$(jq -ce --arg txid "$old_txid" '.transaction_evidence[$txid]' \
      <<<"$after") || return 1
    old_raw=$(jq -er '.transaction.hex' <<<"$evidence") || return 1
    old_script=$(jq -er '.transaction.decoded.vout[1].scriptPubKey.hex' \
      <<<"$evidence") || return 1
    [[ "$old_script" == *"$search"* ]] || return 1
    new_script=${old_script/"$search"/"$replacement"}
    new_payload=${new_script:6}
    [[ "$old_raw" == *"$old_script"* ]] || return 1
    new_raw=${old_raw/"$old_script"/"$new_script"}
    new_txid=$(v3015_txid_from_raw_hex "$new_raw") || return 1
    after=$(jq -c --arg old "$old_txid" --arg new "$new_txid" \
      --arg raw "$new_raw" --arg script "$new_script" --arg payload "$new_payload" \
      --argjson evidence "$evidence" '
      .transaction_evidence |= (del(.[$old]) + {($new):($evidence |
        .transaction.txid=$new | .transaction.hex=$raw |
        .transaction.decoded.txid=$new |
        .transaction.decoded.vout[1].scriptPubKey.hex=$script |
        .transaction.decoded.vout[1].scriptPubKey.asm=("OP_RETURN " + $payload) |
        if .transaction.qq_shadow_pow_lineage_root == $old then
          .transaction.qq_shadow_pow_lineage_root=$new else . end |
        if (.transaction.qq_shadow_pow_lineage_parent // "") == $old then
          .transaction.qq_shadow_pow_lineage_parent=$new else . end |
        .active_block.tx |= map(if . == $old then $new else . end))}) |
      .transactions |= map(
        if .txid == $old then .txid=$new else . end |
        if .qq_shadow_pow_lineage_root == $old then
          .qq_shadow_pow_lineage_root=$new else . end |
        if (.qq_shadow_pow_lineage_parent // "") == $old then
          .qq_shadow_pow_lineage_parent=$new else . end)' <<<"$after") || return 1
    v3015_make_wallet_audit "$before" "$after"
}

rekey_recovery_absent_claim_raw()
{
    local audit=$1 new_raw=$2 before after old_txid new_txid evidence
    before=$(jq -ce '.before' <<<"$audit") || return 1
    after=$(jq -ce '.after' <<<"$audit") || return 1
    old_txid=$(jq -er '.transactions[-1].txid' <<<"$after") || return 1
    evidence=$(jq -ce --arg txid "$old_txid" '.transaction_evidence[$txid]' \
      <<<"$after") || return 1
    new_txid=$(v3015_txid_from_raw_hex "$new_raw") || return 1
    after=$(jq -c --arg old "$old_txid" --arg new "$new_txid" \
      --arg raw "$new_raw" --argjson evidence "$evidence" '
      .transaction_evidence |= (del(.[$old]) + {($new):($evidence |
        .transaction.txid=$new | .transaction.hex=$raw |
        .transaction.decoded.txid=$new |
        if .transaction.qq_shadow_pow_lineage_root == $old then
          .transaction.qq_shadow_pow_lineage_root=$new else . end |
        if (.transaction.qq_shadow_pow_lineage_parent // "") == $old then
          .transaction.qq_shadow_pow_lineage_parent=$new else . end |
        .active_block.tx |= map(if . == $old then $new else . end))}) |
      .transactions |= map(
        if .txid == $old then .txid=$new else . end |
        if .qq_shadow_pow_lineage_root == $old then
          .qq_shadow_pow_lineage_root=$new else . end |
        if (.qq_shadow_pow_lineage_parent // "") == $old then
          .qq_shadow_pow_lineage_parent=$new else . end)' <<<"$after") || return 1
    v3015_make_wallet_audit "$before" "$after"
}

make_recovery_absent_confirmed_authored_descendant_delta()
{
    local root_audit before root_txid root_created_tip created_tip inclusion_parent blockhash input
    local family payout target payload payload_bytes carrier_script carrier_bytes
    local raw txid after_recovery after
    root_audit=$(make_recovery_absent_confirmed_authored_claim_delta 4) || return 1
    before=$(jq -ce '.after' <<<"$root_audit") || return 1
    root_txid=$(jq -er '.transactions[0].txid' <<<"$before") || return 1
    root_created_tip=$(jq -er --arg root "$root_txid" \
      '.transaction_evidence[$root].transaction.qq_shadow_pow_created_tip' \
      <<<"$before") || return 1
    created_tip=$(jq -er '.chain.bestblockhash' <<<"$before") || return 1
    inclusion_parent=$(printf '6%.0s' {1..64})
    blockhash=$(printf '7%.0s' {1..64})
    input=$(printf 'a%.0s' {1..64})
    family=$(printf 'b%.0s' {1..64})
    payout="6020$(printf '9%.0s' {1..64})"
    target="76a914$(printf '8%.0s' {1..40})88ac"
    before=$(jq -c --arg root "$root_txid" --arg input "$input" \
      --arg family "$family" --arg target "$target" \
      --arg root_tip "$root_created_tip" '
      .transactions[0] |=
        (.confirmations=0 | del(.blockhash) |
         del(.qq_shadow_pow_lineage_schema,.qq_shadow_pow_lineage_family,
           .qq_shadow_pow_lineage_root,.qq_shadow_pow_lineage_parent,
           .qq_shadow_pow_lineage_ordinal)) |
      .transaction_evidence[$root] |=
        (.transaction |=
          (.confirmations=0 |
           del(.blockhash,.blockheight,.blockindex,
             .qq_shadow_pow_lineage_schema,.qq_shadow_pow_lineage_family,
             .qq_shadow_pow_lineage_root,.qq_shadow_pow_lineage_parent,
             .qq_shadow_pow_lineage_ordinal)) |
         .active_header=null | .active_block=null | .active_chain_hash=null |
         del(.created_tip_header,.created_tip_active_chain_hash)) |
      .recovery |=
        (.actionable_quarantined_claims=1 | .blocking_components=1 |
         .blocking_quarantined_claims=1 | .components=1 |
         .raw_claim_objects=1 | .quarantined_claim_objects=1 |
         .raw_quarantined_claims=1 |
         .component_details=[{
           all_claims_expired_locally_retired:false,
           all_claims_explicitly_provenanced:true,all_claims_quarantined:true,
           all_claims_zero_payment_retirable:false,
           anchor:{amount:1000,scriptPubKey:$target,txid:$input,vout:0},
           anchor_authenticated:true,anchor_unspent:true,anchor_user_locked:false,
           claim_txids:[$root],classification:"transient",
           component_fingerprint:$family,descendant_claims:0,
           generation_fingerprint:$family,has_revalidating_unbound_proof:false,
           minimum_stale_depth:0,nodes:[{
             abandoned:false,active_chain_confirmed:false,
             authored_metadata_valid:true,authored_tip_active_branch_bound:true,
             claim_descriptor_valid:true,disposition:"eligible",
             exact_authored_carrier_shape:true,expected_shape:true,
             expired_locally_retired:false,in_mempool:false,kind:"claim",
             lineage_family_fingerprint:("0"*64),lineage_metadata_present:false,
             lineage_metadata_valid:false,lineage_ordinal:0,
             lineage_parent_txid:("0"*64),lineage_root_txid:("0"*64),
             proof_evaluation_skipped_resolved_anchor:false,
             proof_input_bound:true,proof_may_revalidate_on_descendant:false,
             proof_mode:"pow",proof_origin_bound:true,proof_origin_height:1000,
             proof_origin_previous_block_hash:$root_tip,proof_version:4,
             provenance:"explicit_authored",quarantined:true,relay_expiry_time:0,
             relay_ttl_expired:false,resolution_metadata_valid:false,
             resolution_relay_authorized:false,stale_depth:0,
             stale_depth_known:true,txid:$root,wallet_authored:true,
             wallet_from_me:true}],ordinary_or_mixed_txids:[],resolution_txids:[],
           root_claim_txids:[$root],stale_depth_known:true}])' <<<"$before") || return 1
    payload="51515350524f4f4651515034000200000000000000ea030000${created_tip}"
    payload+="${input}000000001900${target}2200${payout}"
    payload_bytes=$((${#payload} / 2))
    printf -v carrier_script '6a4c%02x%s' "$payload_bytes" "$payload"
    carrier_bytes=$((${#carrier_script} / 2))
    raw="0200000001${input}0000000000fdffffff02"
    raw+="a08601000000000019${target}"
    printf -v raw '%s0000000000000000%02x%s00000000' \
      "$raw" "$carrier_bytes" "$carrier_script"
    txid=$(v3015_txid_from_raw_hex "$raw") || return 1
    after_recovery=$(make_recovery 12 "$blockhash" | jq '
      .active_height=1003 | .wallet_processed_height=1003')
    after=$(jq -c --argjson recovery "$after_recovery" --arg txid "$txid" \
      --arg root "$root_txid" --arg raw "$raw" --arg input "$input" \
      --arg family "$family" --arg target "$target" --arg payload "$payload" \
      --arg carrier "$carrier_script" --arg created_tip "$created_tip" \
      --arg inclusion_parent "$inclusion_parent" --arg blockhash "$blockhash" '
      .recovery=$recovery |
      .chain={bestblockhash:$blockhash,blocks:1003,headers:1003,
        initialblockdownload:false} |
      .transactions[0].confirmations=-1 |
      .transactions += [{txid:$txid,category:"send",amount:0,label:"PoW Claim",
        vout:0,fee:-0.00001,confirmations:1,blockhash:$blockhash,
        abandoned:false,comment:"PoW Claim",qq_shadow_pow_authored:"1",
        qq_shadow_pow_created_height:"1002",qq_shadow_pow_created_tip:$created_tip,
        qq_shadow_pow_lineage_schema:"1",qq_shadow_pow_lineage_family:$family,
        qq_shadow_pow_lineage_root:$root,
        qq_shadow_pow_lineage_parent:$root,qq_shadow_pow_lineage_ordinal:"1"}] |
      .wallet.txcount=2 |
      .transaction_evidence += {($txid):{
        kind:"base_transaction",
        transaction:{txid:$txid,hex:$raw,amount:0,fee:-0.00001,
          confirmations:1,blockhash:$blockhash,blockheight:1003,blockindex:1,
          comment:"PoW Claim",qq_shadow_pow_authored:"1",
          qq_shadow_pow_created_height:"1002",qq_shadow_pow_created_tip:$created_tip,
          qq_shadow_pow_lineage_schema:"1",qq_shadow_pow_lineage_family:$family,
          qq_shadow_pow_lineage_root:$root,
          qq_shadow_pow_lineage_parent:$root,qq_shadow_pow_lineage_ordinal:"1",
          decoded:{txid:$txid,
            vin:[{txid:$input,vout:0,sequence:4294967293}],
            vout:[{n:0,value:0.001,
                scriptPubKey:{asm:"OP_DUP OP_HASH160 8888888888888888888888888888888888888888 OP_EQUALVERIFY OP_CHECKSIG",
                  hex:$target,type:"pubkeyhash"}},
              {n:1,value:0,scriptPubKey:{asm:("OP_RETURN " + $payload),
                  hex:$carrier,type:"nulldata"}}]},
          details:[{category:"send",amount:0,label:"PoW Claim",vout:0,
            fee:-0.00001,abandoned:false}]},
        active_header:{hash:$blockhash,height:1003,confirmations:1,
          previousblockhash:$inclusion_parent},
        active_block:{hash:$blockhash,height:1003,confirmations:1,
          tx:[("f"*64),$txid]},
        active_chain_hash:$blockhash,
        created_tip_header:{hash:$created_tip,height:1001,confirmations:3},
        created_tip_active_chain_hash:$created_tip}}' <<<"$before") || return 1
    v3015_make_wallet_audit "$before" "$after"
}

make_synthetic_payout_delta()
{
    local recovery source payout anchor before after
    source=$(printf '7%.0s' {1..64}); payout=$(printf '8%.0s' {1..64})
    anchor=$(printf '9%.0s' {1..64})
    recovery=$(make_recovery)
    before=$(make_wallet_state "$recovery")
    after=$(jq -c --arg source "$source" --arg payout "$payout" \
      --arg anchor "$anchor" '
      . |
      .transactions += [{txid:$payout,category:"generate",amount:5,confirmations:1,
        address:"qq-payout",blockhash:.chain.bestblockhash,abandoned:false,
        qq_synthetic_goldrush_payout:"1"}] |
      .wallet.txcount=1 |
      (.chain.bestblockhash) as $blockhash |
      {txid:$source,hex:"00",blockhash:$blockhash,
        vin:[{txid:$anchor,vout:0}],
        vout:[{scriptPubKey:{asm:"OP_RETURN 51515350524f4f4651515034"}}]} as $raw |
      {txid:$source,vout:0,logical_proof_id:("b"*64),canonical_rank:("c"*64),
        disposition:"winner",base_fee_known:true,base_fee:0.001,proof_version:4,
        origin_bound:true,origin_height:1000,origin_previous_block_hash:("d"*64),
        inclusion_height:1000,origin_age:0,input_bound:true,
        claim_outpoint:{txid:$anchor,vout:0}} as $source_descriptor |
      {schema:"blackcoin.shadow.transaction.v1",synthetic:true,merkle_included:false,
        synthetic_txid:$payout,vout:0,mode:"pow",confirmations:1,status:"unspent",
        lifecycle_category:"migration_spendable_direct_quantum",
        nominal_amount:5,scriptPubKey:"51",address:"qq-payout",
        valuation_status:"current_next_block_consensus",spend:null,
        base_anchor:{blockhash:$blockhash,height:1000,time:1700000000,claim_index:0},
        pow_claim_source:$source_descriptor} as $shadow |
      .transaction_evidence={
        ($payout):{kind:"synthetic_payout",shadow_transaction:$shadow,
          active_header:{hash:$blockhash,height:1000,confirmations:1},
          active_block:{hash:$blockhash,height:1000,confirmations:1,tx:[$source]},
          active_chain_hash:$blockhash,source_transaction:$raw}}' <<<"$before")
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

make_graph_descendant_delta()
{
    local base before after root sibling child_a child_b
    child_a=$(printf 'f%.0s' {1..64})
    child_b=$(printf '9%.0s' {1..64})
    base=$(make_sibling_claim_delta)
    before=$(jq -c '.before' <<<"$base")
    root=$(jq -r '.after.recovery.component_details[0].nodes |
      sort_by(.lineage_ordinal) | .[0].txid' <<<"$base")
    sibling=$(jq -r '.after.recovery.component_details[0].nodes |
      sort_by(.lineage_ordinal) | .[1].txid' <<<"$base")
    after=$(jq -c --arg root "$root" --arg sibling "$sibling" \
      --arg child_a "$child_a" --arg child_b "$child_b" '
      .after |
      (.recovery.component_details[0].nodes[] | select(.txid == $sibling)) as $template |
      ($template | .txid=$child_a | .lineage_ordinal=2 |
        .lineage_root_txid=$root | .lineage_parent_txid=$sibling) as $first |
      ($template | .txid=$child_b | .lineage_ordinal=3 |
        .lineage_root_txid=$root | .lineage_parent_txid=$child_a) as $second |
      .recovery.component_details[0].nodes += [$first,$second] |
      .recovery.component_details[0].claim_txids |=
        (. + [$child_a,$child_b] | unique | sort) |
      .recovery.component_details[0].descendant_claims=2 |
      .recovery.raw_claim_objects=4 | .recovery.quarantined_claim_objects=4 |
      .transactions += [{txid:$child_a,category:"receive",abandoned:false},
        {txid:$child_b,category:"receive",abandoned:false}] |
      .wallet.txcount=4' <<<"$base")
    v3015_make_wallet_audit "$before" "$after"
}

make_legacy_root_descendant_delta()
{
    local base before after root sibling
    base=$(make_sibling_claim_delta)
    root=$(jq -r '.after.recovery.component_details[0].nodes |
      sort_by(.lineage_ordinal) | .[0].txid' <<<"$base")
    sibling=$(jq -r '.after.recovery.component_details[0].nodes |
      sort_by(.lineage_ordinal) | .[1].txid' <<<"$base")
    after=$(jq -c --arg root "$root" '
      .after |
      (.recovery.component_details[0].nodes[] | select(.txid == $root)) |=
        (.provenance="explicit_authored" |
         .proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
         .lineage_metadata_present=false | .lineage_metadata_valid=false |
         .lineage_family_fingerprint=("0"*64) |
         .lineage_root_txid=("0"*64) | .lineage_parent_txid=("0"*64))' <<<"$base")
    before=$(jq -c --arg sibling "$sibling" '
      . |
      .recovery.component_details[0].nodes |= map(select(.txid != $sibling)) |
      .recovery.component_details[0].claim_txids |= map(select(. != $sibling)) |
      .recovery.component_details[0].root_claim_txids |= map(select(. != $sibling)) |
      .recovery.raw_claim_objects=1 | .recovery.quarantined_claim_objects=1 |
      .transactions |= map(select(.txid != $sibling)) | .wallet.txcount=1' <<<"$after")
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
pow=$(make_pow wait_for_live "$(printf '%064x' 8)" 0.1 0)
expect_pass 'typed wait state permits a positive transient hashrate sample' \
  v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow wait_for_next_tip "$(printf '%064x' 8)" 0 0 | jq \
  '.mining_gate_can_submit=false')
expect_pass 'fresh zero-relay next-tip deferral may report can-submit false' \
  v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow wait_for_live "$(printf '%064x' 8)" 0 0 | jq '.payout_address=""')
expect_pass 'retained-family wait may have no configured future payout address' \
  v3015_pow_json_is_typed_safe "$pow"

pow=$(make_pow create_new_anchor "$(printf '%064x' 9)" 0.1 0 | jq '
  .unresolved_claims=1 | .live_claims=19 |
  .quarantined_claims=13 | .blocking_quarantined_claims=5 |
  .actionable_quarantined_claims=3 | .indeterminate_quarantined_claims=7 |
  .raw_quarantined_claims=2 | .claim_components=9')
expect_pass 'typed gate ignores contradictory legacy quarantine telemetry when the authoritative gate is safe' \
  v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow create_new_anchor "$(printf '%064x' 9)" 0.1 0 | jq '
  .mining_gate_unresolved_components=2 | .unresolved_claims=7 |
  .claim_components=9 | .raw_quarantined_claims=5 | .quarantined_claims=5')
expect_fail 'create-new-anchor rejects an authoritative unresolved component' \
  v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow create_new_anchor "$(printf '%064x' 9)" 0.1 0 | jq \
  '.mining_gate_unsafe_components=1')
expect_fail 'create-new-anchor still rejects an authoritative unsafe component' \
  v3015_pow_json_is_typed_safe "$pow"
familyless_pow=$(make_pow create_new_anchor "$(printf '%064x' 15)" 0 0 | jq \
  --arg zero "$zero" '
  .mining_gate_action="wait_for_next_tip" | .mining_gate_can_submit=true |
  .mining_gate_unresolved_components=0 | .mining_gate_live_claims=0 |
  .mining_gate_eligible_claims=0 | .mining_gate_family_claims=0 |
  .mining_gate_lineage_head_txid=$zero | .mining_gate_relay_txid=$zero |
  .state="claim_in_flight"')
expect_pass 'typed gate accepts the exact familyless fresh-new-anchor wait' \
  v3015_pow_json_is_typed_safe "$familyless_pow"
for malformed_familyless in \
    '.mining_gate_can_submit=false' \
    '.mining_gate_unresolved_components=1' \
    '.mining_gate_live_claims=1' \
    '.mining_gate_eligible_claims=1' \
    '.mining_gate_family_claims=1' \
    '.mining_gate_lineage_head_txid=("a"*64)' \
    '.mining_gate_relay_txid=("b"*64)'; do
    pow=$(jq "$malformed_familyless" <<<"$familyless_pow")
    expect_fail "familyless wait rejects ${malformed_familyless}" \
      v3015_pow_json_is_typed_safe "$pow"
done
pow=$(make_pow wait_for_next_tip "$(printf '%064x' 9)" 0 0 | jq \
  '.mining_gate_unresolved_components=3')
expect_pass 'typed gate accepts one Core-selected family among multiple clean components' \
  v3015_pow_json_is_typed_safe "$pow"
for aggregate_action in relay_existing refresh_same_anchor wait_for_next_tip; do
    if [[ "$aggregate_action" == refresh_same_anchor ]]; then
        pow=$(make_pow "$aggregate_action" "$(printf '%064x' 14)" 0.1 0)
    else
        pow=$(make_pow "$aggregate_action" "$(printf '%064x' 14)" 0 0)
    fi
    pow=$(jq '.mining_gate_unresolved_components=2 |
      .mining_gate_family_claims+=1 | .mining_gate_live_claims=1 |
      .live_claims=1 | .claim_components=2' <<<"$pow")
    expect_pass "typed $aggregate_action may coexist with a live unselected family" \
      v3015_pow_json_is_typed_safe "$pow"
done

pow=$(make_pow wait_for_live "$(printf '%064x' 11)" 0 0 | jq '.mining_gate_unsafe_claims=1')
expect_fail 'typed gate rejects unsafe claim' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow wait_for_live "$(printf '%064x' 11)" 0 0 | jq '.mining_gate_coherent=false')
expect_fail 'typed gate rejects an incoherent gate' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow relay_existing "$(printf '%064x' 12)" 0 0 | jq 'del(.mining_gate_coherent)')
expect_fail 'typed gate rejects partial schema' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow relay_existing "$(printf '%064x' 12)" 0 0 | jq '.unexpected_field=true')
expect_fail 'typed gate rejects unexpected schema field' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow create_new_anchor "$(printf '%064x' 12)" 0.1 0 | jq '.allow_automatic_quantum_key_creation=true')
expect_fail 'typed gate rejects automatic key authority' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow refresh_same_anchor "$(printf '%064x' 13)" 0.1 0 | jq '.mining_gate_database_ambiguous=true')
expect_fail 'typed gate rejects database ambiguity' v3015_pow_json_is_typed_safe "$pow"
pow=$(make_pow refresh_same_anchor "$(printf '%064x' 13)" 0.1 0 | jq \
  '.claim_recovery_database_outcome_ambiguous=true')
expect_fail 'typed gate rejects recovery database ambiguity' v3015_pow_json_is_typed_safe "$pow"
expect_pass 'unchanged valid cache fingerprint across fresh tips is live' \
  v3015_pow_series_is_live "$(make_samples wait_for_next_tip)"
locked_wait=$(make_samples wait_for_next_tip | jq \
  '.[] |= (.pow.mining_gate_can_submit=false |
    .action_freshness.recovery_component.anchor_user_locked=true)')
expect_pass 'user-locked selected anchor permits only a non-submit zero-relay next-tip wait' \
  v3015_pow_series_is_live "$locked_wait"
locked_submit=$(jq '.[].pow.mining_gate_can_submit=true' <<<"$locked_wait")
expect_fail 'user-locked selected anchor rejects stale can-submit authority' \
  v3015_pow_series_is_live "$locked_submit"
for locked_wrong_action in wait_for_live relay_existing refresh_same_anchor; do
    locked_wrong=$(make_samples "$locked_wrong_action" | jq \
      '.[].action_freshness.recovery_component.anchor_user_locked=true')
    expect_fail "user-locked selected anchor rejects $locked_wrong_action" \
      v3015_pow_series_is_live "$locked_wrong"
done
fresh_deferred_wait=$(make_samples wait_for_next_tip | jq \
  '.[].pow.mining_gate_can_submit=false')
expect_pass 'fresh zero-relay next-tip deferral remains live with can-submit false' \
  v3015_pow_series_is_live "$fresh_deferred_wait"
locked_live_wait=$(make_samples wait_for_live | jq '
  .[] |= (.pow.mining_gate_action="wait_for_next_tip" |
    .pow.mining_gate_can_submit=false |
    .action_freshness.action="wait_for_next_tip" |
    .action_freshness.recovery_component.anchor_user_locked=true)')
expect_pass 'zero-relay locked next-tip wait may retain one authenticated local live member' \
  v3015_pow_series_is_live "$locked_live_wait"
familyless_waits=$(make_familyless_wait_samples 4)
create_work=$(make_samples create_new_anchor 4)
familyless_same_cut_1=$(rebind_sample_cut \
  "$(jq -c '.[1]' <<<"$familyless_waits")" "$(jq -c '.[0]' <<<"$create_work")")
familyless_same_cut_3=$(rebind_sample_cut \
  "$(jq -c '.[3]' <<<"$familyless_waits")" "$(jq -c '.[2]' <<<"$create_work")")
bounded_familyless=$(jq -cn --argjson create "$create_work" \
  --argjson wait1 "$familyless_same_cut_1" --argjson wait3 "$familyless_same_cut_3" \
  '[$create[0],$wait1,$create[2],$wait3]')
expect_pass 'same-cut familyless waits remain bounded by fresh create hash work' \
  v3015_pow_series_is_live "$bounded_familyless"
expect_pass 'fresh-tip familyless waits count active-chain progress without claim work' \
  v3015_pow_series_is_complete "$familyless_waits"
familyless_with_target=$(jq -cn --argjson familyless "$familyless_waits" \
  --argjson selected "$(make_samples wait_for_next_tip 4)" \
  '$familyless | .[1].action_freshness=$selected[1].action_freshness')
expect_fail 'familyless wait rejects selected-family freshness evidence' \
  v3015_pow_series_is_live "$familyless_with_target"
familyless_counter_progress=$(jq '
  .[0].pow.claims_submitted=0 | .[1].pow.claims_submitted=1 |
  .[2].pow.claims_submitted=1 | .[3].pow.claims_submitted=2' <<<"$familyless_waits")
expect_pass 'familyless waits accept only real worker submission-count progress' \
  v3015_pow_series_is_live "$familyless_counter_progress"
short_familyless=$(collapse_series_to_first_cut "$familyless_waits" | jq '
  .[0].sample_started_unix_ms as $base |
  to_entries | map(.key as $i | .value |
    .sample_started_unix_ms=($base + ($i * 5000)) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100))')
expect_pass 'several identical five-second familyless polls collapse without fake transitions' \
  v3015_pow_series_is_live "$short_familyless"
expect_fail 'short same-tip familyless polls remain intermediate until a witness arrives' \
  v3015_pow_series_is_complete "$short_familyless"
short_retained=$(collapse_series_to_first_cut \
  "$(make_samples wait_for_next_tip 4 '' no_progress)" | jq '
  .[0].sample_started_unix_ms as $base |
  to_entries | map(.key as $i | .value |
    .sample_started_unix_ms=($base + ($i * 5000)) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100) |
    .action_freshness.observed_unix_ms=.sample_finished_unix_ms)')
expect_pass 'several identical five-second retained-family polls collapse without progress' \
  v3015_pow_series_is_live "$short_retained"
expect_fail 'short same-tip retained-family polling remains intermediate' \
  v3015_pow_series_is_complete "$short_retained"
foreign_telemetry_churn=$(jq '
  ["1","2","3","4"] as $fingerprints |
  to_entries | map(.key as $i | .value |
    .pow.mining_gate_candidate_state_fingerprint=($fingerprints[$i] * 64) |
    .action_freshness.candidate_state_fingerprint=
      .pow.mining_gate_candidate_state_fingerprint |
    .pow.unresolved_claims=(10 + $i) |
    .pow.live_claims=(20 + $i) | .pow.claim_components=(30 + $i) |
    .pow.quarantined_claims=(40 + $i) |
    .pow.raw_quarantined_claims=(50 + $i) |
    .pow.blocking_quarantined_claims=(60 + $i) |
    .pow.actionable_quarantined_claims=(70 + $i) |
    .pow.indeterminate_quarantined_claims=(80 + $i) |
    .pow.pending_manual_resolutions=(90 + $i) |
    .pow.pending_automatic_resolutions=(100 + $i) |
    .pow.cumulative_resolution_fees=(110 + $i) |
    .pow.claims_auto_resolved=(120 + $i) |
    .pow.claims_recycled=(130 + $i) |
    .pow.resolved_on_active_chain_claims=(140 + $i))' <<<"$short_retained")
expect_pass 'foreign-only fingerprint and legacy recovery-counter churn collapses without blocking' \
  v3015_pow_series_is_live "$foreign_telemetry_churn"
wallet_generation_churn=$(jq '
  to_entries | map(.key as $i | .value |
    .wallet_generation=(500 + $i))' <<<"$short_retained")
expect_pass 'foreign-only wallet-generation churn collapses without blocking selected work' \
  v3015_pow_series_is_live "$wallet_generation_churn"
unrelated_mempool_churn=$(jq '
  ["5","6","7","8"] as $foreign_txids |
  to_entries | map(.key as $i | .value |
    .action_freshness.raw_mempool[($foreign_txids[$i] * 64)]={time:(1700000000+$i)})' \
  <<<"$short_retained")
expect_pass 'unrelated foreign or ordinary mempool churn does not consume progress budget' \
  v3015_pow_series_is_live "$unrelated_mempool_churn"
long_unchanged=$(jq '
  .[0].sample_started_unix_ms as $base | .[-1] |= (
    .sample_started_unix_ms=($base + 600001) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100) |
    .action_freshness.observed_unix_ms=.sample_finished_unix_ms)' <<<"$short_retained")
expect_fail 'collapsed unchanged authority still fails the ten-minute elapsed bound' \
  v3015_pow_series_is_live "$long_unchanged"
frozen_tip_positive_hash=$(collapse_series_to_first_cut \
  "$(make_samples create_new_anchor 4)" | jq '
  .[0].sample_started_unix_ms as $base |
  .[].pow.hashrate=0.1 |
  .[-1] |= (.sample_started_unix_ms=($base + 600001) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100))')
expect_fail 'positive submit work cannot mask a chain frozen beyond ten minutes' \
  v3015_pow_series_is_live "$frozen_tip_positive_hash"
for wait_action in wait_for_live wait_for_next_tip relay_existing; do
    same_tip_wait=$(collapse_series_to_first_cut \
      "$(make_samples "$wait_action" 5 '' no_progress)")
    expect_pass "short unchanged $wait_action remains valid intermediate polling" \
      v3015_pow_series_is_live "$same_tip_wait"
    expect_fail "short coherent $wait_action still needs bounded action or tip progress" \
      v3015_pow_series_is_complete "$same_tip_wait"
done
positive_wait_stall=$(collapse_series_to_first_cut \
  "$(make_samples wait_for_next_tip 5 '' no_progress)" | jq \
  '.[].pow.hashrate=0.1')
expect_fail 'transient hash alone is not retained-family action progress' \
  v3015_pow_series_is_complete "$positive_wait_stall"
fingerprint_churn=$(make_samples wait_for_next_tip 5 '' no_progress | jq '
  to_entries | map(.key as $i | .value |
    .pow.mining_gate_candidate_state_fingerprint=(["1","2","3","4","5"][$i] * 64) |
    .action_freshness.candidate_state_fingerprint=
      .pow.mining_gate_candidate_state_fingerprint)')
expect_fail 'cache-fingerprint churn is not authoritative mining progress' \
  v3015_pow_series_is_complete "$(collapse_series_to_first_cut "$fingerprint_churn")"
same_tip_fingerprint_churn=$(collapse_series_to_first_cut "$fingerprint_churn")
expect_pass 'same-tip foreign-only candidate fingerprint churn collapses without blocking' \
  v3015_pow_series_is_live "$same_tip_fingerprint_churn"
unauthenticated_churn=$(make_samples wait_for_next_tip | jq \
  '.[2:] |= map(.action_freshness.recovery_component.anchor_authenticated=false)')
expect_fail 'unauthenticated lineage-field churn is not mining progress' \
  v3015_pow_series_is_live "$unauthenticated_churn"
wait_a=$(make_samples wait_for_next_tip 8 '' no_progress)
wait_b=$(make_samples relay_existing 8 '' no_progress)
alternating=$(jq -cn --argjson a "$wait_a" --argjson b "$wait_b" '
  $a | to_entries | map(if (.key % 2) == 0 then .value else $b[.key] end)')
expect_fail 'alternating previously seen safe waits cannot reset progress budget' \
  v3015_pow_series_is_live "$alternating"
same_tip_action_churn=$(make_samples wait_for_next_tip 5 '' no_progress | jq '
  to_entries | map(.key as $i | .value |
    if ($i % 2) == 1 then
      .pow.mining_gate_action="refresh_same_anchor" |
      .pow.mining_gate_can_submit=true | .pow.state="ready" |
      .action_freshness.action="refresh_same_anchor"
    else . end)')
same_tip_action_churn=$(collapse_series_to_first_cut "$same_tip_action_churn")
expect_fail 'same-tip action switches remain distinct but receive no progress credit' \
  v3015_pow_series_is_complete "$same_tip_action_churn"
family_a=$(collapse_series_to_first_cut \
  "$(make_samples wait_for_next_tip 4 '' no_progress)")
family_b=$(collapse_series_to_first_cut \
  "$(make_samples refresh_same_anchor 4 '' no_progress)" | jq \
  --arg root "$(printf '5%.0s' {1..64})" \
  --arg family "$(printf '6%.0s' {1..64})" \
  --arg anchor "$(printf '4%.0s' {1..64})" --arg zero "$zero" '
  .[] |= (.action_freshness.recovery_component_claims[0] as $base |
    ($base | .txid=$root | .lineage_family_fingerprint=$family |
      .lineage_root_txid=$root | .lineage_parent_txid=$zero |
      .lineage_ordinal=0) as $node |
    .pow.mining_gate_lineage_head_txid=$root |
    .action_freshness.lineage_head_txid=$root |
    .action_freshness.recovery_component.anchor.txid=$anchor |
    .action_freshness.recovery_component.anchor.vout=1 |
    .action_freshness.recovery_component.generation_fingerprint=$family |
    .action_freshness.recovery_component.claim_txids=[$root] |
    .action_freshness.recovery_component.root_claim_txids=[$root] |
    .action_freshness.recovery_component.nodes=[$node] |
    .action_freshness.recovery_component_claims=[$node] |
    .action_freshness.recovery_component_claim_txids=[$root] |
    .action_freshness.recovery_component_root_claim_txids=[$root] |
    .action_freshness.recovery_node=$node)')
same_tip_family_defer=$(jq -cn --argjson a "$family_a" --argjson b "$family_b" \
  '[$a[0],$b[1],$a[2],$b[3]]')
expect_pass 'same-tip family A deferral permits real positive-hash progress on safe family B' \
  v3015_pow_series_is_live "$same_tip_family_defer"
live_samples=$(make_samples wait_for_live 4 '' no_progress)
relay_to_live=$(jq -cn --argjson absent "$(make_samples wait_for_next_tip 4 '' no_progress)" \
  --argjson live "$live_samples" '$absent |
    .[2]=$live[2] | .[3]=$live[3]')
expect_pass 'short safe wait followed by authoritative mempool-live transition passes' \
  v3015_pow_series_is_live "$relay_to_live"
progress_then_stall=$(jq -cn \
  --argjson absent "$(make_samples wait_for_next_tip 5 '' no_progress)" \
  --argjson live "$(make_samples wait_for_live 5 '' no_progress)" \
  '[$absent[0],$live[1],$absent[2],$absent[3],$absent[4]]')
expect_pass 'one live transition is a valid witness before the ten-minute budget expires' \
  v3015_pow_series_is_complete "$progress_then_stall"
live_a=$(make_samples wait_for_live 4 '' no_progress)
absent_a=$(make_samples wait_for_next_tip 4 '' no_progress)
live_a_replay=$(jq -cn --argjson live "$live_a" --argjson absent "$absent_a" \
  '[$live[0],$absent[1],$live[2],$absent[3]]')
live_a_replay=$(collapse_series_to_first_cut "$live_a_replay")
expect_fail 'a live txid cannot complete same-tip polling after absence and reappearance' \
  v3015_pow_series_is_complete "$live_a_replay"
progressed_live=$(make_samples wait_for_live 4)
progressed_absent=$(make_samples wait_for_next_tip 4)
new_live_member=$(jq -cn --argjson live "$progressed_live" --argjson absent "$absent_a" \
  --argjson progressed_absent "$progressed_absent" \
  '[$live[0],$absent[1],$live[2],$progressed_absent[3]]')
expect_pass 'a genuinely first-seen authenticated live txid resets progress budget' \
  v3015_pow_series_is_live "$new_live_member"
same_family_live_2=$(rebind_sample_family \
  "$(jq -c '.[2]' <<<"$live_a")" "$(jq -c '.[1]' <<<"$live_a")")
same_family_live_3=$(rebind_sample_family \
  "$(jq -c '.[3]' <<<"$live_a")" "$(jq -c '.[1]' <<<"$live_a")")
same_family_live=$(jq -cn --argjson absent "$absent_a" --argjson live "$live_a" \
  --argjson live2 "$same_family_live_2" --argjson live3 "$same_family_live_3" \
  '[$absent[0],$live[1],$live2,$live3]')
same_family_live=$(collapse_series_to_first_cut "$same_family_live")
expect_pass 'first live member is progress after the same family/member was authenticated absent' \
  v3015_pow_series_is_live "$same_family_live"
unseen_live_b=$(jq -c --arg root "$(printf '5%.0s' {1..64})" \
  --arg family "$(printf '6%.0s' {1..64})" \
  --arg anchor "$(printf '4%.0s' {1..64})" --arg zero "$zero" '
  .[2] |= (.action_freshness.recovery_node as $base |
    .action_freshness.mempool_entry as $entry |
    ($base | .txid=$root | .lineage_family_fingerprint=$family |
      .lineage_root_txid=$root | .lineage_parent_txid=$zero |
      .lineage_ordinal=0) as $node |
    .pow.mining_gate_lineage_head_txid=$root |
    .action_freshness.lineage_head_txid=$root |
    .action_freshness.recovery_component.anchor.txid=$anchor |
    .action_freshness.recovery_component.anchor.vout=1 |
    .action_freshness.recovery_component.generation_fingerprint=$family |
    .action_freshness.recovery_component.claim_txids=[$root] |
    .action_freshness.recovery_component.root_claim_txids=[$root] |
    .action_freshness.recovery_component.descendant_claims=0 |
    .action_freshness.recovery_component.nodes=[$node] |
    .action_freshness.recovery_component_claims=[$node] |
    .action_freshness.recovery_component_claim_txids=[$root] |
    .action_freshness.recovery_component_root_claim_txids=[$root] |
    .action_freshness.recovery_node=$node |
    .action_freshness.raw_mempool={($root):$entry} |
    .action_freshness.live_members=[{recovery_node:$node,mempool_entry:$entry,
      mempool_entry_time:$entry.time}])' <<<"$live_a")
first_unseen_live=$(jq -cn --argjson live "$live_a" --argjson absent "$absent_a" \
  --argjson unseen "$unseen_live_b" \
  '[$live[0],$absent[1],$unseen[2],$absent[3]]')
first_unseen_live=$(collapse_series_to_first_cut "$first_unseen_live")
expect_fail 'first live member of an unseen family is selection churn, not progress' \
  v3015_pow_series_is_complete "$first_unseen_live"
live_a_replaced_by_b=$(make_samples wait_for_live 4 '' no_progress | jq \
  --arg root "$head_tx" --arg next "$relay_tx" '
  to_entries | map(.key as $i | .value as $sample | $sample |
    .action_freshness.recovery_component_claims[0] as $old_root |
    ($old_root | .txid=$root | .lineage_root_txid=$root |
      .lineage_parent_txid=("0"*64) | .lineage_ordinal=0 |
      .in_mempool=($i < 2) | .quarantined=($i >= 2) |
      .disposition=(if $i < 2 then "eligible" else "origin_expired" end)) as $root_node |
    ($root_node | .txid=$next | .lineage_root_txid=$root |
      .lineage_parent_txid=$root | .lineage_ordinal=1 |
      .in_mempool=($i >= 2) | .quarantined=($i < 2) |
      .disposition=(if $i >= 2 then "eligible" else "origin_expired" end)) as $desc |
    ([$root_node,$desc]) as $claims |
    ([$root,$next] | sort) as $claim_txids |
    (if $i < 2 then $root_node else $desc end) as $selected |
    (($sample.sample_finished_unix_ms/1000|floor)-10) as $entry_time |
    {time:$entry_time} as $entry |
    .pow.mining_gate_lineage_head_txid=$next |
    .pow.mining_gate_family_claims=2 | .pow.unresolved_claims=2 |
    .pow.mining_gate_live_claims=1 | .pow.live_claims=1 |
    .pow.mining_gate_eligible_claims=1 |
    .action_freshness.lineage_head_txid=$next |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component_claim_txids=$claim_txids |
    .action_freshness.recovery_component_root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_component.claim_txids=$claim_txids |
    .action_freshness.recovery_component.root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.classification="live" |
    .action_freshness.recovery_component.all_claims_quarantined=false |
    .action_freshness.recovery_node=$selected |
    .action_freshness.raw_mempool={($selected.txid):$entry} |
    .action_freshness.live_members=[{recovery_node:$selected,
      mempool_entry:$entry,mempool_entry_time:$entry_time}] |
    .action_freshness.mempool_entry_present=true |
    .action_freshness.mempool_entry=$entry |
    .action_freshness.mempool_entry_time=$entry_time)')
expect_pass 'previously authenticated absent B becoming live replaces A as real progress' \
  v3015_pow_series_is_live "$live_a_replaced_by_b"
live_a_then_b=$(make_samples wait_for_live 4 '' no_progress | jq \
  --arg root "$head_tx" --arg next "$relay_tx" '
  .[2:] |= map(. as $sample |
    .action_freshness.recovery_component_claims[0] as $root_node |
    ($root_node | .txid=$next | .lineage_root_txid=$root |
      .lineage_parent_txid=$root | .lineage_ordinal=1) as $desc |
    ([$root_node,$desc]) as $claims |
    ([$root,$next] | sort) as $claim_txids |
    (($sample.sample_finished_unix_ms/1000|floor)-10) as $entry_time |
    (reduce $claims[] as $node ({}; .[$node.txid]={time:$entry_time})) as $raw_mempool |
    .pow.mining_gate_lineage_head_txid=$next |
    .pow.mining_gate_family_claims=2 |
    .pow.unresolved_claims=2 |
    .pow.mining_gate_live_claims=2 | .pow.live_claims=2 |
    .pow.mining_gate_eligible_claims=2 |
    .action_freshness.lineage_head_txid=$next |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component_claim_txids=$claim_txids |
    .action_freshness.recovery_component_root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_component.claim_txids=$claim_txids |
    .action_freshness.recovery_component.root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.all_claims_quarantined=false |
    .action_freshness.recovery_node=$desc |
    .action_freshness.raw_mempool=$raw_mempool |
    .action_freshness.live_members=($claims |
      map({recovery_node:.,mempool_entry:$raw_mempool[.txid],
        mempool_entry_time:$entry_time}) |
      sort_by(.recovery_node.txid)) |
    .action_freshness.mempool_entry_present=true |
    .action_freshness.mempool_entry=$raw_mempool[$next] |
    .action_freshness.mempool_entry_time=$entry_time)')
expect_fail 'two simultaneously live members in one selected family are unsafe' \
  v3015_pow_series_is_live "$live_a_then_b"
multi_live=$(make_samples wait_for_live | jq --arg root "$head_tx" '
  .[3] |= (. as $sample |
    (.action_freshness.recovery_component_claims |
      .[0].in_mempool=true | .[0].quarantined=false |
      .[0].disposition="eligible") as $claims |
    (($sample.sample_finished_unix_ms/1000|floor)-10) as $entry_time |
    (reduce ($claims[] | select(.in_mempool == true)) as $node
      ({}; .[$node.txid]={time:$entry_time})) as $raw_mempool |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_component.all_claims_quarantined=false |
    .action_freshness.raw_mempool=$raw_mempool |
    .action_freshness.live_members=($claims |
      map(select(.in_mempool == true) |
        {recovery_node:.,mempool_entry:$raw_mempool[.txid],
         mempool_entry_time:$entry_time}) |
      sort_by(.recovery_node.txid)) |
    .pow.mining_gate_live_claims=2 | .pow.live_claims=2 |
    .pow.mining_gate_eligible_claims=2)')
expect_fail 'wait-for-live rejects multiple live members in one selected family' \
  v3015_pow_series_is_live "$multi_live"
single_live=$(make_samples wait_for_live)
expect_fail 'wait-for-live rejects a live member outside the authenticated family' \
  v3015_pow_series_is_live "$(jq '.[3].action_freshness.live_members[0].recovery_node.lineage_family_fingerprint=("f"*64)' <<<"$single_live")"
wrong_live_root=$(jq '.[3].action_freshness.live_members[0].recovery_node.lineage_root_txid=
  ("1"*64)' <<<"$single_live")
expect_fail 'wait-for-live rejects a member root contradicting the canonical component' \
  v3015_pow_series_is_live "$wrong_live_root"
expect_fail 'wait-for-live rejects a live txid omitted from exact component membership' \
  v3015_pow_series_is_live "$(jq --arg root "$head_tx" '
    .[3].action_freshness.recovery_component_claim_txids -= [$root]' <<<"$single_live")"
expect_fail 'wait-for-live rejects a duplicate authenticated live member' \
  v3015_pow_series_is_live "$(jq '
    .[3].action_freshness.live_members += [.[3].action_freshness.live_members[0]] |
    .[3].pow.mining_gate_live_claims=2 | .[3].pow.live_claims=2' <<<"$single_live")"
live_entry_mismatch=$(jq '
  .[3].action_freshness.live_members[0].mempool_entry.time += 1 |
  .[3].action_freshness.live_members[0].mempool_entry_time += 1' <<<"$single_live")
expect_fail 'wait-for-live rejects a member entry contradicting raw mempool bytes' \
  v3015_pow_series_is_live "$live_entry_mismatch"
raw_live_omission=$(jq '
  .[3].action_freshness.recovery_node.txid as $txid |
  del(.[3].action_freshness.raw_mempool[$txid])' <<<"$single_live")
expect_fail 'wait-for-live rejects a live component member omitted from raw mempool' \
  v3015_pow_series_is_live "$raw_live_omission"
raw_absent_inclusion=$(make_samples wait_for_next_tip | jq --arg txid "$head_tx" '
  .[2].action_freshness.raw_mempool[$txid]={time:1700000002}')
expect_fail 'absent component member cannot contradict raw mempool membership' \
  v3015_pow_series_is_live "$raw_absent_inclusion"
older_head=$(printf 'd%.0s' {1..64})
older_member=$relay_tx
older_relay=$(make_samples relay_existing 6 '' no_progress | jq --arg head "$older_head" \
  --arg member "$older_member" '
  .[] |= (.action_freshness.recovery_component_claims[0] as $root |
    ($root | .txid=$head | .lineage_root_txid=$member |
      .lineage_parent_txid=$member | .lineage_ordinal=1 |
      .in_mempool=false | .quarantined=true |
      .disposition="origin_expired" | .relay_expiry_time=0) as $desc |
    ([$root,$desc]) as $claims |
    ([$member,$head] | sort) as $claim_txids |
    .pow.mining_gate_lineage_head_txid=$head |
    .pow.mining_gate_family_claims=2 |
    .pow.unresolved_claims=2 |
    .action_freshness.lineage_head_txid=$head |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component_claim_txids=$claim_txids |
    .action_freshness.recovery_component_root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_component.claim_txids=$claim_txids |
    .action_freshness.recovery_component.root_claim_txids=$claim_txids)')
older_live=$(make_samples wait_for_live 6 '' no_progress | jq \
  --arg head "$older_head" --arg member "$older_member" '
  .[] |= (.action_freshness.recovery_component_claims[0] as $old_root |
    ($old_root | .txid=$member | .lineage_root_txid=$member) as $root |
    ($root | .txid=$head | .lineage_parent_txid=$member |
      .lineage_ordinal=1 | .in_mempool=false | .quarantined=true |
      .disposition="origin_expired") as $desc |
    ([$root,$desc]) as $claims |
    ([$member,$head] | sort) as $claim_txids |
    .pow.mining_gate_lineage_head_txid=$head |
    .pow.mining_gate_family_claims=2 |
    .pow.unresolved_claims=2 |
    .action_freshness.lineage_head_txid=$head |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component_claim_txids=$claim_txids |
    .action_freshness.recovery_component_root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_component.claim_txids=$claim_txids |
    .action_freshness.recovery_component.root_claim_txids=$claim_txids |
    .action_freshness.recovery_component.all_claims_quarantined=false |
    .action_freshness.recovery_node=$root |
    .action_freshness.raw_mempool={($member):.action_freshness.mempool_entry} |
    .action_freshness.live_members=[{recovery_node:$root,
      mempool_entry:.action_freshness.mempool_entry,
      mempool_entry_time:.action_freshness.mempool_entry_time}])')
older_member_live=$(jq -cn --argjson relay "$older_relay" --argjson live "$older_live" \
  '[$relay[0],$relay[1],$live[2],$live[3]]')
expect_pass 'older eligible family member may become live while newest head stays absent' \
  v3015_pow_series_is_live "$older_member_live"
older_member_replay=$(jq -cn --argjson relay "$older_relay" --argjson live "$older_live" \
  '[$relay[0],$relay[1],$live[2],$live[3],$live[4],$live[5]]')
older_member_replay=$(collapse_series_to_first_cut "$older_member_replay" | jq '
  .[2].sample_finished_unix_ms as $base | .[-1] |= (
    .sample_started_unix_ms=($base + 600001) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100) |
    .action_freshness.observed_unix_ms=.sample_finished_unix_ms)')
expect_fail 'replayed already-seen live family member cannot reset a ten-minute budget' \
  v3015_pow_series_is_live "$older_member_replay"
relay_wait=$(make_samples relay_existing | jq '
  .[] |= (.pow.mining_gate_action="wait_for_next_tip" |
    .action_freshness.action="wait_for_next_tip")')
expect_pass 'wait-for-next-tip binds a current deterministic relay candidate' \
  v3015_pow_series_is_live "$relay_wait"
suppressed_zero_relay=$(make_samples wait_for_next_tip | jq '
  .[2] |= (. as $sample |
    (.action_freshness.recovery_component_claims |
      .[-1].disposition="eligible" |
      .[-1].relay_ttl_expired=false |
      .[-1].relay_expiry_time=(($sample.sample_finished_unix_ms/1000|floor)+3600)) as $claims |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_node=$claims[-1] |
    .pow.mining_gate_eligible_claims=1)')
expect_pass 'zero-relay wait accepts a wallet-facing suppressed relay candidate' \
  v3015_pow_series_is_live "$suppressed_zero_relay"
latest_relay_family=$(jq -c --arg head "$older_head" '
  .[] |= (. as $sample |
    (.action_freshness.recovery_component_claims |
      .[1].disposition="eligible" |
      .[1].relay_expiry_time=(($sample.sample_finished_unix_ms/1000|floor)+3600)) as $claims |
    .pow.mining_gate_action="wait_for_next_tip" |
    .pow.mining_gate_relay_txid=$head |
    .pow.mining_gate_eligible_claims=2 |
    .action_freshness.action="wait_for_next_tip" |
    .action_freshness.relay_txid=$head |
    .action_freshness.recovery_component_claims=$claims |
    .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
    .action_freshness.recovery_node=$claims[1])' <<<"$older_relay")
latest_relay_wait=$(jq -cn --argjson first "$relay_wait" \
  --argjson extended "$latest_relay_family" \
  '[$first[0],$first[1],$extended[2],$extended[3]]')
expect_pass 'wait-for-next-tip binds an exact eligible absent member selected by Core' \
  v3015_pow_series_is_live "$latest_relay_wait"
older_relay_target=$(jq --arg older "$older_member" '
  .[] |= (.pow.mining_gate_relay_txid=$older |
    .action_freshness.relay_txid=$older |
    .action_freshness.recovery_node=.action_freshness.recovery_component_claims[0])' \
  <<<"$latest_relay_wait")
expect_pass 'wait-for-next-tip accepts an older eligible member after per-tx suppression' \
  v3015_pow_series_is_live "$older_relay_target"
wrong_relay_target=$(jq '.[2].pow.mining_gate_relay_txid=("6"*64) |
  .[2].action_freshness.relay_txid=("6"*64)' <<<"$latest_relay_wait")
expect_fail 'wait-for-next-tip rejects a relay txid outside the exact component' \
  v3015_pow_series_is_live "$wrong_relay_target"
noneligible_relay=$(jq '
  .[2].action_freshness.recovery_component_claims[1].disposition="origin_expired" |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("d"*64)
    then .disposition="origin_expired" else . end) |
  .[2].action_freshness.recovery_node.disposition="origin_expired" |
  .[2].pow.mining_gate_eligible_claims=1' <<<"$latest_relay_wait")
expect_fail 'wait-for-next-tip rejects a noneligible selected relay target' \
  v3015_pow_series_is_live "$noneligible_relay"
expired_relay=$(jq '
  .[2].action_freshness.recovery_component_claims[1].relay_ttl_expired=true |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("d"*64)
    then .relay_ttl_expired=true else . end) |
  .[2].action_freshness.recovery_node.relay_ttl_expired=true' <<<"$latest_relay_wait")
expect_fail 'wait-for-next-tip rejects an expired selected relay target' \
  v3015_pow_series_is_live "$expired_relay"
live_relay=$(jq '
  .[2].action_freshness.recovery_component_claims[1].in_mempool=true |
  .[2].action_freshness.recovery_component_claims[1].quarantined=false |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("d"*64)
    then .in_mempool=true | .quarantined=false else . end) |
  .[2].action_freshness.recovery_node.in_mempool=true |
  .[2].action_freshness.recovery_node.quarantined=false |
  .[2].action_freshness.raw_mempool[("d"*64)]={time:1700000002} |
  .[2].pow.mining_gate_live_claims=1 | .[2].pow.live_claims=1' <<<"$latest_relay_wait")
expect_fail 'wait-for-next-tip rejects a relay target already in raw mempool' \
  v3015_pow_series_is_live "$live_relay"
latest_relay_existing=$(jq '.[] |= (
  .pow.mining_gate_action="relay_existing" |
  .pow.mining_gate_can_submit=false |
  .action_freshness.action="relay_existing")' <<<"$latest_relay_wait")
expect_pass 'relay-existing binds an exact eligible absent member selected by Core' \
  v3015_pow_series_is_live "$latest_relay_existing"
older_relay_existing=$(jq '.[] |= (
  .pow.mining_gate_action="relay_existing" |
  .pow.mining_gate_can_submit=false |
  .action_freshness.action="relay_existing")' <<<"$older_relay_target")
expect_pass 'relay-existing accepts an older eligible member after per-tx suppression' \
  v3015_pow_series_is_live "$older_relay_existing"
for relay_hostile_name in wrong_relay_target noneligible_relay \
    expired_relay live_relay; do
    relay_hostile=${!relay_hostile_name}
    relay_hostile=$(jq '.[] |= (
      .pow.mining_gate_action="relay_existing" |
      .pow.mining_gate_can_submit=false |
      .action_freshness.action="relay_existing")' <<<"$relay_hostile")
    expect_fail "relay-existing rejects $relay_hostile_name authority" \
      v3015_pow_series_is_live "$relay_hostile"
done

aggregate_only_wait_live=$(make_samples wait_for_next_tip 4 '' no_progress | jq '
  .[] |= (.pow.mining_gate_action="wait_for_live" |
    .pow.mining_gate_can_submit=false |
    .pow.mining_gate_unresolved_components=2 |
    .pow.mining_gate_family_claims+=1 |
    .pow.mining_gate_live_claims=1 | .pow.live_claims=1 |
    .pow.claim_components=2 |
    .action_freshness.action="wait_for_live")')
expect_fail 'wait-for-live requires a live member in the selected component, not another family' \
  v3015_pow_series_is_live "$aggregate_only_wait_live"
relay_wait_selected_live=$(mark_selected_component_live "$latest_relay_wait")
expect_fail 'relay-bearing next-tip wait rejects a live member in the selected component' \
  v3015_pow_series_is_live "$relay_wait_selected_live"
relay_existing_selected_live=$(mark_selected_component_live "$latest_relay_existing")
expect_fail 'relay-existing rejects a live member in the selected component' \
  v3015_pow_series_is_live "$relay_existing_selected_live"
refresh_selected_live=$(mark_selected_component_live \
  "$(make_samples refresh_same_anchor 4 '' no_progress)")
expect_fail 'refresh-same-anchor rejects a live member in the selected component' \
  v3015_pow_series_is_live "$refresh_selected_live"

for aggregate_action in relay_existing refresh_same_anchor; do
    aggregate_series=$(make_samples "$aggregate_action" | jq '.[] |= (
      .pow.mining_gate_unresolved_components=2 |
      .pow.mining_gate_family_claims+=1 |
      .pow.mining_gate_live_claims=1 |
      .pow.live_claims=1 |
      .pow.claim_components=2)')
    expect_pass "$aggregate_action selected component may coexist with a live family" \
      v3015_pow_series_is_live "$aggregate_series"
done
aggregate_multi_live=$(make_samples wait_for_live | jq '.[] |= (
  .pow.mining_gate_unresolved_components=2 |
  .pow.mining_gate_family_claims+=1 |
  .pow.mining_gate_live_claims=2 | .pow.live_claims=2 |
  .pow.claim_components=2)')
expect_pass 'aggregate live count may exceed one across independent safe families' \
  v3015_pow_series_is_live "$aggregate_multi_live"

graph_descendants=$(make_graph_descendant_samples)
expect_fail 'selected operational family rejects four claims with graph descendants' \
  v3015_pow_series_is_live "$graph_descendants"
legacy_graph_descendants=$(jq '
  .[] |= (
    .action_freshness.recovery_component_claims[0] as $old |
    ($old | .proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
      .proof_may_revalidate_on_descendant=true |
      .disposition="unbound_proof_may_revalidate" |
      .lineage_metadata_present=false | .lineage_metadata_valid=false |
      .lineage_family_fingerprint=("0"*64) | .lineage_root_txid=("0"*64) |
      .lineage_parent_txid=("0"*64)) as $root |
    .action_freshness.recovery_component_claims[0]=$root |
    .action_freshness.recovery_component.nodes |=
      map(if .txid == $root.txid then $root else . end) |
    .action_freshness.recovery_component.has_revalidating_unbound_proof=true)' \
  <<<"$graph_descendants")
expect_fail 'selected operational family rejects an implicit-root graph with descendants' \
  v3015_pow_series_is_live "$legacy_graph_descendants"
unknown_graph_root=$(jq '
  .[2] |= (
    .action_freshness.recovery_component.root_claim_txids += [("5"*64)] |
    .action_freshness.recovery_component.root_claim_txids |= sort |
    .action_freshness.recovery_component.descendant_claims=1 |
    .action_freshness.recovery_component_root_claim_txids=
      .action_freshness.recovery_component.root_claim_txids)' <<<"$graph_descendants")
expect_fail 'selected family rejects a graph root outside exact claim membership' \
  v3015_pow_series_is_live "$unknown_graph_root"
duplicate_graph_root=$(jq '
  .[2] |= (
    .action_freshness.recovery_component.root_claim_txids +=
      [ .action_freshness.recovery_component.root_claim_txids[0] ] |
    .action_freshness.recovery_component_root_claim_txids=
      .action_freshness.recovery_component.root_claim_txids)' <<<"$graph_descendants")
expect_fail 'selected family rejects a duplicate transaction-graph root' \
  v3015_pow_series_is_live "$duplicate_graph_root"
wrong_graph_count=$(jq '.[2].action_freshness.recovery_component.descendant_claims=1' \
  <<<"$graph_descendants")
expect_fail 'selected family binds graph descendant count to roots and members' \
  v3015_pow_series_is_live "$wrong_graph_count"
duplicate_graph_member=$(jq '
  .[2] |= (
    .action_freshness.recovery_component_claims +=
      [ .action_freshness.recovery_component_claims[1] ] |
    .action_freshness.recovery_component.nodes +=
      [ .action_freshness.recovery_component.nodes[1] ])' <<<"$graph_descendants")
expect_fail 'selected family rejects a duplicate component member' \
  v3015_pow_series_is_live "$duplicate_graph_member"
missing_graph_member=$(jq '
  .[2] |= (
    .action_freshness.recovery_component.nodes |= map(select(.txid != ("2"*64))))' \
  <<<"$graph_descendants")
expect_fail 'selected family rejects a member omitted from exact component nodes' \
  v3015_pow_series_is_live "$missing_graph_member"
wrong_lineage_root=$(jq '
  .[2] |= (
    .action_freshness.recovery_component_claims[2].lineage_root_txid=("3"*64) |
    .action_freshness.recovery_component.nodes |= map(if .txid == ("3"*64)
      then .lineage_root_txid=("3"*64) else . end))' <<<"$graph_descendants")
expect_fail 'selected family separates graph roots from one canonical lineage root' \
  v3015_pow_series_is_live "$wrong_lineage_root"
broken_graph_lineage=$(jq '
  .[2] |= (
    .action_freshness.recovery_component_claims[2].lineage_parent_txid=("6"*64) |
    .action_freshness.recovery_component.nodes |= map(if .txid == ("3"*64)
      then .lineage_parent_txid=("6"*64) else . end))' <<<"$graph_descendants")
expect_fail 'selected family rejects a broken lineage parent across graph branches' \
  v3015_pow_series_is_live "$broken_graph_lineage"

implicit_v3=$(make_samples wait_for_next_tip | jq --arg zero "$zero" '
  def replace_claim($index;$node):
    .action_freshness.recovery_component_claims[$index]=$node |
    .action_freshness.recovery_component.nodes=
      (.action_freshness.recovery_component_claims | sort_by(.txid)) |
    if .action_freshness.recovery_node.txid == $node.txid
    then .action_freshness.recovery_node=$node else . end;
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .lineage_metadata_present=false | .lineage_metadata_valid=false |
      .lineage_family_fingerprint=$zero | .lineage_root_txid=$zero |
      .lineage_parent_txid=$zero | .lineage_ordinal=0 |
      .proof_version=3 | .proof_origin_bound=true | .proof_input_bound=false) as $root |
    replace_claim(0;$root))')
expect_pass 'one implicit QQP3 root plus exact lineaged descendants is authenticated' \
  v3015_pow_series_is_live "$implicit_v3"
implicit_v4=$(jq '
  def replace_claim($index;$node):
    .action_freshness.recovery_component_claims[$index]=$node |
    .action_freshness.recovery_component.nodes=
      (.action_freshness.recovery_component_claims | sort_by(.txid)) |
    if .action_freshness.recovery_node.txid == $node.txid
    then .action_freshness.recovery_node=$node else . end;
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .proof_version=4 | .proof_input_bound=true) as $root |
    replace_claim(0;$root))' <<<"$implicit_v3")
expect_pass 'one authenticated implicit QQP4 input-bound root may establish lineage' \
  v3015_pow_series_is_live "$implicit_v4"
implicit_v4_unbound=$(jq '
  .[2].action_freshness.recovery_component_claims[0].proof_input_bound=false |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("a"*64)
    then .proof_input_bound=false else . end)' <<<"$implicit_v4")
expect_fail 'implicit QQP4 root requires exact input binding' \
  v3015_pow_series_is_live "$implicit_v4_unbound"
implicit_v2=$(jq '
  def replace_claim($index;$node):
    .action_freshness.recovery_component_claims[$index]=$node |
    .action_freshness.recovery_component.nodes=
      (.action_freshness.recovery_component_claims | sort_by(.txid)) |
    if .action_freshness.recovery_node.txid == $node.txid
    then .action_freshness.recovery_node=$node else . end;
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .proof_version=2 | .proof_origin_bound=false |
      .proof_input_bound=false | .disposition="unbound_proof_may_revalidate" |
      .proof_may_revalidate_on_descendant=true) as $root |
    replace_claim(0;$root) |
    .action_freshness.recovery_component.has_revalidating_unbound_proof=true)' \
  <<<"$implicit_v3")
expect_pass 'one authenticated implicit QQP2 root may establish exact lineage' \
  v3015_pow_series_is_live "$implicit_v2"
implicit_v2_eligible=$(jq '
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .disposition="eligible" |
      .proof_may_revalidate_on_descendant=false) as $root |
    .action_freshness.recovery_component_claims[0]=$root |
    .action_freshness.recovery_component.nodes |=
      map(if .txid == $root.txid then $root else . end) |
    if .action_freshness.recovery_node.txid == $root.txid
    then .action_freshness.recovery_node=$root else . end |
    .action_freshness.recovery_component.has_revalidating_unbound_proof=false |
    .pow.mining_gate_eligible_claims=1)' \
  <<<"$implicit_v2")
expect_pass 'implicit QQP2 singleton accepts active-branch-bound eligible disposition' \
  v3015_pow_series_is_live "$implicit_v2_eligible"
implicit_v2_unsupported=$(jq '
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .disposition="unsupported_version" |
      .proof_may_revalidate_on_descendant=false) as $root |
    .action_freshness.recovery_component_claims[0]=$root |
    .action_freshness.recovery_component.nodes |=
      map(if .txid == $root.txid then $root else . end) |
    if .action_freshness.recovery_node.txid == $root.txid
    then .action_freshness.recovery_node=$root else . end |
    .action_freshness.recovery_component.has_revalidating_unbound_proof=false)' \
  <<<"$implicit_v2")
expect_fail 'mainnet implicit QQP2 rejects inapplicable unsupported-version disposition' \
  v3015_pow_series_is_live "$implicit_v2_unsupported"
implicit_v3_unsupported=$(jq '
  .[] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .disposition="unsupported_version" |
      .proof_may_revalidate_on_descendant=false) as $root |
    .action_freshness.recovery_component_claims[0]=$root |
    .action_freshness.recovery_component.nodes |=
      map(if .txid == $root.txid then $root else . end) |
    if .action_freshness.recovery_node.txid == $root.txid
    then .action_freshness.recovery_node=$root else . end)' \
  <<<"$implicit_v3")
expect_fail 'mainnet implicit QQP3 rejects inapplicable unsupported-version disposition' \
  v3015_pow_series_is_live "$implicit_v3_unsupported"
qqp4_activation_height=$(jq '.[0].height + 1' <<<"$implicit_v2_unsupported")
implicit_v2_unsupported_active=$(jq --argjson activation "$qqp4_activation_height" '
  .[] |= (.qqp4_activation.qqp4_activation_disabled=false |
    .qqp4_activation.qqp4_activation_height=$activation |
    .qqp4_activation.qqp4_active=(.height >= $activation) |
    .qqp4_activation.qqp4_active_next_block=((.height + 1) >= $activation))' \
  <<<"$implicit_v2_unsupported")
expect_pass 'implicit QQP2 accepts unsupported-version only across an authenticated QQP4 boundary' \
  v3015_pow_series_is_live "$implicit_v2_unsupported_active"
implicit_v3_unsupported_active=$(jq --argjson activation "$qqp4_activation_height" '
  .[] |= (.qqp4_activation.qqp4_activation_disabled=false |
    .qqp4_activation.qqp4_activation_height=$activation |
    .qqp4_activation.qqp4_active=(.height >= $activation) |
    .qqp4_activation.qqp4_active_next_block=((.height + 1) >= $activation))' \
  <<<"$implicit_v3_unsupported")
expect_pass 'implicit QQP3 accepts unsupported-version only across an authenticated QQP4 boundary' \
  v3015_pow_series_is_live "$implicit_v3_unsupported_active"
qqp4_bad=$(jq '.[0].qqp4_activation.qqp4_active_next_block=false' \
  <<<"$implicit_v2_unsupported_active")
expect_fail 'QQP4 receipt binds next-block activation at the exact boundary' \
  v3015_pow_series_is_live "$qqp4_bad"
qqp4_bad=$(jq '.[1].qqp4_activation.bestblock=("f"*64)' \
  <<<"$implicit_v2_unsupported_active")
expect_fail 'QQP4 receipt binds the exact active tip' \
  v3015_pow_series_is_live "$qqp4_bad"
qqp4_bad=$(jq '.[1].qqp4_activation.height += 1' \
  <<<"$implicit_v2_unsupported_active")
expect_fail 'QQP4 receipt binds the exact active height' \
  v3015_pow_series_is_live "$qqp4_bad"
qqp4_bad=$(jq '.[].qqp4_activation.qqp4_activation_disabled=true |
  .[].qqp4_activation.qqp4_activation_height=0 |
  .[].qqp4_activation.qqp4_active=false |
  .[].qqp4_activation.qqp4_active_next_block=true' \
  <<<"$implicit_v2_unsupported_active")
expect_fail 'disabled QQP4 schedule cannot claim next-block activation' \
  v3015_pow_series_is_live "$qqp4_bad"
qqp4_bad=$(jq '.[2:] |= map(
  .qqp4_activation.qqp4_activation_height += 1 |
  .qqp4_activation.qqp4_active=
    (.height >= .qqp4_activation.qqp4_activation_height) |
  .qqp4_activation.qqp4_active_next_block=
    ((.height + 1) >= .qqp4_activation.qqp4_activation_height))' \
  <<<"$implicit_v2_unsupported_active")
expect_fail 'QQP4 activation schedule cannot drift between samples' \
  v3015_pow_series_is_live "$qqp4_bad"
implicit_v2_unbound_tip=$(jq '
  .[1] |= (.action_freshness.recovery_component_claims[0] as $old |
    ($old | .authored_tip_active_branch_bound=false) as $root |
    .action_freshness.recovery_component_claims[0]=$root |
    .action_freshness.recovery_component.nodes |=
      map(if .txid == $root.txid then $root else . end) |
    .action_freshness.recovery_node=$root)' <<<"$implicit_v2")
expect_fail 'implicit QQP2 singleton requires authored active-branch tip binding' \
  v3015_pow_series_is_live "$implicit_v2_unbound_tip"
multiple_implicit=$(jq --arg zero "$zero" '
  .[2].action_freshness.recovery_component_claims[1] |=
    (.lineage_metadata_present=false | .lineage_metadata_valid=false |
     .lineage_family_fingerprint=$zero | .lineage_root_txid=$zero |
     .lineage_parent_txid=$zero | .lineage_ordinal=0) |
  .[2].action_freshness.recovery_node=
    .[2].action_freshness.recovery_component_claims[1] |
  .[2].action_freshness.recovery_component.nodes=
    (.[2].action_freshness.recovery_component_claims | sort_by(.txid))' <<<"$implicit_v3")
expect_fail 'component cannot contain two implicit lineage roots' \
  v3015_pow_series_is_live "$multiple_implicit"
nondefault_implicit=$(jq '.[2].action_freshness.recovery_component_claims[0].lineage_root_txid=
  ("f"*64) | .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("a"*64) then .lineage_root_txid=("f"*64) else . end)' <<<"$implicit_v3")
expect_fail 'implicit root rejects nondefault absent-metadata lineage fields' \
  v3015_pow_series_is_live "$nondefault_implicit"
unbound_implicit=$(jq '.[2].action_freshness.recovery_component_claims[0].proof_origin_bound=false |
  .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("a"*64) then .proof_origin_bound=false else . end)' <<<"$implicit_v3")
expect_fail 'implicit QQP3 root requires the exact former-origin binding' \
  v3015_pow_series_is_live "$unbound_implicit"
bad_ordinal=$(jq '.[2].action_freshness.recovery_component_claims[1].lineage_ordinal=2 |
  .[2].action_freshness.recovery_node.lineage_ordinal=2 |
  .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("d"*64) then .lineage_ordinal=2 else . end)' <<<"$implicit_v3")
expect_fail 'implicit-root lineage rejects a noncontiguous ordinal' \
  v3015_pow_series_is_live "$bad_ordinal"
bad_parent=$(jq '.[2].action_freshness.recovery_component_claims[1].lineage_parent_txid=("f"*64) |
  .[2].action_freshness.recovery_node.lineage_parent_txid=("f"*64) |
  .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("d"*64) then .lineage_parent_txid=("f"*64) else . end)' \
  <<<"$implicit_v3")
expect_fail 'implicit-root lineage rejects a broken parent chain' \
  v3015_pow_series_is_live "$bad_parent"
mixed_family=$(jq '.[2].action_freshness.recovery_component_claims[1].lineage_family_fingerprint=
  ("f"*64) | .[2].action_freshness.recovery_node.lineage_family_fingerprint=("f"*64) |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("d"*64)
    then .lineage_family_fingerprint=("f"*64) else . end)' <<<"$implicit_v3")
expect_fail 'implicit-root lineage rejects a mixed generation family' \
  v3015_pow_series_is_live "$mixed_family"
adopted_root=$(jq '.[2].action_freshness.recovery_component_claims[0].provenance="explicit_adopted" |
  .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("a"*64) then .provenance="explicit_adopted" else . end)' <<<"$implicit_v3")
expect_fail 'mining gate lineage rejects an adopted rather than authored root' \
  v3015_pow_series_is_live "$adopted_root"
legacy_provenance_root=$(jq '
  .[2].action_freshness.recovery_component_claims[0].provenance="legacy_wallet_authored" |
  .[2].action_freshness.recovery_component.nodes |=
  map(if .txid == ("a"*64) then .provenance="legacy_wallet_authored" else . end)' \
  <<<"$implicit_v3")
expect_fail 'selected implicit root still requires exact explicit-authored provenance' \
  v3015_pow_series_is_live "$legacy_provenance_root"
unknown_version=$(jq '
  .[2].action_freshness.recovery_component_claims[0].proof_version=5 |
  .[2].action_freshness.recovery_component.nodes |=
    map(if .txid == ("a"*64) then .proof_version=5 else . end)' \
  <<<"$(make_samples wait_for_next_tip)")
expect_fail 'exact authored carrier rejects an unsupported proof-version tuple' \
  v3015_pow_series_is_live "$unknown_version"
explicit_v4_unbound=$(jq '
  .[2].action_freshness.recovery_component_claims[1].proof_input_bound=false |
  .[2].action_freshness.recovery_node.proof_input_bound=false |
  .[2].action_freshness.recovery_component.nodes |=
    map(if .txid == ("d"*64) then .proof_input_bound=false else . end)' <<<"$implicit_v4")
expect_fail 'explicit QQP4 descendant rejects forged input-bound carrier shape' \
  v3015_pow_series_is_live "$explicit_v4_unbound"
explicit_v3_input=$(jq '
  .[2].action_freshness.recovery_component_claims[1] |=
    (.proof_version=3 | .proof_origin_bound=true | .proof_input_bound=true) |
  .[2].action_freshness.recovery_node=
    .[2].action_freshness.recovery_component_claims[1] |
  .[2].action_freshness.recovery_component.nodes |=
    map(if .txid == ("d"*64) then
      .proof_version=3 | .proof_origin_bound=true | .proof_input_bound=true
    else . end)' <<<"$implicit_v4")
expect_fail 'explicit QQP3 descendant rejects an input-bound contradiction' \
  v3015_pow_series_is_live "$explicit_v3_input"
skipped_unspent=$(jq '
  .[2].action_freshness.recovery_component_claims[1].proof_evaluation_skipped_resolved_anchor=true |
  .[2].action_freshness.recovery_node.proof_evaluation_skipped_resolved_anchor=true |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("d"*64)
    then .proof_evaluation_skipped_resolved_anchor=true else . end)' <<<"$implicit_v4")
expect_fail 'unspent authenticated anchor cannot skip proof evaluation as resolved' \
  v3015_pow_series_is_live "$skipped_unspent"
false_revalidation=$(jq '
  .[0].action_freshness.recovery_component_claims[0] |=
    (.proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
     .disposition="unbound_proof_may_revalidate" |
     .proof_may_revalidate_on_descendant=false) |
  .[0].action_freshness.recovery_node=
    .[0].action_freshness.recovery_component_claims[0] |
  .[0].action_freshness.recovery_component.nodes=
    .[0].action_freshness.recovery_component_claims' <<<"$implicit_v4")
expect_fail 'unbound revalidation disposition requires its exact proof flag' \
  v3015_pow_series_is_live "$false_revalidation"
forged_revalidation=$(jq '
  .[2].action_freshness.recovery_component_claims[0].proof_may_revalidate_on_descendant=true |
  .[2].action_freshness.recovery_component.nodes |= map(if .txid == ("a"*64)
    then .proof_may_revalidate_on_descendant=true else . end)' <<<"$implicit_v4")
expect_fail 'non-unbound claim cannot forge the descendant-revalidation flag' \
  v3015_pow_series_is_live "$forged_revalidation"
unsafe_v2_singleton=$(jq '
  .[0].action_freshness.recovery_component_claims[0] |=
    (.proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
     .disposition="origin_expired") |
  .[0].action_freshness.recovery_node=
    .[0].action_freshness.recovery_component_claims[0] |
  .[0].action_freshness.recovery_component.nodes=
    .[0].action_freshness.recovery_component_claims' <<<"$implicit_v3")
expect_fail 'implicit QQP2 singleton requires its exact branch-safe disposition' \
  v3015_pow_series_is_live "$unsafe_v2_singleton"
root_shape=$(jq '.[2].action_freshness.recovery_component.root_claim_txids=
  [.[2].action_freshness.recovery_component.claim_txids[0]] |
  .[2].action_freshness.recovery_component_root_claim_txids=
  .[2].action_freshness.recovery_component.root_claim_txids' <<<"$implicit_v3")
expect_fail 'graph-root removal requires the matching descendant-count evidence' \
  v3015_pow_series_is_live "$root_shape"
descendant_shape=$(jq '.[2].action_freshness.recovery_component.descendant_claims=1' \
  <<<"$implicit_v3")
expect_fail 'graph descendant count cannot change without graph-root evidence' \
  v3015_pow_series_is_live "$descendant_shape"
for impossible_classification in transient indeterminate resolution_pending \
    retired_on_active_branch resolved_on_active_chain; do
    impossible=$(jq --arg classification "$impossible_classification" \
      '.[2].action_freshness.recovery_component.classification=$classification' \
      <<<"$implicit_v3")
    expect_fail "safe gate rejects impossible $impossible_classification component state" \
      v3015_pow_series_is_live "$impossible"
done

continuity_base=$(make_samples wait_for_next_tip)
anchor_amount_drift=$(jq '.[2:] |= map(
  .action_freshness.recovery_component.anchor.amount=11)' <<<"$continuity_base")
expect_fail 'same-outpoint family rejects direct anchor amount drift' \
  v3015_pow_series_is_live "$anchor_amount_drift"
anchor_script_drift=$(jq '.[2:] |= map(
  .action_freshness.recovery_component.anchor.scriptPubKey="52")' <<<"$continuity_base")
expect_fail 'same-outpoint family rejects direct anchor script drift' \
  v3015_pow_series_is_live "$anchor_script_drift"

generation_churn=$(jq --arg generation "$(printf 'f%.0s' {1..64})" '
  .[2:] |= map(
    .action_freshness.recovery_component.generation_fingerprint=$generation |
    .action_freshness.recovery_component_claims |= map(
      .lineage_family_fingerprint=$generation) |
    .action_freshness.recovery_component.nodes |= map(
      .lineage_family_fingerprint=$generation) |
    .action_freshness.recovery_node.lineage_family_fingerprint=$generation)' \
  <<<"$continuity_base")
expect_fail 'same-anchor family rejects generation churn across fresh tips' \
  v3015_pow_series_is_live "$generation_churn"

root_substitution=$(jq --arg replacement "$(printf '3%.0s' {1..64})" '
  .[2:] |= map(. as $sample |
    .action_freshness.lineage_head_txid as $head |
    .action_freshness.recovery_component_claims as $old |
    (($old[0] | .txid=$replacement | .lineage_root_txid=$replacement) as $root |
     ([$root] + [$old[1:][] |
       .lineage_root_txid=$replacement |
       if .lineage_ordinal == 1 then .lineage_parent_txid=$replacement else . end]) as $claims |
     ([$claims[].txid] | sort) as $txids |
     .action_freshness.recovery_component_claims=$claims |
     .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
     .action_freshness.recovery_component.claim_txids=$txids |
     .action_freshness.recovery_component.root_claim_txids=$txids |
     .action_freshness.recovery_component_claim_txids=$txids |
     .action_freshness.recovery_component_root_claim_txids=$txids |
     .action_freshness.recovery_node=
       ([$claims[] | select(.txid == $head)] | first)))' <<<"$continuity_base")
expect_fail 'same-anchor family rejects canonical root substitution' \
  v3015_pow_series_is_live "$root_substitution"

middle_rewrite=$(jq --arg replacement "$(printf '6%.0s' {1..64})" '
  .[4] |= (.action_freshness.recovery_component_claims as $old |
    (($old[1] | .txid=$replacement) as $middle |
     ($old[2] | .lineage_parent_txid=$replacement) as $head |
     ([$old[0],$middle,$head]) as $claims |
     ([$claims[].txid] | sort) as $txids |
     .action_freshness.recovery_component_claims=$claims |
     .action_freshness.recovery_component.nodes=($claims | sort_by(.txid)) |
     .action_freshness.recovery_component.claim_txids=$txids |
     .action_freshness.recovery_component.root_claim_txids=$txids |
     .action_freshness.recovery_component_claim_txids=$txids |
     .action_freshness.recovery_component_root_claim_txids=$txids |
     .action_freshness.recovery_node=$head))' <<<"$continuity_base")
expect_fail 'append-only lineage rejects a rewritten middle ordinal' \
  v3015_pow_series_is_live "$middle_rewrite"

descriptor_rewrite=$(jq '.[3:] |= map(
  .action_freshness.recovery_component_claims[0].proof_origin_height=901 |
  .action_freshness.recovery_component.nodes |= map(if .txid == ("a"*64)
    then .proof_origin_height=901 else . end))' <<<"$continuity_base")
expect_fail 'unchanged lineage head rejects immutable descriptor mutation' \
  v3015_pow_series_is_live "$descriptor_rewrite"

head_regression=$(jq -c '.' <<<"$continuity_base")
head_regression_sample=$(rebind_sample_family \
  "$(jq -c '.[3]' <<<"$head_regression")" \
  "$(jq -c '.[0]' <<<"$head_regression")")
head_regression=$(jq -cn --argjson samples "$head_regression" \
  --argjson replacement "$head_regression_sample" '$samples | .[3]=$replacement')
expect_fail 'append-only lineage rejects a head regression' \
  v3015_pow_series_is_live "$head_regression"

interleaved=$(make_interleaved_samples)
same_tip_extension=$(collapse_series_to_first_cut \
  "$(jq -c '.[0:4]' <<<"$continuity_base")")
expect_pass 'same-tip same-family strict prefix/head extension is authenticated progress' \
  v3015_pow_series_is_live "$same_tip_extension"
unseen_families=$(collapse_series_to_first_cut "$(make_unseen_family_samples)")
expect_fail 'A-to-B-to-C-to-D unseen family selection churn is never progress' \
  v3015_pow_series_is_complete "$unseen_families"
same_tip_b=$(rebind_sample_cut \
  "$(jq -c '.[1]' <<<"$interleaved")" "$(jq -c '.[0]' <<<"$interleaved")")
same_tip_a_replay=$(rebind_sample_family \
  "$(jq -c '.[2]' <<<"$interleaved")" "$(jq -c '.[0]' <<<"$interleaved")")
same_tip_a_replay=$(rebind_sample_cut "$same_tip_a_replay" \
  "$(jq -c '.[0]' <<<"$interleaved")")
same_tip_b_replay=$(rebind_sample_family \
  "$(jq -c '.[3]' <<<"$interleaved")" "$(jq -c '.[1]' <<<"$interleaved")")
same_tip_b_replay=$(rebind_sample_cut "$same_tip_b_replay" \
  "$(jq -c '.[0]' <<<"$interleaved")")
same_tip_family_switches=$(jq -cn --argjson samples "$interleaved" \
  --argjson b "$same_tip_b" --argjson a_replay "$same_tip_a_replay" \
  --argjson b_replay "$same_tip_b_replay" \
  '$samples | .[1]=$b | .[2]=$a_replay | .[3]=$b_replay')
expect_fail 'same-tip family and sample switches cannot replay seen heads as progress' \
  v3015_pow_series_is_complete "$same_tip_family_switches"
interleaved_amount=$(jq '.[2:] |= map(
  .action_freshness.recovery_component.anchor.amount=11)' <<<"$interleaved")
expect_fail 'A-B-A continuity rejects interleaved anchor amount drift' \
  v3015_pow_series_is_live "$interleaved_amount"
interleaved_script=$(jq '.[2:] |= map(
  .action_freshness.recovery_component.anchor.scriptPubKey="52")' <<<"$interleaved")
expect_fail 'A-B-A continuity rejects interleaved anchor script drift' \
  v3015_pow_series_is_live "$interleaved_script"
interleaved_generation=$(jq --arg generation "$(printf 'f%.0s' {1..64})" '
  .[2:] |= map(
    .action_freshness.recovery_component.generation_fingerprint=$generation |
    .action_freshness.recovery_component_claims |= map(
      .lineage_family_fingerprint=$generation) |
    .action_freshness.recovery_component.nodes |= map(
      .lineage_family_fingerprint=$generation) |
    .action_freshness.recovery_node.lineage_family_fingerprint=$generation)' \
  <<<"$interleaved")
expect_fail 'A-B-A continuity rejects interleaved generation churn' \
  v3015_pow_series_is_live "$interleaved_generation"

regression_sources=$(make_samples wait_for_next_tip 4)
regression_interleaved=$(make_interleaved_samples)
regression_first=$(rebind_sample_family \
  "$(jq -c '.[0]' <<<"$regression_interleaved")" \
  "$(jq -c '.[2]' <<<"$regression_sources")")
regression_after_b=$(rebind_sample_family \
  "$(jq -c '.[2]' <<<"$regression_interleaved")" \
  "$(jq -c '.[0]' <<<"$regression_sources")")
regression_tail=$(rebind_sample_family \
  "$(jq -c '.[3]' <<<"$regression_interleaved")" \
  "$(jq -c '.[3]' <<<"$regression_sources")")
regression_tail=$(jq '.pow.claims_submitted=1' <<<"$regression_tail")
regression_interleaved=$(jq -cn --argjson samples "$regression_interleaved" \
  --argjson first "$regression_first" --argjson after "$regression_after_b" \
  --argjson tail "$regression_tail" \
  '$samples | .[0]=$first | .[2]=$after | .[3]=$tail')
expect_fail 'A-B-A continuity rejects an interleaved head regression' \
  v3015_pow_series_is_live "$regression_interleaved"

rewrite_timeline=$(make_samples wait_for_next_tip)
rewrite_b=$(rebind_sample_family \
  "$(jq -c '.[2]' <<<"$rewrite_timeline")" \
  "$(jq -c '.[1]' <<<"$interleaved")")
rewrite_first_extension=$(rebind_sample_family \
  "$(jq -c '.[1]' <<<"$rewrite_timeline")" \
  "$(jq -c '.[2]' <<<"$continuity_base")")
rewritten_source=$(jq -c '.[4]' <<<"$middle_rewrite")
rewrite_after_b=$(rebind_sample_family \
  "$(jq -c '.[3]' <<<"$rewrite_timeline")" "$rewritten_source")
rewrite_tail=$(rebind_sample_family \
  "$(jq -c '.[4]' <<<"$rewrite_timeline")" "$rewritten_source")
rewrite_interleaved=$(jq -cn --argjson samples "$rewrite_timeline" \
  --argjson first "$rewrite_first_extension" --argjson b "$rewrite_b" \
  --argjson after "$rewrite_after_b" --argjson tail "$rewrite_tail" \
  '$samples | .[1]=$first | .[2]=$b | .[3]=$after | .[4]=$tail')
expect_fail 'A-B-A continuity rejects an interleaved middle rewrite' \
  v3015_pow_series_is_live "$rewrite_interleaved"

same_tip_stall=$(collapse_series_to_first_cut \
  "$(make_samples wait_for_next_tip 5 '' no_progress)")
expect_pass 'short identical-cut sample-time churn collapses before transition accounting' \
  v3015_pow_series_is_live "$same_tip_stall"
same_tip_height_drift=$(jq '
  .[1] |= (.height+=1 | .blocks=.height | .headers=.height |
    .chain_before.blocks=.height | .chain_before.headers=.height |
    .chain_after.blocks=.height | .chain_after.headers=.height |
    .pow.current_height=.height | .staking.blocks=.height |
    .staking.active_blocks=.height)' <<<"$same_tip_extension")
expect_fail 'adjacent same-tip cuts require an identical height' \
  v3015_pow_series_is_live "$same_tip_height_drift"
same_tip_work_drift=$(jq '
  .[1].chain_before.chainwork=("f"*64) |
  .[1].chain_after.chainwork=("f"*64)' <<<"$same_tip_extension")
expect_fail 'adjacent same-tip cuts require identical chainwork' \
  v3015_pow_series_is_live "$same_tip_work_drift"
nonadvancing_height=$(make_interleaved_samples | jq '
  .[0].height as $height | .[1] |= (
    .height=$height | .blocks=$height | .headers=$height |
    .chain_before.blocks=$height | .chain_before.headers=$height |
    .chain_after.blocks=$height | .chain_after.headers=$height |
    .qqp4_activation.height=$height |
    .pow.current_height=$height | .staking.blocks=$height |
    .staking.active_blocks=$height)')
expect_pass 'a changed tip may retain height when fixed-width chainwork strictly advances' \
  v3015_pow_series_is_live "$nonadvancing_height"
lower_height=$(jq '.[0].height as $height | .[1] |= (.height=($height-1) | .blocks=.height | .headers=.height |
  .chain_before.blocks=.height | .chain_before.headers=.height |
  .chain_after.blocks=.height | .chain_after.headers=.height |
  .pow.current_height=.height | .staking.blocks=.height | .staking.active_blocks=.height)' \
  <<<"$(make_samples wait_for_next_tip 4)")
expect_fail 'a changed tip cannot lower active-chain height' \
  v3015_pow_series_is_live "$lower_height"
same_work_new_tip=$(jq '.[1].chain_before.chainwork=.[0].chain_after.chainwork |
  .[1].chain_after.chainwork=.[0].chain_after.chainwork' \
  <<<"$(make_samples wait_for_next_tip 4)")
expect_fail 'a changed tip requires strictly greater fixed-width chainwork' \
  v3015_pow_series_is_live "$same_work_new_tip"
replayed=$(make_samples wait_for_next_tip | jq '
  .[0].tip as $old_tip | .[4] |= (
    .tip=$old_tip | .chain_before.bestblockhash=$old_tip |
    .chain_after.bestblockhash=$old_tip | .pow.claim_inventory_tip=$old_tip |
    .wallet_processed_tip=$old_tip | .action_freshness.tip=$old_tip)')
expect_fail 'a compressed nonconsecutive tip cannot reappear' \
  v3015_pow_series_is_live "$replayed"
stale=$(make_samples wait_for_live | jq '
  ((.[2].sample_finished_unix_ms/1000|floor)-3601) as $stale_time |
  .[2].action_freshness.recovery_node.txid as $txid |
  .[2].action_freshness.live_members[0].mempool_entry_time=$stale_time |
  .[2].action_freshness.live_members[0].mempool_entry.time=$stale_time |
  .[2].action_freshness.raw_mempool[$txid].time=$stale_time |
  .[2].action_freshness.mempool_entry_time=$stale_time |
  .[2].action_freshness.mempool_entry.time=$stale_time')
expect_pass 'wait-for-live accepts an old entry still bound to the exact raw mempool cut' \
  v3015_pow_series_is_live "$stale"
stale=$(make_samples wait_for_live | jq '.[2].action_freshness.live_members=[]')
expect_fail 'wait-for-live requires current mempool membership evidence' \
  v3015_pow_series_is_live "$stale"
stale=$(make_samples relay_existing | jq '
  (.[1].sample_finished_unix_ms/1000|floor) as $expiry |
  .[1].action_freshness.recovery_node.relay_expiry_time=$expiry |
  .[1].action_freshness.recovery_component_claims[0].relay_expiry_time=$expiry |
  .[1].action_freshness.recovery_component.nodes[0].relay_expiry_time=$expiry')
expect_fail 'relay-existing requires an unexpired recovery relay target' \
  v3015_pow_series_is_live "$stale"
# Build a valid relay-existing sample in the middle, then expire only its
# current relay evidence. Per-sample freshness must catch it despite action alternation.
alternating=$(jq -cn --argjson wait "$(make_samples wait_for_next_tip)" \
  --argjson relay "$(make_samples relay_existing)" '$wait | .[1]=$relay[1] |
  (.[1].sample_finished_unix_ms/1000|floor) as $expiry |
  .[1].action_freshness.recovery_node.relay_expiry_time=$expiry |
  .[1].action_freshness.recovery_component_claims[0].relay_expiry_time=$expiry |
  .[1].action_freshness.recovery_component.nodes[0].relay_expiry_time=$expiry')
expect_fail 'alternating zero-hash actions cannot evade per-sample freshness' \
  v3015_pow_series_is_live "$alternating"
stale=$(make_samples wait_for_next_tip | jq '.[-1].sample_finished_unix_ms =
  (.[0].sample_started_unix_ms + 1800001) |
  .[-1].action_freshness.observed_unix_ms = .[-1].sample_finished_unix_ms')
expect_fail 'zero-hash series rejects an observation window over thirty minutes' \
  v3015_pow_series_is_live "$stale"
stale=$(collapse_series_to_first_cut "$(make_samples wait_for_next_tip 4 '' no_progress)" | jq '.[3].sample_started_unix_ms =
  (.[2].sample_finished_unix_ms + 600001) |
  .[3].sample_finished_unix_ms = (.[3].sample_started_unix_ms + 100) |
  .[3].action_freshness.observed_unix_ms = .[3].sample_finished_unix_ms')
expect_fail 'series rejects a ten-minute authoritative no-progress gap' \
  v3015_pow_series_is_live "$stale"
no_work=$(collapse_series_to_first_cut "$(make_samples create_new_anchor)" | jq \
  '.[].pow.hashrate=0 | .[].pow.claims_submitted=0')
expect_fail 'same-tip create cannot complete without work or submission progress' \
  v3015_pow_series_is_complete "$no_work"
no_work=$(collapse_series_to_first_cut \
  "$(make_samples refresh_same_anchor 5 '' no_progress)" | jq \
  '.[].pow.hashrate=0 | .[].pow.claims_submitted=0')
expect_fail 'same-tip refresh cannot complete without work or submission progress' \
  v3015_pow_series_is_complete "$no_work"
changing_tip_create=$(make_samples create_new_anchor 5 | jq \
  '.[].pow.hashrate=0 | .[].pow.claims_submitted=0')
expect_fail 'changing tips alone cannot complete zero-work create action' \
  v3015_pow_series_is_complete "$changing_tip_create"
changing_tip_refresh=$(make_samples refresh_same_anchor 5 '' no_progress | jq \
  '.[].pow.hashrate=0 | .[].pow.claims_submitted=0')
expect_fail 'changing tips alone cannot complete zero-work refresh action' \
  v3015_pow_series_is_complete "$changing_tip_refresh"
long_submit_stall=$(make_samples create_new_anchor 5 | jq '
  .[].pow.hashrate=0 | .[].pow.claims_submitted=0 |
  .[0].sample_started_unix_ms as $base |
  to_entries | map(.key as $i | .value |
    .sample_started_unix_ms=($base + ($i * 300000)) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100))')
expect_fail 'advancing tips cannot hide a submit transition stalled beyond ten minutes' \
  v3015_pow_series_is_complete "$long_submit_stall"
expect_fail 'live monitoring rejects an advancing-tip zero-submit stall beyond ten minutes' \
  v3015_pow_series_is_live "$long_submit_stall"
old_hash_then_long_stall=$(make_samples create_new_anchor 5 | jq '
  .[1:] |= map(.pow.hashrate=0) |
  .[0].sample_started_unix_ms as $base |
  to_entries | map(.key as $i | .value |
    .sample_started_unix_ms=($base + ($i * 300000)) |
    .sample_finished_unix_ms=(.sample_started_unix_ms + 100))')
expect_fail 'old positive hash cannot mask a trailing submit stall beyond ten minutes' \
  v3015_pow_series_is_complete "$old_hash_then_long_stall"
expect_fail 'live monitoring rejects a submit stall aged beyond an old hash witness' \
  v3015_pow_series_is_live "$old_hash_then_long_stall"
bounded_create=$(make_samples create_new_anchor | jq \
  '.[2].pow.hashrate=0 | .[2].pow.state="claim_in_flight"')
expect_pass 'one zero-hash create transition consumes the shared no-progress budget' \
  v3015_pow_series_is_live "$bounded_create"
bounded_refresh=$(make_samples refresh_same_anchor | jq \
  '.[2].pow.hashrate=0 | .[2].pow.state="ready"')
expect_pass 'one zero-hash refresh transition consumes the shared no-progress budget' \
  v3015_pow_series_is_live "$bounded_refresh"
create_transition_then_work=$(make_samples create_new_anchor | jq \
  '.[0:2] |= map(.pow.hashrate=0 | .pow.state="ready")')
expect_pass 'bounded create transition completes after positive hash work appears' \
  v3015_pow_series_is_complete "$create_transition_then_work"
refresh_transition_then_submission=$(make_samples refresh_same_anchor 5 '' no_progress | jq \
  '.[].pow.hashrate=0 | .[3:] |= map(.pow.claims_submitted=1)')
expect_pass 'bounded refresh transition completes after a submission outcome appears' \
  v3015_pow_series_is_complete "$refresh_transition_then_submission"
mixed_submit_to_wait=$(jq -cn \
  --argjson submit "$(make_samples refresh_same_anchor 4 '' no_progress)" \
  --argjson wait "$(make_samples wait_for_next_tip 4 '' no_progress)" '
  $submit | .[].pow.hashrate=0 | .[].pow.claims_submitted=0 |
  .[2]=$wait[2] | .[3]=$wait[3]')
expect_pass 'bounded zero-submit transition may resolve into an exact safe retained wait' \
  v3015_pow_series_is_complete "$mixed_submit_to_wait"
one_old_hash=$(collapse_series_to_first_cut \
  "$(make_samples create_new_anchor)" | jq '.[1:] |= map(.pow.hashrate=0)')
expect_pass 'an initial submit-capable positive hash is an eventual-work witness' \
  v3015_pow_series_is_complete "$one_old_hash"
count_progress=$(make_samples refresh_same_anchor | jq \
  '.[].pow.hashrate=0 | to_entries | map(.value.pow.claims_submitted=.key | .value)')
expect_pass 'strict submission-count increase satisfies each refresh interval' \
  v3015_pow_series_is_live "$count_progress"
expect_pass 'create action accepts bounded hashrate evidence' v3015_pow_series_is_live "$(make_samples create_new_anchor)"
expect_pass 'refresh action binds an authenticated selected recovery family' \
  v3015_pow_series_is_live "$(make_samples refresh_same_anchor)"
bad_refresh=$(make_samples refresh_same_anchor | jq '.[2].action_freshness=null')
expect_fail 'refresh action rejects missing selected-family freshness' \
  v3015_pow_series_is_live "$bad_refresh"
bad_refresh=$(make_samples refresh_same_anchor | jq \
  '.[2].action_freshness.recovery_component.generation_fingerprint=("f"*64)')
expect_fail 'refresh action rejects a forged recovery-family generation' \
  v3015_pow_series_is_live "$bad_refresh"
bad_refresh=$(make_samples refresh_same_anchor | jq \
  '.[2].action_freshness.raw_mempool[.[2].action_freshness.lineage_head_txid]={time:1}')
expect_fail 'refresh action rejects a selected head contradicted by raw mempool' \
  v3015_pow_series_is_live "$bad_refresh"
mixed_tip=$(make_samples wait_for_next_tip | jq \
  '.[2].chain_after.bestblockhash=("f"*64)')
expect_fail 'regular sample rejects a mixed-tip Core before/after cut' \
  v3015_pow_series_is_live "$mixed_tip"
state_transition=$(make_samples wait_for_next_tip | jq '.[2].pow.state="ready"')
expect_pass 'bounded fresh wait sample may expose a prior operational worker state' \
  v3015_pow_series_is_live "$state_transition"
state_stall=$(collapse_series_to_first_cut \
  "$(make_samples wait_for_next_tip 5 '' no_progress)" | jq '.[].pow.state="ready"')
expect_fail 'operational state mismatch cannot excuse sustained no-progress waits' \
  v3015_pow_series_is_complete "$state_stall"
bad_state=$(make_samples wait_for_next_tip | jq '.[2].pow.state="disabled"')
expect_fail 'nonoperational worker state fails even with otherwise fresh gate evidence' \
  v3015_pow_series_is_live "$bad_state"
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

migration=$(make_preunlock_migration)
expect_pass 'portable pre-unlock guard ignores legacy recovery classification counters' \
  v3015_preunlock_migration_is_safe "$migration"
expect_pass 'portable pre-unlock guard preserves a named default wallet' \
  v3015_preunlock_migration_is_safe "$(make_preunlock_migration default_wallet)"
locked_payout_reset=$(jq '.after.payout="" | .after.payout_address_info=null' <<<"$migration")
expect_pass 'portable locked restart may reset process-local future payout state to empty' \
  v3015_preunlock_migration_is_safe "$locked_payout_reset"
unlabeled_configured=$(jq '
  .before.labeled_addresses=[] | .after.labeled_addresses=[] |
  .before.quantum_inventory.keys[0].label="" |
  .after.quantum_inventory.keys[0].label="" |
  .before.payout_address_info.labels=[] | .after.payout_address_info.labels=[]' <<<"$migration")
expect_pass 'owned quantum payout does not require a nonempty address-book label' \
  v3015_preunlock_migration_is_safe "$unlabeled_configured"
legacy_label_restore=$(jq '
  .before.payout="" | .before.payout_address_info=null |
  .before.labeled_addresses[0].label="goldrush-pow" |
  .before.quantum_inventory.keys[0].label="goldrush-pow" |
  .after.labeled_addresses[0].label="PoW - Quantum Claim Address" |
  .after.quantum_inventory.keys[0].label="PoW - Quantum Claim Address" |
  .after.payout_address_info.labels=[{name:"PoW - Quantum Claim Address",purpose:"receive"}]' \
  <<<"$migration")
expect_pass 'normal payout restoration permits only the known legacy-to-canonical relabel' \
  v3015_preunlock_migration_is_safe "$legacy_label_restore"
bad_migration=$(jq '.after.labeled_addresses[0].label="arbitrary" |
  .after.quantum_inventory.keys[0].label="arbitrary"' <<<"$migration")
expect_fail 'portable payout guard rejects arbitrary label mutation' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.payout_address_info.isquantummigration=false' <<<"$migration")
expect_fail 'portable payout guard rejects a non-quantum configured address' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.payout_address_info.ismine=false' <<<"$migration")
expect_fail 'portable payout guard rejects an unowned configured address' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.wallet.walletname="default_wallet" |
  .after.loaded_wallets=["default_wallet"]' <<<"$migration")
expect_fail 'portable pre-unlock guard rejects wallet identity drift' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.loaded_wallets=["", "default_wallet"]' <<<"$migration")
expect_fail 'portable pre-unlock guard rejects multiple loaded wallets' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.payout="qq-other"' <<<"$migration")
expect_fail 'portable pre-unlock guard rejects payout drift' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.quantum_inventory.count=2' <<<"$migration")
expect_fail 'portable pre-unlock guard rejects key inventory drift' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq 'del(.after.recovery.component_details)' <<<"$migration")
expect_fail 'portable candidate capture rejects nonverbose recovery shape' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.transactions=[{txid:("a"*64),category:"receive"}] |
  .after.wallet.txcount=1' <<<"$migration")
expect_fail 'portable pre-unlock guard rejects an unbound new cutover transaction' \
  v3015_preunlock_migration_is_safe "$bad_migration"
foreign_migration=$(make_foreign_receive_migration)
expect_pass 'portable pre-unlock guard accepts one exact audit-only foreign receive' \
  v3015_preunlock_migration_is_safe "$foreign_migration"
default_anchor_foreign_migration=$(jq '.after.recovery.component_details[0].anchor =
  {txid:("0"*64),vout:4294967295,amount:0,scriptPubKey:""}' <<<"$foreign_migration")
expect_pass 'portable pre-unlock guard accepts the exact default foreign anchor shape' \
  v3015_preunlock_migration_is_safe "$default_anchor_foreign_migration"
commented_foreign_migration=$(jq '.after.transactions[0].comment="peer memo"' \
  <<<"$foreign_migration")
expect_pass 'portable foreign receive permits an arbitrary non-control comment' \
  v3015_preunlock_migration_is_safe "$commented_foreign_migration"
watch_only_foreign_migration=$(jq '
  .after.transactions[0].involvesWatchonly=true |
  .after.transaction_evidence[.after.transactions[0].txid].transaction.involvesWatchonly=true |
  .after.transaction_evidence[.after.transactions[0].txid].transaction.details[0].involvesWatchonly=true' \
  <<<"$foreign_migration")
expect_pass 'portable foreign receive accepts a proven positive watch-only credit' \
  v3015_preunlock_migration_is_safe "$watch_only_foreign_migration"
for foreign_row_mutation in \
    '.after.transactions[0].category="send"' \
    '.after.transactions += [(.after.transactions[0] | .category="send")]' \
    '.after.transactions[0].amount=0' \
    '.after.transactions[0].confirmations=1' \
    '.after.transactions[0].abandoned=true' \
    '.after.transactions[0].fee=0' \
    '.after.transactions[0].generated=false' \
    '.after.transactions[0].qq_synthetic_goldrush_payout="1"' \
    '.after.transactions[0].comment="PoW Claim"' \
    '.after.transactions[0].comment="Quantum PoW Claim"' \
    '.after.transactions[0].comment="Quantum Quasar built-in shadow PoW claim"' \
    '.after.transactions[0].comment="Blackcoin shadow PoW claim"' \
    '.after.transactions[0].comment="PoS Claim"' \
    '.after.transactions[0].qq_shadow_pow_authored="1"' \
    '.after.transactions[0].qq_shadow_pow_lineage_schema="1"' \
    '.after.transactions[0].qq_shadow_pow_resolution_origin="manual"'; do
    bad_migration=$(jq "$foreign_row_mutation" <<<"$foreign_migration")
    expect_fail "portable foreign receive rejects ${foreign_row_mutation}" \
      v3015_preunlock_migration_is_safe "$bad_migration"
done
bad_migration=$(jq '.after.recovery.component_details[0].nodes[0].wallet_from_me=true' \
  <<<"$foreign_migration")
expect_fail 'portable foreign receive rejects wallet-owned authority' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.recovery.component_details[0].nodes[0].provenance="explicit_authored"' \
  <<<"$foreign_migration")
expect_fail 'portable foreign receive rejects authored provenance' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.recovery.unanchored_claim_txids=[]' <<<"$foreign_migration")
expect_fail 'portable foreign receive requires exact unanchored membership' \
  v3015_preunlock_migration_is_safe "$bad_migration"
bad_migration=$(jq '.after.recovery.component_details +=
  [.after.recovery.component_details[0]] | .after.recovery.components=2 |
  .after.recovery.blocking_components=2 | .after.recovery.raw_claim_objects=2 |
  .after.recovery.quarantined_claim_objects=2' <<<"$foreign_migration")
expect_fail 'portable foreign receive rejects ambiguous duplicate component membership' \
  v3015_preunlock_migration_is_safe "$bad_migration"
ordinary_migration_base=$(make_preunlock_migration)
ordinary_delta=$(make_ordinary_receive_delta)
ordinary_after=$(jq -cn --argjson base "$(jq -c '.after' <<<"$ordinary_migration_base")" \
  --argjson incoming "$(jq -c '.after' <<<"$ordinary_delta")" '
  $base | .transactions=$incoming.transactions |
  .transaction_evidence=$incoming.transaction_evidence | .wallet.txcount=1')
ordinary_migration=$(v3015_make_preunlock_migration_audit \
  "$(jq -c '.before' <<<"$ordinary_migration_base")" "$ordinary_after")
expect_pass 'portable pre-unlock guard accepts a proven ordinary external receive' \
  v3015_preunlock_migration_is_safe "$ordinary_migration"
confirmed_delta=$(make_confirmed_receive_delta)
confirmed_after=$(jq -cn --argjson base "$(jq -c '.after' <<<"$ordinary_migration_base")" \
  --argjson incoming "$(jq -c '.after' <<<"$confirmed_delta")" '
  $base | .transactions=$incoming.transactions |
  .transaction_evidence=$incoming.transaction_evidence | .wallet.txcount=1')
confirmed_migration=$(v3015_make_preunlock_migration_audit \
  "$(jq -c '.before' <<<"$ordinary_migration_base")" "$confirmed_after")
expect_pass 'portable pre-unlock guard accepts a confirmed external receive with active membership' \
  v3015_preunlock_migration_is_safe "$confirmed_migration"
expect_pass 'empty wallet delta is safe' v3015_wallet_delta_is_safe "$(make_delta)"
expect_pass 'named default wallet delta is safe' \
  v3015_wallet_delta_is_safe "$(make_delta default_wallet)"
bad_delta=$(make_delta | jq 'del(.before.recovery.component_details)')
expect_fail 'candidate-native locked baseline rejects nonverbose recovery shape' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq 'del(.after.recovery.component_details)')
expect_fail 'candidate-native final capture rejects nonverbose recovery shape' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.wallet.walletname="default_wallet" |
  .after.loaded_wallets=["default_wallet"]')
expect_fail 'coherent wallet-name drift fails baseline identity binding' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.loaded_wallets=["", "default_wallet"]')
expect_fail 'multiple loaded wallets fail exact single-wallet identity' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.loaded_wallets=[]')
expect_fail 'missing loaded wallet fails exact single-wallet identity' \
  v3015_wallet_delta_is_safe "$bad_delta"
claim_delta=$(make_claim_delta)
expect_pass 'candidate-native recovery accepts coherent nonzero retained quarantine telemetry' \
  v3015_recovery_json_is_exact_safe "$(jq -c '.after.recovery' <<<"$claim_delta")"
telemetry_recovery=$(jq -c '.after.recovery |
  .raw_quarantined_claims=2 | .blocking_quarantined_claims=5 |
  .actionable_quarantined_claims=3 | .indeterminate_quarantined_claims=7' \
  <<<"$claim_delta")
expect_pass 'candidate-native recovery treats legacy quarantine-counter arithmetic as telemetry' \
  v3015_recovery_json_is_exact_safe "$telemetry_recovery"
compat_components_recovery=$(jq -c '.after.recovery | .components=7' <<<"$claim_delta")
expect_pass 'candidate-native recovery treats compatibility component count as telemetry' \
  v3015_recovery_json_is_exact_safe "$compat_components_recovery"
foreign_delta=$(make_foreign_receive_delta)
foreign_recovery=$(jq -c '.after.recovery' <<<"$foreign_delta")
expect_pass 'candidate-native recovery accepts exact audit-only foreign nonnull-anchor telemetry' \
  v3015_recovery_json_is_exact_safe "$foreign_recovery"
default_anchor_foreign=$(jq '.component_details[0].anchor =
  {txid:("0"*64),vout:4294967295,amount:0,scriptPubKey:""}' <<<"$foreign_recovery")
expect_pass 'candidate-native recovery accepts exact audit-only foreign default-anchor telemetry' \
  v3015_recovery_json_is_exact_safe "$default_anchor_foreign"
mixed_foreign=$(jq --arg ordinary "$(printf 'f%.0s' {1..64})" '
  .component_details[0] |= (
    .nodes[0] as $claim |
    ($claim | .txid=$ordinary | .kind="ordinary" |
      .in_mempool=false | .quarantined=false) as $ordinary_node |
    .nodes += [$ordinary_node] | .nodes |= sort_by(.txid) |
    .ordinary_or_mixed_txids=[$ordinary])' <<<"$foreign_recovery")
expect_pass 'audit-only foreign component permits mixed unknown ordinary graph nodes' \
  v3015_recovery_json_is_exact_safe "$mixed_foreign"
bad_mixed_foreign=$(jq '(.component_details[0].nodes[] |
  select(.kind == "ordinary")).wallet_from_me=true' <<<"$mixed_foreign")
expect_fail 'audit-only foreign component rejects a wallet-from-me ordinary sibling' \
  v3015_recovery_json_is_exact_safe "$bad_mixed_foreign"
bad_foreign=$(jq '.component_details[0].nodes[0].wallet_from_me=true' \
  <<<"$foreign_recovery")
expect_fail 'audit-only foreign component rejects a wallet-from-me claim' \
  v3015_recovery_json_is_exact_safe "$bad_foreign"
bad_foreign=$(jq '.component_details[0].anchor_authenticated=true' \
  <<<"$foreign_recovery")
expect_fail 'audit-only foreign component rejects authenticated wallet authority' \
  v3015_recovery_json_is_exact_safe "$bad_foreign"
bad_foreign=$(jq '.component_details[0].nodes[0].provenance="explicit_authored"' \
  <<<"$foreign_recovery")
expect_fail 'audit-only foreign component rejects authored provenance' \
  v3015_recovery_json_is_exact_safe "$bad_foreign"
bad_foreign=$(jq '.component_details[0].anchor_user_locked=true' <<<"$foreign_recovery")
expect_fail 'audit-only foreign component rejects a user-locked anchor claim' \
  v3015_recovery_json_is_exact_safe "$bad_foreign"
bad_foreign=$(jq '.unanchored_claim_txids=[]' <<<"$foreign_recovery")
expect_fail 'audit-only foreign claims bind to unanchored inventory membership' \
  v3015_recovery_json_is_exact_safe "$bad_foreign"
duplicate_component_recovery=$(jq -c '.after.recovery |
  .component_details += [.component_details[0]] | .components=2 |
  .blocking_components=2 | .raw_claim_objects=2 |
  .quarantined_claim_objects=2' <<<"$claim_delta")
expect_fail 'candidate-native recovery rejects a txid duplicated across components' \
  v3015_recovery_json_is_exact_safe "$duplicate_component_recovery"
expect_pass 'candidate-native wallet audit accepts one exact audit-only foreign receive' \
  v3015_wallet_delta_is_safe "$foreign_delta"
ordinary_delta=$(make_ordinary_receive_delta)
expect_pass 'candidate-native wallet audit accepts an unconfirmed ordinary external receive' \
  v3015_wallet_delta_is_safe "$ordinary_delta"
confirmed_receive=$(make_confirmed_receive_delta)
expect_pass 'candidate-native wallet audit binds a confirmed receive to active block membership' \
  v3015_wallet_delta_is_safe "$confirmed_receive"
confirmed_before=$(jq -c '.before' <<<"$confirmed_receive")
confirmed_claim_after=$(jq -c '.after |
  .transaction_evidence[.transactions[0].txid].transaction.decoded.vout[0].scriptPubKey.asm=
    "OP_RETURN 51515350524f4f46deadbeef"' <<<"$confirmed_receive")
confirmed_claim_delta=$(v3015_make_wallet_audit "$confirmed_before" "$confirmed_claim_after")
expect_pass 'confirmed foreign claim-shaped receive remains safe after recovery inventory disappears' \
  v3015_wallet_delta_is_safe "$confirmed_claim_delta"
for claim_version in 2 3 4; do
    versioned_recovery_absent_claim=$(
      make_recovery_absent_confirmed_authored_claim_delta "$claim_version")
    expect_pass "confirmed candidate-authored QQP${claim_version} claim survives recovery disappearance" \
      v3015_wallet_delta_is_safe "$versioned_recovery_absent_claim"
done
recovery_absent_claim=$(make_recovery_absent_confirmed_authored_claim_delta 4)
expect_pass 'recovery-absent authored claim is the sole authenticated allowed class' \
  jq -e '.after.recovery.component_details == [] and
    .delta.transactions == [(.delta.transactions[0])] and
    .delta.transactions[0].authenticated_same_anchor_claim == true and
    .delta.transactions[0].exactly_one_allowed_class == true' \
    <<<"$recovery_absent_claim"
recovery_absent_before=$(jq -c '.before' <<<"$recovery_absent_claim")
qqp2_absent=$(make_recovery_absent_confirmed_authored_claim_delta 2)
bad_delta=$(rewrite_recovery_absent_claim_carrier \
  "$qqp2_absent" 51515032 51515031)
expect_fail 'recovery-absent QQP2 rejects a non-QQP2 carrier tuple' \
  v3015_wallet_delta_is_safe "$bad_delta"
qqp3_absent=$(make_recovery_absent_confirmed_authored_claim_delta 3)
bad_delta=$(rewrite_recovery_absent_claim_carrier \
  "$qqp3_absent" e8030000 e7030000)
expect_fail 'recovery-absent QQP3 binds origin height to created height' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(rewrite_recovery_absent_claim_carrier \
  "$qqp3_absent" "$(printf 'd%.0s' {1..64})" "$(printf 'c%.0s' {1..64})")
expect_fail 'recovery-absent QQP3 binds origin parent to created tip' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(rewrite_recovery_absent_claim_carrier \
  "$recovery_absent_claim" "$(printf 'a%.0s' {1..64})" \
  "$(printf '1%.0s' {1..64})")
expect_fail 'recovery-absent QQP4 binds carrier outpoint to decoded vin0' \
  v3015_wallet_delta_is_safe "$bad_delta"
for authored_claim_mutation in \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_authored="0"' \
    '.transactions[0].qq_shadow_pow_authored="0"' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_created_height="999"' \
    '.transactions[0].qq_shadow_pow_created_height="999"' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_created_tip=("1"*64)' \
    '.transactions[0].qq_shadow_pow_created_tip=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_legacy_cleanup_quarantine="1"' \
    '.transactions[0].qq_shadow_pow_legacy_cleanup_quarantine="1"' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_auto_shadow_stale="1"' \
    '.transactions[0].qq_auto_shadow_stale="1"' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_manual_shadow_abandon="1"' \
    '.transactions[0].qq_manual_shadow_abandon="1"' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_reorg_shadow_resubmit="1"' \
    '.transactions[0].qq_reorg_shadow_resubmit="1"' \
    '.transaction_evidence[.transactions[0].txid].created_tip_active_chain_hash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].created_tip_header.hash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].created_tip_header.height=998' \
    '.transaction_evidence[.transactions[0].txid].created_tip_header.confirmations=2' \
    '.transaction_evidence[.transactions[0].txid].transaction.hex |= sub("02000000";"03000000")' \
    '.transaction_evidence[.transactions[0].txid].transaction.decoded.txid=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.decoded.vin[0].sequence=4294967294' \
    '.transaction_evidence[.transactions[0].txid].transaction.decoded.vout[0].scriptPubKey.hex="51"' \
    '.transaction_evidence[.transactions[0].txid].transaction.decoded.vout[1].scriptPubKey.asm="OP_RETURN 00"' \
    '.transaction_evidence[.transactions[0].txid].transaction.decoded.vout[1].scriptPubKey.hex="6a0100"' \
    '.transaction_evidence[.transactions[0].txid].transaction.blockhash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.blockheight=1000' \
    '.transaction_evidence[.transactions[0].txid].transaction.blockindex=0' \
    '.transaction_evidence[.transactions[0].txid].active_block.tx |= reverse' \
    '.transaction_evidence[.transactions[0].txid].active_block.hash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].active_block.height=1000' \
    '.transaction_evidence[.transactions[0].txid].active_block.confirmations=2' \
    '.transaction_evidence[.transactions[0].txid].active_chain_hash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].active_header.hash=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].active_header.height=1000' \
    '.transaction_evidence[.transactions[0].txid].active_header.confirmations=2' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_lineage_schema="2"' \
    '.transactions[0].qq_shadow_pow_lineage_schema="2"' \
    'del(.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_lineage_family)' \
    '.transactions[0].qq_shadow_pow_lineage_family=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_lineage_root=("1"*64)' \
    '.transactions[0].qq_shadow_pow_lineage_root=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_lineage_parent=("1"*64)' \
    '.transactions[0].qq_shadow_pow_lineage_parent=("1"*64)' \
    '.transaction_evidence[.transactions[0].txid].transaction.qq_shadow_pow_lineage_ordinal="1"' \
    '.transactions[0].qq_shadow_pow_lineage_ordinal="1"'; do
    bad_after=$(jq -c ".after | $authored_claim_mutation" \
      <<<"$recovery_absent_claim")
    bad_delta=$(v3015_make_wallet_audit "$recovery_absent_before" "$bad_after")
    expect_fail "recovery-absent authored claim rejects ${authored_claim_mutation}" \
      v3015_wallet_delta_is_safe "$bad_delta"
done
raw_input=$(jq -er '.after.transaction_evidence[.after.transactions[0].txid].transaction.decoded.vin[0].txid' \
  <<<"$recovery_absent_claim")
raw_target=$(jq -er '.after.transaction_evidence[.after.transactions[0].txid].transaction.decoded.vout[0].scriptPubKey.hex' \
  <<<"$recovery_absent_claim")
raw_carrier=$(jq -er '.after.transaction_evidence[.after.transactions[0].txid].transaction.decoded.vout[1].scriptPubKey.hex' \
  <<<"$recovery_absent_claim")
printf -v raw_carrier_bytes '%02x' "$((${#raw_carrier} / 2))"
swapped_raw="0200000001${raw_input}0000000000fdffffff02"
swapped_raw+="0000000000000000${raw_carrier_bytes}${raw_carrier}"
swapped_raw+="a08601000000000019${raw_target}00000000"
bad_delta=$(rekey_recovery_absent_claim_raw \
  "$recovery_absent_claim" "$swapped_raw")
expect_fail 'recovery-absent authored claim binds decoded carrier to exact raw vout1' \
  v3015_wallet_delta_is_safe "$bad_delta"

recovery_absent_descendant=$(
  make_recovery_absent_confirmed_authored_descendant_delta)
expect_pass 'confirmed explicit descendant authenticates a candidate-before implicit root' \
  v3015_wallet_delta_is_safe "$recovery_absent_descendant"
bad_delta=$(rewrite_recovery_absent_claim_carrier \
  "$recovery_absent_descendant" "$(printf '9%.0s' {1..64})" \
  "$(printf '7%.0s' {1..64})")
expect_fail 'confirmed descendant preserves its authenticated family payout bytes' \
  v3015_wallet_delta_is_safe "$bad_delta"
descendant_before=$(jq -c '.before' <<<"$recovery_absent_descendant")
descendant_after=$(jq -c '.after' <<<"$recovery_absent_descendant")
descendant_txid=$(jq -r '.delta.added_txids[0]' \
  <<<"$recovery_absent_descendant")
descendant_root=$(jq -r '.before.transactions[0].txid' \
  <<<"$recovery_absent_descendant")
bad_after=$(jq -c --arg txid "$descendant_txid" '
  (.transactions[] | select(.txid == $txid) |
    .qq_shadow_pow_lineage_ordinal)="2" |
  .transaction_evidence[$txid].transaction.qq_shadow_pow_lineage_ordinal="2"' \
  <<<"$descendant_after")
bad_delta=$(v3015_make_wallet_audit "$descendant_before" "$bad_after")
expect_fail 'recovery-absent descendant rejects an ordinal gap' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c --arg txid "$descendant_txid" '
  (.transactions[] | select(.txid == $txid) |
    .qq_shadow_pow_lineage_parent)=("2"*64) |
  .transaction_evidence[$txid].transaction.qq_shadow_pow_lineage_parent=("2"*64)' \
  <<<"$descendant_after")
bad_delta=$(v3015_make_wallet_audit "$descendant_before" "$bad_after")
expect_fail 'recovery-absent descendant rejects a non-predecessor parent' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c --arg txid "$descendant_txid" '
  (.transactions[] | select(.txid == $txid) |
    .qq_shadow_pow_lineage_root)=("3"*64) |
  .transaction_evidence[$txid].transaction.qq_shadow_pow_lineage_root=("3"*64)' \
  <<<"$descendant_after")
bad_delta=$(v3015_make_wallet_audit "$descendant_before" "$bad_after")
expect_fail 'recovery-absent descendant rejects a foreign lineage root' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c --arg root "$descendant_root" '
  (.transactions[] | select(.txid == $root) |
    .qq_shadow_pow_authored)="0"' <<<"$descendant_after")
bad_delta=$(v3015_make_wallet_audit "$descendant_before" "$bad_after")
expect_fail 'recovery-absent descendant requires an authenticated authored predecessor row' \
  v3015_wallet_delta_is_safe "$bad_delta"
for before_component_mutation in \
    '.recovery.component_details=[] | .recovery.components=0 |
      .recovery.blocking_components=0 | .recovery.actionable_quarantined_claims=0 |
      .recovery.blocking_quarantined_claims=0 | .recovery.raw_claim_objects=0 |
      .recovery.quarantined_claim_objects=0 | .recovery.raw_quarantined_claims=0' \
    '.recovery.component_details[0].anchor_authenticated=false' \
    '.recovery.component_details[0].anchor_unspent=false' \
    '.recovery.component_details[0].all_claims_explicitly_provenanced=false' \
    '.recovery.component_details[0].nodes[0].provenance="unknown"' \
    '.recovery.component_details[0].nodes[0].exact_authored_carrier_shape=false' \
    '.recovery.component_details[0].generation_fingerprint=("4"*64)' \
    '.recovery.component_details[0].nodes[0].proof_version=3' \
    '.recovery.component_details += [.recovery.component_details[0]] |
      .recovery.components=2 | .recovery.blocking_components=2'; do
    bad_before=$(jq -c "$before_component_mutation" <<<"$descendant_before")
    bad_delta=$(v3015_make_wallet_audit "$bad_before" "$descendant_after")
    expect_fail "implicit-root descendant rejects before component ${before_component_mutation}" \
      v3015_wallet_delta_is_safe "$bad_delta"
done
bad_before=$(jq -c --arg root "$descendant_root" '
  .transaction_evidence[$root].transaction.hex |= sub("02000000";"03000000")' \
  <<<"$descendant_before")
bad_delta=$(v3015_make_wallet_audit "$bad_before" "$descendant_after")
expect_fail 'implicit-root descendant binds its preserved baseline raw transaction' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after | .transaction_evidence[.transactions[0].txid].active_block.tx=[]' \
  <<<"$confirmed_receive")
bad_delta=$(v3015_make_wallet_audit "$confirmed_before" "$bad_after")
expect_fail 'confirmed receive rejects an active block omitting the exact transaction' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after |
  .transaction_evidence[.transactions[0].txid].active_chain_hash=("f"*64)' \
  <<<"$confirmed_receive")
bad_delta=$(v3015_make_wallet_audit "$confirmed_before" "$bad_after")
expect_fail 'confirmed receive rejects a height-to-active-hash mismatch' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after |
  .transaction_evidence[.transactions[0].txid].transaction.fee=0' \
  <<<"$confirmed_receive")
bad_delta=$(v3015_make_wallet_audit "$confirmed_before" "$bad_after")
expect_fail 'confirmed receive rejects even a zero-valued from-me fee field' \
  v3015_wallet_delta_is_safe "$bad_delta"
watch_only_after=$(jq -c '.after |
  .transactions[0].involvesWatchonly=true |
  .transaction_evidence[.transactions[0].txid].transaction.involvesWatchonly=true |
  .transaction_evidence[.transactions[0].txid].transaction.details[0].involvesWatchonly=true' \
  <<<"$confirmed_receive")
watch_only_delta=$(v3015_make_wallet_audit "$confirmed_before" "$watch_only_after")
expect_pass 'external receive accepts a proven positive watch-only credit' \
  v3015_wallet_delta_is_safe "$watch_only_delta"
bad_after=$(jq -c '.after |
  .transaction_evidence[.transactions[0].txid].transaction.details +=
    [{category:"send",amount:-0.25,fee:-0.001,involvesWatchonly:true}]' \
  <<<"$confirmed_receive")
bad_delta=$(v3015_make_wallet_audit "$confirmed_before" "$bad_after")
expect_fail 'watch-only receive evidence rejects a mixed debit detail' \
  v3015_wallet_delta_is_safe "$bad_delta"
expect_pass 'candidate-native wallet audit labels the foreign receive as its only class' \
  jq -e '.delta.transactions | length == 1 and
    .[0].safe_external_receive == true and
    .[0].exactly_one_allowed_class == true' <<<"$foreign_delta"
foreign_before=$(jq -c '.before' <<<"$foreign_delta")
commented_foreign_after=$(jq -c '.after |
  .transactions[0].comment="peer memo"' <<<"$foreign_delta")
commented_foreign_delta=$(v3015_make_wallet_audit \
  "$foreign_before" "$commented_foreign_after")
expect_pass 'candidate-native foreign receive permits an arbitrary non-control comment' \
  v3015_wallet_delta_is_safe "$commented_foreign_delta"
for foreign_row_mutation in \
    '.transactions[0].category="send"' \
    '.transactions += [(.transactions[0] | .category="send")]' \
    '.transactions[0].amount=0' \
    '.transactions[0].confirmations=1' \
    '.transactions[0].abandoned=true' \
    '.transactions[0].fee=0' \
    '.transactions[0].generated=false' \
    '.transactions[0].qq_synthetic_goldrush_payout="1"' \
    '.transactions[0].comment="PoW Claim"' \
    '.transactions[0].comment="Quantum PoW Claim"' \
    '.transactions[0].comment="Quantum Quasar built-in shadow PoW claim"' \
    '.transactions[0].comment="Blackcoin shadow PoW claim"' \
    '.transactions[0].comment="PoS Claim"' \
    '.transactions[0].qq_shadow_pow_authored="1"' \
    '.transactions[0].qq_shadow_pow_lineage_schema="1"' \
    '.transactions[0].qq_shadow_pow_cleanup_for=("1"*64)' \
    '.transactions[0].qq_shadow_pow_resolution_origin="manual"'; do
    bad_after=$(jq -c ".after | $foreign_row_mutation" <<<"$foreign_delta")
    bad_delta=$(v3015_make_wallet_audit "$foreign_before" "$bad_after")
    expect_fail "candidate-native foreign receive rejects ${foreign_row_mutation}" \
      v3015_wallet_delta_is_safe "$bad_delta"
done
bad_after=$(jq -c '.after |
  .recovery.component_details[0].nodes[0].wallet_authored=true' <<<"$foreign_delta")
bad_delta=$(v3015_make_wallet_audit "$foreign_before" "$bad_after")
expect_fail 'candidate-native foreign receive rejects wallet-authored membership' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after |
  .recovery.component_details[0].nodes[0].provenance="explicit_authored"' \
  <<<"$foreign_delta")
bad_delta=$(v3015_make_wallet_audit "$foreign_before" "$bad_after")
expect_fail 'candidate-native foreign receive rejects authored component membership' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after | .recovery.unanchored_claim_txids=[]' <<<"$foreign_delta")
bad_delta=$(v3015_make_wallet_audit "$foreign_before" "$bad_after")
expect_fail 'candidate-native foreign receive rejects missing unanchored membership' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after |
  .recovery.component_details += [.recovery.component_details[0]] |
  .recovery.components=2 | .recovery.blocking_components=2 |
  .recovery.raw_claim_objects=2 | .recovery.quarantined_claim_objects=2' \
  <<<"$foreign_delta")
bad_delta=$(v3015_make_wallet_audit "$foreign_before" "$bad_after")
expect_fail 'candidate-native foreign receive rejects ambiguous duplicate claim matches' \
  v3015_wallet_delta_is_safe "$bad_delta"
synthetic_delta=$(make_synthetic_payout_delta)
expect_pass 'candidate-native audit accepts an authenticated foreign-source synthetic credit' \
  v3015_wallet_delta_is_safe "$synthetic_delta"
synthetic_before=$(jq -c '.before' <<<"$synthetic_delta")
synthetic_v3_after=$(jq -c '.after |
  (.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
    .key) as $payout |
  .transaction_evidence[$payout].shadow_transaction.pow_claim_source |= (
    .proof_version=3 | .origin_bound=true | .input_bound=false |
    .claim_outpoint=null) |
  .transaction_evidence[$payout].source_transaction.vout[0].scriptPubKey.asm=
    "OP_RETURN 51515350524f4f4651515033"' <<<"$synthetic_delta")
synthetic_v3=$(v3015_make_wallet_audit "$synthetic_before" "$synthetic_v3_after")
expect_pass 'synthetic payout binds the exact QQP3 source descriptor shape' \
  v3015_wallet_delta_is_safe "$synthetic_v3"
synthetic_v2_after=$(jq -c '.after |
  (.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
    .key) as $payout |
  .transaction_evidence[$payout].shadow_transaction.pow_claim_source |= (
    .proof_version=2 | .origin_bound=false | .origin_height=0 |
    .origin_previous_block_hash=null | .origin_age=0 | .input_bound=false |
    .claim_outpoint=null) |
  .transaction_evidence[$payout].source_transaction.vout[0].scriptPubKey.asm=
    "OP_RETURN 51515350524f4f4651515032"' <<<"$synthetic_delta")
synthetic_v2=$(v3015_make_wallet_audit "$synthetic_before" "$synthetic_v2_after")
expect_pass 'synthetic payout binds the exact QQP2 source descriptor shape' \
  v3015_wallet_delta_is_safe "$synthetic_v2"
immature_synthetic_after=$(jq -c '.after |
  .transactions[0].category="immature" |
  (.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
    .key) as $payout |
  .transaction_evidence[$payout].shadow_transaction |= (
    .status="immature" | .lifecycle_category="gold_rush_synthetic_immature")' \
  <<<"$synthetic_delta")
immature_synthetic=$(v3015_make_wallet_audit \
  "$synthetic_before" "$immature_synthetic_after")
expect_pass 'immature synthetic credit binds its exact lifecycle and wallet category' \
  v3015_wallet_delta_is_safe "$immature_synthetic"
spent_synthetic_after=$(jq -c '.after |
  (.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
    .key) as $payout |
  .transaction_evidence[$payout].shadow_transaction |= (
    .status="spent" | .lifecycle_category="spent" |
    .valuation_status="recorded_at_spend" |
    .spend={height:1000,blockhash:.base_anchor.blockhash,txid:("e"*64),
      tx_index:2,input_index:0})' <<<"$synthetic_delta")
spent_synthetic=$(v3015_make_wallet_audit "$synthetic_before" "$spent_synthetic_after")
expect_pass 'spent synthetic payout remains authenticated with exact spend lifecycle evidence' \
  v3015_wallet_delta_is_safe "$spent_synthetic"
# These are literal jq programs; their $payout/$source names belong to jq.
# shellcheck disable=SC2016
for synthetic_mutation in \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout | .transaction_evidence[$payout].shadow_transaction.schema="wrong"' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout | .transaction_evidence[$payout].active_chain_hash=("f"*64)' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout | .transaction_evidence[$payout].active_block.tx=[]' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout |
       .transaction_evidence[$payout].source_transaction.vout[0].scriptPubKey.asm="OP_RETURN 00"' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout |
       .transaction_evidence[$payout].source_transaction.vin[0].txid=("f"*64)' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout |
       .transaction_evidence[$payout].shadow_transaction.pow_claim_source.proof_version=2' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout |
       .transaction_evidence[$payout].shadow_transaction.lifecycle_category="other"' \
    '.transactions[0].amount=6' \
    '.transactions[0].address="qq-other"' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout | .transaction_evidence[$payout].shadow_transaction.scriptPubKey="0"' \
    '(.transaction_evidence | to_entries[] | select(.value.kind == "synthetic_payout") |
       .key) as $payout | .transaction_evidence[$payout].shadow_transaction.address="qq-other"'; do
    bad_after=$(jq -c ".after | $synthetic_mutation" <<<"$synthetic_delta")
    bad_delta=$(v3015_make_wallet_audit "$synthetic_before" "$bad_after")
    expect_fail "synthetic payout rejects ${synthetic_mutation}" \
      v3015_wallet_delta_is_safe "$bad_delta"
done
expect_pass 'authenticated unspent same-anchor claim delta is safe' \
  v3015_wallet_delta_is_safe "$claim_delta"
claim_before=$(jq -c '.before' <<<"$claim_delta")
resolved_after=$(jq -c '.after |
  .recovery.component_details[0] |= (
    .anchor_unspent=false | .classification="resolved_on_active_chain" |
    .all_claims_quarantined=false |
    .nodes[0] |= (.active_chain_confirmed=true | .quarantined=false |
      .disposition="confirmed")) |
  .recovery.blocking_components=0 | .recovery.resolved_components=1 |
  .recovery.quarantined_claim_objects=0 |
  .transactions[0].confirmations=1' <<<"$claim_delta")
resolved_delta=$(v3015_make_wallet_audit "$claim_before" "$resolved_after")
expect_pass 'candidate-authored added claim remains classified after resolving on chain' \
  v3015_wallet_delta_is_safe "$resolved_delta"
retired_after=$(jq -c '.after |
  .recovery.component_details[0] |= (
    .classification="retired_on_active_branch" |
    .all_claims_quarantined=false | .all_claims_expired_locally_retired=true |
    .nodes[0] |= (.abandoned=true | .expired_locally_retired=true |
      .quarantined=false | .disposition="origin_expired")) |
  .recovery.blocking_components=0 | .recovery.retired_components=1 |
  .recovery.retired_claim_objects=1 | .recovery.quarantined_claim_objects=0 |
  .transactions[0].abandoned=true' <<<"$claim_delta")
retired_delta=$(v3015_make_wallet_audit "$claim_before" "$retired_after")
expect_pass 'exact retired candidate claim permits its Core-bound abandoned row' \
  v3015_wallet_delta_is_safe "$retired_delta"
unbound_abandoned_after=$(jq -c '. |
  .recovery.component_details[0].nodes[0].expired_locally_retired=false' \
  <<<"$retired_after")
unbound_abandoned_delta=$(v3015_make_wallet_audit \
  "$claim_before" "$unbound_abandoned_after")
expect_fail 'abandoned candidate claim requires exact expired-retired node status' \
  v3015_wallet_delta_is_safe "$unbound_abandoned_delta"
expect_pass 'same-input sibling roots preserve authenticated lineage topology' \
  v3015_wallet_delta_is_safe "$(make_sibling_claim_delta)"
expect_pass 'wallet delta accepts four claims with two graph roots and two descendants' \
  v3015_wallet_delta_is_safe "$(make_graph_descendant_delta)"
expect_pass 'metadata-implicit explicit-authored root may anchor one valid lineaged descendant' \
  v3015_wallet_delta_is_safe "$(make_legacy_root_descendant_delta)"
bad_after=$(jq -c '.after | .recovery.component_details[0].nodes[0] |=
  (.proof_version=2 | .proof_origin_bound=true | .proof_input_bound=true)' <<<"$claim_delta")
bad_delta=$(v3015_make_wallet_audit "$claim_before" "$bad_after")
expect_fail 'candidate-added QQP2 claim rejects a contradictory true/true proof tuple' \
  v3015_wallet_delta_is_safe "$bad_delta"
sibling_delta=$(make_sibling_claim_delta)
sibling_before=$(jq -c '.before' <<<"$sibling_delta")
bad_after=$(jq -c '.after | (.recovery.component_details[0].nodes |
  sort_by(.lineage_ordinal) | .[1].txid) as $child |
  (.recovery.component_details[0].nodes[] | select(.txid == $child) |
    .lineage_ordinal)=2' <<<"$sibling_delta")
bad_delta=$(v3015_make_wallet_audit "$sibling_before" "$bad_after")
expect_fail 'candidate-added claim rejects a lineage ordinal gap' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_after=$(jq -c '.after | (.recovery.component_details[0].nodes |
  sort_by(.lineage_ordinal) | .[1].txid) as $child |
  (.recovery.component_details[0].nodes[] | select(.txid == $child)) |=
    (.lineage_ordinal=0 | .lineage_root_txid=$child |
     .lineage_parent_txid=("0"*64))' <<<"$sibling_delta")
bad_delta=$(v3015_make_wallet_audit "$sibling_before" "$bad_after")
expect_fail 'candidate-added claims reject a second canonical schema root' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.recovery.confirmed_resolution_fees=0.01')
expect_pass 'derived confirmed-fee counter drift alone is not a wallet mutation' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.quantum_inventory.count=2')
expect_fail 'new key fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.recovery.automatic_fee_exposure_in_window=0.01')
expect_pass 'derived rolling exposure drift alone is not a wallet mutation' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.before.recovery.database_outcome_ambiguous=true')
expect_fail 'candidate-native locked baseline rejects database ambiguity' \
  v3015_wallet_delta_is_safe "$bad_delta"
carried_recovery=$(make_recovery | jq '
  .pending_manual_resolutions=3 | .pending_automatic_resolutions=2 |
  .confirmed_manual_resolutions=4 | .confirmed_automatic_resolutions=1 |
  .confirmed_resolution_fees=0.25 | .automatic_actions_in_window=5 |
  .automatic_fee_exposure_in_window=0.5')
carried_before=$(make_wallet_state "$carried_recovery" '' 0 '' 0)
carried_after=$(make_wallet_state "$carried_recovery")
carried_audit=$(v3015_make_wallet_audit "$carried_before" "$carried_after")
expect_pass 'candidate-native audit accepts unchanged nonzero pending and fee exposure' \
  v3015_wallet_delta_is_safe "$carried_audit"
fee_after=$(jq '.recovery.confirmed_resolution_fees += 0.01' <<<"$carried_after")
fee_audit=$(v3015_make_wallet_audit "$carried_before" "$fee_after")
expect_pass 'candidate-native audit accepts recomputed fee-counter drift without a new tx' \
  v3015_wallet_delta_is_safe "$fee_audit"
exposure_after=$(jq '.recovery.automatic_fee_exposure_in_window += 0.01' <<<"$carried_after")
exposure_audit=$(v3015_make_wallet_audit "$carried_before" "$exposure_after")
expect_pass 'candidate-native audit accepts recomputed rolling-exposure drift without a new tx' \
  v3015_wallet_delta_is_safe "$exposure_audit"
derived_after=$(jq '.recovery.pending_manual_resolutions=2 |
  .recovery.pending_automatic_resolutions=1 |
  .recovery.confirmed_manual_resolutions=5 |
  .recovery.confirmed_automatic_resolutions=2 |
  .recovery.confirmed_resolution_fees=0.75 |
  .recovery.automatic_actions_in_window=1 |
  .recovery.automatic_fee_exposure_in_window=0.1' <<<"$carried_after")
derived_audit=$(v3015_make_wallet_audit "$carried_before" "$derived_after")
expect_pass 'pending/confirmed rolling counters may drift with unchanged transaction identity' \
  v3015_wallet_delta_is_safe "$derived_audit"
resolution_after=$(jq '.transactions=[{txid:("f"*64),category:"send",abandoned:false,
  qq_shadow_pow_resolution_schema:"1",fee:0.01}] | .wallet.txcount=1' <<<"$carried_after")
resolution_audit=$(v3015_make_wallet_audit "$carried_before" "$resolution_after")
expect_fail 'candidate-native audit rejects a newly observed resolution transaction' \
  v3015_wallet_delta_is_safe "$resolution_audit"
bad_delta=$(make_delta | jq '.delta.removed_txids=[("a"*64)]')
expect_fail 'declared removed txid mismatch fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.after.wallet.txcount=1')
expect_fail 'incomplete transaction inventory fails wallet contract' v3015_wallet_delta_is_safe "$bad_delta"
policy_delta=$(make_delta | jq '.after.recovery.policy.mode="pause_and_ask" |
  .after.recovery.policy.choice_recorded=true')
expect_pass 'nonautomatic recovery policy detail may drift without a wallet mutation' \
  v3015_wallet_delta_is_safe "$policy_delta"
bad_delta=$(make_delta | jq '.after.recovery.policy.automatic_enabled=true')
expect_fail 'automatic recovery policy fails candidate-native safety' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(make_delta | jq '.delta.transactions=[{txid:("a"*64),
  authenticated_same_anchor_claim:true,normal_coinstake:true,
  authenticated_synthetic_payout:false,exactly_one_allowed_class:true,
  per_tx_abandoned:false,cleanup:false,recovery:false,resolution:false,recovery_fee:0}]')
expect_fail 'fabricated or multiply classified transaction fails wallet contract' \
  v3015_wallet_delta_is_safe "$bad_delta"
bad_delta=$(jq '.after.recovery.component_details[0].anchor_unspent=false' <<<"$claim_delta")
expect_pass 'candidate-added claim classification does not veto later spent-anchor status' \
  v3015_wallet_delta_is_safe "$bad_delta"
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
image_manifest=${image##*@sha256:}
topology="$package_dir/topology.map"
topology_lookup_equals()
{
    [[ "$(v3015_topology_lookup "$1" "$2")" == "$3" ]]
}
expect_pass 'sealed logical-node topology is complete and unambiguous' \
  v3015_validate_topology_map "$topology"
expect_pass 'logical node1 maps to recorded zero-padded service and unsuffixed container' \
  topology_lookup_equals "$topology" 1 $'node01\tblackcoin-v4-gui'
expect_pass 'logical node9 maps to recorded zero-padded service' \
  topology_lookup_equals "$topology" 9 $'node09\tblackcoin-v4-gui-9'
expect_pass 'logical node10 maps to recorded unpadded service' \
  topology_lookup_equals "$topology" 10 $'node10\tblackcoin-v4-gui-10'
expect_fail 'topology lookup rejects node outside the fleet' \
  v3015_topology_lookup "$topology" 33

missing_topology="$tmp/topology-missing.map"
awk '$1 != 32' "$topology" >"$missing_topology"
expect_fail 'topology rejects a missing logical node' \
  v3015_validate_topology_map "$missing_topology"
duplicate_node_topology="$tmp/topology-duplicate-node.map"
awk '$1 == 32 {$1=31} {print}' "$topology" >"$duplicate_node_topology"
expect_fail 'topology rejects a duplicate logical node' \
  v3015_validate_topology_map "$duplicate_node_topology"
duplicate_service_topology="$tmp/topology-duplicate-service.map"
awk '$1 == 32 {$2="node31"} {print}' "$topology" >"$duplicate_service_topology"
expect_fail 'topology rejects an ambiguous Compose service' \
  v3015_validate_topology_map "$duplicate_service_topology"
duplicate_container_topology="$tmp/topology-duplicate-container.map"
awk '$1 == 32 {$3="blackcoin-v4-gui-31"} {print}' "$topology" >"$duplicate_container_topology"
expect_fail 'topology rejects an ambiguous container name' \
  v3015_validate_topology_map "$duplicate_container_topology"
leading_zero_topology="$tmp/topology-leading-zero.map"
awk '$1 == 1 {$1="01"} {print}' "$topology" >"$leading_zero_topology"
expect_fail 'topology rejects noncanonical logical node numbers' \
  v3015_validate_topology_map "$leading_zero_topology"
extra_field_topology="$tmp/topology-extra-field.map"
awk '$1 == 1 {$0=$0 " extra"} {print}' "$topology" >"$extra_field_topology"
expect_fail 'topology rejects rows with hidden extra fields' \
  v3015_validate_topology_map "$extra_field_topology"

compose_topology=$(jq -Rn '
  [inputs | select(length > 0 and (startswith("#") | not)) | split(" ") |
    {key:.[1],value:{container_name:.[2]}}] | {services:(from_entries)}' <"$topology")
expect_pass 'Compose model exactly matches the sealed topology' \
  v3015_compose_topology_matches "$topology" "$compose_topology"
expect_fail 'Compose topology rejects a missing service' \
  v3015_compose_topology_matches "$topology" \
  "$(jq 'del(.services.node32)' <<<"$compose_topology")"
expect_fail 'Compose topology rejects an extra service' \
  v3015_compose_topology_matches "$topology" \
  "$(jq '.services.extra={container_name:"extra-container"}' <<<"$compose_topology")"
expect_fail 'Compose topology rejects duplicate container ownership' \
  v3015_compose_topology_matches "$topology" \
  "$(jq '.services.node32.container_name=.services.node31.container_name' <<<"$compose_topology")"

expect_pass 'regular Compose overlay renders' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes='1 31' -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q -- '- -powmining=1'"
expect_pass 'Free Claim overlay hard-disables regular PoW' bash -c \
  "awk -v image_ref='$image' -v role=free_claim -v nodes=30 -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q -- '- -powmining=0'"
expect_pass 'Compose wrapper body has reviewed exact hash' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes=1 -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | awk '/- \|/{body=1;next} /      - node1-v3015-rollout/{exit} body{sub(/^          /,\"\");print}' | sed 's/[$][$]/$/g' | sha256sum | grep -q '^753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4'"
expect_pass 'Compose overlay addresses recorded node01 for logical node1' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes=1 -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q '^  node01:'"
expect_pass 'Compose overlay addresses recorded node09 for logical node9' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes=9 -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q '^  node09:'"
expect_pass 'Compose overlay preserves recorded node10 for logical node10' bash -c \
  "awk -v image_ref='$image' -v role=regular -v nodes=10 -v topology_file='$topology' -f '$package_dir/render_compose_runtime.awk' /dev/null | grep -q '^  node10:'"
expect_fail 'Compose overlay rejects missing topology authority' awk -v image_ref="$image" -v role=regular -v nodes=1 -f "$package_dir/render_compose_runtime.awk" /dev/null
expect_fail 'Compose overlay rejects incomplete topology authority' awk -v image_ref="$image" -v role=regular -v nodes=1 -v topology_file="$missing_topology" -f "$package_dir/render_compose_runtime.awk" /dev/null
expect_fail 'Compose overlay rejects mutable tag' awk -v image_ref=example:latest -v role=regular -v nodes=1 -v topology_file="$topology" -f "$package_dir/render_compose_runtime.awk" /dev/null
expect_fail 'Compose overlay rejects node outside fleet' awk -v image_ref="$image" -v role=regular -v nodes=33 -v topology_file="$topology" -f "$package_dir/render_compose_runtime.awk" /dev/null

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
fixture_source='0e62ec0af3daefba30f87382d9b3cc8b00224e62'
fixture_tree='d460eee11b7c8c6d5fffe6935f2e9a5d58e18aac'
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
    printf "CORE_CI_RUN_ID='31710198720'\nCORE_CI_HEAD_SHA='%s'\nCORE_CI_CONCLUSION='success'\n" "$fixture_source"
    printf "CORE_CI_WORKFLOW='.github/workflows/pr-gate.yml'\n"
    printf "CANDIDATE_ARTIFACT_NAME='v3015-linux-x86_64-fixture'\nCANDIDATE_ARTIFACT_RUN_ID='31710198720'\nCANDIDATE_ARTIFACT_RUN_ATTEMPT='1'\n"
    printf "CANDIDATE_IMAGE_REF='%s'\nCANDIDATE_IMAGE_ID='%s'\n" "$image" "$image_id"
    printf "CANDIDATE_BUNDLE_SHA256='%s'\nCANDIDATE_OCI_ARCHIVE_SHA256='%s'\n" "$hex3" "$hex4"
    printf "CANDIDATE_OCI_MANIFEST_SHA256='%s'\nCANDIDATE_BLACKCOIND_SHA256='%s'\n" "$image_manifest" "$hex6"
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

make_node30_samples()
{
    local observation=$1 start=$2 wallet_name=${3:-} regular
    regular=$(make_samples wait_for_next_tip 5 "$wallet_name")
    jq -cn --argjson regular "$regular" --arg observation "$observation" \
      --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg nonce "${LIVE_EXECUTION_CLEARED##*:}" --argjson start "$start" '
      $regular | to_entries | map(.key as $i | .value as $s |
        ($start + 100 + ($i * 1000)) as $sample_start |
        ($sample_start + 100) as $sample_finish |
        {sample_index:$i,observation:$observation,probe_tool_sha256:$tool,
         source_sha:$source,candidate_image_ref:$image,candidate_image_id:$image_id,
         rollout_nonce:$nonce,sample_started_unix_ms:$sample_start,
         sample_finished_unix_ms:$sample_finish,
         core_before:{bestblockhash:$s.tip,blocks:$s.height,headers:$s.height,
           initialblockdownload:false},
         core_after:{bestblockhash:$s.tip,blocks:$s.height,headers:$s.height,
           initialblockdownload:false},
         tip:$s.tip,height:$s.height,blocks:$s.height,headers:$s.height,ibd:false,
         peers_out:8,walletname:$s.walletname,loaded_wallets:$s.loaded_wallets,
         wallet_normal_unlocked:true,free_claim_healthy:true,free_claim_paused:true,
         pos:$s.staking,regular_pow:{enabled:false,hashrate:0,state:"disabled"}})'
}

make_node30_probe()
{
    local observation=$1 start=$2 wallet_name=${3:-} samples finish recheck_start payload
    samples=$(make_node30_samples "$observation" "$start" "$wallet_name")
    finish=$((start + 9000))
    recheck_start=$((start + 7000))
    payload=$(jq -cn --argjson samples "$samples" '{node:30,healthy:true,paused:true,
      wallet_normal_unlocked:true,free_claim_intent_retained:true,
      locked_restart:{free_claim_intent_retained:true},samples:$samples}')
    jq -cn --arg observation "$observation" --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
      --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg nonce "${LIVE_EXECUTION_CLEARED##*:}" \
      --argjson start "$start" --argjson finish "$finish" \
      --argjson recheck_start "$recheck_start" --argjson payload "$payload" '
      {schema:2,observation:$observation,probe_tool_sha256:$tool,source_sha:$source,
       candidate_image_ref:$image,candidate_image_id:$image_id,rollout_nonce:$nonce,
       probe_started_unix_ms:$start,probe_finished_unix_ms:$finish,payload:$payload,
       active_chain_rechecks:[$payload.samples[] |
         {sample_index:.sample_index,blockhash:.tip,height:.height,confirmations:2,
          rechecked_unix_ms:($recheck_start + .sample_index)}]}'
}

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
  result:"passed",candidate_source_sha:$source,
  automatic_recovery_unauthorized_continuously:true,baseline_health_gate_passed:true,
  baseline_precondition_sha256:("1"*64),baseline_cutover_stop_sha256:("2"*64),
  candidate_final_recovery_sha256:("3"*64),
  candidate_final_resolution_txids_sha256:("4"*64),
  candidate_locked_resolution_txids_sha256:("e"*64),candidate_locked_sync_sha256:("f"*64),
  candidate_native_resolution_txids_unchanged:true,
  promoted_no_rewind_marker_verified:true,marker_sha256:$marker,
  snapshots_absent_before_launch:true,datasets_preserved:true,candidate_running:true,
  final_container_identity_stable:true,final_container_sha256:("5"*64),
  final_envelope_sha256:("6"*64),invocation_sha256:("7"*64),
  live_dataset_identity_sha256:("8"*64),
  wallet_chain_synchronized_before_unlock:true,normal_unlock_completed:true,pos_active:true,
  pos_explicitly_enabled:true,pow_policy_restored:true,p2p_ready:true,typed_gate_safe:true,
  package_sha256sums_sha256:$package,phase_a_result_sha256:$phase_a,
  phase_b_progress_sha256:("9"*64),phase_b_script_sha256:$script,
  phase_b_tooling_identity_sha256:$tooling,pre_result_manifest_sha256:("a"*64),
  quantum_keys_unchanged:true,no_new_fee_bearing_recovery_wallet_transaction:true,
  wallet_delta_fully_classified:true,only_allowed_wallet_delta_classes_added:true,
  failure_policy:"contain-stop-preserve",old_core_autostarted:false,
  data_rewind_performed:false,storage_absence_recheck_sha256:("b"*64),
  tooling_commit:$tooling_commit,typed_contract_sha256:$contract,verifier_sha256:$verifier,
  wallet_delta_raw_sha256:("c"*64),wallet_delta_sha256:("d"*64)}' \
  >"$phase_b_fixture/RESULT.json"
expect_pass 'completed no-rewind Phase-B contract passes' v3015_phase_b_evidence_is_valid \
  "$phase_b_fixture/RESULT.json" "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-recovery-authority.json"
jq '.automatic_recovery_unauthorized_continuously=false' \
  "$phase_b_fixture/RESULT-recovery-authority.json" >"$phase_b_fixture/change" &&
  mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-recovery-authority.json"
expect_fail 'Phase-B contract requires continuous no-automatic-recovery authority' \
  v3015_phase_b_evidence_is_valid "$phase_b_fixture/RESULT-recovery-authority.json" \
  "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-stale-counter.json"
jq '.recovery_counters_unchanged=true' "$phase_b_fixture/RESULT-stale-counter.json" \
  >"$phase_b_fixture/change" &&
  mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-stale-counter.json"
expect_fail 'Phase-B contract rejects obsolete cross-version counter authority' \
  v3015_phase_b_evidence_is_valid "$phase_b_fixture/RESULT-stale-counter.json" \
  "$phase_b_fixture/PROMOTED_NO_REWIND"
cp "$phase_b_fixture/RESULT.json" "$phase_b_fixture/RESULT-stale-payout.json"
jq '.payout_unchanged=true' "$phase_b_fixture/RESULT-stale-payout.json" \
  >"$phase_b_fixture/change" &&
  mv "$phase_b_fixture/change" "$phase_b_fixture/RESULT-stale-payout.json"
expect_fail 'Phase-B contract rejects process-local future-payout equality authority' \
  v3015_phase_b_evidence_is_valid "$phase_b_fixture/RESULT-stale-payout.json" \
  "$phase_b_fixture/PROMOTED_NO_REWIND"
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
    core_ci:{run_id:31710198720,head_sha:$source,conclusion:"success",workflow:".github/workflows/pr-gate.yml"},
    artifact:{name:"v3015-linux-x86_64-fixture",run_id:31710198720,run_attempt:1},
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

rollout_nonce=0123456789abcdef0123456789abcdef
jq -cn --arg source "$SOURCE_SHA" --arg phase_b "$PHASE_B_RESULT_SHA256" \
  --arg package "$PACKAGE_SHA256SUMS_SHA256" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --arg nonce "$rollout_nonce" \
  '{schema:1,source_sha:$source,
  phase_b_result_sha256:$phase_b,package_sha256sums_sha256:$package,
  node30_probe_tool_sha256:$probe_tool,nonce:$nonce,
  live_execution_confirmation:("v30.1.5:"+$source+":"+$nonce),
  native_restart_confirmation:("v30.1.5-native-restart:"+$source+":"+$nonce)}' \
  >"$evidence/rollout-authority.json"
rollout_authority_sha=$(sha256sum "$evidence/rollout-authority.json" | awk '{print $1}')

samples=$(make_samples wait_for_next_tip 5 default_wallet)
locked=$(make_locked)
migration=$(make_preunlock_migration default_wallet)
candidate_before=$(jq -c '.after' <<<"$migration")
candidate_final=$(jq -c '.after | .wallet.unlocked_until=9999999999' <<<"$migration")
delta=$(v3015_make_wallet_audit "$candidate_before" "$candidate_final")
for node in $(seq 1 29) 31 32; do
    jq -cn --argjson node "$node" --arg source "$SOURCE_SHA" --argjson locked "$locked" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg nonce "$rollout_nonce" --arg authority "$rollout_authority_sha" \
      --argjson migration "$migration" --argjson samples "$samples" \
      --argjson delta "$delta" '{schema:1,node:$node,
      source_sha:$source,rollout_nonce:$nonce,rollout_authority_sha256:$authority,
      network_version:300105,subversion:"/Blackcoin:30.1.5/",
      container_id_before:("d"*64),container_id_after_recreate:("e"*64),
      restart_performed:true,container_recreated:true,normal_unlock_only:true,
      repair_rpcs:[],data_rewind_used:false,containment_only_on_failure:true,
      invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
        entrypoint_body_sha256:"753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4",
        runtime_argv_sha256:("c"*64),config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
          "-powminingthreads=1","-powminingcpu=1"]},
      locked_restart:$locked,preunlock_migration:$migration,
      samples:$samples,wallet_audit:$delta}' \
      >"$(printf '%s/node-%02d.json' "$evidence" "$node")"
done
node30_initial_start=1800000000000
node30_terminal_start=1800000020000
node30_initial=$(make_node30_probe initial "$node30_initial_start" default_wallet)
node30_terminal=$(make_node30_probe terminal "$node30_terminal_start" default_wallet)
node30_samples=$(jq -c '.payload.samples' <<<"$node30_initial")
node30_audit=$delta
printf '%s\n' "$node30_initial" >"$evidence/node-30-free-claim-probe.raw.json"
printf '%s\n' "$node30_terminal" >"$evidence/node-30-free-claim-terminal-probe.raw.json"
node30_probe_sha=$(sha256sum "$evidence/node-30-free-claim-probe.raw.json" | awk '{print $1}')
node30_terminal_probe_sha=$(sha256sum \
  "$evidence/node-30-free-claim-terminal-probe.raw.json" | awk '{print $1}')
jq -cn --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
  --arg image_id "$CANDIDATE_IMAGE_ID" --arg raw_sha "$node30_probe_sha" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --argjson migration "$migration" --argjson samples "$node30_samples" \
  --argjson audit "$node30_audit" --arg nonce "$rollout_nonce" '{schema:1,node:30,
  source_sha:$source,rollout_nonce:$nonce,network_version:300105,subversion:"/Blackcoin:30.1.5/",
  role:"free_claim",regular_pow_enabled:false,raw_probe_sha256:$raw_sha,healthy:true,
  probe_tool_sha256:$probe_tool,
  paused:true,wallet_normal_unlocked:true,container_recreated:true,restart_performed:true,
  deployment_state:"pause_preserved_pending_separate_release",
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
  preunlock_migration:$migration,
  no_recovery_or_resolution_transaction:true}' \
  >"$evidence/node-30-free-claim.json"
cp "$policy_receipt" "$evidence/runtime-policy-handoff-receipt.json"
cp "$compose_receipt" "$evidence/persistent-compose-handoff-receipt.json"
cp "$reconcile_proof" "$evidence/post-compose-reconcile-identity.json"
terminal_nodes='[]'
for node in $(seq 1 32); do
    probe_tool=''
    terminal_pos=$(jq -c '.[-1].staking' <<<"$samples")
    terminal_height=$(jq -r '.[-1].height' <<<"$samples")
    terminal_tip=$(jq -r '.[-1].tip' <<<"$samples")
    if [[ "$node" == 30 ]]; then
        result_file="$evidence/node-30-free-claim.json"
        role=free_claim
        terminal_pow=$(jq -cn '{enabled:false,autostart:false,hashrate:0,state:"disabled"}')
        healthy=true; paused=true; probe_sha=$node30_terminal_probe_sha
        probe_tool=$NODE30_FREE_CLAIM_PROBE_SHA256
        terminal_core=$(jq -cn --arg tip "$terminal_tip" --argjson height "$terminal_height" \
          '{bestblockhash:$tip,blocks:$height,headers:$height,chainwork:("9"*64),
            initialblockdownload:false}')
    else
        result_file=$(printf '%s/node-%02d.json' "$evidence" "$node")
        role=regular
        terminal_pow=$(jq -c '.[-1].pow' <<<"$samples")
        healthy=false; paused=false; probe_sha=''
        terminal_core=$(jq -c '.[-1].chain_after' <<<"$samples")
    fi
    result_sha=$(sha256sum "$result_file" | awk '{print $1}')
    row=$(jq -cn --argjson node "$node" --arg role "$role" --arg source "$SOURCE_SHA" \
      --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
      --arg tip "$terminal_tip" --argjson height "$terminal_height" \
      --argjson staking "$terminal_pos" --argjson pow "$terminal_pow" \
      --arg result_sha "$result_sha" --argjson healthy "$healthy" --argjson paused "$paused" \
      --arg probe "$probe_sha" --arg probe_tool "$probe_tool" \
      --argjson core "$terminal_core" \
      '{node:$node,role:$role,source_sha:$source,network_version:300105,
      subversion:"/Blackcoin:30.1.5/",container_image_ref:$image,container_image_id:$image_id,
      chain:{bestblockhash:$tip,blocks:$height,headers:$height,
        chainwork:$core.chainwork,initialblockdownload:false},
      core_before:$core,core_after:$core,
      network:{connections_out:8},wallet:{walletname:"default_wallet",private_keys_enabled:true,
        unlocked_until:9999999999},loaded_wallets:["default_wallet"],
      staking:$staking,pow:$pow,pos_contract_passed:true,
      pow_contract_passed:($role == "regular"),free_claim_healthy:$healthy,
      free_claim_paused:$paused,free_claim_probe_output_sha256:
        (if $role == "free_claim" then $probe else null end),node_result_sha256:$result_sha}')
    row=$(jq -c --arg tool "$probe_tool" \
      '.free_claim_probe_tool_sha256=(if .role == "free_claim" then $tool else null end)' \
      <<<"$row")
    terminal_nodes=$(jq -cn --argjson old "$terminal_nodes" --argjson row "$row" '$old+[$row]')
done
jq -cn --arg source "$SOURCE_SHA" --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$node30_terminal_probe_sha" --arg nonce "$rollout_nonce" \
  --argjson nodes "$terminal_nodes" '{schema:1,
  source_sha:$source,rollout_nonce:$nonce,captured_utc:"2026-08-10T00:00:00Z",nodes:$nodes,
  deployment_state:"pause_preserved_pending_separate_release",
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
  --arg nonce "$rollout_nonce" \
  --arg policy_receipt "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" \
  --arg compose_receipt "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" \
  --arg compose_sha "$FINAL_COMPOSE_SHA256" --arg policy_sha "$FINAL_IMAGE_POLICY_SHA256" \
  --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
  --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$node30_terminal_probe_sha" \
  '{schema:1,transaction:"v30.1.5-fleet-rollout",
  source_sha:$source,rollout_nonce:$nonce,
  status:"PAUSE_PRESERVED_PENDING_SEPARATE_RELEASE",
  deployment_state:"pause_preserved_pending_separate_release",terminal_census_sha256:$census,
  pos_active:32,pos_active_nodes:[range(1;33)],regular_pow_operational:31,
  regular_pow_nodes:([range(1;30)] + [31,32]),node30_role:"free_claim",
  node30_free_claim_healthy:true,node30_free_claim_paused:true,data_rewind_used:false,
  node30_free_claim_probe_tool_sha256:$tool,node30_terminal_probe_sha256:$terminal_probe,
  runtime_policy_handoff_receipt_sha256:$policy_receipt,
  persistent_compose_handoff_receipt_sha256:$compose_receipt,
  final_compose_sha256:$compose_sha,final_image_policy_sha256:$policy_sha,
  post_compose_reconcile_identity_sha256:$reconcile,
  containment_only_failure_policy:true}' >"$evidence/fleet-result.json"
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
node30_receive_before=$(jq -c '.wallet_audit.before' \
  "$evidence/node-30-free-claim.json")
node30_receive_incoming=$(jq -c '.after' <<<"$(make_ordinary_receive_delta)")
node30_receive_after=$(jq -cn --argjson before "$node30_receive_before" \
  --argjson incoming "$node30_receive_incoming" '
  $before | .transactions=$incoming.transactions |
  .transaction_evidence=$incoming.transaction_evidence |
  .wallet.txcount=($before.wallet.txcount + 1)')
node30_receive_audit=$(v3015_make_wallet_audit \
  "$node30_receive_before" "$node30_receive_after")
jq --argjson audit "$node30_receive_audit" '.wallet_audit=$audit' \
  "$evidence/node-30-free-claim.json" >"$tmp/node30-safe-receive.json"
expect_pass 'node30 result permits only an exactly authenticated external receive addition' \
  v3015_node30_result_is_valid "$tmp/node30-safe-receive.json" \
  "$evidence/node-30-free-claim-probe.raw.json" \
  "$evidence/rollout-authority.json"
expect_pass 'reviewed canonical candidate digest identity is accepted' \
  v3015_release_identity_is_valid "$evidence/release-identity.json"

release_manifest_cross_binding_fails()
{
    local wrong_manifest release="$tmp/release-manifest-mismatch.json"
    wrong_manifest=$(printf '5%.0s' {1..64})
    jq --arg manifest "$wrong_manifest" '.candidate_oci_manifest_sha256=$manifest' \
      "$evidence/release-identity.json" >"$release"
    CANDIDATE_OCI_MANIFEST_SHA256="$wrong_manifest" \
      v3015_release_identity_is_valid "$release"
}
expect_fail 'release identity cannot cross-bind an OCI manifest different from its image digest' \
  release_manifest_cross_binding_fails

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
              "$node30_terminal_probe_sha" "$evidence/rollout-authority.json"
            ;;
        terminal-fleet-census.json)
            v3015_terminal_census_is_valid "$copy" "$evidence" \
              "$evidence/rollout-authority.json"
            ;;
        node-30-free-claim.json)
            v3015_node30_result_is_valid "$copy" \
              "$evidence/node-30-free-claim-probe.raw.json" \
              "$evidence/rollout-authority.json"
            ;;
        node-30-free-claim-probe.raw.json)
            v3015_node30_result_is_valid "$evidence/node-30-free-claim.json" "$copy" \
              "$evidence/rollout-authority.json"
            ;;
        node-30-free-claim-terminal-probe.raw.json)
            v3015_node30_probe_output_is_valid "$copy" terminal
            ;;
        node-[0-9][0-9].json)
            node=${file#node-}; node=${node%.json}; node=$((10#$node))
            v3015_node_result_is_valid "$copy" "$node" \
              "$evidence/rollout-authority.json"
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
expect_fail 'verifier rejects premature Free-Claim unpause' mutate_fixture unpaused '.paused=false' node-30-free-claim.json
expect_fail 'verifier rejects false PoS count' mutate_fixture pos31 '.pos_active=31' fleet-result.json
expect_fail 'verifier rejects recovery transaction claim' mutate_fixture recovery '.recovery_transactions_created=true' fleet-result.json
expect_fail 'verifier rejects unsafe node gate' mutate_fixture unsafe '.samples[1].pow.mining_gate_unsafe_components=1' node-01.json
expect_fail 'verifier rejects repair RPC evidence' mutate_fixture repair '.repair_rpcs=["worker-enable"]' node-02.json
expect_fail 'verifier rejects a new wallet resolution-fee record' mutate_fixture fee \
  '.wallet_audit.after.transactions += [{txid:("f"*64),category:"send",abandoned:false,
    qq_shadow_pow_resolution_schema:"1",fee:0.01}] |
   .wallet_audit.after.wallet.txcount += 1' node-03.json
expect_fail 'verifier rejects a replayed nonconsecutive tip' mutate_fixture stale \
  '.[4].tip=.[0].tip | .[4].pow.claim_inventory_tip=.[0].tip |
   .[4].wallet_processed_tip=.[0].tip | .[4].action_freshness.tip=.[0].tip' node-04.json
expect_fail 'verifier rejects release tooling identity mismatch' mutate_fixture tooling \
  '.candidate_tooling_sha256 = ("0"*64)' release-identity.json
expect_fail 'verifier rejects authority nonce mismatch' mutate_fixture nonce \
  '.nonce = ("f"*32)' rollout-authority.json
expect_fail 'regular node result rejects a prior-run rollout nonce' mutate_fixture nodenonce \
  '.rollout_nonce = ("f"*32)' node-01.json
expect_fail 'node30 result rejects a prior-run rollout nonce' mutate_fixture node30nonce \
  '.rollout_nonce = ("f"*32)' node-30-free-claim.json
expect_fail 'terminal census rejects a prior-run rollout nonce' mutate_fixture censusnonce \
  '.rollout_nonce = ("f"*32)' terminal-fleet-census.json
expect_fail 'fleet result rejects a prior-run rollout nonce' mutate_fixture fleetnonce \
  '.rollout_nonce = ("f"*32)' fleet-result.json
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
expect_fail 'terminal census rejects a regular-node mixed Core cut' mutate_fixture terminalmixedtip \
  '.nodes[0].core_after.bestblockhash=("f"*64)' terminal-fleet-census.json
expect_fail 'terminal census rejects a missing loaded wallet identity' mutate_fixture terminalwalletmissing \
  '.nodes[0].loaded_wallets=[]' terminal-fleet-census.json
expect_fail 'regular result binds every sample to baseline wallet identity' mutate_fixture samplewalletdrift \
  '.samples[].walletname="other" | .samples[].loaded_wallets=["other"]' node-01.json

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
expect_fail 'node30 probe rejects legacy schema one' mutate_fixture oldschema \
  '.schema=1' node-30-free-claim-terminal-probe.raw.json
expect_fail 'node30 probe rejects extra outer fields' mutate_fixture outerextra \
  '.unexpected=true' node-30-free-claim-terminal-probe.raw.json
expect_fail 'node30 probe nonce is bound to the rollout authority' mutate_fixture noncedrift \
  '.rollout_nonce=("f"*32) | .payload.samples[].rollout_nonce=("f"*32)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'node30 initial probe is bound to the reviewed tool bytes' mutate_fixture initialtool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim-probe.raw.json
expect_fail 'node30 result records the reviewed probe tool separately' mutate_fixture resulttool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim.json
expect_fail 'terminal node30 probe independently requires the pause-preserved state' mutate_fixture terminalunpause \
  '.payload.paused=false' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe is bound to the reviewed tool bytes' mutate_fixture terminaltool \
  '.probe_tool_sha256=("f"*64)' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample is bound to its observation' mutate_fixture sampleobservation \
  '.payload.samples[1].observation="initial"' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample is bound to source identity' mutate_fixture samplesource \
  '.payload.samples[1].source_sha=("f"*40)' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample is bound to image reference' mutate_fixture sampleimage \
  '.payload.samples[1].candidate_image_ref="example.invalid/other@sha256:"+("f"*64)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample is bound to image ID' mutate_fixture sampleimageid \
  '.payload.samples[1].candidate_image_id="sha256:"+("f"*64)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample is bound to probe tool' mutate_fixture sampletool \
  '.payload.samples[1].probe_tool_sha256=("f"*64)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample indices are contiguous' mutate_fixture sampleindex \
  '.payload.samples[2].sample_index=9' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample rejects an extra field' mutate_fixture sampleextra \
  '.payload.samples[2].unexpected=true' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 regular-PoW projection rejects contradictory extras' \
  mutate_fixture powextra '.payload.samples[2].regular_pow.autostart=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 Core bracket rejects matched extra fields' mutate_fixture coreextra \
  '.payload.samples[2].core_before.unexpected=true |
   .payload.samples[2].core_after.unexpected=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 Core bracket must be stable' mutate_fixture corechanged \
  '.payload.samples[2].core_after.headers += 1' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 top-level tip is bound to Core bracket' mutate_fixture coretip \
  '.payload.samples[2].core_before.bestblockhash=("f"*64) |
   .payload.samples[2].core_after.bestblockhash=("f"*64)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 PoS height is contemporaneous with Core' mutate_fixture posheight \
  '.payload.samples[2].pos.blocks += 1 | .payload.samples[2].pos.active_blocks += 1' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 active-chain recheck binds hash' mutate_fixture recheckhash \
  '.active_chain_rechecks[2].blockhash=("f"*64)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 active-chain recheck binds height' mutate_fixture recheckheight \
  '.active_chain_rechecks[2].height += 1' node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 active-chain recheck rejects an extra field' \
  mutate_fixture recheckextra '.active_chain_rechecks[2].unexpected=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 active-chain recheck requires active confirmation' \
  mutate_fixture recheckconfirm '.active_chain_rechecks[2].confirmations=0' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 rechecks begin after the complete external probe' \
  mutate_fixture earlyrecheck \
  '.active_chain_rechecks[0].rechecked_unix_ms=.payload.samples[0].sample_finished_unix_ms' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 recheck timestamps cannot run backward' mutate_fixture recheckbackward \
  '.active_chain_rechecks[2].rechecked_unix_ms=
    (.active_chain_rechecks[1].rechecked_unix_ms-1)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 recheck must precede envelope finish' mutate_fixture rechecklate \
  '.active_chain_rechecks[2].rechecked_unix_ms=(.probe_finished_unix_ms+1)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample cannot predate its envelope' mutate_fixture sampleearly \
  '.payload.samples[0].sample_started_unix_ms=(.probe_started_unix_ms-1)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample cannot finish before it starts' mutate_fixture samplebackward \
  '.payload.samples[2].sample_finished_unix_ms=
    (.payload.samples[2].sample_started_unix_ms-1)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 sample windows cannot overlap' mutate_fixture sampleoverlap \
  '.payload.samples[2].sample_started_unix_ms=
    (.payload.samples[1].sample_finished_unix_ms-1)' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 copied initial payload cannot masquerade by outer label' \
  mutate_fixture copiedinitial \
  '.observation="terminal"' node-30-free-claim-probe.raw.json
expect_fail 'terminal node30 probe rejects contradictory recovery payload fields' \
  mutate_fixture terminalextra '.payload.recovery_transaction_created=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects contradictory regular-PoW payload fields' \
  mutate_fixture terminalpow '.payload.regular_pow_enabled=true' \
  node-30-free-claim-terminal-probe.raw.json
expect_fail 'terminal node30 probe rejects duplicate-tip samples' mutate_fixture terminalstale \
  '.payload.samples[4].tip=.payload.samples[0].tip |
   .payload.samples[4].core_before.bestblockhash=.payload.samples[0].tip |
   .payload.samples[4].core_after.bestblockhash=.payload.samples[0].tip |
   .active_chain_rechecks[4].blockhash=.payload.samples[0].tip' \
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
expect_pass 'node30 accepts nonautomatic recovery policy detail drift' \
  mutate_fixture node30policy \
  '.wallet_audit.after.recovery.policy.mode="pause_and_ask" |
   .wallet_audit.after.recovery.policy.choice_recorded=true' node-30-free-claim.json
expect_fail 'node30 rejects automatic recovery policy authority' mutate_fixture node30automatic \
  '.wallet_audit.after.recovery.policy.automatic_enabled=true' node-30-free-claim.json
expect_fail 'node30 independent txid comparison rejects addition' mutate_fixture node30tx \
  '.wallet_audit.delta.added_txids=[("f"*64)]' node-30-free-claim.json
expect_fail 'evidence rejects mixed post-Compose identity proof' mutate_fixture reconcilemix \
  '.source_sha=("f"*40)' post-compose-reconcile-identity.json

terminal_drift="$tmp/terminal-drift"
cp -R "$evidence" "$terminal_drift"
jq '.payload.paused=false' "$terminal_drift/node-30-free-claim-terminal-probe.raw.json" \
  >"$terminal_drift/change" &&
  mv "$terminal_drift/change" "$terminal_drift/node-30-free-claim-terminal-probe.raw.json"
make_manifest "$terminal_drift"
expect_fail 'fresh terminal probe catches a pause after initial node30 acceptance' \
  "$package_dir/verify-evidence.sh" --fixture "$env_file" "$terminal_drift"

terminal_cross_fixture()
{
    local name=$1 expression=$2 copy probe_sha
    copy="$tmp/terminal-cross-$name"
    cp -R "$evidence" "$copy"
    jq "$expression" "$copy/node-30-free-claim-terminal-probe.raw.json" >"$copy/change" &&
      mv "$copy/change" "$copy/node-30-free-claim-terminal-probe.raw.json" || return 1
    probe_sha=$(sha256sum "$copy/node-30-free-claim-terminal-probe.raw.json" | awk '{print $1}')
    jq --arg sha "$probe_sha" '.node30_terminal_probe_sha256=$sha |
      .nodes[29].free_claim_probe_output_sha256=$sha' "$copy/terminal-fleet-census.json" \
      >"$copy/change" && mv "$copy/change" "$copy/terminal-fleet-census.json" || return 1
    v3015_terminal_census_is_valid "$copy/terminal-fleet-census.json" "$copy" \
      "$copy/rollout-authority.json"
}
initial_finish=$(jq -r '.probe_finished_unix_ms' \
  "$evidence/node-30-free-claim-probe.raw.json")
expect_fail 'terminal observation must start strictly after initial completion' \
  terminal_cross_fixture chronology \
  ".probe_started_unix_ms=$initial_finish"
expect_fail 'terminal node30 samples remain bound to baseline wallet identity' \
  terminal_cross_fixture walletdrift \
  '.payload.samples[].walletname="other" | .payload.samples[].loaded_wallets=["other"]'

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
manifest_mismatch_env="$tmp/manifest-mismatch.env"
cp "$env_file" "$manifest_mismatch_env"
printf "CANDIDATE_OCI_MANIFEST_SHA256='%064d'\n" 0 >>"$manifest_mismatch_env"
expect_fail 'reviewed image digest must equal the candidate OCI manifest SHA256' bash -c \
  "source '$package_dir/lib/common.sh'; source '$manifest_mismatch_env'; v3015_validate_release_env"
expect_pass 'template binds H0e62 source/tree/run while keeping CI success pending' bash -c \
  "source '$package_dir/rollout.env.example'; [[ \"\$SOURCE_SHA\" == 0e62ec0af3daefba30f87382d9b3cc8b00224e62 && \"\$SOURCE_TREE\" == d460eee11b7c8c6d5fffe6935f2e9a5d58e18aac && \"\$SOURCE_SIGNATURE_VERIFIED\" == 1 && \"\$CORE_CI_RUN_ID\" == 31710198720 && \"\$CORE_CI_HEAD_SHA\" == \"\$SOURCE_SHA\" && \"\$CORE_CI_CONCLUSION\" == __PENDING_EXACT_SHA_CI_SUCCESS__ && \"\$CORE_CI_WORKFLOW\" == .github/workflows/pr-gate.yml ]]"
expect_fail 'recorded pending CI state remains fail-closed' bash -c \
  "source '$package_dir/lib/common.sh'; source '$package_dir/rollout.env.example'; v3015_validate_release_env"
revoked_source_env="$tmp/revoked-source.env"
cp "$env_file" "$revoked_source_env"
printf "SOURCE_SHA='309731e3340f380e48cb67f94a243725465420fb'\nSOURCE_TREE='1517a277e1ab6355db0a14ed40d21e4e5e1dc846'\nCORE_CI_HEAD_SHA='309731e3340f380e48cb67f94a243725465420fb'\n" \
  >>"$revoked_source_env"
expect_fail 'revoked predecessor source/tree cannot satisfy release validation' bash -c \
  "source '$package_dir/lib/common.sh'; source '$revoked_source_env'; v3015_validate_release_env"
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
expect_pass 'native sampler bypasses selected-family lookup for exact familyless waits' bash -c \
  "test \"\$(grep -Fc 'if [[ \"\$action\" != create_new_anchor && \"\$familyless_wait\" != true ]]; then' '$package_dir/native_restart_durability.sh')\" = 2 && grep -Fq '.mining_gate_unresolved_components == 0' '$package_dir/native_restart_durability.sh'"
expect_pass 'native sampler retains authoritative same-tip observations' bash -c \
  "! grep -Fq 'last_tip' '$package_dir/native_restart_durability.sh' && ! grep -Fq '\"\$tip\" !=' '$package_dir/native_restart_durability.sh'"
expect_pass 'regular wallet-state and liveness captures request verbose recovery detail' bash -c \
  "test \"\$(grep -Fc 'recovery=\$(rpc getpowclaimrecoveryinfo true)' '$package_dir/native_restart_durability.sh')\" = 2"
expect_pass 'regular liveness captures the signed-Core QQP4 activation receipt' bash -c \
  "grep -Fq 'qqp4_activation=\$(rpc getgoldrushstate' '$package_dir/native_restart_durability.sh' && grep -Fq 'qqp4_active_next_block' '$package_dir/native_restart_durability.sh'"
expect_pass 'node30 wallet-state capture requests verbose recovery detail' bash -c \
  "grep -Fq 'recovery=\$(node30_rpc getpowclaimrecoveryinfo true)' '$package_dir/fleet_rollout.sh'"
expect_pass 'locked restart polls only recognized Core startup transients before exact convergence' bash -c \
  "grep -Fq '\"\$locked_staking_state\" == starting' '$package_dir/native_restart_durability.sh' && grep -Fq '\"\$locked_staking_state\" == syncing' '$package_dir/native_restart_durability.sh' && grep -Fq '\"\$locked_pow_state\" == starting' '$package_dir/native_restart_durability.sh' && grep -Fq '\"\$node30_locked_staking_state\" == starting' '$package_dir/fleet_rollout.sh' && grep -Fq '\"\$node30_locked_staking_state\" == syncing' '$package_dir/fleet_rollout.sh' && ! grep -Fq initializing '$package_dir/native_restart_durability.sh' '$package_dir/fleet_rollout.sh'"
expect_pass 'wallet-delta evidence includes watch-only external receives on both lanes' bash -c \
  "grep -Fq 'transaction=\$(rpc gettransaction \"\$txid\" true true)' '$package_dir/native_restart_durability.sh' && grep -Fq 'transaction=\$(node30_rpc gettransaction \"\$txid\" true true)' '$package_dir/fleet_rollout.sh'"
expect_pass 'confirmed receive evidence binds header height active hash and block membership' bash -c \
  "grep -Fq 'active_header=\$(rpc getblockheader \"\$blockhash\")' '$package_dir/native_restart_durability.sh' && grep -Fq 'active_chain_hash=\$(rpc getblockhash \"\$blockheight\")' '$package_dir/native_restart_durability.sh' && grep -Fq 'active_block=\$(rpc getblock \"\$blockhash\" 1)' '$package_dir/native_restart_durability.sh' && grep -Fq 'active_block=\$(node30_rpc getblock \"\$blockhash\" 1)' '$package_dir/fleet_rollout.sh'"
expect_pass 'synthetic payout evidence uses active source bytes without wallet-authorship inference' bash -c \
  "grep -Fq 'shadow_transaction=\$(rpc getshadowtransaction \"\$txid\")' '$package_dir/native_restart_durability.sh' && grep -Fq 'source_transaction=\$(rpc getrawtransaction' '$package_dir/native_restart_durability.sh' && ! grep -Fq 'gettransaction \"\$source_txid\"' '$package_dir/native_restart_durability.sh' '$package_dir/fleet_rollout.sh'"
expect_pass 'node30 runtime admits only canonical safe external receive additions' bash -c \
  "grep -Fq '.safe_external_receive == true' '$package_dir/fleet_rollout.sh' && ! grep -Fq '.delta.added_txids == []' '$package_dir/fleet_rollout.sh'"
expect_pass 'v30.1.5 package does not source v30.1.4 libraries' bash -c \
  "! grep -Eq 'source .*v30[.]1[.]4' '$package_dir/fleet_rollout.sh' '$package_dir/native_restart_durability.sh' '$package_dir/verify-evidence.sh'"
# The single-quoted body is intentionally evaluated by the child Bash.
# shellcheck disable=SC2016
expect_pass 'package contains the exact twenty-one-payload reviewed inventory' bash -c \
  'set -euo pipefail
   package_dir=$1
   source "$package_dir/lib/common.sh"
   actual=$(cd "$package_dir" && find . -type f ! -name SHA256SUMS -print |
     sed "s#^[.]/##" | LC_ALL=C sort)
   expected=$(v3015_expected_package_payloads | LC_ALL=C sort)
   test "$actual" = "$expected"
   test "$(printf "%s\n" "$expected" | wc -l | tr -d " ")" = 21' \
  bash "$package_dir"
expect_pass 'maintenance include declares Bash for standalone ShellCheck' bash -c \
  "head -n 1 '$package_dir/guard_rollout_maintenance_block.sh.inc' | grep -Fqx '# shellcheck shell=bash' && shellcheck -x '$package_dir/guard_rollout_maintenance_block.sh.inc'"
expect_pass 'maintenance guard exact-checks rollout authority schema' bash -c \
  "grep -Fq '(keys | sort) ==' '$package_dir/guard_rollout_maintenance_block.sh.inc' && grep -Fq 'node30_probe_tool_sha256' '$package_dir/guard_rollout_maintenance_block.sh.inc'"
expect_pass 'terminal node30 Core sample is captured after the multi-tip probe' bash -c \
  "awk '/capture_node30_probe_evidence .*terminal/{p=NR} p && !s && /staking=.*getstakinginfo/{s=NR} p && s && !v && /v3015_pos_json_is_active/{v=NR} END{exit !(p && p<s && s<v)}' '$package_dir/fleet_rollout.sh'"
expect_pass 'node30 probe receives the complete identity challenge' bash -c \
  "grep -Fq -- '--observation \"\$observation\" --rollout-nonce \"\$nonce\"' '$package_dir/fleet_rollout.sh' && grep -Fq -- '--expected-source-sha \"\$SOURCE_SHA\"' '$package_dir/fleet_rollout.sh' && grep -Fq -- '--expected-image-ref \"\$CANDIDATE_IMAGE_REF\"' '$package_dir/fleet_rollout.sh' && grep -Fq -- '--expected-image-id \"\$CANDIDATE_IMAGE_ID\"' '$package_dir/fleet_rollout.sh' && grep -Fq -- '--expected-tool-sha256 \"\$NODE30_FREE_CLAIM_PROBE_SHA256\"' '$package_dir/fleet_rollout.sh'"
expect_pass 'node30 envelope fences tool sampling and active-chain rechecks' bash -c \
  "awk '/^capture_node30_probe_evidence\(\)/{f=1} f && !s && /started=.*date/{s=NR} f && s && !p && /node30_probe_tool.*--node/{p=NR} f && p && !h && /getblockheader/{h=NR} f && h && !x && /header[.]hash/{x=NR} f && x && !e && /finished=.*date/{e=NR} f && e && !v && /v3015_node30_probe_output_is_valid/{v=NR} f && /^}/{exit} END{exit !(s<p && p<h && h<x && x<e && e<v)}' '$package_dir/fleet_rollout.sh'"
expect_pass 'runtime invocation binds actual container image identity' bash -c \
  "grep -Fq '.[0].Image == \$image_id' '$package_dir/native_restart_durability.sh' && grep -Fq '.[0].Image == \$image_id' '$package_dir/fleet_rollout.sh' && grep -Fq \"docker inspect -f '{{.Image}}'\" '$package_dir/fleet_rollout.sh'"
expect_pass 'live scripts resolve service and container names only through sealed topology' bash -c \
  "grep -Fq 'v3015_topology_lookup' '$package_dir/native_restart_durability.sh' && grep -Fq 'v3015_topology_lookup' '$package_dir/fleet_rollout.sh' && ! grep -Eq 'service=\"node\\\$\\\{node\\\}\"|container=\"blackcoin-v4-gui-\\\$\\\{node\\\}\"|blackcoin-v4-gui-[0-9]+' '$package_dir/native_restart_durability.sh' '$package_dir/fleet_rollout.sh'"
expect_pass 'live mutation validates the rendered Compose topology before use' bash -c \
  "grep -Fq 'v3015_compose_topology_matches' '$package_dir/native_restart_durability.sh' && grep -Fq 'v3015_compose_topology_matches' '$package_dir/fleet_rollout.sh'"
expect_pass 'dedicated PoS renewal supervisor hostile suite passes' \
  bash "$package_dir/tests/pos_unlock_renewal_supervisor.sh"
expect_pass 'dedicated node30 audit-only release-gate hostile suite passes' \
  bash "$package_dir/tests/node30_free_claim_release.sh"
# The single-quoted body is intentionally evaluated by the child Bash.
# shellcheck disable=SC2016
expect_pass 'accepted source/artifact predicates contain no revoked predecessor identity' bash -c \
  '! grep -Eq "309731e3340f380e48cb67f94a243725465420fb|1517a277e1ab6355db0a14ed40d21e4e5e1dc846" \
    "$1/lib/common.sh" "$1/lib/node30_free_claim_release_contract.sh"' \
  bash "$package_dir"
# The single-quoted body is intentionally evaluated by the child Bash.
# shellcheck disable=SC2016
expect_pass 'nondeployable H0e62 integration preseal covers exact twenty-one payloads' bash -c '
  set -euo pipefail
  package_dir=$1
  actual=$(cd "$package_dir" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
  listed=$(cd "$package_dir" && awk "{print \$2}" SHA256SUMS | LC_ALL=C sort)
  test "$actual" = "$listed"
  test "$(printf "%s\n" "$listed" | uniq | wc -l | tr -d " ")" = 21
  ! grep -Eq "UNSEALED|PLACEHOLDER|__" "$package_dir/SHA256SUMS"
  (cd "$package_dir" && sha256sum --strict -c SHA256SUMS >/dev/null)
' bash "$package_dir"

printf '1..%d\n' "$tests"
if ((failures != 0)); then
    printf '%d/%d tests failed\n' "$failures" "$tests" >&2
    exit 1
fi
printf '%d/%d tests passed\n' "$tests" "$tests"
