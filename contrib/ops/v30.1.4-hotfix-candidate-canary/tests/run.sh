#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail

ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
readonly ROOT
# Tests exercise the exact provisional Core pin while keeping the independent
# candidate packaging run and artifact identities synthetic and unresolved.
export HOTFIX_CANDIDATE_SOURCE_SHA='a0695f22740e111d0487a194fb46f1bae05952c5'
export HOTFIX_CANDIDATE_RELEASE_VERSION='30.1.5'
# shellcheck source=lib/typed_contract.sh
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091 # Dynamic package root is validated before sourcing.
source "$ROOT/lib/typed_contract.sh"

tests=0
failures=0
TMP_ROOT="/private/tmp/blackcoin-hotfix-canary-tests.$(id -u).$$"
mkdir -m 700 -- "$TMP_ROOT"
TMP=$(CDPATH='' cd -P -- "$TMP_ROOT" && pwd -P)
readonly TMP
cleanup_tmp()
{
    if [[ "${HOTFIX_KEEP_TEST_TMP:-0}" == 1 ]]; then
        printf 'preserved test fixtures: %s\n' "$TMP" >&2
    else
        rm -rf -- "$TMP"
    fi
}
trap cleanup_tmp EXIT

ok()
{
    local name="$1"
    shift
    tests=$((tests + 1))
    if "$@"; then
        printf 'ok %03d - %s\n' "$tests" "$name"
    else
        printf 'not ok %03d - %s\n' "$tests" "$name"
        failures=$((failures + 1))
    fi
}

reject()
{
    local name="$1"
    shift
    tests=$((tests + 1))
    if "$@"; then
        printf 'not ok %03d - %s (unexpected pass)\n' "$tests" "$name"
        failures=$((failures + 1))
    else
        printf 'ok %03d - %s\n' "$tests" "$name"
    fi
}

mutate()
{
    local source="$1" target="$2" filter="$3"
    jq "$filter" "$source" >"$target"
}

hex64()
{
    printf '%064d' "$1"
}

NONCE='0123456789abcdef0123456789abcdef'
IMAGE_ID="sha256:$(printf 'a%.0s' {1..64})"
TIP1=$(hex64 1)
TIP2=$(hex64 2)
TIP3=$(hex64 3)
TIP4=$(hex64 4)
FAMILY=$(printf 'b%.0s' {1..64})
ANCHOR=$(printf 'c%.0s' {1..64})
CLAIM1=$(printf 'e%.0s' {1..64})
CLAIM2=$(printf 'f%.0s' {1..64})
CLAIM3=$(printf '1%.0s' {1..64})
CLAIM4=$(printf '9%.0s' {1..64})
FINGERPRINT=$(printf '2%.0s' {1..64})

mining_json()
{
    local action="${1:-refresh_same_anchor}" enabled="${2:-true}" state="${3:-claim_in_flight}"
    local can_submit=true relay="$HOTFIX_ZERO_TXID" head="$CLAIM4" hashrate=0
    local unresolved=1 live=0 eligible=0 family_claims=4 components=1
    case "$action" in
        create_new_anchor)
            head="$HOTFIX_ZERO_TXID" unresolved=0 family_claims=0 components=0
            ;;
        wait_for_live) can_submit=false; live=1 ;;
        relay_existing) can_submit=false; relay="$CLAIM4"; eligible=1 ;;
        wait_for_next_tip) can_submit=true ;;
        refresh_same_anchor) ;;
    esac
    [[ "$enabled" == true ]] || state=disabled
    jq -cn --arg action "$action" --arg state "$state" --arg relay "$relay" \
        --arg head "$head" --arg fp "$FINGERPRINT" --arg tip "$TIP4" \
        --argjson enabled "$enabled" --argjson can "$can_submit" --argjson hash "$hashrate" \
        --argjson unresolved "$unresolved" --argjson live "$live" \
        --argjson eligible "$eligible" --argjson families "$family_claims" \
        --argjson components "$components" '
        {accrued_jackpot:0,actionable_quarantined_claims:$families,
         allow_automatic_quantum_key_creation:false,autostart:false,
         blocking_quarantined_claims:$families,blocks_remaining:100,
         claim_coins_after_stake_reserve:1,claim_components:$components,
         claim_inventory_tip:$tip,claim_inventory_wallet_tip_matches:true,
         claim_recovery_database_outcome_ambiguous:false,claims_auto_resolved:0,
         claims_recycled:0,claims_submitted:0,configured_stake_reserve_coins:1,
         cpu_percent:1,cumulative_resolution_fees:0,current_height:104,
         enabled:$enabled,epoch_active:true,hashrate:$hash,
         indeterminate_quarantined_claims:0,last_stake_coin_guard:true,
         live_claims:$live,mature_stakeable_legacy_coins:1,
         mature_stakeable_legacy_weight:10,mining_gate_action:$action,
         mining_gate_can_submit:$can,mining_gate_candidate_state_fingerprint:$fp,
         mining_gate_coherent:true,mining_gate_database_ambiguous:false,
         mining_gate_eligible_claims:$eligible,mining_gate_family_claims:$families,
         mining_gate_lineage_head_txid:$head,mining_gate_live_claims:$live,
         mining_gate_relay_txid:$relay,mining_gate_unresolved_components:$unresolved,
         mining_gate_unsafe_claims:0,mining_gate_unsafe_components:0,
         next_claim_amount:10,next_claim_payout:1.5,payout_address:"Qfixture",
         pending_automatic_resolutions:0,pending_manual_resolutions:0,
         quarantined_claims:$families,raw_quarantined_claims:$families,
         reserved_stake_coins:1,reserved_stake_weight:10,
         resolved_on_active_chain_claims:0,shadow_reward_end_height:1000,
         shadow_reward_next_height:105,shadow_reward_start_height:1,
         stake_reserve_snapshot_available:true,state:$state,threads:1,
         unresolved_claims:$families}
    '
}

recovery_json()
{
    local tip="${1:-$TIP4}" generation="${2:-9}"
    jq -cn --arg tip "$tip" --argjson generation "$generation" \
      --arg anchor "$ANCHOR" --arg family "$FAMILY" --arg root "$CLAIM1" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" \
      --arg zero "$HOTFIX_ZERO_TXID" '
      def node($tx;$ordinal;$parent):
        {abandoned:false,active_chain_confirmed:false,authored_metadata_valid:true,
         authored_tip_active_branch_bound:true,claim_descriptor_valid:true,
         disposition:"origin-expired",exact_authored_carrier_shape:true,
         expected_shape:true,expired_locally_retired:false,in_mempool:false,kind:"claim",
         lineage_family_fingerprint:$family,lineage_metadata_present:true,
         lineage_metadata_valid:true,lineage_ordinal:$ordinal,lineage_parent_txid:$parent,
         lineage_root_txid:$root,proof_evaluation_skipped_resolved_anchor:false,
         proof_input_bound:true,proof_may_revalidate_on_descendant:false,proof_mode:"pow",
         proof_origin_bound:true,proof_origin_height:100,
         proof_origin_previous_block_hash:$tip,proof_version:2,
         provenance:"explicit_authored",quarantined:true,relay_expiry_time:0,
         relay_ttl_expired:false,resolution_metadata_valid:false,
         resolution_relay_authorized:false,stale_depth:1,stale_depth_known:true,
         txid:$tx,wallet_authored:true,wallet_from_me:true};
      {active_height:104,active_tip:$tip,actionable_quarantined_claims:4,
       automatic_actions_in_window:0,automatic_fee_exposure_in_window:0,
       blocking_components:1,blocking_quarantined_claims:4,chain_ready:true,
       claims_recycled:0,component_details:[{
         all_claims_expired_locally_retired:false,all_claims_explicitly_provenanced:true,
         all_claims_quarantined:true,all_claims_zero_payment_retirable:false,
         anchor:{amount:1000,scriptPubKey:"51",txid:$anchor,vout:0},
         anchor_authenticated:true,anchor_unspent:true,
         claim_txids:[$c1,$c2,$c3,$c4],classification:"current_branch_ineligible",
         component_fingerprint:$family,descendant_claims:0,generation_fingerprint:$family,
         has_revalidating_unbound_proof:false,minimum_stale_depth:1,
         nodes:[node($c1;0;$zero),node($c2;1;$c1),node($c3;2;$c2),node($c4;3;$c3)],
         ordinary_or_mixed_txids:[],resolution_txids:[],root_claim_txids:[$root],
         stale_depth_known:true}],components:1,confirmed_automatic_resolutions:0,
       confirmed_manual_resolutions:0,confirmed_resolution_fees:0,
       database_outcome_ambiguous:false,indeterminate_quarantined_claims:0,
       live_claim_objects:0,policy:{aggregate_batch_fee_cap:0,automatic_authorized:false,
         automatic_enabled:false,choice_recorded:false,max_actions_per_window:0,
         max_fee_per_resolution:0,minimum_stale_blocks:0,mode:"unset",
         rolling_fee_budget:0,rolling_fee_window_seconds:0,version:1},
       pending_automatic_resolutions:0,pending_manual_resolutions:0,
       policy_authoritative:true,policy_state_detail:"fixture",policy_state_status:"success",
       quarantined_claim_objects:4,raw_claim_objects:4,raw_quarantined_claims:4,
       reconciled_descendant_claims:0,resolved_components:0,
       resolved_on_active_chain_claims:0,retired_claim_objects:0,retired_components:0,
       unanchored_claim_txids:[],wallet_generation:$generation,
       wallet_processed_height:104,wallet_processed_tip:$tip,wallet_tip_matches:true}
    '
}

recovery_metrics_json_value()
{
    jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,
      confirmed_resolution_fees,automatic_actions_in_window,
      automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' \
      <<<"$1"
}

recovery_metrics_sha_value()
{
    local metrics
    metrics=$(recovery_metrics_json_value "$1") || return 1
    printf '%s' "$metrics" | sha256sum | awk '{print $1}'
}

recovery_metrics_sha_file()
{
    recovery_metrics_sha_value "$(<"$1")"
}

staking_disabled()
{
    jq -cn '{active_blocks:104,allow_automatic_quantum_key_creation:false,
      automatic_demurrage_attestation:false,automatic_qqsignal:false,
      automatic_redelegation:false,autostart_staking:false,
      autostart_staking_source:"autostartstaking",blocks:104,chain:"main",
      chainstate_cached:true,consensus_demurrage_automatic:true,difficulty:1,
      eligible:false,enabled:false,expectedtime:0,netstakeweight:100,pooledtx:0,
      "search-interval":0,staking:false,staking_reason:"disabled",
      staking_snapshot_current:true,staking_snapshot_sequence:1,
      staking_state:"disabled",warnings:"",weight:0,weight_cache_height:104,
      weight_cached:true,worker_running:false}'
}

staking_active()
{
    local height="${1:-104}"
    jq -cn --argjson height "$height" '{active_blocks:$height,
      allow_automatic_quantum_key_creation:false,automatic_demurrage_attestation:false,
      automatic_qqsignal:false,automatic_redelegation:false,autostart_staking:false,
      autostart_staking_source:"autostartstaking",blocks:$height,chain:"main",
      chainstate_cached:true,consensus_demurrage_automatic:true,difficulty:1,
      eligible:true,enabled:true,expectedtime:10,netstakeweight:1000,pooledtx:0,
      "search-interval":1,staking:true,staking_reason:"searching",
      staking_snapshot_current:true,staking_snapshot_sequence:1,
      staking_state:"searching",warnings:"",weight:100,weight_cache_height:$height,
      weight_cached:true,worker_running:true}'
}

make_invocation()
{
    local phase="$1" file="$2" image_id="${3:-$IMAGE_ID}" nonce="${4:-$NONCE}"
    local runtime_source="${5:-$HOTFIX_CANDIDATE_SOURCE_SHA}"
    local flags body runtime runtime_sha
    if [[ "$phase" == A ]]; then
        flags=$(hotfix_exact_phase_a_flags_json)
    else
        flags=$(hotfix_exact_phase_b_flags_json)
    fi
    body=$(printf '%s\n%s' 'export DISPLAY=:0
rm -f /tmp/.X0-lock
Xvfb :0 -screen 0 1280x800x16 &
sleep 2
fluxbox &
x11vnc -display :0 -nopw -listen localhost -xkb -forever -shared &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &
sleep 2
exec /usr/local/bin/blackcoin-qt -datadir=/home/blackcoin/.blackcoin "$@"' X)
    body=${body%X}
    runtime=$(jq -cn --argjson flags "$flags" \
        '["/usr/local/bin/blackcoin-qt","-datadir=/home/blackcoin/.blackcoin"] + $flags')
    runtime_sha=$(jq . <<<"$runtime" | sha256sum | awk '{print $1}')
    jq -S -n --arg phase "$phase" --arg nonce "$nonce" \
        --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg runtime_source "$runtime_source" \
        --arg id "$image_id" \
        --arg start "$IMMUTABLE_START_GUI_SHA256" \
        --arg body_sha "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
        --arg sentinel "$HOTFIX_CANDIDATE_ENTRYPOINT_SENTINEL" --arg body "$body" \
        --arg hash "$(printf '3%.0s' {1..64})" --arg argv_sha "$runtime_sha" \
        --argjson flags "$flags" --argjson runtime "$runtime" '
        {schema:2,phase:$phase,run_nonce:$nonce,candidate_source_sha:$source,
         runtime_source_sha:$runtime_source,image_id:$id,
         immutable_start_gui_sha256:$start,entrypoint_body_sha256:$body_sha,
         created_stopped:true,inspected_before_start:true,image_user:"blackcoin",
         working_dir:"/home/blackcoin",image_entrypoint:["/home/blackcoin/start-gui.sh"],
         image_cmd:null,effective_entrypoint:["/bin/bash","-c",$body,$sentinel],
         effective_cmd:$flags,container_path:"/bin/bash",
         container_args:(["-c",$body,$sentinel]+$flags),
         runtime_executable:"/usr/local/bin/blackcoin-qt",runtime_argv:$runtime,
         pid1_exe_sha256:$hash,runtime_argv_sha256:$argv_sha,display_environment:"DISPLAY=:0",
         setup_processes:{xvfb:true,fluxbox:true,x11vnc:true,websockify:true},
         mounts_sha256:$hash,network_sha256:$hash,config_sha256:$hash,
         mounts_equal_baseline:true,network_equal_baseline:true,
         baseline_config_unchanged:true,
         operator_override_allowed:false,conflicting_cli_flags:[],
         conflicting_environment_entries:[]} +
        (if $phase=="B" then
          {container_id:("d"*64),container_started_at:"2026-08-08T00:00:00Z",
           container_restart_count:0,observed_start_gui_sha256:$start,
           restart_policy:{MaximumRetryCount:0,Name:"unless-stopped"},
           restart_policy_equal_baseline:true}
         else {} end)
    ' >"$file"
}

make_helper()
{
    jq -S -n --arg nonce "$NONCE" --arg sha "$HOTFIX_UNLOCK_HELPER_SHA256" '
      {schema:1,run_nonce:$nonce,
       path:"/boot/config/plugins/blackcoin-quantum-nodes/blackcoin_node_normal_unlock.sh",
       sha256:$sha,regular:true,symlink:false,uid:0,gid:0,mode:"600",size:3206,lines:54,
       bash_syntax:true,classification:"unlock_only_normal_walletpassphrase",
       mutating_rpc_methods:["walletpassphrase"],
       readonly_rpc_methods:["getstakinginfo","getwalletinfo","listwallets"],
       walletpassphrase_staking_only:false,forbidden_tokens:[],indirection_detected:false,
       secret_captured:false,invoked_during_audit:false}
    ' >"$1"
}

make_nonpublication()
{
    local file="$1" base listener firewall nft ports mounts auth targets
    base=${file%.json}
    listener="${base}.listeners.txt"
    printf '%s\n' 'LISTEN 0 128 127.0.0.1:15715' >"$listener"
    printf '%s\n' ':INPUT DROP [0:0]' >"${base}.iptables.txt"
    printf '%s\n' ':INPUT DROP [0:0]' >"${base}.ip6tables.txt"
    printf '%s\n' 'table inet filter {}' >"${base}.nft.txt"
    jq -cn '{node27:{},vpn_container:{}}' >"${base}.port-bindings.json"
    jq -cn '[{Source:"/tmp/safe",Destination:"/tmp/safe",RW:false}]' \
        >"${base}.vpn-mounts.json"
    jq -cn '{candidate_processes:["Xvfb","blackcoin-qt","fluxbox","ps"],
      candidate_rpc_capable_processes:["blackcoin-qt"],cookie_or_conf_paths_present:[],
      rpc_auth_material_unavailable_to_shared_namespace:true,separate_pid_namespace:true,
      shared_rpc_unauthenticated_rejected:true,vpn_namespace:{privileged:false,pid_mode:"",
      dangerous_caps:[],auth_environment_names:[],sensitive_mounts:[]}}' \
        >"${base}.rpc-auth-boundary.json"
    jq -cn '{all_host_and_vpn_targets_observed_inaccessible:true,
      host_addresses:["192.0.2.27"],loopback_addresses:["127.0.0.1","::1"],
      ports:[8080,5900,15715],shared_namespace_gui_vnc_ports_observed_inaccessible:true,
      shared_namespace_rpc_tcp_reachable:true,
      shared_namespace_rpc_unauthenticated_rejected:true,vpn_addresses:["198.51.100.27"]}' \
        >"${base}.probe-targets.json"
    firewall=$(sha256sum "${base}.iptables.txt" | awk '{print $1}')
    nft=$(sha256sum "${base}.nft.txt" | awk '{print $1}')
    ports=$(sha256sum "${base}.port-bindings.json" | awk '{print $1}')
    mounts=$(sha256sum "${base}.vpn-mounts.json" | awk '{print $1}')
    auth=$(sha256sum "${base}.rpc-auth-boundary.json" | awk '{print $1}')
    targets=$(sha256sum "${base}.probe-targets.json" | awk '{print $1}')
    jq -S -n --arg nonce "$NONCE" \
      --arg listener "$(sha256sum "$listener" | awk '{print $1}')" \
      --arg ipv4 "$firewall" --arg ipv6 "$(sha256sum "${base}.ip6tables.txt" | awk '{print $1}')" \
      --arg nft "$nft" --arg ports "$ports" --arg mounts "$mounts" \
      --arg auth "$auth" --arg targets "$targets" '
      {schema:1,phase:"A",run_nonce:$nonce,rpc_loopback_only:true,rpc_host_port_bindings:[],
       rpc_shared_namespace_port_bindings:["127.0.0.1:15715/tcp"],
       rpc_external_probe:"host-and-vpn-inaccessible-shared-netns-authenticated-only",
       gui_vnc_external_probe:"inaccessible",vpn_namespace_port_bindings:[],
       vpn_firewall_blocks_gui_vnc:true,vpn_namespace_sharers:["blackcoin-v4-gui-27"],
       keeper_api_suspended:true,guard_start_suspended:true,suspension_nonce:$nonce,
       keeper_api_suspension_basis:["four-locks-held","guard-contract-hash",
        "shared-netns-rpc-auth-boundary","rpc-host-vpn-unpublished"],
       probe_results:[{path:"host-loopback",reachable:false,status:"observed"},
        {path:"host-lan",reachable:false,status:"observed"},
        {path:"vpn-ingress",reachable:false,status:"observed"},
        {path:"shared-namespace",reachable:true,status:"authenticated-only",
         tcp_rpc_reachable:true,unauthenticated_rpc_rejected:true,
         gui_vnc_ports_closed:true,cookie_mount_absent:true}],walletnotify:null,
       zmq_transaction_endpoints:[],relay_forcerelay_peer_ids:[],all_peer_relaytxes_false:true,
       network_localrelay:false,networkactive:true,blocksonly:true,
       config_no_walletbroadcast_override:true,unknown_surfaces:[],includeconf_rejected:true,
       interactive_services_stopped:true,guard_authority_observed:true,
       rpc_auth_material_unavailable_to_shared_namespace:true,
       candidate_rpc_capable_processes:["blackcoin-qt"],listener_evidence_sha256:$listener,
       ipv4_firewall_evidence_sha256:$ipv4,ipv6_firewall_evidence_sha256:$ipv6,
       nft_evidence_sha256:$nft,port_binding_evidence_sha256:$ports,
       vpn_mount_evidence_sha256:$mounts,rpc_auth_boundary_evidence_sha256:$auth,
       probe_target_evidence_sha256:$targets}
    ' >"$file"
}

make_envelope()
{
    local sample="$1" epoch="$2" tip="$3" work="$4" isolation_sha="$5" file="$6"
    local mining recovery staking recovery_metrics recovery_metrics_sha
    mining=$(mining_json refresh_same_anchor)
    recovery=$(recovery_json "$tip" 9)
    recovery_metrics=$(recovery_metrics_json_value "$recovery")
    recovery_metrics_sha=$(recovery_metrics_sha_value "$recovery")
    staking=$(staking_disabled)
    mining=$(jq --arg tip "$tip" '.claim_inventory_tip=$tip' <<<"$mining")
    jq -S -n --argjson sample "$sample" --argjson epoch "$epoch" \
        --argjson observed 2000000000 --arg tip "$tip" \
        --arg work "$work" --argjson mining "$mining" --argjson recovery "$recovery" \
        --argjson staking "$staking" --argjson recovery_metrics "$recovery_metrics" \
        --arg recovery_metrics_sha "$recovery_metrics_sha" --arg isolation "$isolation_sha" '
      {schema:2,phase:"A",sample:$sample,observed_epoch:$observed,restart_epoch:$epoch,
       chain_before:{chain:"main",initialblockdownload:false,blocks:(100+$sample),headers:(100+$sample),
         bestblockhash:$tip,chainwork:$work},
       chain_after:{chain:"main",initialblockdownload:false,blocks:(100+$sample),headers:(100+$sample),
         bestblockhash:$tip,chainwork:$work},recovery_before:$recovery,recovery_after:$recovery,
       mining_before:$mining,mining_after:$mining,staking:$staking,
       wallet:{walletname:"",private_keys_enabled:true,scanning:false,unlocked_staking_only:false,
         unlocked_until:4102444800},network:{networkactive:true,localrelay:false,connections_out:4},
       wallets:[""],expected_recovery_fee:0,expected_pending_manual:0,
       expected_pending_automatic:0,expected_recovery_metrics:$recovery_metrics,
       expected_recovery_metrics_sha256:$recovery_metrics_sha,isolation_continuously_valid:true,
       isolation_sha256:$isolation,observer_status:"observed_absent"}
    ' >"$file"
}

make_progress()
{
    local output="$1" dir e1 e2 e3 e4 sample file vis_sha
    local -a isolation_hashes=() visibility_hashes=()
    dir=${output%/*}
    [[ "$dir" != "$output" ]] || dir=.
    e1="$dir/e1.json"; e2="$dir/e2.json"; e3="$dir/e3.json"; e4="$dir/e4.json"
    for sample in 1 2 3 4; do
        file="$dir/candidate-isolation-sample-${sample}.json"
        make_nonpublication "$file"
        isolation_hashes+=("$(sha256sum "$file" | awk '{print $1}')")
        file="$dir/candidate-visibility-sample-${sample}.json"
        if [[ ! -f "$file" ]]; then
            jq -cn --argjson sample "$sample" '{sample:$sample}' >"$file"
        fi
        vis_sha=$(sha256sum "$file" | awk '{print $1}')
        visibility_hashes+=("$vis_sha")
    done
    make_envelope 1 1 "$TIP1" "$(hex64 1)" "${isolation_hashes[0]}" "$e1"
    make_envelope 2 2 "$TIP2" "$(hex64 2)" "${isolation_hashes[1]}" "$e2"
    make_envelope 3 2 "$TIP3" "$(hex64 3)" "${isolation_hashes[2]}" "$e3"
    make_envelope 4 2 "$TIP4" "$(hex64 4)" "${isolation_hashes[3]}" "$e4"
    local isolation_json visibility_json
    isolation_json=$(printf '%s\n' "${isolation_hashes[@]}" | jq -R . | jq -s .)
    visibility_json=$(printf '%s\n' "${visibility_hashes[@]}" | jq -R . | jq -s .)
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$NONCE" \
      --argjson isolation "$isolation_json" --argjson visibility "$visibility_json" \
      --slurpfile e1 "$e1" \
      --slurpfile e2 "$e2" --slurpfile e3 "$e3" --slurpfile e4 "$e4" '
      {schema:2,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
       envelopes:[$e1[0],$e2[0],$e3[0],$e4[0]],tip_changes:3,
       hard_flags_continuous:true,pos_disabled_continuous:true,
       nonpublication_continuous:true,interactive_surfaces_stopped_continuously:true,
       worker_only_pow:true,lineage_continuation_tips:3,per_epoch_claims_submitted_zero:true,
       isolation_sample_sha256s:$isolation,visibility_sample_sha256s:$visibility,
       bounded_worker_tip_progress:true,
       single_positive_hash_sample_required:false,wait_for_next_tip_required_for_liveness:false}
    ' >"$output"
}

make_claim()
{
    local hash recovery_metrics_sha
    hash=$(printf '4%.0s' {1..64})
    recovery_metrics_sha=$(recovery_metrics_sha_value "$(recovery_json "$TIP4" 9)")
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg rpc "$hash" \
      --arg nonce "$NONCE" --arg payout Qfixture --arg quantum "$hash" \
      --arg anchor "$ANCHOR" --arg family "$FAMILY" --arg root "$CLAIM1" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" \
      --arg tip1 "$TIP1" --arg tip2 "$TIP2" --arg tip3 "$TIP3" --arg tip4 "$TIP4" \
      --arg zero "$HOTFIX_ZERO_TXID" --arg recovery_metrics "$recovery_metrics_sha" '
      def member($tx;$ordinal;$parent;$tip):
        {txid:$tx,ordinal:$ordinal,parent_txid:$parent,anchor_txid:$anchor,anchor_vout:0,
        family:$family,root_txid:$root,created_tip:$tip,quarantine_marker:"1",confirmations:0,
        abandoned:false,in_local_mempool:false,in_active_chain:false,observer_absent:true,
        proof_origin_bound:true,proof_input_bound:true,expired_locally_retired:false,
        first_quarantine_observation_present:false,branch_quarantine_observation_present:false};
      {schema:3,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
       final_order:["tip-proof","pow-stop-joined","wallet-claim-mempool-observer-proof",
        "wallet-locked","candidate-clean-stop","logs-complete-through-stop"],
       pow_worker_joined:true,final_pow_enabled:false,
       final_pow_hashrate:0,logs_complete_through_stop:true,wallet_locked:true,
       candidate_cleanly_stopped:true,candidate_stopped_receipt_sha256:$rpc,
       candidate_complete_log_sha256:$rpc,candidate_post_stop_log_receipt_sha256:$rpc,
       observer_terminal_proof_sha256:$rpc,final_stable_cut_sha256:$rpc,
       terminal_stable_cut_verified:true,interactive_surfaces_stopped_continuously:true,
       shared_namespace_rpc_auth_boundary_continuously_verified:true,
       rpc_allowlist_enforced:true,unexpected_rpc_methods:[],
       persisted_pending_worker_log_observed:true,
       persisted_without_relay_log_observed:true,candidate_claims_submitted:0,
       candidate_mining_gate_coherent:true,candidate_mining_gate_database_ambiguous:false,
       candidate_mining_gate_unsafe_claims:0,candidate_mining_gate_unsafe_components:0,
       candidate_recovery_database_ambiguous:false,hard_staking_disabled_continuously:true,
       retired_claim_objects:0,retired_components:0,candidate_retired_member_txids:[],
       coinstake_created_txids:[],network_visible_wallet_txids:[],fee_payments_authorized:false,
       automatic_recovery_authorized:false,recovery_rpc_invoked:false,
       sendrawtransaction_invoked:false,abandontransaction_invoked:false,
       payout_rotation_invoked:false,forbidden_rpc_methods:[],rpc_methods_sha256:$rpc,
       payout_address_before:$payout,payout_address_after:$payout,quantum_key_count_before:2,
       quantum_key_count_after:2,quantum_inventory_sha256_before:$quantum,
       quantum_inventory_sha256_after:$quantum,confirmed_resolution_fees_before:0,
       confirmed_resolution_fees_after:0,cumulative_resolution_fees_before:0,
       cumulative_resolution_fees_after:0,pending_manual_before:0,pending_manual_after:0,
       pending_automatic_before:0,pending_automatic_after:0,
       recovery_metrics_sha256_before:$recovery_metrics,
       recovery_metrics_sha256_after:$recovery_metrics,recovery_metrics_unchanged:true,
       resolution_txids_before:[],
       resolution_txids_after:[],component_resolution_txids_before:[],
       component_resolution_txids_after:[],candidate_created_qqsproof_txids:[$c1,$c2,$c3,$c4],
       candidate_created_qqsproof_mempool_txids:[],candidate_created_qqsproof_confirmed_txids:[],
       candidate_created_qqsproof_observer_txids:[],candidate_created_qqsproof_unclassifiable_txids:[],
       observer_status:"observed_absent",observer_samples:4,continuous_absence_verified:true,
       initial_atomic_reservation_verified:true,new_nonclaim_wallet_transactions:[],
       abandoned_wallet_txids:[],baseline_wallet_records_static_equal:true,
       baseline_wallet_record_mutations:[],progress_tips:[$tip1,$tip2,$tip3,$tip4],
       claim_sample_tips:[$tip1,$tip2,$tip3,$tip4],claim_samples_monotonic:true,
       visibility_samples_bound_to_progress:true,progress_tips_bound_to_lineage:true,
       one_lineage_member_per_progress_tip:true,final_claim_sample_complete:true,
       distinct_anchor_consumption_observed:false,
       lineage:{authenticated:true,anchor_txid:$anchor,anchor_vout:0,family:$family,
        root_txid:$root,component_claim_txids:([$c1,$c2,$c3,$c4]|sort),
        all_claims_zero_payment_retirable:false,
        all_claims_expired_locally_retired:false,
        members:[member($c1;0;$zero;$tip1),member($c2;1;$c1;$tip2),
          member($c3;2;$c2;$tip3),member($c4;3;$c3;$tip4)],
        contiguous_parents:true,same_anchor:true,same_family:true,same_root:true,
        same_tip_duplicates:false,tip_span:4},txid_differential_classified:true,
       mempool_differential_classified:true,wallet_outpoint_differential_classified:true}
    ' >"$1"
}

make_phase_a_stable_stop()
{
    local transition="$1" image_id="$2" image_ref="$3" original_policy="$4" output="$5"
    local container_id started finished
    case "$transition" in
        baseline-pre-snapshot) container_id=$(printf 'a%.0s' {1..64}) ;;
        candidate-terminal) container_id=$(printf 'b%.0s' {1..64}) ;;
        base-quarantine-to-baseline) container_id=$(printf 'c%.0s' {1..64}) ;;
        *) return 1 ;;
    esac
    started="2026-08-08T00:00:00Z"
    finished="2026-08-08T00:00:01Z"
    jq -S -n --arg transition "$transition" --arg container "$container_id" \
      --arg image "$image_id" --arg ref "$image_ref" --arg started "$started" \
      --arg finished "$finished" --argjson original "$original_policy" '
      {schema:1,transition:$transition,container_id:$container,image_id:$image,image_ref:$ref,
       original_restart_policy:$original,
       armed_restart_policy:{Name:"no",MaximumRetryCount:0},
       stopped_restart_policy_first:{Name:"no",MaximumRetryCount:0},
       stopped_restart_policy_second:{Name:"no",MaximumRetryCount:0},
       started_at_before:$started,started_at_armed:$started,
       stopped_started_at_first:$started,stopped_started_at_second:$started,
       stopped_finished_at_first:$finished,stopped_finished_at_second:$finished,
       restart_count_before:0,restart_count_armed:0,restart_count_stopped_first:0,
       restart_count_stopped_second:0,restart_authority_disabled_before_rpc_stop:true,
       clean_rpc_stop_completed:true,stable_stopped_samples:2,
       automatic_restart_observed:false}
    ' >"$output"
}

make_snapshot_set()
{
    local baseline_stop_authority_sha256="${2:-$(printf '5%.0s' {1..64})}"
    jq -S -n --arg nonce "$NONCE" --arg stop "$baseline_stop_authority_sha256" '
      {schema:1,run_nonce:$nonce,baseline_stop_authority_sha256:$stop,
       created_after_clean_stop:true,held:true,snapshots:[
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27@v30.1.4-hotfix-candidate-node27-"+$nonce),guid:1,creation_txg:1,hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce),hold_present:true},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/blocks",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27/blocks@v30.1.4-hotfix-candidate-node27-"+$nonce),guid:2,creation_txg:2,hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce),hold_present:true},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/indexes",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27/indexes@v30.1.4-hotfix-candidate-node27-"+$nonce),guid:3,creation_txg:3,hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce),hold_present:true},
       {dataset:"pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27",snapshot:("pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27@v30.1.4-hotfix-candidate-node27-"+$nonce),guid:4,creation_txg:4,hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce),hold_present:true}]}
    ' >"$1"
}

make_rewind_safe()
{
    local hash
    hash=$(printf '5%.0s' {1..64})
    jq -S -n --arg nonce "$NONCE" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg id "$IMAGE_ID" \
      --arg ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
      --arg manifest "sha256:$hash" --arg hash "$hash" --arg tip "$TIP4" \
      --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" '
      {schema:1,result:"REWIND_SAFE",run_nonce:$nonce,candidate_source_sha:$source,
       candidate_image_id:$id,candidate_image_ref:$ref,candidate_manifest_digest:$manifest,
       candidate_blackcoin_qt_sha256:$hash,
       tooling_commit:"1234567890123456789012345678901234567890",
       phase_a_tooling_identity_sha256:$hash,package_sha256sums_sha256:$hash,
       phase_a_script_sha256:$hash,phase_b_script_sha256:$hash,
       verifier_sha256:$hash,typed_contract_sha256:$hash,recovery_metrics_sha256:$hash,
       entrypoint_body_sha256:$body,invocation_sha256:$hash,helper_audit_sha256:$hash,
       nonpublication_sha256:$hash,snapshot_set_sha256:$hash,progress_sha256:$hash,
       claim_proof_sha256:$hash,logs_sha256:$hash,rpc_journal_sha256:$hash,
       locks_sha256:$hash,guard_sources_sha256:$hash,pre_rewind_state_sha256:$hash,
       maintenance_marker_sha256:$hash,offline_verifier_receipt_sha256:$hash,
       compose_sha256:$hash,baseline_runtime_identity_sha256:$hash,
       candidate_bundle_manifest_sha256:$hash,candidate_oci_identity_sha256:$hash,
       candidate_binary_sha256sums_sha256:$hash,candidate_loaded_image_sha256:$hash,
       pre_rewind_manifest_sha256:$hash,candidate_final_chain_sha256:$hash,
       candidate_final_chain_after_sha256:$hash,candidate_final_pow_sha256:$hash,
       candidate_final_pow_after_sha256:$hash,candidate_final_staking_sha256:$hash,
       candidate_final_staking_after_sha256:$hash,candidate_final_recovery_sha256:$hash,
       candidate_final_recovery_after_sha256:$hash,
       candidate_final_wallet_transactions_sha256:$hash,candidate_final_mempool_sha256:$hash,
       observer_terminal_proof_sha256:$hash,observer_final_chain_sha256:$hash,
       observer_anchor_unspent_sha256:$hash,observer_tx_absence_sha256:$hash,
       candidate_final_stable_cut_sha256:$hash,candidate_stopped_receipt_sha256:$hash,
       candidate_stop_authority_sha256:$hash,
       candidate_post_stop_log_receipt_sha256:$hash,
       candidate_stopped:true,candidate_exit_code:0,
       pow_worker_joined:true,wallet_locked:true,hard_flags_continuously_verified:true,
       pos_disabled_continuously:true,interactive_surfaces_stopped_continuously:true,
       rpc_allowlist_enforced:true,shared_namespace_rpc_auth_boundary_verified:true,
       complete_log_captured_after_stop:true,terminal_stable_cut_verified:true,
       nonpublication_verified:true,
       observer_absence_verified:true,unknown_or_ambiguous:false,
       coinstake_or_wallet_escape_detected:false,
       candidate_created_qqsproof_txids:[$c1,$c2,$c3,$c4],
       network_visible_wallet_txids:[],confirmed_candidate_txids:[],
       unclassifiable_candidate_txids:[],recovery_spend_or_fee_detected:false,
       unrelated_wallet_delta:false,terminal_tip:$tip,terminal_height:104,
       terminal_chainwork:$tip,wallet_generation:9,promotion_marker_absent:true,snapshots_held:true}
    ' >"$1"
}

make_catchup()
{
    local recovery wallet staking pow network hash
    recovery=$(recovery_json "$TIP4" 9)
    wallet=$(jq -cn '{walletname:"",private_keys_enabled:true,scanning:false,
      unlocked_until:0,unlocked_staking_only:false}')
    staking=$(staking_disabled)
    pow=$(mining_json refresh_same_anchor false disabled)
    network=$(jq -cn '{networkactive:true,localrelay:false,connections_out:4}')
    hash=$(printf '5%.0s' {1..64})
    jq -S -n --arg nonce "$NONCE" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" \
      --arg image "$IMMUTABLE_V3014_IMAGE_REF" --arg id "$IMMUTABLE_V3014_IMAGE_ID" \
      --arg work "$TIP4" --arg tip "$TIP4" --arg anchor "$ANCHOR" --arg hash "$hash" \
      --argjson recovery "$recovery" --argjson wallet "$wallet" --argjson staking "$staking" \
      --argjson pow "$pow" --argjson network "$network" '
      {schema:1,run_nonce:$nonce,source_sha:$source,image:$image,image_id:$id,
       hard_quarantine_flags_verified:true,wallet_locked:true,pow_enabled:false,pos_enabled:false,
       walletbroadcast:false,chain:{chain:"main",initialblockdownload:false,blocks:104,headers:104,
        bestblockhash:$tip,chainwork:$work},chain_after:{chain:"main",initialblockdownload:false,
        blocks:104,headers:104,bestblockhash:$tip,chainwork:$work},
       phase_a_terminal_chainwork:$work,
       phase_a_terminal_tip:$tip,chainwork_at_least_phase_a:true,terminal_tip_active:true,
       terminal_tip_superseded_by_greater_work:false,wallet:$wallet,recovery:$recovery,
       staking:$staking,pow:$pow,network:$network,wallets:[""],
       authenticated_anchor:{txid:$anchor,vout:0,unspent:true,
        txout:{confirmations:100,coinbase:false}},invocation_sha256:$hash,
       nonpublication_sha256:$hash,observer_cut_sha256:$hash,chain_evidence_sha256:$hash,
       chain_after_evidence_sha256:$hash,recovery_evidence_sha256:$hash,
       wallet_evidence_sha256:$hash,staking_evidence_sha256:$hash,pow_evidence_sha256:$hash,
       network_evidence_sha256:$hash,wallets_evidence_sha256:$hash,
       wallet_transactions_sha256:$hash,mempool_sha256:$hash,
       authenticated_anchor_evidence_sha256:$hash,wallet_processed_tip_current:true,
       candidate_image_not_applied:true,candidate_txids_absent_from_wallet:true,
       candidate_txids_absent_from_mempool:true,authenticated_anchor_unspent:true,
       observer_candidate_txids_absent:true,observer_anchor_unspent:true,
       candidate_claim_escape_absent:true,stable_cut:true}
    ' >"$1"
}

make_absence()
{
    local set_file="$1" output="$2" set_sha
    set_sha=$(sha256sum "$set_file" | awk '{print $1}')
    jq -S -n --arg nonce "$NONCE" --arg set_sha "$set_sha" '
      {schema:1,run_nonce:$nonce,catchup_verified_before_release:true,
       snapshot_set_sha256:$set_sha,catchup_proof_sha256:("5"*64),
       authority_rechecks_sha256:("5"*64),authority_recheck_count:10,
       authority_rechecked_before_every_release_and_destroy:true,snapshots:[
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27@v30.1.4-hotfix-candidate-node27-"+$nonce),hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce)},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/blocks",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27/blocks@v30.1.4-hotfix-candidate-node27-"+$nonce),hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce)},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/indexes",snapshot:("pulsar/Blackcoin_Blocks/node-data/node-27/indexes@v30.1.4-hotfix-candidate-node27-"+$nonce),hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce)},
       {dataset:"pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27",snapshot:("pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27@v30.1.4-hotfix-candidate-node27-"+$nonce),hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce)}],
       release_order:"child-before-parent",recursive_or_force_flags_used:false,
       all_holds_released:true,all_four_snapshots_destroyed:true,
       remaining_snapshots:[],remaining_holds:[]}
    ' >"$output"
}

make_phase_a_result()
{
    local hash
    hash=$(printf '6%.0s' {1..64})
    jq -S -n --arg candidate "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg base "$IMMUTABLE_V3014_SOURCE_SHA" --arg nonce "$NONCE" --arg hash "$hash" '
      {schema:3,phase:"A",node:27,result:"passed",candidate_source_sha:$candidate,
       base_source_sha:$base,run_nonce:$nonce,rewind_safe_certificate_verified:true,
       data_rewind_completed:true,base_hard_quarantine_catchup_verified:true,
       all_snapshots_absent_before_baseline_restore:true,baseline_restored:true,
       phase_b_invoked:false,promotion_marker_absent:true,
       tooling_commit:"1234567890123456789012345678901234567890",
       phase_a_tooling_identity_sha256:$hash,package_sha256sums_sha256:$hash,
       phase_a_script_sha256:$hash,phase_b_script_sha256:$hash,
       verifier_sha256:$hash,typed_contract_sha256:$hash,
       baseline_recovery_metrics_sha256:$hash,
       base_quarantine_stop_authority_sha256:$hash,
       baseline_restored_container_sha256:$hash,rewind_safe_sha256:$hash,
       catchup_proof_sha256:$hash,snapshot_absence_sha256:$hash,
       evidence_sha256sums_sha256:$hash}
    ' >"$1"
}

make_marker()
{
    local result_sha="$1" file="$2" hash
    hash=$(printf '7%.0s' {1..64})
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result "$result_sha" \
      --arg hash "$hash" --arg nonce "$NONCE" \
      --arg promotion "fedcba9876543210fedcba9876543210" --arg id "$IMAGE_ID" \
      --arg ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
      --arg manifest "sha256:$hash" '
      {schema:1,state:"PROMOTED_NO_REWIND",node:27,candidate_source_sha:$source,
       phase_a_result_sha256:$result,phase_a_evidence_sha256sums_sha256:$hash,
       phase_a_run_nonce:$nonce,promotion_nonce:$promotion,storage_absence_sha256:$hash,
       phase_a_authority_receipt_sha256:$hash,phase_a_rewind_safe_sha256:$hash,
       candidate_image_ref:$ref,candidate_image_id:$id,candidate_manifest_digest:$manifest,
       tooling_commit:"1234567890123456789012345678901234567890",
       phase_b_tooling_identity_sha256:$hash,package_sha256sums_sha256:$hash,
       phase_b_script_sha256:$hash,verifier_sha256:$hash,typed_contract_sha256:$hash,
       created_utc:"2026-08-08T00:00:00Z",
       data_rewind_permanently_prohibited:true,marker_fsync_verified:true,
       parent_directory_fsync_verified:true,reread_verified:true,
       snapshots_absent_before_marker:true}
    ' >"$file"
}

make_phase_b_result()
{
    local result_sha="$1" file="$2" hash
    hash=$(printf '8%.0s' {1..64})
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result "$result_sha" --arg hash "$hash" '
      {schema:2,phase:"B",node:27,result:"passed",candidate_source_sha:$source,
       phase_a_result_sha256:$result,promoted_no_rewind_marker_verified:true,
       snapshots_absent_before_launch:true,datasets_preserved:true,candidate_running:true,
       wallet_chain_synchronized_before_unlock:true,normal_unlock_completed:true,
       pos_explicitly_enabled:true,pos_active:true,pow_policy_restored:true,p2p_ready:true,
       typed_gate_safe:true,payout_unchanged:true,quantum_keys_unchanged:true,
       recovery_fees_unchanged:true,resolution_txids_unchanged:true,
       recovery_counters_unchanged:true,recovery_policy_unchanged:true,
       wallet_delta_fully_classified:true,only_allowed_wallet_delta_classes_added:true,
       baseline_health_gate_passed:true,final_container_identity_stable:true,
       failure_policy:"contain-stop-preserve",old_core_autostarted:false,
       data_rewind_performed:false,marker_sha256:$hash,invocation_sha256:$hash,
       live_dataset_identity_sha256:$hash,storage_absence_recheck_sha256:$hash,
       phase_b_progress_sha256:$hash,pre_result_manifest_sha256:$hash,
       final_container_sha256:$hash,final_envelope_sha256:$hash,wallet_delta_sha256:$hash,
       wallet_delta_raw_sha256:$hash,baseline_precondition_sha256:$hash,
       baseline_cutover_stop_sha256:$hash,
       tooling_commit:"1234567890123456789012345678901234567890",
       phase_b_tooling_identity_sha256:$hash,package_sha256sums_sha256:$hash,
       phase_b_script_sha256:$hash,verifier_sha256:$hash,typed_contract_sha256:$hash,
       baseline_recovery_policy_sha256:$hash,baseline_recovery_metrics_sha256:$hash,
       baseline_pending_manual_resolutions:0,baseline_pending_automatic_resolutions:0,
       baseline_automatic_fee_exposure_in_window:0,baseline_confirmed_resolution_fees:0}
    ' >"$file"
}

sha_file()
{
    sha256sum "$1" | awk '{print $1}'
}

seal_manifest()
{
    local root="$1" manifest="$2" path base excluded name
    shift 2
    rm -f -- "$root/$manifest"
    (
        cd "$root"
        while IFS= read -r -d '' path; do
            base=${path#./}
            excluded=false
            for name in "$manifest" "$@"; do
                if [[ "$base" == "$name" ]]; then
                    excluded=true
                    break
                fi
            done
            [[ "$excluded" == true ]] || sha256sum "./$base"
        done < <(find . -mindepth 1 -maxdepth 1 -type f -print0)
    ) | sort -k2 >"$root/$manifest"
}

secure_fixture_tree()
{
    local root="$1"
    chmod 700 "$root"
    chgrp "$(id -g)" "$root"
    find "$root" -mindepth 1 -maxdepth 1 -type f -exec chmod 600 {} +
    find "$root" -mindepth 1 -maxdepth 1 -type f -exec chgrp "$(id -g)" {} +
}

prepare_fixture_verifier()
{
    local package="$TMP/fixture-package" relative
    local -a sealed_files=(
        README.md
        VALIDATION.txt
        candidate.env.example
        lib/typed_contract.sh
        node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh
        node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh
        tests/run.sh
        verify-evidence.sh
    )
    mkdir -p "$package/lib" "$package/tests"
    for relative in "${sealed_files[@]}"; do
        cp "$ROOT/$relative" "$package/$relative"
    done
    (
        cd "$package"
        sha256sum "${sealed_files[@]/#/./}" >SHA256SUMS
    )
    chmod 700 "$package" "$package/lib" "$package/tests"
    find "$package" -type f -exec chmod 600 {} +
    FIXTURE_PACKAGE="$package"
    FIXTURE_VERIFIER="$package/verify-evidence.sh"
    readonly FIXTURE_PACKAGE FIXTURE_VERIFIER
}

make_phase_a_tooling_identity()
{
    local output="$1"
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg tooling "1234567890123456789012345678901234567890" \
      --arg package "$(sha_file "$FIXTURE_PACKAGE/SHA256SUMS")" \
      --arg phase_a "$(sha_file \
        "$FIXTURE_PACKAGE/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh")" \
      --arg phase_b "$(sha_file \
        "$FIXTURE_PACKAGE/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh")" \
      --arg verifier "$(sha_file "$FIXTURE_VERIFIER")" \
      --arg contract "$(sha_file "$FIXTURE_PACKAGE/lib/typed_contract.sh")" '
      {schema:1,candidate_source_sha:$source,tooling_commit:$tooling,
       package_sha256sums_sha256:$package,phase_a_script_sha256:$phase_a,
       phase_b_script_sha256:$phase_b,verifier_sha256:$verifier,
       typed_contract_sha256:$contract,exact_bytes_recorded_before_any_live_mutation:true}
    ' >"$output"
}

clone_fixture_package()
{
    local source="$1" target="$2"
    cp -R "$source" "$target"
}

run_package_integrity_fixture()
{
    local package="$1" bad_owner_path="${2:-}"
    /bin/bash -c '
      set -Eeuo pipefail
      package=$1
      bad_owner_path=$2
      # The production helper is Linux-only. Translate only its three GNU stat
      # queries so the exact helper body can be exercised on this macOS host.
      stat()
      {
          local format path
          [[ "$1" == -Lc ]] || return 1
          format=$2
          shift 2
          [[ "${1:-}" == -- ]] && shift
          path=$1
          case "$format" in
              %u:%g)
                  if [[ -n "$bad_owner_path" && "$path" == "$bad_owner_path" ]]; then
                      printf "1:1\n"
                  else
                      printf "0:0\n"
                  fi
                  ;;
              %a) command stat -f "%Lp" "$path" ;;
              %h) command stat -f "%l" "$path" ;;
              *) return 1 ;;
          esac
      }
      # shellcheck disable=SC1090 # Exact copied production script selected by the fixture.
      source "$package/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh"
      verify_package_integrity
    ' _ "$package" "$bad_owner_path"
}

atomic_result_link_fixture()
{
    local staging="$1" target="$2" expected_sha links
    [[ -f "$staging" && ! -L "$staging" && ! -e "$target" && ! -L "$target" ]] ||
        return 1
    expected_sha=$(sha_file "$staging") || return 1
    ln -- "$staging" "$target" || return 1
    rm -f -- "$staging"
    links=$(stat -c '%h' "$target" 2>/dev/null || stat -f '%l' "$target") || return 1
    [[ -f "$target" && ! -L "$target" && "$links" == 1 &&
       "$(sha_file "$target")" == "$expected_sha" ]]
}

run_fixture_verifier()
{
    local mode="$1" evidence="$2"
    /bin/bash -c '
      set -Eeuo pipefail
      source "$1"
      fixture_parent=$4
      secure_root()
      {
          local root="$1" canonical file mode uid gid links
          canonical=$(CDPATH="" cd -P -- "$root" && pwd -P) || die "fixture root absent"
          case "$canonical" in
              "$fixture_parent"/evidence-*) ;;
              *) die "fixture root escaped canonical test root" ;;
          esac
          [[ -d "$canonical" && ! -L "$canonical" ]] || die "fixture root is not real"
          uid=$(stat_uid "$canonical") || die "fixture owner unreadable"
          gid=$(stat_gid "$canonical") || die "fixture group unreadable"
          mode=$(stat_mode "$canonical") || die "fixture mode unreadable"
          [[ "$uid" == "$(id -u)" && "$gid" == "$(id -g)" && "$mode" == 700 ]] ||
              die "fixture root metadata unsafe"
          [[ -z "$(find "$canonical" -mindepth 1 -type d -print -quit)" ]] ||
              die "fixture contains subdirectory"
          [[ -z "$(find "$canonical" -type l -print -quit)" ]] ||
              die "fixture contains symlink"
          while IFS= read -r -d "" file; do
              [[ -f "$file" && ! -L "$file" ]] || die "fixture object is not regular"
              mode=$(stat_mode "$file") || die "fixture file mode unreadable"
              uid=$(stat_uid "$file") || die "fixture file owner unreadable"
              gid=$(stat_gid "$file") || die "fixture file group unreadable"
              links=$(stat_nlink "$file") || die "fixture link count unreadable"
              [[ "$uid" == "$(id -u)" && "$gid" == "$(id -g)" &&
                 "$mode" == 600 && "$links" == 1 ]] ||
                  die "fixture file metadata unsafe"
          done < <(find "$canonical" -mindepth 1 -maxdepth 1 -type f -print0)
      }
      case "$2" in
          phase-a-pre-rewind) verify_phase_a_pre "$3" ;;
          phase-a-final) verify_phase_a_final "$3" ;;
          phase-b-final) verify_phase_b_final "$3" ;;
          *) die "unknown fixture mode" ;;
      esac
    ' _ "$FIXTURE_VERIFIER" "$mode" "$evidence" "$TMP"
}

make_candidate_identity_bundle()
{
    local root="$1" hash qt config_sha manifest_sha image_id
    hash=$(printf '3%.0s' {1..64})
    qt="$hash"
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
      --arg version "$HOTFIX_CANDIDATE_IMAGE_VERSION" \
      --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" \
      --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" '
      {architecture:"amd64",os:"linux",config:{User:"blackcoin",
       Entrypoint:["/home/blackcoin/start-gui.sh"],Cmd:null,WorkingDir:"/home/blackcoin",
       Labels:{"org.blackcoin.source.commit":$source,
        "org.blackcoin.release.channel":("v"+$release+"-candidate"),
        "org.blackcoin.release.qualification":"canary-only-not-release",
        "org.blackcoin.candidate.kind":("v"+$release+"-candidate"),
        "org.blackcoin.candidate.registry-pushed":"false",
        "org.blackcoin.candidate.published":"false","org.blackcoin.release.tag":"none",
        "org.opencontainers.image.version":$version,
        "org.blackcoin.rollback.base.image":$base_ref,
        "org.blackcoin.rollback.base.image.id":$base_id}},
       rootfs:{type:"layers",diff_ids:[("sha256:"+("4"*64))]}}
    ' >"$root/candidate-oci-config.json"
    config_sha=$(sha_file "$root/candidate-oci-config.json")
    image_id="sha256:$config_sha"
    jq -S -n --arg config "sha256:$config_sha" '
      {schemaVersion:2,config:{digest:$config},layers:[{digest:("sha256:"+("5"*64))}]}
    ' >"$root/candidate-oci-manifest.json"
    manifest_sha=$(sha_file "$root/candidate-oci-manifest.json")
    jq -S -n --arg digest "sha256:$manifest_sha" \
      '{schemaVersion:2,manifests:[{digest:$digest}]}' >"$root/candidate-oci-index.json"
    jq -S -n --arg commit "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg fp "$HOTFIX_SIGNING_FINGERPRINT" '
      {schema:1,commit:$commit,repository:"Blackcoin-Dev/Blackcoin",signer:"Blackcoin-Dev",
       format:"ssh",fingerprint:$fp,local_git_verified:true,github_verified:true,
       github_verification_reason:"valid",workflow_actor:"Blackcoin-Dev",
       workflow_triggering_actor:"Blackcoin-Dev"}
    ' >"$root/candidate-source-signature.json"
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg base "$HOTFIX_EXPECTED_CORE_CI_PULL_REQUEST_BASE_SHA" \
      --arg workflow_blob "$HOTFIX_EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256" \
      --argjson run "$HOTFIX_EXPECTED_CORE_CI_RUN_ID" '
      {schema:1,workflow_path:".github/workflows/pr-gate.yml",
       workflow_name:"pull-request safety gate",event:"pull_request",
       repository:"Blackcoin-Dev/Blackcoin",head_repository:"Blackcoin-Dev/Blackcoin",
       pull_request_number:49,pull_request_head_sha:$source,
       pull_request_base_sha:$base,workflow_blob_sha256:$workflow_blob,
       head_sha:$source,status:"completed",conclusion:"success",run_id:$run}
    ' >"$root/candidate-core-ci.json"
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg base "$IMMUTABLE_V3014_IMAGE_DIGEST" --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" \
      --arg manifest "sha256:$manifest_sha" --arg config "sha256:$config_sha" \
      --arg ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
      --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
      --arg archive "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" \
      --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" '
      {schema:1,classification:$classification,
       source_commit:$source,image_reference:$ref,archive_name:$archive,
       base_reference:$base_ref,base_manifest_digest:$base,base_config_digest:$base_id,
       os:"linux",architecture:"amd64",user:"blackcoin",
       entrypoint:["/home/blackcoin/start-gui.sh"],cmd:null,working_dir:"/home/blackcoin",
       healthcheck:null,rootfs_base_prefix_exact:true,candidate_added_rootfs_layers:1,
       oci_roundtrip_verified:true,published:false,registry_pushed:false,
       image_manifest_digest:$manifest,image_config_digest:$config}
    ' >"$root/candidate-oci-identity.json"
    jq -S -n --slurpfile signature "$root/candidate-source-signature.json" \
      --slurpfile core "$root/candidate-core-ci.json" \
      --slurpfile image "$root/candidate-oci-identity.json" \
      --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg tooling "1234567890123456789012345678901234567890" \
      --arg classification "$HOTFIX_CANDIDATE_CLASSIFICATION" \
      --arg prefix "$HOTFIX_CANDIDATE_PREFIX" \
      --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
      --arg workflow "$HOTFIX_CANDIDATE_WORKFLOW_PATH" \
      --arg artifact "$(hotfix_candidate_artifact_name 7)" '
      {schema:1,classification:$classification,
       package:{name:$prefix,version:$release,platform:"linux/amd64"},
       source:{commit:$source,signature:$signature[0]},core_ci:$core[0],image:$image[0],
       authorization:{state:"authorized_exact_signed_source_and_green_ci",
        dispatch_enabled:true,temporary_source_pin:false,core_ci_run_id:$core[0].run_id},
       build:{tooling_commit:$tooling,workflow_definition_commit:$tooling,
        workflow_path:$workflow,workflow_run_id:2,workflow_run_attempt:7,
        artifact_name:$artifact},
       release:{tag:null,published:false,registry_pushed:false,canary_only:true}}
    ' >"$root/candidate-bundle-manifest.json"
    jq -S -n --arg id "$image_id" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg ref "$HOTFIX_CANDIDATE_IMAGE_REF" \
      --arg release "$HOTFIX_CANDIDATE_RELEASE_VERSION" \
      --arg version "$HOTFIX_CANDIDATE_IMAGE_VERSION" \
      --arg base_ref "$IMMUTABLE_V3014_IMAGE_REF" \
      --arg base_id "$IMMUTABLE_V3014_IMAGE_ID" '
      [{Id:$id,RepoTags:[$ref],Os:"linux",Architecture:"amd64",Config:{User:"blackcoin",
        WorkingDir:"/home/blackcoin",Entrypoint:["/home/blackcoin/start-gui.sh"],Cmd:null,
        Healthcheck:null,Labels:{"org.blackcoin.source.commit":$source,
         "org.blackcoin.release.channel":("v"+$release+"-candidate"),
         "org.blackcoin.release.qualification":"canary-only-not-release",
         "org.blackcoin.candidate.kind":("v"+$release+"-candidate"),
         "org.blackcoin.candidate.registry-pushed":"false",
         "org.blackcoin.candidate.published":"false","org.blackcoin.release.tag":"none",
         "org.opencontainers.image.version":$version,
         "org.blackcoin.rollback.base.image":$base_ref,
         "org.blackcoin.rollback.base.image.id":$base_id}}}]
    ' >"$root/candidate-loaded-image.json"
    jq -S -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg source "$IMMUTABLE_V3014_SOURCE_SHA" '
      [{Id:$id,Os:"linux",Architecture:"amd64",Config:{User:"blackcoin",
        WorkingDir:"/home/blackcoin",Entrypoint:["/home/blackcoin/start-gui.sh"],Cmd:null,
        Labels:{"org.blackcoin.source.commit":$source}}}]
    ' >"$root/rollback-loaded-image.json"
    printf '%s\n' "$HOTFIX_CANDIDATE_SOURCE_SHA" >"$root/candidate-source-commit.txt"
    : >"$root/candidate-bundle-sha256sums.txt"
    jq -n '{}' >"$root/candidate-provenance.intoto.json"
    : >"$root/candidate-binary-sha256sums.txt"
    : >"$root/candidate-loaded-binary-sha256.tsv"
    local binary
    for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
        printf '%s  %s\n' "$hash" "$binary" >>"$root/candidate-binary-sha256sums.txt"
        printf '%s\t%s\n' "$binary" "$hash" >>"$root/candidate-loaded-binary-sha256.tsv"
    done
    CANDIDATE_FIXTURE_IMAGE_ID="$image_id"
    CANDIDATE_FIXTURE_QT_SHA="$qt"
}

make_claim_wallet_row()
{
    local txid="$1" ordinal="$2" parent="$3" tip="$4"
    jq -cn --arg txid "$txid" --arg ordinal "$ordinal" --arg parent "$parent" \
      --arg tip "$tip" --arg family "$FAMILY" --arg root "$CLAIM1" \
      --arg anchor "$ANCHOR" '
      {txid:$txid,category:"send",amount:-10,fee:0,address:"Qfixture",comment:"PoW Claim",
       confirmations:0,abandoned:false,qq_shadow_pow_authored:"1",
       qq_shadow_pow_quarantine:"1",qq_shadow_pow_lineage_schema:"1",
       qq_shadow_pow_lineage_family:$family,qq_shadow_pow_lineage_root:$root,
       qq_shadow_pow_lineage_parent:$parent,qq_shadow_pow_lineage_ordinal:$ordinal,
       qq_shadow_pow_created_tip:$tip,qq_shadow_pow_anchor_txid:$anchor,
       qq_shadow_pow_anchor_vout:"0"}
    '
}

make_phase_a_raw_evidence()
{
    local root="$1" sample tip work height mining recovery staking
    local c1 c2 c3 c4 final_wallet quantum_sha stopped_sha log_sha post_sha stable_sha terminal_sha
    c1=$(make_claim_wallet_row "$CLAIM1" 0 "$HOTFIX_ZERO_TXID" "$TIP1")
    c2=$(make_claim_wallet_row "$CLAIM2" 1 "$CLAIM1" "$TIP2")
    c3=$(make_claim_wallet_row "$CLAIM3" 2 "$CLAIM2" "$TIP3")
    c4=$(make_claim_wallet_row "$CLAIM4" 3 "$CLAIM3" "$TIP4")
    jq -S -n --arg txid "$ANCHOR" \
      '[{txid:$txid,vout:0,category:"receive",address:"legacy",amount:1000,fee:0,
         confirmations:100,abandoned:false}]' >"$root/prelaunch-wallet-transactions.json"
    final_wallet=$(jq -S -n --slurpfile before "$root/prelaunch-wallet-transactions.json" \
      --argjson c1 "$c1" --argjson c2 "$c2" --argjson c3 "$c3" --argjson c4 "$c4" \
      '$before[0]+[$c1,$c2,$c3,$c4]')
    printf '%s\n' "$final_wallet" >"$root/candidate-final-wallet-transactions.json"
    jq -S -n --arg txid "$ANCHOR" '[{txid:$txid,vout:0}]' \
        >"$root/prelaunch-wallet-outpoints.json"
    jq -n '[]' >"$root/candidate-final-wallet-outpoints.json"
    for name in prelaunch-resolution-txids candidate-final-resolution-txids \
        prelaunch-component-resolution-txids candidate-final-component-resolution-txids \
        candidate-final-mempool candidate-created-qqsproof-txids; do
        if [[ "$name" == candidate-created-qqsproof-txids ]]; then
            jq -S -n --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" \
              --arg c4 "$CLAIM4" '[$c1,$c2,$c3,$c4]' >"$root/$name.json"
        else
            jq -n '[]' >"$root/$name.json"
        fi
    done
    mining=$(mining_json refresh_same_anchor)
    printf '%s\n' "$mining" >"$root/baseline-pow.json"
    recovery=$(recovery_json "$TIP4" 9 | jq '.automatic_authorized=false')
    printf '%s\n' "$recovery" >"$root/baseline-recovery.json"
    printf '%s\n' "$recovery" >"$root/candidate-final-recovery-inventory.json"
    printf '%s\n' "$recovery" >"$root/candidate-final-recovery-after.json"
    mining=$(mining_json refresh_same_anchor false disabled)
    printf '%s\n' "$mining" >"$root/candidate-final-pow.json"
    printf '%s\n' "$mining" >"$root/candidate-final-pow-after.json"
    staking=$(staking_disabled)
    printf '%s\n' "$staking" >"$root/candidate-final-staking.json"
    printf '%s\n' "$staking" >"$root/candidate-final-staking-after.json"
    jq -S -n --arg tip "$TIP4" '{chain:"main",initialblockdownload:false,blocks:104,
      headers:104,bestblockhash:$tip,chainwork:$tip}' >"$root/candidate-final-chain.json"
    cp "$root/candidate-final-chain.json" "$root/candidate-final-chain-after.json"
    jq -S -n '[{key:"q1"},{key:"q2"}]' >"$root/baseline-quantum-inventory.json"
    cp "$root/baseline-quantum-inventory.json" "$root/candidate-final-quantum-inventory.json"
    jq -S -n --arg tip "$TIP4" '
      {stable:true,terminal_tip:$tip,terminal_chainwork:$tip,wallet_generation:9}
    ' >"$root/candidate-final-stable-cut.json"
    : >"$root/observer-mempools.jsonl"
    : >"$root/observer-final-chain.jsonl"
    : >"$root/observer-anchor-unspent.jsonl"
    : >"$root/observer-tx-absence.jsonl"
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        jq -cS -n --arg observer "$observer" '{observer:$observer,txids:[]}' \
            >>"$root/observer-mempools.jsonl"
        jq -cS -n --arg observer "$observer" --arg tip "$TIP4" '
          def chain:{chain:"main",initialblockdownload:false,blocks:104,headers:104,
            bestblockhash:$tip,chainwork:$tip};
          {observer:$observer,stable:true,chain_before:chain,chain_after:chain,
           terminal_relation:"same_terminal_tip"}
        ' >>"$root/observer-final-chain.jsonl"
        jq -cS -n --arg observer "$observer" --arg anchor "$ANCHOR" '
          {observer:$observer,unspent:true,anchor:{txid:$anchor,vout:0},
           txout:{confirmations:100,coinbase:false}}
        ' >>"$root/observer-anchor-unspent.jsonl"
        for txid in "$CLAIM1" "$CLAIM2" "$CLAIM3" "$CLAIM4"; do
            jq -cS -n --arg observer "$observer" --arg txid "$txid" --arg anchor "$ANCHOR" '
              {observer:$observer,txid:$txid,status:"observed_absent",mempool_absent:true,
               active_chain_absent:true,active_chain_absence_basis:"authenticated-anchor-unspent",
               anchor:{txid:$anchor,vout:0,unspent:true},rpc_error_code:-5}
            ' >>"$root/observer-tx-absence.jsonl"
        done
    done
    jq -S -n --arg tip "$TIP4" --slurpfile chains "$root/observer-final-chain.jsonl" \
      --slurpfile anchors "$root/observer-anchor-unspent.jsonl" \
      --slurpfile absence "$root/observer-tx-absence.jsonl" '
      {schema:1,terminal_tip:$tip,terminal_chainwork:$tip,observer_chains:$chains,
       observer_anchors:$anchors,tx_absence:$absence,
       observers_stable_and_cover_terminal:true,
       authenticated_anchor_unspent_on_all_observers:true}
    ' >"$root/observer-terminal-proof.json"
    : >"$root/tx-visibility-samples.jsonl"
    for sample in 1 2 3 4; do
        case "$sample" in
            1) tip=$TIP1; work=$(hex64 1); height=101 ;;
            2) tip=$TIP2; work=$(hex64 2); height=102 ;;
            3) tip=$TIP3; work=$(hex64 3); height=103 ;;
            4) tip=$TIP4; work=$(hex64 4); height=104 ;;
        esac
        mining=$(mining_json refresh_same_anchor | jq --arg tip "$tip" \
          '.claim_inventory_tip=$tip|.claims_submitted=0')
        recovery=$(recovery_json "$tip" 9)
        jq -cS -n --argjson sample "$sample" --arg tip "$tip" --arg work "$work" \
          --argjson height "$height" --argjson mining "$mining" --argjson recovery "$recovery" '
          def chain:{chain:"main",initialblockdownload:false,blocks:$height,headers:$height,
            bestblockhash:$tip,chainwork:$work};
          def observer($name):{observer:$name,stable:true,chain_before:chain,chain_after:chain,
            terminal_relation:"same_terminal_tip",txids:[]};
          {sample:$sample,candidate_tip:$tip,candidate_chainwork:$work,
           stable_cut_completed:true,post_claim_chain:chain,post_claim_mining:$mining,
           post_claim_recovery:$recovery,observer_chains_stable_and_cover_candidate_tip:true,
           local_mempool:[],observers:[observer("blackcoin-v4-gui-26"),
             observer("blackcoin-v4-gui-28")]}
        ' >"$root/candidate-visibility-sample-${sample}.json"
        cat "$root/candidate-visibility-sample-${sample}.json" \
            >>"$root/tx-visibility-samples.jsonl"
        case "$sample" in
            1) jq -S -n --arg tip "$tip" --argjson c1 "$c1" '{tip:$tip,claims:[$c1]}' ;;
            2) jq -S -n --arg tip "$tip" --argjson c1 "$c1" --argjson c2 "$c2" \
                 '{tip:$tip,claims:[$c1,$c2]}' ;;
            3) jq -S -n --arg tip "$tip" --argjson c1 "$c1" --argjson c2 "$c2" \
                 --argjson c3 "$c3" '{tip:$tip,claims:[$c1,$c2,$c3]}' ;;
            4) jq -S -n --arg tip "$tip" --argjson c1 "$c1" --argjson c2 "$c2" \
                 --argjson c3 "$c3" --argjson c4 "$c4" \
                 '{tip:$tip,claims:[$c1,$c2,$c3,$c4]}' ;;
        esac >"$root/candidate-claims-sample-${sample}.json"
    done
    make_progress "$root/phase-a-progress.json"
    jq -S -n --arg id "$CANDIDATE_FIXTURE_IMAGE_ID" \
      '{running:false,exit_code:0,image_id:$id}' >"$root/candidate-stopped.json"
    printf '%s\n' 'retained a claim after relay failure' 'persisted without relay' \
        >"$root/candidate-complete.log"
    stopped_sha=$(sha_file "$root/candidate-stopped.json")
    log_sha=$(sha_file "$root/candidate-complete.log")
    jq -S -n --arg stopped "$stopped_sha" --arg log "$log_sha" '
      {schema:1,candidate_stopped_receipt_sha256:$stopped,complete_log_sha256:$log,
       captured_after_clean_stop:true,candidate_finished_at:"2026-08-08T00:00:00Z",
       captured_utc:"2026-08-08T00:00:01Z"}
    ' >"$root/candidate-post-stop-log-receipt.json"
    post_sha=$(sha_file "$root/candidate-post-stop-log-receipt.json")
    stable_sha=$(sha_file "$root/candidate-final-stable-cut.json")
    terminal_sha=$(sha_file "$root/observer-terminal-proof.json")
    quantum_sha=$(sha_file "$root/baseline-quantum-inventory.json")
    make_claim "$root/phase-a-claim-proof.base.json"
    jq -S --arg rpc "$(sha_file "$root/candidate-rpc-methods-through-proof.log")" \
      --arg stopped "$stopped_sha" --arg log "$log_sha" --arg post "$post_sha" \
      --arg stable "$stable_sha" --arg terminal "$terminal_sha" --arg quantum "$quantum_sha" '
      .rpc_methods_sha256=$rpc | .candidate_stopped_receipt_sha256=$stopped |
      .candidate_complete_log_sha256=$log | .candidate_post_stop_log_receipt_sha256=$post |
      .final_stable_cut_sha256=$stable | .observer_terminal_proof_sha256=$terminal |
      .quantum_inventory_sha256_before=$quantum | .quantum_inventory_sha256_after=$quantum
    ' "$root/phase-a-claim-proof.base.json" >"$root/phase-a-claim-proof.json"
    rm "$root/phase-a-claim-proof.base.json"
}

build_phase_a_pre_fixture()
{
    local root="$1" hash candidate_ref baseline_policy no_restart
    mkdir -m 700 "$root"
    make_candidate_identity_bundle "$root"
    hash=$(printf '3%.0s' {1..64})
    candidate_ref=$(jq -er '.image_reference' "$root/candidate-oci-identity.json")
    baseline_policy='{"Name":"unless-stopped","MaximumRetryCount":0}'
    no_restart='{"Name":"no","MaximumRetryCount":0}'
    make_helper "$root/unlock-helper-audit.json"
    make_phase_a_stable_stop baseline-pre-snapshot "$IMMUTABLE_V3014_IMAGE_ID" \
        "$IMMUTABLE_V3014_IMAGE_REF" "$baseline_policy" \
        "$root/baseline-cold-stop-authority.json"
    make_snapshot_set "$root/snapshot-set.json" \
        "$(sha_file "$root/baseline-cold-stop-authority.json")"
    jq -S -n --arg nonce "$NONCE" '
      {schema:1,run_nonce:$nonce,held:true,order:["/run/blackcoin-endpoint-guard.lock",
       "/var/run/blackcoin-node-cutover.lock","/run/blackcoin-pow-quarantine-cycle.lock",
       "/var/run/blackcoin-wallet-runtime-guard.lock"]}
    ' >"$root/locks.json"
    jq -S -n --arg id "$CANDIDATE_FIXTURE_IMAGE_ID" --arg hash "$hash" \
      --argjson restart "$no_restart" '
      {image_id:$id,running:false,user:"blackcoin",working_dir:"/home/blackcoin",
       mounts_sha256:$hash,network_sha256:$hash,restart_policy:$restart}
    ' >"$root/candidate-created-stopped.json"
    make_invocation A "$root/candidate-invocation-initial.json" "$CANDIDATE_FIXTURE_IMAGE_ID"
    make_invocation A "$root/candidate-invocation-restart.json" "$CANDIDATE_FIXTURE_IMAGE_ID"
    for prefix in phase-a-nonpublication-initial phase-a-nonpublication-restart-preunlock \
        phase-a-nonpublication-final; do
        make_nonpublication "$root/$prefix.json"
    done
    printf '%s\n' 'setpowmining:true:1:1:false' 'getpowmininginfo' \
      'setpowmining:false:1:1:false' >"$root/candidate-rpc-methods-through-proof.log"
    make_phase_a_raw_evidence "$root"
    make_phase_a_stable_stop candidate-terminal "$CANDIDATE_FIXTURE_IMAGE_ID" \
        "$candidate_ref" "$no_restart" "$root/candidate-stop-authority.json"
    mining_json refresh_same_anchor false disabled >"$root/candidate-pow-joined.json"
    jq -S -n '{unlocked_until:0}' >"$root/candidate-wallet-locked.json"
    jq -S -n '{clean_stop_requested:true}' >"$root/candidate-stop.json"
    jq -S -n --arg hash "$hash" '
      {schema:1,runtime_guard_sha256:$hash,endpoint_guard_sha256:$hash,
       pow_cycle_sha256:$hash,node27_canary_marker_contract_verified:true,
       maintenance_fail_closed_verified:true}
    ' >"$root/guard-source-identity.json"
    jq -S -n --arg hash "$hash" --argjson restart "$baseline_policy" '
      {schema:1,blackcoin_conf_sha256:$hash,mounts_sha256:$hash,network_sha256:$hash,
       restart_policy:$restart}
    ' >"$root/baseline-runtime-identity.json"
    make_phase_a_tooling_identity "$root/tooling-identity.json"
    seal_manifest "$root" PRE_REWIND_SHA256SUMS
    secure_fixture_tree "$root"
}

make_base_catchup_evidence()
{
    local root="$1" recovery wallet staking pow network invocation_sha isolation_sha observer_sha
    jq -S -n --arg tip "$TIP4" '{chain:"main",initialblockdownload:false,blocks:104,
      headers:104,bestblockhash:$tip,chainwork:$tip}' >"$root/base-catchup-chain.json"
    cp "$root/base-catchup-chain.json" "$root/base-catchup-chain-after.json"
    recovery=$(recovery_json "$TIP4" 9)
    printf '%s\n' "$recovery" >"$root/base-catchup-recovery.json"
    wallet=$(jq -cn '{walletname:"",private_keys_enabled:true,scanning:false,
      unlocked_until:0,unlocked_staking_only:false}')
    printf '%s\n' "$wallet" >"$root/base-catchup-wallet.json"
    staking=$(staking_disabled)
    printf '%s\n' "$staking" >"$root/base-catchup-staking.json"
    pow=$(mining_json refresh_same_anchor false disabled)
    printf '%s\n' "$pow" >"$root/base-catchup-pow.json"
    network=$(jq -cn '{networkactive:true,localrelay:false,connections_out:4}')
    printf '%s\n' "$network" >"$root/base-catchup-network.json"
    jq -n '[""]' >"$root/base-catchup-wallets.json"
    cp "$root/base-catchup-wallets.json" "$root/baseline-wallets.json"
    cp "$root/prelaunch-wallet-transactions.json" "$root/base-catchup-wallet-transactions.json"
    jq -n '[]' >"$root/base-catchup-mempool.json"
    jq -S -n '{confirmations:100,coinbase:false}' >"$root/base-catchup-anchor.json"
    : >"$root/base-catchup-observer.jsonl"
    local observer
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        jq -cS -n --arg observer "$observer" --arg tip "$TIP4" --arg anchor "$ANCHOR" \
          --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" '
          def chain:{chain:"main",initialblockdownload:false,blocks:104,headers:104,
            bestblockhash:$tip,chainwork:$tip};
          {observer:$observer,stable:true,candidate_txids_absent:true,chain_before:chain,
           chain_after:chain,mempool:[],candidate_txids:[$c1,$c2,$c3,$c4],
           anchor:{txid:$anchor,vout:0,unspent:true,txout:{confirmations:100,coinbase:false}}}
        ' >>"$root/base-catchup-observer.jsonl"
    done
    make_invocation A "$root/base-quarantine-invocation.json" \
        "$IMMUTABLE_V3014_IMAGE_ID" "$NONCE" "$IMMUTABLE_V3014_SOURCE_SHA"
    cp "$root/base-quarantine-invocation.json" "$root/base-quarantine-invocation-current.json"
    make_nonpublication "$root/base-quarantine-nonpublication-current.json"
    jq -S -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" \
      '{image_id:$id,running:false,user:"blackcoin",working_dir:"/home/blackcoin",
        restart_policy:{Name:"no",MaximumRetryCount:0}}' \
      >"$root/base-quarantine-created-stopped.json"
    invocation_sha=$(sha_file "$root/base-quarantine-invocation-current.json")
    isolation_sha=$(sha_file "$root/base-quarantine-nonpublication-current.json")
    observer_sha=$(sha_file "$root/base-catchup-observer.jsonl")
    make_catchup "$root/base-catchup-proof.base.json"
    jq -S --arg invocation "$invocation_sha" --arg isolation "$isolation_sha" \
      --arg observer "$observer_sha" \
      --arg chain "$(sha_file "$root/base-catchup-chain.json")" \
      --arg chain_after "$(sha_file "$root/base-catchup-chain-after.json")" \
      --arg recovery "$(sha_file "$root/base-catchup-recovery.json")" \
      --arg wallet "$(sha_file "$root/base-catchup-wallet.json")" \
      --arg staking "$(sha_file "$root/base-catchup-staking.json")" \
      --arg pow "$(sha_file "$root/base-catchup-pow.json")" \
      --arg network "$(sha_file "$root/base-catchup-network.json")" \
      --arg wallets "$(sha_file "$root/base-catchup-wallets.json")" \
      --arg wallet_tx "$(sha_file "$root/base-catchup-wallet-transactions.json")" \
      --arg mempool "$(sha_file "$root/base-catchup-mempool.json")" \
      --arg anchor "$(sha_file "$root/base-catchup-anchor.json")" \
      --slurpfile c "$root/base-catchup-chain.json" \
      --slurpfile ca "$root/base-catchup-chain-after.json" \
      --slurpfile r "$root/base-catchup-recovery.json" \
      --slurpfile w "$root/base-catchup-wallet.json" \
      --slurpfile s "$root/base-catchup-staking.json" \
      --slurpfile p "$root/base-catchup-pow.json" \
      --slurpfile n "$root/base-catchup-network.json" \
      --slurpfile ws "$root/base-catchup-wallets.json" '
      .invocation_sha256=$invocation | .nonpublication_sha256=$isolation |
      .observer_cut_sha256=$observer | .chain_evidence_sha256=$chain |
      .chain_after_evidence_sha256=$chain_after | .recovery_evidence_sha256=$recovery |
      .wallet_evidence_sha256=$wallet | .staking_evidence_sha256=$staking |
      .pow_evidence_sha256=$pow | .network_evidence_sha256=$network |
      .wallets_evidence_sha256=$wallets | .wallet_transactions_sha256=$wallet_tx |
      .mempool_sha256=$mempool | .authenticated_anchor_evidence_sha256=$anchor |
      .chain=$c[0] | .chain_after=$ca[0] | .recovery=$r[0] | .wallet=$w[0] |
      .staking=$s[0] | .pow=$p[0] | .network=$n[0] | .wallets=$ws[0]
    ' "$root/base-catchup-proof.base.json" >"$root/base-catchup-proof.json"
    rm "$root/base-catchup-proof.base.json"
}

make_baseline_restored_evidence()
{
    local root="$1" baseline_policy mounts network recovery
    baseline_policy=$(jq -c '.restart_policy' "$root/baseline-runtime-identity.json")
    mounts=$(jq -er '.mounts_sha256' "$root/baseline-runtime-identity.json")
    network=$(jq -er '.network_sha256' "$root/baseline-runtime-identity.json")
    jq -S -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" \
      --arg ref "$IMMUTABLE_V3014_IMAGE_REF" --arg mounts "$mounts" \
      --arg network "$network" --argjson restart "$baseline_policy" '
      {schema:1,container_id:("d"*64),image_id:$id,image_ref:$ref,running:true,
       mounts_sha256:$mounts,network_sha256:$network,restart_policy:$restart}
    ' >"$root/baseline-restored-container.json"
    jq -S -n --arg tip "$TIP4" '
      {chain:"main",initialblockdownload:false,blocks:104,headers:104,
       bestblockhash:$tip,chainwork:$tip}
    ' >"$root/baseline-restored-chain.json"
    jq -S -n '{networkactive:true,localrelay:true,connections_out:4}' \
        >"$root/baseline-restored-network.json"
    jq -S -n '{walletname:"",private_keys_enabled:true,scanning:false,
      unlocked_staking_only:false,unlocked_until:4102444800}' \
        >"$root/baseline-restored-wallet.json"
    staking_active 104 >"$root/baseline-restored-staking.json"
    jq -S -n '{enabled:true,state:"mining",hashrate:1,threads:1,cpu_percent:1,
      payout_address:"Qfixture"}' >"$root/baseline-restored-pow-state.json"
    recovery=$(<"$root/baseline-recovery.json")
    printf '%s\n' "$recovery" >"$root/baseline-restored-recovery.json"
    cp "$root/baseline-quantum-inventory.json" "$root/baseline-restored-quantum.json"
    cp "$root/baseline-wallets.json" "$root/baseline-restored-wallets.json"
}

update_rewind_safe_hashes()
{
    local root="$1" cert output
    cert="$root/REWIND_SAFE.base.json"
    output="$root/REWIND_SAFE.json"
    make_rewind_safe "$cert"
    jq -S \
      --arg image "$(jq -er '.image_config_digest' "$root/candidate-oci-identity.json")" \
      --arg manifest "$(jq -er '.image_manifest_digest' "$root/candidate-oci-identity.json")" \
      --arg qt "$CANDIDATE_FIXTURE_QT_SHA" \
      --arg invocation "$(sha_file "$root/candidate-invocation-restart.json")" \
      --arg helper "$(sha_file "$root/unlock-helper-audit.json")" \
      --arg isolation "$(sha_file "$root/phase-a-nonpublication-final.json")" \
      --arg snapshots "$(sha_file "$root/snapshot-set.json")" \
      --arg progress "$(sha_file "$root/phase-a-progress.json")" \
      --arg claim "$(sha_file "$root/phase-a-claim-proof.json")" \
      --arg logs "$(sha_file "$root/candidate-complete.log")" \
      --arg rpc "$(sha_file "$root/candidate-rpc-methods-through-proof.log")" \
      --arg locks "$(sha_file "$root/locks.json")" \
      --arg guard "$(sha_file "$root/guard-source-identity.json")" \
      --arg state "$(sha_file "$root/pre-rewind-state.json")" \
      --arg maintenance "$(sha_file "$root/maintenance-marker-activated.json")" \
      --arg receipt "$(sha_file "$root/pre-rewind-verifier.json")" \
      --arg baseline "$(sha_file "$root/baseline-runtime-identity.json")" \
      --arg bundle "$(sha_file "$root/candidate-bundle-manifest.json")" \
      --arg oci "$(sha_file "$root/candidate-oci-identity.json")" \
      --arg binaries "$(sha_file "$root/candidate-binary-sha256sums.txt")" \
      --arg loaded "$(sha_file "$root/candidate-loaded-image.json")" \
      --arg pre "$(sha_file "$root/PRE_REWIND_SHA256SUMS")" \
      --arg tooling_identity "$(sha_file "$root/tooling-identity.json")" \
      --arg tooling "$(jq -er '.tooling_commit' "$root/tooling-identity.json")" \
      --arg package "$(jq -er '.package_sha256sums_sha256' "$root/tooling-identity.json")" \
      --arg phase_a "$(jq -er '.phase_a_script_sha256' "$root/tooling-identity.json")" \
      --arg phase_b "$(jq -er '.phase_b_script_sha256' "$root/tooling-identity.json")" \
      --arg verifier "$(jq -er '.verifier_sha256' "$root/tooling-identity.json")" \
      --arg contract "$(jq -er '.typed_contract_sha256' "$root/tooling-identity.json")" \
      --arg recovery_metrics "$(recovery_metrics_sha_file "$root/baseline-recovery.json")" \
      --arg chain "$(sha_file "$root/candidate-final-chain.json")" \
      --arg chain_after "$(sha_file "$root/candidate-final-chain-after.json")" \
      --arg pow "$(sha_file "$root/candidate-final-pow.json")" \
      --arg pow_after "$(sha_file "$root/candidate-final-pow-after.json")" \
      --arg staking "$(sha_file "$root/candidate-final-staking.json")" \
      --arg staking_after "$(sha_file "$root/candidate-final-staking-after.json")" \
      --arg recovery "$(sha_file "$root/candidate-final-recovery-inventory.json")" \
      --arg recovery_after "$(sha_file "$root/candidate-final-recovery-after.json")" \
      --arg wallet_tx "$(sha_file "$root/candidate-final-wallet-transactions.json")" \
      --arg mempool "$(sha_file "$root/candidate-final-mempool.json")" \
      --arg terminal "$(sha_file "$root/observer-terminal-proof.json")" \
      --arg observer_chain "$(sha_file "$root/observer-final-chain.jsonl")" \
      --arg observer_anchor "$(sha_file "$root/observer-anchor-unspent.jsonl")" \
      --arg observer_absence "$(sha_file "$root/observer-tx-absence.jsonl")" \
      --arg stable "$(sha_file "$root/candidate-final-stable-cut.json")" \
      --arg stopped "$(sha_file "$root/candidate-stopped.json")" \
      --arg stop_authority "$(sha_file "$root/candidate-stop-authority.json")" \
      --arg post "$(sha_file "$root/candidate-post-stop-log-receipt.json")" '
      .candidate_image_id=$image | .candidate_manifest_digest=$manifest |
      .candidate_blackcoin_qt_sha256=$qt | .invocation_sha256=$invocation |
      .helper_audit_sha256=$helper | .nonpublication_sha256=$isolation |
      .snapshot_set_sha256=$snapshots | .progress_sha256=$progress |
      .claim_proof_sha256=$claim | .logs_sha256=$logs | .rpc_journal_sha256=$rpc |
      .locks_sha256=$locks | .guard_sources_sha256=$guard | .pre_rewind_state_sha256=$state |
      .maintenance_marker_sha256=$maintenance | .offline_verifier_receipt_sha256=$receipt |
      .baseline_runtime_identity_sha256=$baseline | .candidate_bundle_manifest_sha256=$bundle |
      .candidate_oci_identity_sha256=$oci | .candidate_binary_sha256sums_sha256=$binaries |
      .candidate_loaded_image_sha256=$loaded | .pre_rewind_manifest_sha256=$pre |
      .phase_a_tooling_identity_sha256=$tooling_identity | .tooling_commit=$tooling |
      .package_sha256sums_sha256=$package | .phase_a_script_sha256=$phase_a |
      .phase_b_script_sha256=$phase_b | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract | .recovery_metrics_sha256=$recovery_metrics |
      .candidate_final_chain_sha256=$chain | .candidate_final_chain_after_sha256=$chain_after |
      .candidate_final_pow_sha256=$pow | .candidate_final_pow_after_sha256=$pow_after |
      .candidate_final_staking_sha256=$staking |
      .candidate_final_staking_after_sha256=$staking_after |
      .candidate_final_recovery_sha256=$recovery |
      .candidate_final_recovery_after_sha256=$recovery_after |
      .candidate_final_wallet_transactions_sha256=$wallet_tx |
      .candidate_final_mempool_sha256=$mempool |
      .observer_terminal_proof_sha256=$terminal | .observer_final_chain_sha256=$observer_chain |
      .observer_anchor_unspent_sha256=$observer_anchor |
      .observer_tx_absence_sha256=$observer_absence |
      .candidate_final_stable_cut_sha256=$stable |
      .candidate_stopped_receipt_sha256=$stopped |
      .candidate_stop_authority_sha256=$stop_authority |
      .candidate_post_stop_log_receipt_sha256=$post
    ' "$cert" >"$output"
    rm "$cert"
}

build_phase_a_final_fixture()
{
    local pre="$1" root="$2" hash invocation isolation observer no_restart
    mkdir -m 700 "$root"
    cp "$pre"/* "$root/"
    jq -S -n --arg nonce "$NONCE" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg manifest "$(sha_file "$root/PRE_REWIND_SHA256SUMS")" \
      --arg verifier "$(sha_file "$FIXTURE_VERIFIER")" '
      {schema:1,mode:"phase-a-pre-rewind",result:"passed",run_nonce:$nonce,
       candidate_source_sha:$source,pre_rewind_manifest_sha256:$manifest,
       verifier_sha256:$verifier}
    ' >"$root/pre-rewind-verifier.json"
    jq -S -n --arg nonce "$NONCE" '
      {schema:2,phase:"A",run_nonce:$nonce,state:"PRE_REWIND_VERIFIED",
       previous_state:"CANDIDATE_STOPPED"}
    ' >"$root/pre-rewind-state.json"
    jq -S -n --arg nonce "$NONCE" '{schema:1,run_nonce:$nonce,active:true}' \
        >"$root/maintenance-marker-activated.json"
    make_base_catchup_evidence "$root"
    update_rewind_safe_hashes "$root"
    no_restart='{"Name":"no","MaximumRetryCount":0}'
    make_phase_a_stable_stop base-quarantine-to-baseline \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF" "$no_restart" \
        "$root/base-quarantine-stop-authority.json"
    make_baseline_restored_evidence "$root"
    hash=$(printf '5%.0s' {1..64})
    invocation=$(sha_file "$root/base-quarantine-invocation-current.json")
    isolation=$(sha_file "$root/base-quarantine-nonpublication-current.json")
    observer=$(sha_file "$root/base-catchup-observer.jsonl")
    : >"$root/snapshot-destroy-authority-rechecks.jsonl"
    local index
    for index in {1..10}; do
        jq -cS -n --arg tip "$TIP4" --arg invocation "$invocation" \
          --arg isolation "$isolation" --arg observer "$observer" --argjson index "$index" '
          {authenticated_anchor_unspent:true,authority_valid:true,candidate_txids_absent:true,
           chain_tip:$tip,chainwork:$tip,invocation_sha256:$invocation,
           nonpublication_sha256:$isolation,observed_utc:("2026-08-08T00:00:"+
             (if $index<10 then "0" else "" end)+($index|tostring)+"Z"),
           observer_cut_sha256:$observer,pos_disabled:true,pow_disabled:true,
           terminal_relation:"same_terminal_tip",wallet_locked:true}
        ' >>"$root/snapshot-destroy-authority-rechecks.jsonl"
    done
    make_absence "$root/snapshot-set.json" "$root/snapshot-absence-proof.base.json"
    jq -S --arg catchup "$(sha_file "$root/base-catchup-proof.json")" \
      --arg authority "$(sha_file "$root/snapshot-destroy-authority-rechecks.jsonl")" '
      .catchup_proof_sha256=$catchup | .authority_rechecks_sha256=$authority
    ' "$root/snapshot-absence-proof.base.json" >"$root/snapshot-absence-proof.json"
    rm "$root/snapshot-absence-proof.base.json"
    seal_manifest "$root" POST_REWIND_SHA256SUMS SHA256SUMS RESULT.json
    make_phase_a_result "$root/RESULT.base.json"
    jq -S --arg cert "$(sha_file "$root/REWIND_SAFE.json")" \
      --arg catchup "$(sha_file "$root/base-catchup-proof.json")" \
      --arg absence "$(sha_file "$root/snapshot-absence-proof.json")" \
      --arg tooling_identity "$(sha_file "$root/tooling-identity.json")" \
      --arg tooling "$(jq -er '.tooling_commit' "$root/tooling-identity.json")" \
      --arg package "$(jq -er '.package_sha256sums_sha256' "$root/tooling-identity.json")" \
      --arg phase_a "$(jq -er '.phase_a_script_sha256' "$root/tooling-identity.json")" \
      --arg phase_b "$(jq -er '.phase_b_script_sha256' "$root/tooling-identity.json")" \
      --arg verifier "$(jq -er '.verifier_sha256' "$root/tooling-identity.json")" \
      --arg contract "$(jq -er '.typed_contract_sha256' "$root/tooling-identity.json")" \
      --arg recovery_metrics "$(recovery_metrics_sha_file "$root/baseline-recovery.json")" \
      --arg base_stop "$(sha_file "$root/base-quarantine-stop-authority.json")" \
      --arg restored_container "$(sha_file "$root/baseline-restored-container.json")" \
      --arg manifest "$(sha_file "$root/POST_REWIND_SHA256SUMS")" '
      .rewind_safe_sha256=$cert | .catchup_proof_sha256=$catchup |
      .snapshot_absence_sha256=$absence | .evidence_sha256sums_sha256=$manifest |
      .phase_a_tooling_identity_sha256=$tooling_identity | .tooling_commit=$tooling |
      .package_sha256sums_sha256=$package | .phase_a_script_sha256=$phase_a |
      .phase_b_script_sha256=$phase_b | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract |
      .baseline_recovery_metrics_sha256=$recovery_metrics |
      .base_quarantine_stop_authority_sha256=$base_stop |
      .baseline_restored_container_sha256=$restored_container
    ' "$root/RESULT.base.json" >"$root/RESULT.json"
    rm "$root/RESULT.base.json"
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

make_storage_absence_receipt()
{
    local stage="$1" result_sha="$2" snapshot_sha="$3" output="$4"
    jq -S -n --arg stage "$stage" --arg result "$result_sha" --arg nonce "$NONCE" \
      --arg set "$snapshot_sha" '
      def row($dataset):{dataset:$dataset,
        snapshot:($dataset+"@v30.1.4-hotfix-candidate-node27-"+$nonce),
        hold_tag:("blackcoin-hotfix-candidate-node27-"+$nonce),
        dataset_enumeration_succeeded:true,snapshot_absent:true,hold_absent:true};
      {schema:1,stage:$stage,phase_a_result_sha256:$result,phase_a_run_nonce:$nonce,
       snapshot_set_sha256:$set,zpool:"pulsar",zpool_health:"ONLINE",
       zfs_enumeration_succeeded:true,snapshots:[
        row("pulsar/Blackcoin_Blocks/node-data/node-27"),
        row("pulsar/Blackcoin_Blocks/node-data/node-27/blocks"),
        row("pulsar/Blackcoin_Blocks/node-data/node-27/indexes"),
        row("pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27")],
       all_snapshots_absent:true,all_holds_absent:true}
    ' >"$output"
}

make_live_datasets()
{
    jq -S -n '
      {schema:1,datasets:[
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27",guid:"101",
        mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27"},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/blocks",guid:"102",
        mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/blocks"},
       {dataset:"pulsar/Blackcoin_Blocks/node-data/node-27/indexes",guid:"103",
        mount_path:"/mnt/pulsar/Blackcoin_Blocks/node-data/node-27/indexes"},
       {dataset:"pulsar/Blackcoin_Blocks/alpha-chain-raw-clones-20260715T032403Z/node-27",
        guid:"104",mount_path:"/mnt/pulsar/Blackcoin_Blocks/27/blocks"}]}
    ' >"$1"
}

make_phase_b_cutover_stop()
{
    local original_policy="$1" output="$2"
    jq -S -n --arg id "$(printf 'c%.0s' {1..64})" \
      --arg image "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
      --arg started "2026-08-08T00:00:00Z" --arg finished "2026-08-08T00:00:01Z" \
      --argjson original "$original_policy" '
      {schema:1,container_id:$id,image_id:$image,image_ref:$ref,
       original_restart_policy:$original,
       armed_restart_policy:{Name:"no",MaximumRetryCount:0},
       stopped_restart_policy_first:{Name:"no",MaximumRetryCount:0},
       stopped_restart_policy_second:{Name:"no",MaximumRetryCount:0},
       started_at_before:$started,started_at_armed:$started,
       stopped_started_at_first:$started,stopped_started_at_second:$started,
       stopped_finished_at_first:$finished,stopped_finished_at_second:$finished,
       stopped_exit_code_first:0,stopped_exit_code_second:0,
       restart_count_before:0,restart_count_armed:0,restart_count_stopped_first:0,
       restart_count_stopped_second:0,restart_authority_disabled_before_rpc_stop:true,
       clean_rpc_stop_completed:true,stable_stopped_samples:2,old_core_restart_observed:false}
    ' >"$output"
}

make_phase_b_progress()
{
    local output="$1" sample tip height mining recovery staking wallet chain network
    local samples='[]'
    for sample in 1 2 3 4; do
        case "$sample" in
            1) tip=$TIP1; height=101 ;;
            2) tip=$TIP2; height=102 ;;
            3) tip=$TIP3; height=103 ;;
            4) tip=$TIP4; height=104 ;;
        esac
        mining=$(mining_json refresh_same_anchor | jq --arg tip "$tip" \
          '.claim_inventory_tip=$tip')
        recovery=$(recovery_json "$tip" 9)
        staking=$(staking_active "$height")
        wallet=$(jq -cn '{walletname:"",private_keys_enabled:true,scanning:false,
          unlocked_staking_only:false,unlocked_until:4102444800}')
        chain=$(jq -cn --arg tip "$tip" --argjson height "$height" \
          '{chain:"main",initialblockdownload:false,blocks:$height,headers:$height,
            bestblockhash:$tip,chainwork:$tip}')
        network=$(jq -cn '{networkactive:true,connections_out:4}')
        samples=$(jq -cn --argjson existing "$samples" --argjson sample "$sample" \
          --argjson chain "$chain" --argjson network "$network" --argjson wallet "$wallet" \
          --argjson staking "$staking" --argjson pow "$mining" \
          --argjson recovery "$recovery" '
          $existing+[{sample:$sample,observed_epoch:2000000000,chain:$chain,network:$network,
            wallet:$wallet,staking:$staking,pow:$pow,recovery:$recovery}]
        ')
    done
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg nonce 'fedcba9876543210fedcba9876543210' --argjson samples "$samples" '
      {schema:1,phase:"B",candidate_source_sha:$source,promotion_nonce:$nonce,
       samples:$samples,tip_changes:3,wallet_chain_synchronized_continuously:true,
       pos_active_continuously:true,p2p_ready_continuously:true}
    ' >"$output"
}

make_phase_b_wallet_delta()
{
    local root="$1" coinstake payout coin_block payout_block coinbase claim_row
    local recovery raw_sha baseline_sha final_sha recovery_sha
    coinstake=$(printf 'a%.0s' {1..64})
    payout=$(printf '6%.0s' {1..64})
    coin_block=$(printf 'b%.0s' {1..64})
    payout_block=$(printf 'c%.0s' {1..64})
    coinbase=$(printf '0%.0s' {1..63}; printf '1')
    jq -S -n --arg old "$ANCHOR" '
      [{txid:$old,category:"receive",amount:1000,confirmations:100,abandoned:false}]
    ' >"$root/baseline-wallet-transactions.json"
    claim_row=$(make_claim_wallet_row "$CLAIM1" 0 "$HOTFIX_ZERO_TXID" "$TIP4")
    jq -S -n --slurpfile baseline "$root/baseline-wallet-transactions.json" \
      --arg coinstake "$coinstake" --arg payout "$payout" --arg coin_block "$coin_block" \
      --arg payout_block "$payout_block" --argjson claim "$claim_row" '
      $baseline[0]+[
       {txid:$coinstake,generated:true,category:"generate",abandoned:false,
        blockhash:$coin_block,amount:1.5},$claim,
       {txid:$payout,qq_synthetic_goldrush_payout:"1",generated:true,category:"generate",
        abandoned:false,blockhash:$payout_block,amount:1.5}]
    ' >"$root/candidate-final-wallet-transactions.json"
    recovery=$(recovery_json "$TIP4" 9)
    printf '%s\n' "$recovery" >"$root/candidate-final-recovery.json"
    baseline_sha=$(sha_file "$root/baseline-wallet-transactions.json")
    final_sha=$(sha_file "$root/candidate-final-wallet-transactions.json")
    recovery_sha=$(sha_file "$root/candidate-final-recovery.json")
    jq -S -n --arg baseline "$baseline_sha" --arg final "$final_sha" \
      --arg recovery "$recovery_sha" --arg coinstake "$coinstake" --arg claim "$CLAIM1" \
      --arg payout "$payout" --arg coin_block "$coin_block" --arg payout_block "$payout_block" \
      --arg coinbase "$coinbase" --arg family "$FAMILY" --arg address Qfixture \
      --slurpfile wallet "$root/candidate-final-wallet-transactions.json" \
      --slurpfile inventory "$root/candidate-final-recovery.json" '
      def rows($id):[$wallet[0][]|select(.txid==$id)];
      def matches($id):[$inventory[0].component_details[] as $component |
        $component.nodes[]|select(.txid==$id)|{component:$component,node:.}];
      {schema:1,baseline_wallet_transactions_sha256:$baseline,
       final_wallet_transactions_sha256:$final,recovery_inventory_sha256:$recovery,
       records:[
        {txid:$payout,class:"authenticated_qq_claim_payout",wallet_rows:rows($payout),
         recovery_matches:matches($claim),blockhash:$payout_block,source_claim_txid:$claim,
         getblock_response:null,getshadowtransaction_response:{
          schema:"blackcoin.shadow.transaction.v1",synthetic:true,merkle_included:false,
          synthetic_txid:$payout,mode:"pow",base_anchor:{blockhash:$payout_block},
          address:$address,status:"unspent",pow_claim_source:{input_bound:true,
           disposition:"winner",txid:$claim}}},
        {txid:$coinstake,class:"confirmed_coinstake",wallet_rows:rows($coinstake),
         recovery_matches:[],blockhash:$coin_block,source_claim_txid:null,
         getblock_response:{hash:$coin_block,confirmations:1,tx:[$coinbase,$coinstake]},
         getshadowtransaction_response:null},
        {txid:$claim,class:"authenticated_qq_claim",wallet_rows:rows($claim),
         recovery_matches:matches($claim),blockhash:null,source_claim_txid:null,
         getblock_response:null,getshadowtransaction_response:null}],complete:true}
    ' >"$root/phase-b-wallet-delta-raw.json"
    raw_sha=$(sha_file "$root/phase-b-wallet-delta-raw.json")
    jq -S -n --arg old "$ANCHOR" --arg coinstake "$coinstake" --arg claim "$CLAIM1" \
      --arg payout "$payout" --arg coin_block "$coin_block" --arg payout_block "$payout_block" \
      --arg raw "$raw_sha" '
      {schema:1,baseline_txids:[$old],new_txids:[$payout,$coinstake,$claim],removed_txids:[],
       allowed_classes:["confirmed_coinstake","authenticated_qq_claim",
        "authenticated_qq_claim_payout"],classifications:[
         {txid:$payout,class:"authenticated_qq_claim_payout",blockhash:$payout_block,
          source_claim_txid:$claim},
         {txid:$coinstake,class:"confirmed_coinstake",blockhash:$coin_block},
         {txid:$claim,class:"authenticated_qq_claim"}],rejected_txids:[],complete:true,
       raw_evidence_sha256:$raw}
    ' >"$root/phase-b-wallet-delta.json"
}

make_phase_b_authority()
{
    local phase_a="$1" root="$2" phase_a_sha snapshot_sha package_sha script_sha verifier_sha contract_sha
    local name hash files='{}' tooling
    local -a names=(SHA256SUMS RESULT.json REWIND_SAFE.json snapshot-set.json
      snapshot-absence-proof.json candidate-loaded-image.json candidate-bundle-manifest.json
      candidate-oci-identity.json candidate-binary-sha256sums.txt baseline-runtime-identity.json
      candidate-invocation-restart.json base-catchup-proof.json guard-source-identity.json
      maintenance-marker-activated.json unlock-helper-audit.json tooling-identity.json
      base-quarantine-stop-authority.json baseline-restored-container.json)
    for name in "${names[@]}"; do
        cp "$phase_a/$name" "$root/phase-a-$name"
        hash=$(sha_file "$root/phase-a-$name")
        files=$(jq -cn --argjson existing "$files" --arg name "$name" --arg hash "$hash" \
          '$existing+{($name):$hash}')
    done
    phase_a_sha=$(sha_file "$root/phase-a-RESULT.json")
    snapshot_sha=$(sha_file "$root/phase-a-snapshot-set.json")
    for name in before-marker after-marker before-launch; do
        make_storage_absence_receipt "$name" "$phase_a_sha" "$snapshot_sha" \
            "$root/storage-absence-${name}.json"
    done
    package_sha=$(sha_file "$FIXTURE_PACKAGE/SHA256SUMS")
    script_sha=$(sha_file \
      "$FIXTURE_PACKAGE/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh")
    verifier_sha=$(sha_file "$FIXTURE_VERIFIER")
    contract_sha=$(sha_file "$FIXTURE_PACKAGE/lib/typed_contract.sh")
    tooling=$(jq -er '.tooling_commit' "$root/phase-a-REWIND_SAFE.json")
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg tooling "$tooling" \
      --arg package "$package_sha" --arg script "$script_sha" --arg verifier "$verifier_sha" \
      --arg contract "$contract_sha" '
      {schema:1,candidate_source_sha:$source,tooling_commit:$tooling,
       package_sha256sums_sha256:$package,phase_b_script_sha256:$script,
       verifier_sha256:$verifier,typed_contract_sha256:$contract,
       exact_bytes_recorded_before_irreversible_marker:true}
    ' >"$root/phase-b-tooling-identity.json"
    jq -S -n --arg result "$phase_a_sha" --arg nonce "$NONCE" \
      --arg ref "$(jq -er '.candidate_image_ref' "$root/phase-a-REWIND_SAFE.json")" \
      --arg id "$(jq -er '.candidate_image_id' "$root/phase-a-REWIND_SAFE.json")" \
      --arg manifest "$(jq -er '.candidate_manifest_digest' "$root/phase-a-REWIND_SAFE.json")" \
      --arg qt "$(jq -er '.candidate_blackcoin_qt_sha256' "$root/phase-a-REWIND_SAFE.json")" \
      --arg compose "$(jq -er '.compose_sha256' "$root/phase-a-REWIND_SAFE.json")" \
      --arg tooling "$tooling" --arg source_manifest "$(sha_file "$root/phase-a-SHA256SUMS")" \
      --arg maintenance "$(sha_file "$root/phase-a-maintenance-marker-activated.json")" \
      --argjson files "$files" '
      {schema:1,phase_a_result_sha256:$result,phase_a_run_nonce:$nonce,
       candidate_image_ref:$ref,candidate_image_id:$id,candidate_manifest_digest:$manifest,
       candidate_blackcoin_qt_sha256:$qt,compose_sha256:$compose,tooling_commit:$tooling,
       source_manifest_sha256:$source_manifest,maintenance_marker_sha256:$maintenance,
       copied_under_all_four_locks:true,source_reverified_immediately_before_copy:true,
       source_reverified_after_copy:true,all_copies_manifest_bound:true,files:$files}
    ' >"$root/phase-a-authority-receipt.json"
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg result "$phase_a_sha" \
      --arg phase_manifest "$(sha_file "$root/phase-a-SHA256SUMS")" --arg nonce "$NONCE" \
      --arg storage "$(sha_file "$root/storage-absence-before-marker.json")" \
      --arg authority "$(sha_file "$root/phase-a-authority-receipt.json")" \
      --arg rewind "$(sha_file "$root/phase-a-REWIND_SAFE.json")" \
      --arg ref "$(jq -er '.candidate_image_ref' "$root/phase-a-REWIND_SAFE.json")" \
      --arg id "$(jq -er '.candidate_image_id' "$root/phase-a-REWIND_SAFE.json")" \
      --arg manifest "$(jq -er '.candidate_manifest_digest' "$root/phase-a-REWIND_SAFE.json")" \
      --arg tooling "$tooling" --arg tooling_id "$(sha_file "$root/phase-b-tooling-identity.json")" \
      --arg package "$package_sha" --arg script "$script_sha" --arg verifier "$verifier_sha" \
      --arg contract "$contract_sha" '
      {schema:1,state:"PROMOTED_NO_REWIND",node:27,candidate_source_sha:$source,
       phase_a_result_sha256:$result,phase_a_evidence_sha256sums_sha256:$phase_manifest,
       phase_a_run_nonce:$nonce,promotion_nonce:"fedcba9876543210fedcba9876543210",
       storage_absence_sha256:$storage,phase_a_authority_receipt_sha256:$authority,
       phase_a_rewind_safe_sha256:$rewind,candidate_image_ref:$ref,candidate_image_id:$id,
       candidate_manifest_digest:$manifest,tooling_commit:$tooling,
       phase_b_tooling_identity_sha256:$tooling_id,package_sha256sums_sha256:$package,
       phase_b_script_sha256:$script,verifier_sha256:$verifier,typed_contract_sha256:$contract,
       created_utc:"2026-08-08T00:00:00Z",data_rewind_permanently_prohibited:true,
       marker_fsync_verified:true,parent_directory_fsync_verified:true,reread_verified:true,
       snapshots_absent_before_marker:true}
    ' >"$root/PROMOTED_NO_REWIND.json"
}

build_phase_b_final_fixture()
{
    local phase_a="$1" root="$2" candidate_id image_ref promotion_nonce
    local chain network wallet staking pow recovery policy_sha metrics_sha observed
    local config mounts net restart argv_sha phase_a_sha package_sha script_sha verifier_sha contract_sha
    mkdir -m 700 "$root"
    make_phase_b_authority "$phase_a" "$root"
    candidate_id=$(jq -er '.candidate_image_id' "$root/phase-a-REWIND_SAFE.json")
    image_ref=$(jq -er '.candidate_image_ref' "$root/phase-a-REWIND_SAFE.json")
    promotion_nonce=$(jq -er '.promotion_nonce' "$root/PROMOTED_NO_REWIND.json")
    config=$(jq -er '.blackcoin_conf_sha256' "$root/phase-a-baseline-runtime-identity.json")
    mounts=$(jq -er '.mounts_sha256' "$root/phase-a-baseline-runtime-identity.json")
    net=$(jq -er '.network_sha256' "$root/phase-a-baseline-runtime-identity.json")
    restart='{"MaximumRetryCount":0,"Name":"unless-stopped"}'
    jq -S -n --arg id "$IMMUTABLE_V3014_IMAGE_ID" --arg ref "$IMMUTABLE_V3014_IMAGE_REF" \
      --argjson restart "$restart" '
      {schema:1,container_id:("c"*64),image_id:$id,image_ref:$ref,running:true,
       restart_policy:$restart}
    ' >"$root/baseline-docker-runtime.json"
    make_phase_b_cutover_stop "$restart" "$root/baseline-cutover-stop.json"
    make_invocation B "$root/candidate-invocation.json" "$candidate_id" "$promotion_nonce"
    jq -S -n --arg id "$candidate_id" --arg mounts "$mounts" --arg network "$net" \
      --argjson restart "$restart" '
      {image_id:$id,running:false,user:"blackcoin",working_dir:"/home/blackcoin",
       mounts_sha256:$mounts,network_sha256:$network,restart_policy:$restart}
    ' >"$root/candidate-created-stopped.json"
    make_live_datasets "$root/baseline-live-datasets.json"
    cp "$root/baseline-live-datasets.json" "$root/candidate-final-live-datasets.json"
    chain=$(jq -cn --arg tip "$TIP4" '{chain:"main",initialblockdownload:false,blocks:104,
      headers:104,bestblockhash:$tip,chainwork:$tip}')
    printf '%s\n' "$chain" >"$root/baseline-chain.json"
    printf '%s\n' "$chain" >"$root/baseline-chain-after.json"
    printf '%s\n' "$chain" >"$root/candidate-final-chain.json"
    printf '%s\n' "$chain" >"$root/candidate-final-chain-after.json"
    network=$(jq -cn '{networkactive:true,localrelay:true,connections_out:4}')
    printf '%s\n' "$network" >"$root/baseline-network.json"
    printf '%s\n' "$network" >"$root/candidate-final-network.json"
    observed=2000000000
    wallet=$(jq -cn '{walletname:"",private_keys_enabled:true,scanning:false,
      unlocked_staking_only:false,unlocked_until:4102444800}')
    printf '%s\n' "$wallet" >"$root/baseline-wallet.json"
    printf '%s\n' "$wallet" >"$root/candidate-final-wallet.json"
    staking=$(staking_active 104)
    printf '%s\n' "$staking" >"$root/baseline-staking.json"
    printf '%s\n' "$staking" >"$root/candidate-final-staking.json"
    pow=$(mining_json refresh_same_anchor)
    printf '%s\n' "$pow" >"$root/baseline-pow.json"
    printf '%s\n' "$pow" >"$root/candidate-final-pow.json"
    make_phase_b_wallet_delta "$root"
    cp "$root/candidate-final-recovery.json" "$root/baseline-recovery.json"
    recovery=$(<"$root/candidate-final-recovery.json")
    jq -S -n '[{key:"q1"},{key:"q2"}]' >"$root/baseline-quantum.json"
    cp "$root/baseline-quantum.json" "$root/candidate-final-quantum.json"
    jq -n '[""]' >"$root/baseline-loaded-wallets.json"
    cp "$root/baseline-loaded-wallets.json" "$root/candidate-final-loaded-wallets.json"
    jq -S -n '{address:"Qfixture",ismine:true}' >"$root/baseline-payout-address.json"
    jq -n '[]' >"$root/baseline-resolution-txids.json"
    cp "$root/baseline-resolution-txids.json" "$root/candidate-final-resolution-txids.json"
    policy_sha=$(jq -cS '{policy_authoritative,policy_state_status,policy}' \
      "$root/baseline-recovery.json" | sha256sum | awk '{print $1}')
    metrics_sha=$(jq -cS '{pending_manual_resolutions,pending_automatic_resolutions,
      confirmed_manual_resolutions,confirmed_automatic_resolutions,
      confirmed_resolution_fees,automatic_actions_in_window,
      automatic_fee_exposure_in_window,reconciled_descendant_claims,claims_recycled}' \
      "$root/baseline-recovery.json" | sha256sum | awk '{print $1}')
    jq -S -n --argjson observed "$observed" --arg tip "$TIP4" --arg policy "$policy_sha" \
      --arg metrics "$metrics_sha" '
      {schema:1,observed_epoch:$observed,stable_tip:$tip,main_chain_ready:true,p2p_ready:true,
       wallet_normally_unlocked:true,exact_loaded_wallets:[""],staking_active:true,
       payout_address:"Qfixture",payout_owned:true,quantum_key_count:2,
       recovery_policy_sha256:$policy,recovery_metrics_sha256:$metrics,
       recovery_database_unambiguous:true,recovery_policy_nonautomatic:true,
       pending_recovery_actions_zero:true,irreversible_marker_allowed:true}
    ' >"$root/baseline-precondition.json"
    jq -S -n --argjson chain "$chain" --argjson recovery "$recovery" '
      {schema:1,synchronized:true,chain:$chain,recovery:$recovery,
       wallet:{walletname:"",private_keys_enabled:true,scanning:false,unlocked_until:0,
        unlocked_staking_only:false}}
    ' >"$root/candidate-chain-wallet-synchronized.json"
    make_phase_b_progress "$root/phase-b-progress.json"
    : >"$root/rpc-methods.log"
    argv_sha=$(jq -er '.runtime_argv_sha256' "$root/candidate-invocation.json")
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg id "$candidate_id" \
      --arg ref "$image_ref" --arg container "$(jq -er '.container_id' "$root/candidate-invocation.json")" \
      --arg started "$(jq -er '.container_started_at' "$root/candidate-invocation.json")" \
      --arg qt "$(jq -er '.pid1_exe_sha256' "$root/candidate-invocation.json")" \
      --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" \
      --arg start "$IMMUTABLE_START_GUI_SHA256" \
      --argjson argv "$(jq -c '.runtime_argv' "$root/candidate-invocation.json")" \
      --arg argv_sha "$argv_sha" --arg config "$config" --arg mounts "$mounts" \
      --arg network "$net" --argjson restart "$restart" '
      {schema:1,candidate_source_sha:$source,image_id:$id,image_ref:$ref,
       container_id:$container,running_first:true,running_second:true,
       stable_started_at:$started,stable_restart_count:0,pid1_exe_sha256:$qt,
       start_gui_sha256:$start,entrypoint_body_sha256:$body,runtime_argv:$argv,
       runtime_argv_sha256:$argv_sha,config_sha256:$config,mounts_sha256:$mounts,
       network_sha256:$network,restart_policy:$restart,
       identity_stable_across_two_samples:true,candidate_running_without_restart:true}
    ' >"$root/candidate-final-container.json"
    jq -S -n --argjson observed "$observed" --arg tip "$TIP4" \
      --argjson chain "$chain" --argjson network "$network" --argjson wallet "$wallet" \
      --argjson staking "$staking" --argjson pow "$pow" --argjson recovery "$recovery" \
      --arg policy "$policy_sha" --arg metrics "$metrics_sha" \
      --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg raw "$(sha_file "$root/phase-b-wallet-delta-raw.json")" '
      {schema:1,observed_epoch:$observed,stable_tip:$tip,chain:$chain,chain_after:$chain,
       network:$network,wallet:$wallet,staking:$staking,pow:$pow,recovery:$recovery,
       loaded_wallets:[""],pow_mode:"active",chain_before_after_identical:true,
       chain_recovery_pow_tip_bound:true,wallet_unlock_current:true,exact_loaded_wallets:[""],
       recovery_policy_sha256:$policy,recovery_metrics_sha256:$metrics,
       recovery_counters_unchanged:true,recovery_txids_unchanged:true,
       wallet_delta_sha256:$delta,wallet_delta_raw_sha256:$raw,
       wallet_delta_fully_classified:true}
    ' >"$root/phase-b-final-envelope.json"
    seal_manifest "$root" PRE_RESULT_SHA256SUMS SHA256SUMS RESULT.json
    phase_a_sha=$(sha_file "$root/phase-a-RESULT.json")
    package_sha=$(sha_file "$FIXTURE_PACKAGE/SHA256SUMS")
    script_sha=$(sha_file \
      "$FIXTURE_PACKAGE/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh")
    verifier_sha=$(sha_file "$FIXTURE_VERIFIER")
    contract_sha=$(sha_file "$FIXTURE_PACKAGE/lib/typed_contract.sh")
    make_phase_b_result "$phase_a_sha" "$root/RESULT.base.json"
    jq -S --arg marker "$(sha_file "$root/PROMOTED_NO_REWIND.json")" \
      --arg invocation "$(sha_file "$root/candidate-invocation.json")" \
      --arg datasets "$(sha_file "$root/candidate-final-live-datasets.json")" \
      --arg absence "$(sha_file "$root/storage-absence-before-launch.json")" \
      --arg progress "$(sha_file "$root/phase-b-progress.json")" \
      --arg pre "$(sha_file "$root/PRE_RESULT_SHA256SUMS")" \
      --arg container "$(sha_file "$root/candidate-final-container.json")" \
      --arg envelope "$(sha_file "$root/phase-b-final-envelope.json")" \
      --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg raw "$(sha_file "$root/phase-b-wallet-delta-raw.json")" \
      --arg baseline "$(sha_file "$root/baseline-precondition.json")" \
      --arg cutover "$(sha_file "$root/baseline-cutover-stop.json")" \
      --arg tooling_id "$(sha_file "$root/phase-b-tooling-identity.json")" \
      --arg tooling "$(jq -er '.tooling_commit' "$root/phase-b-tooling-identity.json")" \
      --arg package "$package_sha" --arg script "$script_sha" --arg verifier "$verifier_sha" \
      --arg contract "$contract_sha" --arg policy "$policy_sha" --arg metrics "$metrics_sha" '
      .marker_sha256=$marker | .invocation_sha256=$invocation |
      .live_dataset_identity_sha256=$datasets | .storage_absence_recheck_sha256=$absence |
      .phase_b_progress_sha256=$progress | .pre_result_manifest_sha256=$pre |
      .final_container_sha256=$container | .final_envelope_sha256=$envelope |
      .wallet_delta_sha256=$delta | .wallet_delta_raw_sha256=$raw |
      .baseline_precondition_sha256=$baseline | .baseline_cutover_stop_sha256=$cutover |
      .tooling_commit=$tooling |
      .phase_b_tooling_identity_sha256=$tooling_id | .package_sha256sums_sha256=$package |
      .phase_b_script_sha256=$script | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract | .baseline_recovery_policy_sha256=$policy |
      .baseline_recovery_metrics_sha256=$metrics
    ' "$root/RESULT.base.json" >"$root/RESULT.json"
    rm "$root/RESULT.base.json"
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

reseal_phase_b_fixture()
{
    local root="$1" raw_sha
    raw_sha=$(sha_file "$root/phase-b-wallet-delta-raw.json")
    jq -S --arg raw "$raw_sha" '.raw_evidence_sha256=$raw' \
        "$root/phase-b-wallet-delta.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-wallet-delta.json"
    jq -S --arg raw "$raw_sha" --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" '
      .wallet_delta_raw_sha256=$raw | .wallet_delta_sha256=$delta
    ' "$root/phase-b-final-envelope.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-final-envelope.json"
    seal_manifest "$root" PRE_RESULT_SHA256SUMS SHA256SUMS RESULT.json
    jq -S --arg raw "$raw_sha" --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg envelope "$(sha_file "$root/phase-b-final-envelope.json")" \
      --arg pre "$(sha_file "$root/PRE_RESULT_SHA256SUMS")" '
      .wallet_delta_raw_sha256=$raw | .wallet_delta_sha256=$delta |
      .final_envelope_sha256=$envelope | .pre_result_manifest_sha256=$pre
    ' "$root/RESULT.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/RESULT.json"
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

clone_fixture_tree()
{
    local source="$1" target="$2"
    mkdir -m 700 "$target"
    cp "$source"/* "$target/"
    secure_fixture_tree "$target"
}

mutate_json_in_place()
{
    local file="$1" temporary
    shift
    temporary="${file}.mutation"
    jq "$@" "$file" >"$temporary"
    mv "$temporary" "$file"
}

mutate_core_ci_fixture()
{
    local root="$1" filter="$2"
    mutate_json_in_place "$root/candidate-core-ci.json" "$filter"
    jq -S --slurpfile core "$root/candidate-core-ci.json" '
      .core_ci=$core[0] | .authorization.core_ci_run_id=$core[0].run_id
    ' "$root/candidate-bundle-manifest.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/candidate-bundle-manifest.json"
    reseal_phase_a_pre_fixture "$root"
}

reseal_phase_a_pre_fixture()
{
    local root="$1"
    seal_manifest "$root" PRE_REWIND_SHA256SUMS
    secure_fixture_tree "$root"
}

reseal_phase_a_final_fixture()
{
    local root="$1"
    seal_manifest "$root" POST_REWIND_SHA256SUMS SHA256SUMS RESULT.json
    mutate_json_in_place "$root/RESULT.json" \
      ".evidence_sha256sums_sha256=\"$(sha_file "$root/POST_REWIND_SHA256SUMS")\""
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

INV_A="$TMP/inv-a.json"
INV_B="$TMP/inv-b.json"
HELPER="$TMP/helper.json"
ISOLATION="$TMP/isolation.json"
PROGRESS="$TMP/progress.json"
CLAIM="$TMP/claim.json"
SNAPSHOTS="$TMP/snapshots.json"
CERT="$TMP/cert.json"
CATCHUP="$TMP/catchup.json"
ABSENCE="$TMP/absence.json"
RESULT_A="$TMP/result-a.json"
MARKER="$TMP/marker.json"
RESULT_B="$TMP/result-b.json"
BASE_STOP="$TMP/base-stop.json"
CANDIDATE_STOP="$TMP/candidate-stop-authority.json"
QUARANTINE_STOP="$TMP/quarantine-stop.json"
CANDIDATE_TEST_REF="$HOTFIX_CANDIDATE_IMAGE_REF"
BASELINE_RESTART_POLICY='{"Name":"unless-stopped","MaximumRetryCount":0}'
NO_RESTART_POLICY='{"Name":"no","MaximumRetryCount":0}'

make_invocation A "$INV_A"
make_invocation B "$INV_B"
make_helper "$HELPER"
make_nonpublication "$ISOLATION"
make_progress "$PROGRESS"
make_claim "$CLAIM"
make_snapshot_set "$SNAPSHOTS"
make_rewind_safe "$CERT"
make_catchup "$CATCHUP"
make_absence "$SNAPSHOTS" "$ABSENCE"
make_phase_a_result "$RESULT_A"
make_phase_a_stable_stop baseline-pre-snapshot "$IMMUTABLE_V3014_IMAGE_ID" \
    "$IMMUTABLE_V3014_IMAGE_REF" "$BASELINE_RESTART_POLICY" "$BASE_STOP"
make_phase_a_stable_stop candidate-terminal "$IMAGE_ID" "$CANDIDATE_TEST_REF" \
    "$NO_RESTART_POLICY" "$CANDIDATE_STOP"
make_phase_a_stable_stop base-quarantine-to-baseline "$IMMUTABLE_V3014_IMAGE_ID" \
    "$IMMUTABLE_V3014_IMAGE_REF" "$NO_RESTART_POLICY" "$QUARANTINE_STOP"
RESULT_A_SHA=$(sha256sum "$RESULT_A" | awk '{print $1}')
make_marker "$RESULT_A_SHA" "$MARKER"
make_phase_b_result "$RESULT_A_SHA" "$RESULT_B"

ok 'provisional candidate source/release identity is exact' hotfix_candidate_identity_is_resolved
ok 'provisional candidate prefix is exact' test "$HOTFIX_CANDIDATE_PREFIX" = \
    'Blackcoin-30.1.5-candidate-a0695f22740e'
ok 'provisional candidate archive name is exact' test "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" = \
    'blackcoin-v4-gui-30.1.5-candidate-a0695f22740e.oci.tar'
ok 'provisional candidate image tag is exact' test "$HOTFIX_CANDIDATE_IMAGE_TAG" = \
    '30.1.5-candidate-a0695f22740e-ci1'
ok 'candidate artifact name is exact and workflow-attempt-bound' test \
    "$(hotfix_candidate_artifact_name 7)" = \
    "v${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-linux-x86_64-${HOTFIX_CANDIDATE_SOURCE_SHA}-attempt-7"
reject 'zero workflow attempt cannot derive a candidate artifact' hotfix_candidate_artifact_name 0
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
ok 'committed provisional defaults resolve only to the exact H and release' \
    /usr/bin/env -u HOTFIX_CANDIDATE_SOURCE_SHA -u HOTFIX_CANDIDATE_RELEASE_VERSION \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved &&
          [[ "$HOTFIX_CANDIDATE_SOURCE_SHA" == a0695f22740e111d0487a194fb46f1bae05952c5 &&
             "$HOTFIX_CANDIDATE_RELEASE_VERSION" == 30.1.5 ]]' \
        _ "$ROOT/lib/typed_contract.sh"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'alternate valid candidate source override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.5 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$ROOT/lib/typed_contract.sh"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'immutable v30.1.4 source override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA="$IMMUTABLE_V3014_SOURCE_SHA" \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.5 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$ROOT/lib/typed_contract.sh"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'nonexact release override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA="$HOTFIX_EXPECTED_CANDIDATE_SOURCE_SHA" \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.4 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$ROOT/lib/typed_contract.sh"
# shellcheck disable=SC2016 # The file paths are passed to the isolated child shell.
ok 'Phase-A and offline verifier both bind exact Core run, base, and workflow bytes' \
    /bin/bash -c '
      for file in "$1" "$2"; do
        grep -Fq HOTFIX_EXPECTED_CORE_CI_RUN_ID "$file" &&
          grep -Fq HOTFIX_EXPECTED_CORE_CI_PULL_REQUEST_BASE_SHA "$file" &&
          grep -Fq HOTFIX_EXPECTED_CORE_CI_WORKFLOW_BLOB_SHA256 "$file" || exit 1
      done
    ' _ "$ROOT/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh" \
        "$ROOT/verify-evidence.sh"

ok 'Phase-A exact invocation accepted' hotfix_invocation_file_is_valid "$INV_A" A "$IMAGE_ID" "$NONCE"
ok 'Phase-B exact invocation accepted' hotfix_invocation_file_is_valid "$INV_B" B "$IMAGE_ID" "$NONCE"
for index in 0 1 2 3 4 5 6; do
    mutate "$INV_A" "$TMP/m.json" ".effective_cmd |= del(.[${index}])"
    reject "Phase-A missing hard flag ${index}" hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
done
mutate "$INV_A" "$TMP/m.json" '.effective_cmd[2]="-staking=1"'
reject 'Phase-A active staking flag rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
mutate "$INV_A" "$TMP/m.json" '.effective_cmd += ["-walletbroadcast=1"]'
reject 'Phase-A contradictory duplicate flag rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
mutate "$INV_A" "$TMP/m.json" '.effective_entrypoint[3]="wrong"'
reject 'wrong fixed sentinel rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
mutate "$INV_A" "$TMP/m.json" '.runtime_argv[2]="-staking=1"'
reject 'runtime argv drift rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
mutate "$INV_A" "$TMP/m.json" '.created_stopped=false'
reject 'candidate not created stopped rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"
mutate "$INV_A" "$TMP/m.json" '.setup_processes.websockify=false'
reject 'missing immutable setup process rejected' hotfix_invocation_file_is_valid "$TMP/m.json" A "$IMAGE_ID" "$NONCE"

ok 'unlock-only helper audit accepted' hotfix_unlock_helper_audit_file_is_valid "$HELPER"
for filter in '.mode="644"' '.symlink=true' '.bash_syntax=false' \
    '.mutating_rpc_methods+=["staking"]' '.walletpassphrase_staking_only=true' \
    '.forbidden_tokens+=["setpowmining"]' '.indirection_detected=true' \
    '.secret_captured=true' '.invoked_during_audit=true'; do
    mutate "$HELPER" "$TMP/m.json" "$filter"
    reject "helper hostile mutation ${filter}" hotfix_unlock_helper_audit_file_is_valid "$TMP/m.json"
done

ok 'nonpublication surface accepted' hotfix_nonpublication_file_is_valid "$ISOLATION" "$NONCE"
for filter in '.rpc_loopback_only=false' '.rpc_host_port_bindings+=["15715/tcp"]' \
    '.gui_vnc_external_probe="unknown"' '.vpn_firewall_blocks_gui_vnc=false' \
    '.vpn_namespace_sharers+=["attacker"]' '.probe_results[2].reachable=true' \
    '.keeper_api_suspended=false' '.walletnotify="/tmp/export"' \
    '.zmq_transaction_endpoints+=["tcp://0.0.0.0:1"]' \
    '.relay_forcerelay_peer_ids+=[1]' '.all_peer_relaytxes_false=false' \
    '.network_localrelay=true' '.blocksonly=false' '.unknown_surfaces+=["vpn-ingress"]'; do
    mutate "$ISOLATION" "$TMP/m.json" "$filter"
    reject "nonpublication hostile mutation ${filter}" hotfix_nonpublication_file_is_valid "$TMP/m.json" "$NONCE"
done

for action in create_new_anchor wait_for_live wait_for_next_tip relay_existing refresh_same_anchor; do
    mining_json "$action" >"$TMP/mining.json"
    ok "typed safe action ${action}" hotfix_candidate_pow_json_is_valid "$(<"$TMP/mining.json")" active
done
mining_json wait_for_live >"$TMP/mining.json"
mutate "$TMP/mining.json" "$TMP/m.json" '.mining_gate_unsafe_claims=1'
reject 'unsafe claim rejected' hotfix_candidate_pow_json_is_valid "$(<"$TMP/m.json")" active
mutate "$TMP/mining.json" "$TMP/m.json" 'del(.mining_gate_candidate_state_fingerprint)'
reject 'partial typed schema rejected' hotfix_candidate_pow_json_is_valid "$(<"$TMP/m.json")" active
mutate "$TMP/mining.json" "$TMP/m.json" '.mining_gate_action="unknown"'
reject 'unknown typed action rejected' hotfix_candidate_pow_json_is_valid "$(<"$TMP/m.json")" active
ok 'hard-disabled Phase-A staking accepted' hotfix_phase_a_staking_json_is_disabled "$(staking_disabled)"
reject 'active PoS rejected during Phase A' hotfix_phase_a_staking_json_is_disabled "$(staking_active)"
ok 'active PoS accepted during Phase B' hotfix_phase_b_staking_json_is_active "$(staking_active)"

ok 'three-tip Phase-A progress accepted' hotfix_phase_a_progress_file_is_valid "$PROGRESS"
for filter in '.tip_changes=2' '.pos_disabled_continuous=false' \
    '.nonpublication_continuous=false' '.envelopes[2].staking.enabled=true' \
    '.envelopes[3].chain_before.chainwork=.envelopes[2].chain_before.chainwork' \
    '.envelopes[1].mining_after.mining_gate_database_ambiguous=true' \
    '.envelopes[1].recovery_after.confirmed_manual_resolutions=1' \
    '.envelopes[1].recovery_after.confirmed_automatic_resolutions=1' \
    '.envelopes[1].recovery_after.automatic_actions_in_window=1' \
    '.envelopes[1].recovery_after.automatic_fee_exposure_in_window=1' \
    '.envelopes[1].recovery_after.reconciled_descendant_claims=1' \
    '.envelopes[1].recovery_after.claims_recycled=1'; do
    mutate "$PROGRESS" "$TMP/m.json" "$filter"
    reject "progress hostile mutation ${filter}" hotfix_phase_a_progress_file_is_valid "$TMP/m.json"
done

ok 'same-anchor persisted-pending claim proof accepted' hotfix_phase_a_claim_proof_file_is_valid "$CLAIM"
for filter in '.candidate_created_qqsproof_txids=[]' \
    '.candidate_created_qqsproof_mempool_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_confirmed_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_observer_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_unclassifiable_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.observer_status="unknown"' '.new_nonclaim_wallet_transactions=["x"]' \
    '.coinstake_created_txids=["x"]' '.lineage.same_anchor=false' \
    '.lineage.same_family=false' '.lineage.same_root=false' \
    '.lineage.contiguous_parents=false' '.lineage.same_tip_duplicates=true' \
    '.lineage.tip_span=2' '.lineage.members[1].ordinal=2' \
    '.lineage.members[0].quarantine_marker="0"' \
    '.retired_claim_objects=1' '.retired_components=1' \
    '.candidate_retired_member_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.lineage.all_claims_zero_payment_retirable=true' \
    '.lineage.all_claims_expired_locally_retired=true' \
    '.lineage.members[0].proof_origin_bound=false' \
    '.lineage.members[0].proof_input_bound=false' \
    '.lineage.members[0].expired_locally_retired=true' \
    '.recovery_metrics_sha256_after="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    '.recovery_metrics_unchanged=false' \
    '.lineage.members[1].parent_txid=.lineage.members[2].txid' \
    '.lineage.component_claim_txids=[]' '.initial_atomic_reservation_verified=false' \
    '.confirmed_resolution_fees_after=1' '.candidate_claims_submitted=1'; do
    mutate "$CLAIM" "$TMP/m.json" "$filter"
    reject "claim hostile mutation ${filter}" hotfix_phase_a_claim_proof_file_is_valid "$TMP/m.json"
done

ok 'Phase-A baseline pre-snapshot stable-stop authority accepted' \
    hotfix_phase_a_stable_stop_file_is_valid "$BASE_STOP" baseline-pre-snapshot \
        "$IMMUTABLE_V3014_IMAGE_ID" "$IMMUTABLE_V3014_IMAGE_REF"
ok 'Phase-A candidate terminal stable-stop authority accepted' \
    hotfix_phase_a_stable_stop_file_is_valid "$CANDIDATE_STOP" candidate-terminal \
        "$IMAGE_ID" "$CANDIDATE_TEST_REF"
ok 'Phase-A base-quarantine stable-stop authority accepted' \
    hotfix_phase_a_stable_stop_file_is_valid "$QUARANTINE_STOP" \
        base-quarantine-to-baseline "$IMMUTABLE_V3014_IMAGE_ID" \
        "$IMMUTABLE_V3014_IMAGE_REF"
for filter in '.armed_restart_policy.Name="unless-stopped"' \
    '.stopped_restart_policy_second.Name="unless-stopped"' \
    '.started_at_armed="2026-08-08T00:00:02Z"' \
    '.stopped_started_at_second="2026-08-08T00:00:02Z"' \
    '.stopped_finished_at_second="2026-08-08T00:00:02Z"' \
    '.restart_count_stopped_second=1' '.stable_stopped_samples=1' \
    '.restart_authority_disabled_before_rpc_stop=false' \
    '.clean_rpc_stop_completed=false' '.automatic_restart_observed=true'; do
    mutate "$CANDIDATE_STOP" "$TMP/m.json" "$filter"
    reject "Phase-A stable-stop hostile mutation ${filter}" \
        hotfix_phase_a_stable_stop_file_is_valid "$TMP/m.json" candidate-terminal \
            "$IMAGE_ID" "$CANDIDATE_TEST_REF"
done
mutate "$CANDIDATE_STOP" "$TMP/m.json" '.image_ref="wrong"'
reject 'Phase-A stable-stop image reference drift rejected' \
    hotfix_phase_a_stable_stop_file_is_valid "$TMP/m.json" candidate-terminal \
        "$IMAGE_ID" "$CANDIDATE_TEST_REF"

ok 'four-snapshot held identity accepted' hotfix_snapshot_set_file_is_valid "$SNAPSHOTS" "$NONCE"
mutate "$SNAPSHOTS" "$TMP/m.json" 'del(.snapshots[3])'
reject 'missing fourth snapshot rejected' hotfix_snapshot_set_file_is_valid "$TMP/m.json" "$NONCE"
mutate "$SNAPSHOTS" "$TMP/m.json" '.snapshots[1].hold_present=false'
reject 'missing hold rejected' hotfix_snapshot_set_file_is_valid "$TMP/m.json" "$NONCE"
ok 'positive REWIND_SAFE certificate accepted' hotfix_rewind_safe_file_is_valid "$CERT" "$NONCE"
for filter in '.result="UNKNOWN"' '.candidate_stopped=false' '.pow_worker_joined=false' \
    '.pos_disabled_continuously=false' '.observer_absence_verified=false' \
    '.unknown_or_ambiguous=true' '.coinstake_or_wallet_escape_detected=true' \
    '.promotion_marker_absent=false' '.snapshots_held=false'; do
    mutate "$CERT" "$TMP/m.json" "$filter"
    reject "certificate hostile mutation ${filter}" hotfix_rewind_safe_file_is_valid "$TMP/m.json" "$NONCE"
done

ok 'base hard-quarantine catch-up accepted' hotfix_base_catchup_file_is_valid "$CATCHUP" "$NONCE"
for filter in '.wallet_locked=false' '.pos_enabled=true' '.pow_enabled=true' \
    '.walletbroadcast=true' '.chain.initialblockdownload=true' \
    '.chainwork_at_least_phase_a=false' \
    '.terminal_tip_active=false|.terminal_tip_superseded_by_greater_work=false' \
    '.wallet.scanning=true' '.wallet_processed_tip_current=false'; do
    mutate "$CATCHUP" "$TMP/m.json" "$filter"
    reject "catch-up hostile mutation ${filter}" hotfix_base_catchup_file_is_valid "$TMP/m.json" "$NONCE"
done
ok 'snapshot/hold absence accepted' hotfix_snapshot_absence_file_is_valid "$ABSENCE" "$NONCE"
mutate "$ABSENCE" "$TMP/m.json" '.remaining_holds=["one"]'
reject 'remaining hold rejected' hotfix_snapshot_absence_file_is_valid "$TMP/m.json" "$NONCE"
mutate "$ABSENCE" "$TMP/m.json" '.all_four_snapshots_destroyed=false'
reject 'incomplete destruction rejected' hotfix_snapshot_absence_file_is_valid "$TMP/m.json" "$NONCE"

ok 'Phase-A final result accepted' hotfix_phase_a_result_file_is_valid "$RESULT_A"
mutate "$RESULT_A" "$TMP/m.json" '.phase_b_invoked=true'
reject 'automatic Phase-B invocation rejected' hotfix_phase_a_result_file_is_valid "$TMP/m.json"
mutate "$RESULT_A" "$TMP/m.json" '.all_snapshots_absent_before_baseline_restore=false'
reject 'baseline restore before absence rejected' hotfix_phase_a_result_file_is_valid "$TMP/m.json"
ok 'durable promotion marker accepted' hotfix_promoted_marker_file_is_valid "$MARKER" "$RESULT_A_SHA"
for filter in '.phase_a_result_sha256="bad"' '.marker_fsync_verified=false' \
    '.parent_directory_fsync_verified=false' '.reread_verified=false' \
    '.snapshots_absent_before_marker=false' '.data_rewind_permanently_prohibited=false'; do
    mutate "$MARKER" "$TMP/m.json" "$filter"
    reject "promotion marker hostile mutation ${filter}" \
        hotfix_promoted_marker_file_is_valid "$TMP/m.json" "$RESULT_A_SHA"
done
ok 'Phase-B final result accepted' hotfix_phase_b_result_file_is_valid "$RESULT_B" "$RESULT_A_SHA"
for filter in '.datasets_preserved=false' '.candidate_running=false' \
    '.wallet_chain_synchronized_before_unlock=false' '.pos_explicitly_enabled=false' \
    '.failure_policy="start-old"' '.old_core_autostarted=true' '.data_rewind_performed=true'; do
    mutate "$RESULT_B" "$TMP/m.json" "$filter"
    reject "Phase-B result hostile mutation ${filter}" \
        hotfix_phase_b_result_file_is_valid "$TMP/m.json" "$RESULT_A_SHA"
done

PHASE_A="$ROOT/node27-v30.1.4-hotfix-candidate.no-recovery-spend.sh"
PHASE_B="$ROOT/node27-v30.1.4-hotfix-candidate.promote-no-data-rewind.sh"
VERIFIER="$ROOT/verify-evidence.sh"
# shellcheck disable=SC2016 # These are intentional child-shell fixture bodies; $1 expands there.
ok 'Phase-A hard flags appear in exact source order' /bin/bash -c '
  got=$(sed -n "/^[[:space:]]*command:/,/^EOF/p" "$1" | grep -E "^[[:space:]]+- -(walletbroadcast|blocksonly|staking|autostartstaking|powmining|qqautoshadowsignal|qqautodemurrageattest)=" | sed "s/^[[:space:]]*- //" | paste -sd " " -)
  expected="-walletbroadcast=0 -blocksonly=1 -staking=0 -autostartstaking=0 -powmining=0 -qqautoshadowsignal=0 -qqautodemurrageattest=0"
  [[ "$got" == "$expected" ]]
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-A trap has no destructive data or old-image start call' /bin/bash -c '
  body=$(sed -n "/^on_exit()/,/^main()/p" "$1")
  ! grep -Eq "certified_rewind|zfs (rollback|destroy|release)|docker compose.*IMMUTABLE" <<<"$body"
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-A only performs plain child-first certified restore' /bin/bash -c '
  grep -F "zfs rollback \"\$snapshot\"" "$1" >/dev/null &&
  ! grep -Eq "zfs rollback[[:space:]]+(-r|-R|-f)|zfs rollback.*--" "$1"
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-A cannot invoke promotion script' /bin/bash -c '
  ! grep -E "exec .*promote-no-data-rewind|source .*promote-no-data-rewind|/bin/bash .*promote-no-data-rewind" "$1"
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Positional parameter expansion belongs to the child shell.
ok 'Phase-A final order is encoded' /bin/bash -c '
  for stage in tip-proof pow-stop-joined wallet-claim-mempool-observer-proof wallet-locked \
    candidate-clean-stop logs-complete-through-stop; do
    grep -F "\"$stage\"" "$1" >/dev/null || exit 1
  done
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Intentional child-shell source-order and call-set audit.
ok 'all three Phase-A stops disable restart before the RPC stop and seal stable identity' \
    /bin/bash -c '
  body=$(sed -n "/^stop_with_restart_authority_disabled()/,/^stable_stop_receipt_matches_live()/p" "$1")
  disable=$(grep -nF "docker update --restart=no" <<<"$body" | cut -d: -f1)
  stop=$(grep -nF "rpc stop" <<<"$body" | cut -d: -f1)
  sample=$(grep -nF "stopped_finished_at_second" <<<"$body" | tail -1 | cut -d: -f1)
  validate=$(grep -nF "hotfix_phase_a_stable_stop_file_is_valid" <<<"$body" | cut -d: -f1)
  calls=$(grep -Ec "stop_with_restart_authority_disabled (baseline-pre-snapshot|candidate-terminal|base-quarantine-to-baseline)" "$1")
  [[ -n "$disable" && -n "$stop" && -n "$sample" && -n "$validate" &&
     "$disable" -lt "$stop" && "$stop" -lt "$sample" && "$sample" -lt "$validate" &&
     "$calls" == 3 ]]
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Literal guard-token publication fragments are audited in a child shell.
ok 'Phase-A guard and maintenance authority transitions are no-clobber publications' \
    /bin/bash -c '
  suspend=$(sed -n "/^suspend_guard_authority()/,/^restore_guard_authority()/p" "$1")
  restore=$(sed -n "/^restore_guard_authority()/,/^publish_maintenance_marker()/p" "$1")
  maintenance=$(sed -n "/^publish_maintenance_marker()/,/^remove_own_maintenance_marker()/p" "$1")
  grep -F "mv -nT -- \"\$ENABLE_GUARD_STARTS\" \"\$SUSPENDED_START_MARKER\"" <<<"$suspend" >/dev/null &&
  grep -F "mv -nT -- \"\$SUSPENDED_START_MARKER\" \"\$ENABLE_GUARD_STARTS\"" <<<"$restore" >/dev/null &&
  grep -F "! -e \"\$MAINTENANCE_MARKER\" && ! -L \"\$MAINTENANCE_MARKER\"" <<<"$maintenance" >/dev/null &&
  grep -F "mv -nT -- \"\$tmp\" \"\$MAINTENANCE_MARKER\"" <<<"$maintenance" >/dev/null &&
  ! grep -F "mv -fT -- \"\$tmp\" \"\$MAINTENANCE_MARKER\"" <<<"$maintenance"
' _ "$PHASE_A"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-B has no textual data-restore command' /bin/bash -c '
  ! grep -Eiq "rollback|zfs[[:space:]]+(snapshot|destroy|release|hold)([[:space:]]|$)" "$1"
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Literal guard-token publication fragments are audited in a child shell.
ok 'Phase-B guard suspension and maintenance publication are no-clobber transitions' \
    /bin/bash -c '
  suspend=$(sed -n "/^suspend_guard_authority()/,/^publish_maintenance()/p" "$1")
  maintenance=$(sed -n "/^publish_maintenance()/,/^write_promotion_marker()/p" "$1")
  grep -F "mv -nT -- \"\$ENABLE_GUARD_STARTS\" \"\$SUSPENDED_START_MARKER\"" <<<"$suspend" >/dev/null &&
  grep -F "! -e \"\$MAINTENANCE_MARKER\" && ! -L \"\$MAINTENANCE_MARKER\"" <<<"$maintenance" >/dev/null &&
  grep -F "mv -nT -- \"\$tmp\" \"\$MAINTENANCE_MARKER\"" <<<"$maintenance" >/dev/null
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell source-order audit.
ok 'Phase-B proves an external ZFS promotion authority before irreversible mutation' \
    /bin/bash -c '
  root=$(grep -nF "external promotion authority root is absent or unsafe" "$1" | cut -d: -f1)
  zfs=$(grep -nF "promotion authority root is not on the required hard-link-capable ZFS filesystem" "$1" | cut -d: -f1)
  outside=$(grep -nF "promotion authority root is inside a live/rewind dataset" "$1" | cut -d: -f1)
  mutation=$(grep -nF "mutation_started=1" "$1" | tail -1 | cut -d: -f1)
  publish=$(grep -nF "write_promotion_marker ||" "$1" | tail -1 | cut -d: -f1)
  marker_body=$(sed -n "/^write_promotion_marker()/,/^capture_live_dataset_identity()/p" "$1")
  grep -F "ln -- \"\$tmp\" \"\$PROMOTION_MARKER\"" <<<"$marker_body" >/dev/null &&
  [[ -n "$root" && -n "$zfs" && -n "$outside" && -n "$mutation" && -n "$publish" &&
     "$root" -lt "$zfs" && "$zfs" -lt "$outside" && "$outside" -lt "$mutation" &&
     "$mutation" -lt "$publish" ]]
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-B ZFS use is read-only list/holds only' /bin/bash -c '
  bad=$(grep -E "^[[:space:]]*(![[:space:]]+)?zfs[[:space:]]+" "$1" | grep -Ev "zfs (list|holds)([[:space:]]|$)" || true)
  [[ -z "$bad" ]]
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-B marker precedes baseline quiesce and candidate launch' /bin/bash -c '
  marker=$(grep -n "write_promotion_marker ||" "$1" | cut -d: -f1)
  quiet=$(grep -n "rpc staking false" "$1" | tail -1 | cut -d: -f1)
  launch=$(grep -n "docker start \"\$CONTAINER\"" "$1" | tail -1 | cut -d: -f1)
  [[ "$marker" -lt "$quiet" && "$quiet" -lt "$launch" ]]
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell source-order audit.
ok 'Phase-B disables restart before RPC stop and seals receipt before candidate create' /bin/bash -c '
  disable=$(grep -nF "old-Core automatic restart authority could not be disabled" "$1" | cut -d: -f1)
  staking=$(grep -nF "baseline PoS stop failed" "$1" | cut -d: -f1)
  stopped=$(grep -nF "baseline clean stop failed" "$1" | cut -d: -f1)
  receipt=$(grep -nF "baseline cutover receipt is internally inconsistent" "$1" | cut -d: -f1)
  override=$(grep -nF "write_override ||" "$1" | cut -d: -f1)
  create=$(grep -nF "candidate create failed" "$1" | cut -d: -f1)
  [[ -n "$disable" && -n "$staking" && -n "$stopped" && -n "$receipt" &&
     -n "$override" && -n "$create" && "$disable" -lt "$staking" &&
     "$staking" -lt "$stopped" && "$stopped" -lt "$receipt" &&
     "$receipt" -lt "$override" && "$override" -lt "$create" ]]
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Literal production fragments are passed as child arguments.
ok 'Phase-B source uses a same-directory no-clobber RESULT publication' /bin/bash -c '
  grep -F "$2" "$1" >/dev/null && grep -F "$3" "$1" >/dev/null &&
    grep -F "$4" "$1" >/dev/null
' _ "$PHASE_B" \
  '[[ ! -e "${EVIDENCE}/RESULT.json" && ! -L "${EVIDENCE}/RESULT.json" ]]' \
  'result_tmp=$(mktemp "${EVIDENCE}/.RESULT.json.XXXXXX")' \
  '! ln -- "$result_tmp" "${EVIDENCE}/RESULT.json"'
# shellcheck disable=SC2016 # Intentional child-shell source-order audit.
ok 'Phase-B RESULT is validated and durable before publish and sealed afterward' /bin/bash -c '
  target=$(grep -nF "Phase-B RESULT target already exists" "$1" | tail -1 | cut -d: -f1)
  stage=$(grep -nF "result_tmp=" "$1" | tail -1 | cut -d: -f1)
  validate=$(grep -nF "Phase-B staged RESULT is invalid or not durable" "$1" | tail -1 | cut -d: -f1)
  publish=$(grep -nF "Phase-B RESULT atomic publication failed" "$1" | tail -1 | cut -d: -f1)
  durable=$(grep -nF "Phase-B RESULT publication was not durable" "$1" | tail -1 | cut -d: -f1)
  reread=$(grep -nF "Phase-B published RESULT is invalid" "$1" | tail -1 | cut -d: -f1)
  seal=$(grep -nF "promotion evidence seal failed" "$1" | tail -1 | cut -d: -f1)
  [[ -n "$target" && -n "$stage" && -n "$validate" && -n "$publish" &&
     -n "$durable" && -n "$reread" && -n "$seal" &&
     "$target" -lt "$stage" && "$stage" -lt "$validate" &&
     "$validate" -lt "$publish" && "$publish" -lt "$durable" &&
     "$durable" -lt "$reread" && "$reread" -lt "$seal" ]]
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Phase-B failure policy is containment-only' /bin/bash -c '
  body=$(sed -n "/^on_exit()/,/^main()/p" "$1")
  grep -F "contain_preserve" <<<"$body" >/dev/null &&
  ! grep -Eq "docker compose|zfs" <<<"$body"
' _ "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1/$2 expand there.
ok 'phase confirmations are distinct and result-hash-bound' /bin/bash -c '
  grep -F "CONFIRM_HOTFIX_CANDIDATE_PHASE_A" "$1" >/dev/null &&
  grep -F "HOTFIX_PHASE_B_CONFIRMATION_PREFIX" "$2" >/dev/null
' _ "$PHASE_A" "$PHASE_B"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'verifier exposes exactly three explicit modes' /bin/bash -c '
  for mode in phase-a-pre-rewind phase-a-final phase-b-final; do grep -F "$mode)" "$1" >/dev/null; done
' _ "$VERIFIER"
# shellcheck disable=SC2016 # Intentional child-shell fixture; positional parameters expand there.
ok 'package contains no build/publish/release mutation' /bin/bash -c '
  ! grep -E "docker (build|push|pull|load)|gh release|git tag|workflow run" "$1" "$2" "$3"
' _ "$PHASE_A" "$PHASE_B" "$VERIFIER"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Core source confirms -staking hard gate' /bin/bash -c '
  grep -R "GetBoolArg(\"-staking\"" "$1/src" >/dev/null &&
  grep -R "CanStake" "$1/src/node" >/dev/null
' _ "$ROOT/../../.."
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Core source confirms blocksonly does not remove RPC relay risk' /bin/bash -c '
  grep -R -- "-blocksonly" "$1/src/init.cpp" "$1/src/wallet/init.cpp" >/dev/null &&
  grep -R "IgnoresIncomingTxs" "$1/src" >/dev/null
' _ "$ROOT/../../.."

reject 'verifier rejects unknown mode' "$VERIFIER" unknown "$TMP"
reject 'verifier rejects missing evidence root' "$VERIFIER" phase-a-final "$TMP/missing"

prepare_fixture_verifier

RESULT_LINK_STAGE="$TMP/result-link-stage"
RESULT_LINK_TARGET="$TMP/result-link-target"
printf '%s\n' '{"result":"passed"}' >"$RESULT_LINK_STAGE"
chmod 600 "$RESULT_LINK_STAGE"
ok 'same-directory hard-link RESULT publication succeeds once' \
    atomic_result_link_fixture "$RESULT_LINK_STAGE" "$RESULT_LINK_TARGET"

RESULT_EXISTING_STAGE="$TMP/result-existing-stage"
RESULT_EXISTING_TARGET="$TMP/result-existing-target"
printf '%s\n' complete >"$RESULT_EXISTING_STAGE"
printf '%s\n' existing >"$RESULT_EXISTING_TARGET"
reject 'preexisting RESULT target blocks no-clobber publication' \
    atomic_result_link_fixture "$RESULT_EXISTING_STAGE" "$RESULT_EXISTING_TARGET"
ok 'preexisting RESULT bytes remain unchanged after rejected publication' \
    test "$(<"$RESULT_EXISTING_TARGET")" = existing

RESULT_SYMLINK_STAGE="$TMP/result-symlink-stage"
RESULT_SYMLINK_TARGET="$TMP/result-symlink-target"
RESULT_SYMLINK_DESTINATION="$TMP/result-symlink-destination"
printf '%s\n' complete >"$RESULT_SYMLINK_STAGE"
printf '%s\n' protected >"$RESULT_SYMLINK_DESTINATION"
ln -s "$RESULT_SYMLINK_DESTINATION" "$RESULT_SYMLINK_TARGET"
reject 'symlink RESULT target blocks no-clobber publication' \
    atomic_result_link_fixture "$RESULT_SYMLINK_STAGE" "$RESULT_SYMLINK_TARGET"
ok 'symlink destination remains unchanged after rejected publication' \
    test "$(<"$RESULT_SYMLINK_DESTINATION")" = protected

RESULT_PARTIAL_STAGE="$TMP/result-partial-stage"
RESULT_PARTIAL_TARGET="$TMP/result-partial-target"
printf '%s\n' complete >"$RESULT_PARTIAL_STAGE"
: >"$RESULT_PARTIAL_TARGET"
reject 'partial preexisting RESULT target blocks publication' \
    atomic_result_link_fixture "$RESULT_PARTIAL_STAGE" "$RESULT_PARTIAL_TARGET"
ok 'partial preexisting RESULT remains byte-empty after rejection' \
    test ! -s "$RESULT_PARTIAL_TARGET"

ok 'exact eight-payload package integrity accepted' \
    run_package_integrity_fixture "$FIXTURE_PACKAGE"

HOSTILE_PACKAGE_OWNER="$TMP/package-hostile-owner"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_OWNER"
reject 'package payload with non-root owner rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_OWNER" \
        "$HOSTILE_PACKAGE_OWNER/README.md"

HOSTILE_PACKAGE_FILE_MODE="$TMP/package-hostile-file-mode"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_FILE_MODE"
chmod 666 "$HOSTILE_PACKAGE_FILE_MODE/README.md"
reject 'package group-writable payload rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_FILE_MODE"

HOSTILE_PACKAGE_DIR_MODE="$TMP/package-hostile-dir-mode"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_DIR_MODE"
chmod 777 "$HOSTILE_PACKAGE_DIR_MODE/lib"
reject 'package group-writable directory rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_DIR_MODE"

HOSTILE_PACKAGE_LINK="$TMP/package-hostile-hardlink"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_LINK"
ln "$HOSTILE_PACKAGE_LINK/README.md" "$TMP/package-hardlink-alias"
reject 'package multiply linked payload rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_LINK"
rm "$TMP/package-hardlink-alias"

HOSTILE_PACKAGE_SYMLINK="$TMP/package-hostile-symlink"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_SYMLINK"
cp "$HOSTILE_PACKAGE_SYMLINK/README.md" "$TMP/package-symlink-target"
rm "$HOSTILE_PACKAGE_SYMLINK/README.md"
ln -s "$TMP/package-symlink-target" "$HOSTILE_PACKAGE_SYMLINK/README.md"
reject 'package symlink payload rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_SYMLINK"

HOSTILE_PACKAGE_SPECIAL="$TMP/package-hostile-special"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_SPECIAL"
rm "$HOSTILE_PACKAGE_SPECIAL/README.md"
mkfifo "$HOSTILE_PACKAGE_SPECIAL/README.md"
reject 'package special-object payload rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_SPECIAL"

HOSTILE_PACKAGE_EXTRA_DIR="$TMP/package-hostile-extra-dir"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_EXTRA_DIR"
mkdir "$HOSTILE_PACKAGE_EXTRA_DIR/unsealed"
reject 'package extra directory rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_EXTRA_DIR"

HOSTILE_PACKAGE_EXTRA_FILE="$TMP/package-hostile-extra-file"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_EXTRA_FILE"
: >"$HOSTILE_PACKAGE_EXTRA_FILE/unsealed.txt"
reject 'package extra file rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_EXTRA_FILE"

HOSTILE_PACKAGE_MANIFEST="$TMP/package-hostile-manifest"
clone_fixture_package "$FIXTURE_PACKAGE" "$HOSTILE_PACKAGE_MANIFEST"
PACKAGE_MANIFEST_LINE=$(sed -n '1p' "$HOSTILE_PACKAGE_MANIFEST/SHA256SUMS")
printf '%s\n' "$PACKAGE_MANIFEST_LINE" >>"$HOSTILE_PACKAGE_MANIFEST/SHA256SUMS"
reject 'package manifest with a ninth entry rejected' \
    run_package_integrity_fixture "$HOSTILE_PACKAGE_MANIFEST"

EVIDENCE_A_PRE="$TMP/evidence-phase-a-pre"
EVIDENCE_A_FINAL="$TMP/evidence-phase-a-final"
EVIDENCE_B_FINAL="$TMP/evidence-phase-b-final"
build_phase_a_pre_fixture "$EVIDENCE_A_PRE"
ok 'full Phase-A pre-rewind evidence verifies' \
    run_fixture_verifier phase-a-pre-rewind "$EVIDENCE_A_PRE"

HOSTILE_CORE_RUN="$TMP/evidence-hostile-core-run"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_RUN"
mutate_core_ci_fixture "$HOSTILE_CORE_RUN" '.run_id=31336502538'
reject 'resealed Core-CI evidence rejects a different successful run' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_RUN"

HOSTILE_CORE_PENDING="$TMP/evidence-hostile-core-pending"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_PENDING"
mutate_core_ci_fixture "$HOSTILE_CORE_PENDING" '.status="in_progress" | .conclusion=null'
reject 'resealed provisional Core-CI evidence cannot authorize while pending' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_PENDING"

HOSTILE_CORE_FAILURE="$TMP/evidence-hostile-core-failure"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_FAILURE"
mutate_core_ci_fixture "$HOSTILE_CORE_FAILURE" '.status="completed" | .conclusion="failure"'
reject 'resealed completed Core-CI failure cannot authorize' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_FAILURE"

HOSTILE_CORE_BASE="$TMP/evidence-hostile-core-base"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_BASE"
mutate_core_ci_fixture "$HOSTILE_CORE_BASE" \
    '.pull_request_base_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reject 'resealed Core-CI evidence rejects a different pull-request base' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_BASE"

HOSTILE_CORE_WORKFLOW="$TMP/evidence-hostile-core-workflow"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_WORKFLOW"
mutate_core_ci_fixture "$HOSTILE_CORE_WORKFLOW" \
    '.workflow_blob_sha256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
reject 'resealed Core-CI evidence rejects different pr-gate bytes' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_WORKFLOW"

HOSTILE_CORE_HEAD="$TMP/evidence-hostile-core-head"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_HEAD"
mutate_core_ci_fixture "$HOSTILE_CORE_HEAD" \
    '.head_sha="cccccccccccccccccccccccccccccccccccccccc" | .pull_request_head_sha=.head_sha'
reject 'resealed Core-CI evidence rejects a different head' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_HEAD"

HOSTILE_CORE_EVENT="$TMP/evidence-hostile-core-event"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_EVENT"
mutate_core_ci_fixture "$HOSTILE_CORE_EVENT" '.event="workflow_dispatch"'
reject 'resealed Core-CI evidence rejects a non-PR event' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_EVENT"

TOOLING_BAD_HASH=$(printf 'a%.0s' {1..64})
for field in package_sha256sums_sha256 phase_a_script_sha256 phase_b_script_sha256 \
    verifier_sha256 typed_contract_sha256; do
    HOSTILE_A_TOOLING="$TMP/evidence-hostile-a-tooling-${field}"
    clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_TOOLING"
    # shellcheck disable=SC2016 # $field and $hash are jq variables.
    mutate_json_in_place "$HOSTILE_A_TOOLING/tooling-identity.json" \
        --arg field "$field" --arg hash "$TOOLING_BAD_HASH" '.[$field]=$hash'
    reseal_phase_a_pre_fixture "$HOSTILE_A_TOOLING"
    reject "resealed Phase-A tooling identity rejects ${field} drift" \
        run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_TOOLING"
done
HOSTILE_A_TOOLING_COMMIT="$TMP/evidence-hostile-a-tooling-commit"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_TOOLING_COMMIT"
mutate_json_in_place "$HOSTILE_A_TOOLING_COMMIT/tooling-identity.json" \
    '.tooling_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_a_pre_fixture "$HOSTILE_A_TOOLING_COMMIT"
reject 'resealed Phase-A tooling identity rejects tooling-commit drift' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_TOOLING_COMMIT"

build_phase_a_final_fixture "$EVIDENCE_A_PRE" "$EVIDENCE_A_FINAL"
ok 'full Phase-A final evidence verifies' \
    run_fixture_verifier phase-a-final "$EVIDENCE_A_FINAL"

HOSTILE_A_BASELINE_STOP_HASH="$TMP/evidence-hostile-a-baseline-stop-hash"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_BASELINE_STOP_HASH"
mutate_json_in_place "$HOSTILE_A_BASELINE_STOP_HASH/baseline-cold-stop-authority.json" \
    '.stopped_finished_at_second="2026-08-08T00:00:02Z"'
reseal_phase_a_final_fixture "$HOSTILE_A_BASELINE_STOP_HASH"
reject 'resealed Phase-A snapshot authority rejects changed baseline stop receipt' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_BASELINE_STOP_HASH"

HOSTILE_A_CANDIDATE_STOP_HASH="$TMP/evidence-hostile-a-candidate-stop-hash"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_CANDIDATE_STOP_HASH"
mutate_json_in_place "$HOSTILE_A_CANDIDATE_STOP_HASH/candidate-stop-authority.json" \
    '.restart_count_stopped_second=1'
reseal_phase_a_final_fixture "$HOSTILE_A_CANDIDATE_STOP_HASH"
reject 'resealed Phase-A certificate rejects changed candidate stop receipt' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_CANDIDATE_STOP_HASH"

HOSTILE_A_BASE_STOP_HASH="$TMP/evidence-hostile-a-base-stop-hash"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_BASE_STOP_HASH"
mutate_json_in_place "$HOSTILE_A_BASE_STOP_HASH/base-quarantine-stop-authority.json" \
    '.automatic_restart_observed=true'
reseal_phase_a_final_fixture "$HOSTILE_A_BASE_STOP_HASH"
reject 'resealed Phase-A RESULT rejects changed base-quarantine stop receipt' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_BASE_STOP_HASH"

HOSTILE_A_RESTORED_RUNTIME="$TMP/evidence-hostile-a-restored-runtime"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_RESTORED_RUNTIME"
mutate_json_in_place "$HOSTILE_A_RESTORED_RUNTIME/baseline-restored-container.json" \
    '.restart_policy.Name="always"'
reseal_phase_a_final_fixture "$HOSTILE_A_RESTORED_RUNTIME"
reject 'resealed Phase-A RESULT rejects changed restored baseline runtime' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_RESTORED_RUNTIME"

HOSTILE_A_RESTORED_STAKING="$TMP/evidence-hostile-a-restored-staking"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_RESTORED_STAKING"
mutate_json_in_place "$HOSTILE_A_RESTORED_STAKING/baseline-restored-staking.json" \
    '.staking=false | .worker_running=false'
reseal_phase_a_final_fixture "$HOSTILE_A_RESTORED_STAKING"
reject 'resealed Phase-A restored baseline must have live staking' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_RESTORED_STAKING"

HOSTILE_A_RESTORED_RECOVERY="$TMP/evidence-hostile-a-restored-recovery"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_RESTORED_RECOVERY"
mutate_json_in_place "$HOSTILE_A_RESTORED_RECOVERY/baseline-restored-recovery.json" \
    '.confirmed_resolution_fees=1'
reseal_phase_a_final_fixture "$HOSTILE_A_RESTORED_RECOVERY"
reject 'resealed Phase-A restored baseline recovery counters cannot drift' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_RESTORED_RECOVERY"

HOSTILE_A_RESTORED_QUANTUM="$TMP/evidence-hostile-a-restored-quantum"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_RESTORED_QUANTUM"
mutate_json_in_place "$HOSTILE_A_RESTORED_QUANTUM/baseline-restored-quantum.json" \
    '.+=[{"key":"q3"}]'
reseal_phase_a_final_fixture "$HOSTILE_A_RESTORED_QUANTUM"
reject 'resealed Phase-A restored baseline quantum inventory cannot drift' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_RESTORED_QUANTUM"

HOSTILE_A_CERT_TOOLING="$TMP/evidence-hostile-a-cert-tooling"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_CERT_TOOLING"
mutate_json_in_place "$HOSTILE_A_CERT_TOOLING/REWIND_SAFE.json" \
    '.phase_a_script_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
# shellcheck disable=SC2016 # $cert is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_A_CERT_TOOLING/RESULT.json" \
    --arg cert "$(sha_file "$HOSTILE_A_CERT_TOOLING/REWIND_SAFE.json")" \
    '.rewind_safe_sha256=$cert'
reseal_phase_a_final_fixture "$HOSTILE_A_CERT_TOOLING"
reject 'resealed Phase-A certificate tooling drift cannot disagree with captured identity' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_CERT_TOOLING"

HOSTILE_A_RESULT_TOOLING="$TMP/evidence-hostile-a-result-tooling"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_RESULT_TOOLING"
mutate_json_in_place "$HOSTILE_A_RESULT_TOOLING/RESULT.json" \
    '.verifier_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_a_final_fixture "$HOSTILE_A_RESULT_TOOLING"
reject 'resealed Phase-A RESULT tooling drift cannot disagree with captured identity' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_RESULT_TOOLING"

build_phase_b_final_fixture "$EVIDENCE_A_FINAL" "$EVIDENCE_B_FINAL"
ok 'full Phase-B final evidence verifies with raw wallet recomputation' \
    run_fixture_verifier phase-b-final "$EVIDENCE_B_FINAL"

ok 'Phase-B baseline cutover stop receipt accepted' \
    hotfix_phase_b_cutover_stop_file_is_valid "$EVIDENCE_B_FINAL/baseline-cutover-stop.json"
for filter in '.armed_restart_policy.Name="unless-stopped"' \
    '.stopped_started_at_second="2026-08-08T00:00:01Z"' \
    '.stopped_finished_at_second="2026-08-08T00:00:02Z"' \
    '.stopped_exit_code_first=1' '.stopped_exit_code_second=1' \
    '.restart_count_stopped_second=1' '.started_at_armed="2026-08-08T00:00:01Z"' \
    '.stable_stopped_samples=1' '.old_core_restart_observed=true'; do
    mutate "$EVIDENCE_B_FINAL/baseline-cutover-stop.json" "$TMP/m.json" "$filter"
    reject "Phase-B cutover hostile mutation ${filter}" \
        hotfix_phase_b_cutover_stop_file_is_valid "$TMP/m.json"
done

HOSTILE_B_CUTOVER_POLICY="$TMP/evidence-hostile-b-cutover-policy"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_CUTOVER_POLICY"
mutate_json_in_place "$HOSTILE_B_CUTOVER_POLICY/baseline-cutover-stop.json" \
    '.original_restart_policy.Name="always"'
# shellcheck disable=SC2016 # $hash is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_B_CUTOVER_POLICY/RESULT.json" \
    --arg hash "$(sha_file "$HOSTILE_B_CUTOVER_POLICY/baseline-cutover-stop.json")" \
    '.baseline_cutover_stop_sha256=$hash'
reseal_phase_b_fixture "$HOSTILE_B_CUTOVER_POLICY"
reject 'resealed Phase-B cutover original policy must match baseline runtime' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_CUTOVER_POLICY"

HOSTILE_B_CUTOVER_CONTAINER="$TMP/evidence-hostile-b-cutover-container"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_CUTOVER_CONTAINER"
mutate_json_in_place "$HOSTILE_B_CUTOVER_CONTAINER/baseline-cutover-stop.json" \
    '.container_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
# shellcheck disable=SC2016 # $hash is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_B_CUTOVER_CONTAINER/RESULT.json" \
    --arg hash "$(sha_file "$HOSTILE_B_CUTOVER_CONTAINER/baseline-cutover-stop.json")" \
    '.baseline_cutover_stop_sha256=$hash'
reseal_phase_b_fixture "$HOSTILE_B_CUTOVER_CONTAINER"
reject 'resealed Phase-B cutover container must match baseline runtime' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_CUTOVER_CONTAINER"

HOSTILE_B_CUTOVER_RESULT="$TMP/evidence-hostile-b-cutover-result-hash"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_CUTOVER_RESULT"
mutate_json_in_place "$HOSTILE_B_CUTOVER_RESULT/RESULT.json" \
    '.baseline_cutover_stop_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_b_fixture "$HOSTILE_B_CUTOVER_RESULT"
reject 'resealed Phase-B RESULT must hash-bind the cutover stop receipt' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_CUTOVER_RESULT"

HOSTILE_B_PHASE_A_TOOLING_COPY="$TMP/evidence-hostile-b-phase-a-tooling-copy"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_PHASE_A_TOOLING_COPY"
mutate_json_in_place "$HOSTILE_B_PHASE_A_TOOLING_COPY/phase-a-tooling-identity.json" \
    '.typed_contract_sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_b_fixture "$HOSTILE_B_PHASE_A_TOOLING_COPY"
reject 'resealed Phase-B authority copy cannot drift from Phase-A tooling identity' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_PHASE_A_TOOLING_COPY"

UNSAFE_FIXTURE="$TMP/evidence-hostile-unsafe-metadata"
clone_fixture_tree "$EVIDENCE_A_PRE" "$UNSAFE_FIXTURE"
chmod 755 "$UNSAFE_FIXTURE"
reject 'sourceable verifier override still rejects unsafe fixture metadata' \
    run_fixture_verifier phase-a-pre-rewind "$UNSAFE_FIXTURE"

HOSTILE_A_PRE="$TMP/evidence-hostile-a-pre-visibility"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_PRE"
mutate_json_in_place "$HOSTILE_A_PRE/candidate-visibility-sample-2.json" \
    '.observers[0].txids=["eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'
reseal_phase_a_pre_fixture "$HOSTILE_A_PRE"
reject 'resealed Phase-A visibility sample cannot escape progress/claim binding' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_PRE"

HOSTILE_A_FINAL_METRICS="$TMP/evidence-hostile-a-final-recovery-metrics"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_FINAL_METRICS"
mutate_json_in_place "$HOSTILE_A_FINAL_METRICS/candidate-final-recovery-inventory.json" \
    '.confirmed_manual_resolutions=1'
cp "$HOSTILE_A_FINAL_METRICS/candidate-final-recovery-inventory.json" \
    "$HOSTILE_A_FINAL_METRICS/candidate-final-recovery-after.json"
HOSTILE_A_FINAL_METRICS_SHA=$(recovery_metrics_sha_file \
    "$HOSTILE_A_FINAL_METRICS/candidate-final-recovery-inventory.json")
# shellcheck disable=SC2016 # $metrics is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_A_FINAL_METRICS/phase-a-claim-proof.json" \
    --arg metrics "$HOSTILE_A_FINAL_METRICS_SHA" \
    '.recovery_metrics_sha256_before=$metrics | .recovery_metrics_sha256_after=$metrics'
reseal_phase_a_pre_fixture "$HOSTILE_A_FINAL_METRICS"
reject 'resealed Phase-A final recovery counters cannot drift from sampled baseline metrics' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_FINAL_METRICS"

HOSTILE_A_RETIRED="$TMP/evidence-hostile-a-retired-lineage"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_RETIRED"
mutate_json_in_place "$HOSTILE_A_RETIRED/phase-a-claim-proof.json" '
  .retired_claim_objects=4 | .retired_components=1 |
  .candidate_retired_member_txids=.candidate_created_qqsproof_txids |
  .lineage.all_claims_zero_payment_retirable=true |
  .lineage.all_claims_expired_locally_retired=true |
  .lineage.members[].expired_locally_retired=true
'
mutate_json_in_place "$HOSTILE_A_RETIRED/candidate-final-recovery-inventory.json" '
  .retired_claim_objects=4 | .retired_components=1 |
  .component_details[0].all_claims_zero_payment_retirable=true |
  .component_details[0].all_claims_expired_locally_retired=true |
  .component_details[0].nodes[].expired_locally_retired=true
'
cp "$HOSTILE_A_RETIRED/candidate-final-recovery-inventory.json" \
    "$HOSTILE_A_RETIRED/candidate-final-recovery-after.json"
reseal_phase_a_pre_fixture "$HOSTILE_A_RETIRED"
reject 'resealed coherent retired-lineage state cannot authorize Phase-A rewind' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_RETIRED"

HOSTILE_A_FINAL="$TMP/evidence-hostile-a-final-catchup-cut"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_FINAL"
mutate_json_in_place "$HOSTILE_A_FINAL/base-catchup-chain-after.json" \
    '.bestblockhash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_a_final_fixture "$HOSTILE_A_FINAL"
reject 'resealed Phase-A catch-up sample cannot forge the stable cut' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_FINAL"

HOSTILE_B_COIN_RECOVERY="$TMP/evidence-hostile-b-coinstake-recovery"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_COIN_RECOVERY"
mutate_json_in_place "$HOSTILE_B_COIN_RECOVERY/phase-b-wallet-delta-raw.json" \
    '.records[1].recovery_matches=.records[2].recovery_matches'
reseal_phase_b_fixture "$HOSTILE_B_COIN_RECOVERY"
reject 'resealed Phase-B coinstake cannot carry claim recovery matches' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_COIN_RECOVERY"

HOSTILE_B_COIN_CASE="$TMP/evidence-hostile-b-coinstake-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_COIN_CASE"
mutate_json_in_place "$HOSTILE_B_COIN_CASE/phase-b-wallet-delta-raw.json" \
    '.records[1].blockhash|=ascii_upcase | .records[1].getblock_response.hash|=ascii_upcase | .records[1].wallet_rows[].blockhash|=ascii_upcase'
reseal_phase_b_fixture "$HOSTILE_B_COIN_CASE"
reject 'resealed Phase-B coinstake uppercase blockhash is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_COIN_CASE"

HOSTILE_B_PAYOUT_CASE="$TMP/evidence-hostile-b-payout-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_PAYOUT_CASE"
mutate_json_in_place "$HOSTILE_B_PAYOUT_CASE/phase-b-wallet-delta-raw.json" \
    '.records[0].blockhash|=ascii_upcase | .records[0].wallet_rows[].blockhash|=ascii_upcase | .records[0].getshadowtransaction_response.base_anchor.blockhash|=ascii_upcase'
reseal_phase_b_fixture "$HOSTILE_B_PAYOUT_CASE"
reject 'resealed Phase-B payout uppercase blockhash is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_PAYOUT_CASE"

HOSTILE_B_SOURCE_CASE="$TMP/evidence-hostile-b-source-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_SOURCE_CASE"
mutate_json_in_place "$HOSTILE_B_SOURCE_CASE/phase-b-wallet-delta-raw.json" \
    '.records[0].source_claim_txid|=ascii_upcase | .records[0].getshadowtransaction_response.pow_claim_source.txid|=ascii_upcase'
reseal_phase_b_fixture "$HOSTILE_B_SOURCE_CASE"
reject 'resealed Phase-B payout uppercase source claim txid is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_SOURCE_CASE"

HOSTILE_B_FAMILY="$TMP/evidence-hostile-b-claim-family"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_FAMILY"
mutate_json_in_place "$HOSTILE_B_FAMILY/phase-b-wallet-delta-raw.json" \
    '.records[2].wallet_rows[0].qq_shadow_pow_lineage_family="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"'
reseal_phase_b_fixture "$HOSTILE_B_FAMILY"
reject 'resealed Phase-B claim family must recompute from recovery evidence' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_FAMILY"

HOSTILE_B_PAYOUT_SOURCE="$TMP/evidence-hostile-b-payout-source"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_PAYOUT_SOURCE"
mutate_json_in_place "$HOSTILE_B_PAYOUT_SOURCE/phase-b-wallet-delta-raw.json" \
    '.records[0].source_claim_txid="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" | .records[0].getshadowtransaction_response.pow_claim_source.txid="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
reseal_phase_b_fixture "$HOSTILE_B_PAYOUT_SOURCE"
reject 'resealed Phase-B payout source must resolve to an authenticated claim' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_PAYOUT_SOURCE"

HOSTILE_B_ORIGIN="$TMP/evidence-hostile-b-origin-unbound"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_ORIGIN"
mutate_json_in_place "$HOSTILE_B_ORIGIN/phase-b-wallet-delta-raw.json" \
    '.records[2].recovery_matches[0].node.proof_origin_bound=false'
reseal_phase_b_fixture "$HOSTILE_B_ORIGIN"
reject 'resealed Phase-B claim must remain origin-bound in raw recovery evidence' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_ORIGIN"

HOSTILE_B_INPUT="$TMP/evidence-hostile-b-input-unbound"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_INPUT"
mutate_json_in_place "$HOSTILE_B_INPUT/phase-b-wallet-delta-raw.json" \
    '.records[2].recovery_matches[0].node.proof_input_bound=false'
reseal_phase_b_fixture "$HOSTILE_B_INPUT"
reject 'resealed Phase-B claim must remain input-bound in raw recovery evidence' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_INPUT"

HOSTILE_B_RETIRED_NODE="$TMP/evidence-hostile-b-retired-node"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_RETIRED_NODE"
mutate_json_in_place "$HOSTILE_B_RETIRED_NODE/phase-b-wallet-delta-raw.json" \
    '.records[2].recovery_matches[0].node.expired_locally_retired=true'
reseal_phase_b_fixture "$HOSTILE_B_RETIRED_NODE"
reject 'resealed Phase-B claim cannot be a locally retired recovery member' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_RETIRED_NODE"

HOSTILE_B_RETIRABLE_COMPONENT="$TMP/evidence-hostile-b-retirable-component"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_RETIRABLE_COMPONENT"
mutate_json_in_place "$HOSTILE_B_RETIRABLE_COMPONENT/phase-b-wallet-delta-raw.json" \
    '.records[2].recovery_matches[0].component.all_claims_zero_payment_retirable=true'
reseal_phase_b_fixture "$HOSTILE_B_RETIRABLE_COMPONENT"
reject 'resealed Phase-B claim component cannot be zero-payment retirable' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_RETIRABLE_COMPONENT"

HOSTILE_B_RETIRED_COMPONENT="$TMP/evidence-hostile-b-retired-component"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_RETIRED_COMPONENT"
mutate_json_in_place "$HOSTILE_B_RETIRED_COMPONENT/phase-b-wallet-delta-raw.json" \
    '.records[0].recovery_matches[0].component.all_claims_expired_locally_retired=true'
reseal_phase_b_fixture "$HOSTILE_B_RETIRED_COMPONENT"
reject 'resealed Phase-B payout component cannot be locally retired' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_RETIRED_COMPONENT"

HOSTILE_B_REMOVED_BASELINE="$TMP/evidence-hostile-b-removed-baseline"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_REMOVED_BASELINE"
# shellcheck disable=SC2016 # $anchor is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_B_REMOVED_BASELINE/candidate-final-wallet-transactions.json" \
    --arg anchor "$ANCHOR" 'map(select(.txid != $anchor))'
HOSTILE_B_REMOVED_FINAL_SHA=$(sha_file \
    "$HOSTILE_B_REMOVED_BASELINE/candidate-final-wallet-transactions.json")
# shellcheck disable=SC2016 # $hash is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_B_REMOVED_BASELINE/phase-b-wallet-delta-raw.json" \
    --arg hash "$HOSTILE_B_REMOVED_FINAL_SHA" '.final_wallet_transactions_sha256=$hash'
# shellcheck disable=SC2016 # $anchor is a jq variable, not a shell expansion.
mutate_json_in_place "$HOSTILE_B_REMOVED_BASELINE/phase-b-wallet-delta.json" \
    --arg anchor "$ANCHOR" '.removed_txids=[$anchor]'
reseal_phase_b_fixture "$HOSTILE_B_REMOVED_BASELINE"
reject 'resealed Phase-B evidence cannot omit a baseline wallet transaction' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_REMOVED_BASELINE"

if (( failures > 0 )); then
    printf '%d/%d assertions failed\n' "$failures" "$tests" >&2
    exit 1
fi
printf 'PASS: %d hostile two-phase canary assertions\n' "$tests"
