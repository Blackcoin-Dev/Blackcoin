#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail

ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
readonly ROOT
readonly TEST_CANDIDATE_SOURCE_SHA='0123456789abcdef0123456789abcdef01234567'
readonly TEST_CORE_CI_RUN_ID='42424242424'
readonly TEST_CORE_AUDIT_SOURCE_SHA='309731e3340f380e48cb67f94a243725465420fb'
readonly TEST_CORE_AUDIT_SOURCE_TREE='1517a277e1ab6355db0a14ed40d21e4e5e1dc846'
readonly TEST_CORE_AUDIT_SOURCE_PARENT='b08ae92024f3586f9d571df885f70af6ebc504ba'
readonly TEST_CORE_AUDIT_SIGNING_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'
readonly TEST_CORE_AUDIT_SOURCE_ROOT='/Users/gte755t/.cache/blackcoin-worktrees/blackcoin-309731e-consumer-audit'
TEST_CORE_SOURCE_ROOT=${HOTFIX_TEST_CORE_SOURCE_ROOT:-"$TEST_CORE_AUDIT_SOURCE_ROOT"}
TEST_CORE_SOURCE_ROOT=$(CDPATH='' cd -P -- "$TEST_CORE_SOURCE_ROOT" && pwd -P) ||
    exit 1
readonly TEST_CORE_SOURCE_ROOT
export HOTFIX_CANDIDATE_RELEASE_VERSION='30.1.5'
export HOTFIX_CANDIDATE_SOURCE_SHA="$TEST_CANDIDATE_SOURCE_SHA"
TMP_ROOT="/private/tmp/blackcoin-hotfix-canary-tests.$(id -u).$$"
mkdir -m 700 -- "$TMP_ROOT"

adapt_test_identity_contract()
{
    local source="$1" output="$2"
    grep -Fq '__FINAL_SIGNED_CORE_SHA__' "$source" &&
        grep -Fq '__FINAL_EXACT_SHA_CORE_CI_RUN_ID__' "$source" || return 1
    sed -e "s/__FINAL_SIGNED_CORE_SHA__/${TEST_CANDIDATE_SOURCE_SHA}/g" \
        -e "s/__FINAL_EXACT_SHA_CORE_CI_RUN_ID__/${TEST_CORE_CI_RUN_ID}/g" \
        "$source" >"$output" || return 1
    ! grep -Eq '__FINAL_(SIGNED_CORE_SHA|EXACT_SHA_CORE_CI_RUN_ID)__' "$output"
}

TEST_TYPED_CONTRACT="$TMP_ROOT/typed_contract.synthetic.sh"
adapt_test_identity_contract "$ROOT/lib/typed_contract.sh" "$TEST_TYPED_CONTRACT"
readonly TEST_TYPED_CONTRACT
# shellcheck source=lib/typed_contract.sh
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC1091 # Deterministic test-only identity adapter is generated above.
source "$TEST_TYPED_CONTRACT"

tests=0
failures=0
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

terminal_authority_equal()
{
    local pow1="$1" recovery1="$2" pow2="$3" recovery2="$4"
    [[ "$(hotfix_pow_gate_authority_json_sha256 "$pow1")" == \
       "$(hotfix_pow_gate_authority_json_sha256 "$pow2")" &&
       "$(hotfix_recovery_authority_json_sha256 "$recovery1")" == \
       "$(hotfix_recovery_authority_json_sha256 "$recovery2")" ]]
}

mutate_jsonl_in_place()
{
    local file="$1" filter="$2" temporary
    temporary="${file}.mutate"
    jq -cs "$filter | .[]" "$file" | jq -cS . >"$temporary"
    mv -f -- "$temporary" "$file"
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
FAMILY_B=$(printf '3%.0s' {1..64})
ANCHOR_B=$(printf '4%.0s' {1..64})
CLAIM_B1=$(printf '5%.0s' {1..64})
CLAIM_B2=$(printf '6%.0s' {1..64})
CLAIM_B3=$(printf '7%.0s' {1..64})
CLAIM_B4=$(printf '8%.0s' {1..64})
CLAIM5=$(printf 'd%.0s' {1..64})

goldrush_state_json()
{
    local tip="$1" height="$2" disabled="${3:-true}" activation_height="${4:-0}"
    jq -cn --arg tip "$tip" --argjson height "$height" \
        --argjson disabled "$disabled" --argjson activation "$activation_height" '
      {bestblock:$tip,height:$height,qqp4_activation_disabled:$disabled,
       qqp4_activation_height:(if $disabled then 0 else $activation end),
       qqp4_active:(if $disabled then false else $height >= $activation end),
       qqp4_active_next_block:
         (if $disabled then false else ($height + 1) >= $activation end)}
    '
}

# Direct unit observations use the disabled activation schedule unless the
# test supplies an exact activation receipt explicitly.  Full Phase-A/Phase-B
# fixtures never use this adapter: their sealed evidence carries the receipt.
test_pow_observation_json_is_valid()
{
    if (( $# == 6 )); then
        hotfix_pow_observation_json_is_valid "$@" \
            "$(goldrush_state_json "$4" "$5")"
    elif (( $# == 7 )); then
        hotfix_pow_observation_json_is_valid "$@"
    else
        return 1
    fi
}

mining_json()
{
    local action="${1:-refresh_same_anchor}" enabled="${2:-true}" state="${3:-claim_in_flight}"
    local autostart="${4:-false}"
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
        --argjson enabled "$enabled" --argjson autostart "$autostart" \
        --argjson can "$can_submit" --argjson hash "$hashrate" \
        --argjson unresolved "$unresolved" --argjson live "$live" \
        --argjson eligible "$eligible" --argjson families "$family_claims" \
        --argjson components "$components" '
        {accrued_jackpot:0,actionable_quarantined_claims:$families,
         allow_automatic_quantum_key_creation:false,autostart:$autostart,
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
         disposition:"origin_expired",exact_authored_carrier_shape:true,
         expected_shape:true,expired_locally_retired:false,in_mempool:false,kind:"claim",
         lineage_family_fingerprint:$family,lineage_metadata_present:true,
         lineage_metadata_valid:true,lineage_ordinal:$ordinal,lineage_parent_txid:$parent,
         lineage_root_txid:$root,proof_evaluation_skipped_resolved_anchor:false,
         proof_input_bound:true,proof_may_revalidate_on_descendant:false,proof_mode:"pow",
         proof_origin_bound:true,proof_origin_height:100,
         proof_origin_previous_block_hash:$tip,proof_version:4,
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
         anchor_authenticated:true,anchor_unspent:true,anchor_user_locked:false,
         claim_txids:[$c1,$c2,$c3,$c4],classification:"current_branch_ineligible",
         component_fingerprint:$family,descendant_claims:0,generation_fingerprint:$family,
         has_revalidating_unbound_proof:false,minimum_stale_depth:1,
         nodes:[node($c1;0;$zero),node($c2;1;$c1),node($c3;2;$c2),node($c4;3;$c3)],
         ordinary_or_mixed_txids:[],resolution_txids:[],
         root_claim_txids:[$c1,$c2,$c3,$c4],
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
    local autostart="${2:-false}"
    jq -cn --argjson height "$height" --argjson autostart "$autostart" '{active_blocks:$height,
      allow_automatic_quantum_key_creation:false,automatic_demurrage_attestation:false,
      automatic_qqsignal:false,automatic_redelegation:false,autostart_staking:$autostart,
      autostart_staking_source:"autostartstaking",blocks:$height,chain:"main",
      chainstate_cached:true,consensus_demurrage_automatic:true,difficulty:1,
      eligible:true,enabled:true,expectedtime:10,netstakeweight:1000,pooledtx:0,
      "search-interval":1,staking:true,staking_reason:"searching",
      staking_snapshot_current:true,staking_snapshot_sequence:1,
      staking_state:"searching",warnings:"",weight:100,weight_cache_height:$height,
      weight_cached:true,worker_running:true}'
}

staking_locked()
{
    local height="${1:-104}"
    staking_active "$height" true | jq -c '
      .staking=false | .eligible=false | .staking_state="locked" |
      .staking_reason="wallet locked" | .weight=0 | ."search-interval"=0'
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
    local mining recovery staking height head claims_json i
    local -a claim_ids=()
    height=$((100 + sample))
    mining=$(mining_json refresh_same_anchor)
    recovery=$(recovery_json "$tip" 9)
    for ((i = 1; i <= sample; i++)); do
        case "$i" in
            1) claim_ids+=("$CLAIM1") ;;
            2) claim_ids+=("$CLAIM2") ;;
            3) claim_ids+=("$CLAIM3") ;;
            4) claim_ids+=("$CLAIM4") ;;
            *) claim_ids+=("$(hex64 $((900 + i)))") ;;
        esac
    done
    head=${claim_ids[$((sample - 1))]}
    claims_json=$(printf '%s\n' "${claim_ids[@]}" | jq -R . | jq -s .)
    mining=$(jq --arg tip "$tip" --arg head "$head" --argjson height "$height" \
      --argjson count "$sample" '
      .claim_inventory_tip=$tip | .current_height=$height |
      .mining_gate_lineage_head_txid=$head | .mining_gate_family_claims=$count |
      .actionable_quarantined_claims=$count |
      .blocking_quarantined_claims=$count | .quarantined_claims=$count |
      .raw_quarantined_claims=$count | .unresolved_claims=$count
      ' <<<"$mining")
    recovery=$(jq --argjson height "$height" --argjson count "$sample" \
      --argjson claims "$claims_json" --arg zero "$HOTFIX_ZERO_TXID" '
      .component_details[0].nodes[0] as $template |
      .active_height=$height | .wallet_processed_height=$height |
      .actionable_quarantined_claims=$count |
      .blocking_quarantined_claims=$count |
      .quarantined_claim_objects=$count | .raw_claim_objects=$count |
      .raw_quarantined_claims=$count |
      .component_details[0].claim_txids=$claims |
      .component_details[0].root_claim_txids=$claims |
      .component_details[0].nodes=[range(0; ($claims | length)) as $i |
        $template |
        .txid=$claims[$i] | .lineage_ordinal=$i |
        .lineage_parent_txid=(if $i == 0 then $zero else $claims[$i - 1] end) |
        .lineage_root_txid=$claims[0]]
      ' <<<"$recovery")
    staking=$(staking_disabled)
    jq -S -n --argjson sample "$sample" --argjson epoch "$epoch" \
      --argjson observed "$((2000000000 + sample))" --arg tip "$tip" \
        --arg work "$work" --argjson mining "$mining" --argjson recovery "$recovery" \
        --argjson staking "$staking" --arg isolation "$isolation_sha" \
        --argjson goldrush "$(goldrush_state_json "$tip" "$height")" '
      {schema:4,phase:"A",sample:$sample,observed_epoch:$observed,restart_epoch:$epoch,
       chain_before:{chain:"main",initialblockdownload:false,blocks:(100+$sample),headers:(100+$sample),
         bestblockhash:$tip,chainwork:$work},
       chain_after:{chain:"main",initialblockdownload:false,blocks:(100+$sample),headers:(100+$sample),
         bestblockhash:$tip,chainwork:$work},recovery_before:$recovery,recovery_after:$recovery,
       mining_before:$mining,mining_after:$mining,staking:$staking,
       goldrush_state:$goldrush,
       mempool_verbose:{},
       wallet:{walletname:"",private_keys_enabled:true,scanning:false,unlocked_staking_only:false,
         unlocked_until:4102444800},network:{networkactive:true,localrelay:false,connections_out:4},
       wallets:[""],isolation_continuously_valid:true,
       isolation_sha256:$isolation,observer_status:"observed_absent"}
    ' >"$file"
}

make_progress()
{
    local output="$1" count="${2:-4}" dir sample file vis_sha tip epoch
    local envelopes_json isolation_json visibility_json
    local -a isolation_hashes=() visibility_hashes=() envelope_files=()
    dir=${output%/*}
    [[ "$dir" != "$output" ]] || dir=.
    for ((sample = 1; sample <= count; sample++)); do
        file="$dir/candidate-isolation-sample-${sample}.json"
        make_nonpublication "$file"
        isolation_hashes+=("$(sha256sum "$file" | awk '{print $1}')")
        file="$dir/candidate-visibility-sample-${sample}.json"
        if [[ ! -f "$file" ]]; then
            jq -cn --argjson sample "$sample" '{sample:$sample}' >"$file"
        fi
        vis_sha=$(sha256sum "$file" | awk '{print $1}')
        visibility_hashes+=("$vis_sha")
        file="$dir/phase-a-envelope-${count}-${sample}.json"
        envelope_files+=("$file")
        tip=$(hex64 "$sample")
        epoch=2
        (( sample == 1 )) && epoch=1
        make_envelope "$sample" "$epoch" "$tip" "$tip" \
            "${isolation_hashes[$((sample - 1))]}" "$file"
    done
    envelopes_json=$(jq -s '.' "${envelope_files[@]}")
    isolation_json=$(printf '%s\n' "${isolation_hashes[@]}" | jq -R . | jq -s .)
    visibility_json=$(printf '%s\n' "${visibility_hashes[@]}" | jq -R . | jq -s .)
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$NONCE" \
      --argjson count "$count" --argjson envelopes "$envelopes_json" \
      --argjson isolation "$isolation_json" --argjson visibility "$visibility_json" '
      {schema:5,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
       observation_sample_count:$count,envelopes:$envelopes,tip_changes:($count - 1),
       hard_flags_continuous:true,pos_disabled_continuous:true,
       nonpublication_continuous:true,interactive_surfaces_stopped_continuously:true,
       worker_only_pow:true,post_restart_advancing_observations:($count - 1),
       per_epoch_claims_submitted_zero:true,
       isolation_sample_sha256s:$isolation,visibility_sample_sha256s:$visibility,
       bounded_worker_tip_progress:true,
       single_positive_hash_sample_required:false,wait_for_next_tip_required_for_liveness:false,
       same_tip_or_submit_no_progress_transition_budget:1}
    ' >"$output"
}

make_claim()
{
    local output="$1" mode="${2:-all-new}" hash
    hash=$(printf '4%.0s' {1..64})
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg rpc "$hash" \
      --arg nonce "$NONCE" --arg payout Qfixture --arg quantum "$hash" \
      --arg mode "$mode" \
      --arg anchor "$ANCHOR" --arg family "$FAMILY" --arg root "$CLAIM1" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" \
      --arg anchor_b "$ANCHOR_B" --arg family_b "$FAMILY_B" --arg root_b "$CLAIM_B1" \
      --arg b1 "$CLAIM_B1" --arg b2 "$CLAIM_B2" \
      --arg tip1 "$TIP1" --arg tip2 "$TIP2" --arg tip3 "$TIP3" --arg tip4 "$TIP4" \
      --arg zero "$HOTFIX_ZERO_TXID" '
      def full_member($tx;$ordinal;$parent;$root_txid;$generation):
        {txid:$tx,ordinal:$ordinal,parent_txid:$parent,root_txid:$root_txid,
         family:$generation,lineage_metadata_present:true,lineage_metadata_valid:true,
         proof_mode:"pow",proof_version:3,proof_origin_bound:true,
         proof_input_bound:false,proof_may_revalidate_on_descendant:false,
         proof_evaluation_skipped_resolved_anchor:false,
         provenance:"explicit_authored",wallet_authored:true,wallet_from_me:true,
         authored_metadata_valid:true,authored_tip_active_branch_bound:true,
         claim_descriptor_valid:true,exact_authored_carrier_shape:true,
         disposition:"origin_expired"};
      def authored_member($tx;$ordinal;$parent;$root_txid;$generation;$anchor_txid;$tip):
        {txid:$tx,ordinal:$ordinal,parent_txid:$parent,anchor_txid:$anchor_txid,
         anchor_vout:0,family:$generation,root_txid:$root_txid,created_tip:$tip,
         quarantine_marker:"1",confirmations:0,abandoned:false,
         in_local_mempool:false,in_active_chain:false,observer_absent:true,
         proof_version:3,proof_origin_bound:true,proof_input_bound:false,
         expired_locally_retired:false,
         first_quarantine_observation_present:false,
         branch_quarantine_observation_present:false};
      def component($anchor_txid;$generation;$root_txid;$full;$new;$rich):
        {authenticated:true,anchor_txid:$anchor_txid,anchor_vout:0,
         family:$generation,root_txid:$root_txid,
         component_claim_txids:[$full[].txid],full_members:$full,
         newly_authored_txids:$new,newly_authored_members:$rich,
         all_claims_zero_payment_retirable:false,
         all_claims_expired_locally_retired:false,
         ordinary_or_mixed_txids:[],resolution_txids:[],contiguous_parents:true,
         newly_authored_contiguous_suffix:true};
      [full_member($c1;0;$zero;$root;$family),
       full_member($c2;1;$c1;$root;$family),
       full_member($c3;2;$c2;$root;$family),
       full_member($c4;3;$c3;$root;$family)] as $full_a |
      [full_member($b1;0;$zero;$root_b;$family_b),
       full_member($b2;1;$b1;$root_b;$family_b)] as $full_b |
      [authored_member($c1;0;$zero;$root;$family;$anchor;$tip1),
       authored_member($c2;1;$c1;$root;$family;$anchor;$tip2),
       authored_member($c3;2;$c2;$root;$family;$anchor;$tip3),
       authored_member($c4;3;$c3;$root;$family;$anchor;$tip4)] as $rich_a |
      [authored_member($c1;0;$zero;$root;$family;$anchor;$tip1),
       authored_member($c2;1;$c1;$root;$family;$anchor;$tip2),
       authored_member($c3;2;$c2;$root;$family;$anchor;$tip3),
       authored_member($c4;3;$c3;$root;$family;$anchor;$tip3)] as $rich_dense |
      [authored_member($b2;1;$b1;$root_b;$family_b;$anchor_b;$tip4)] as $rich_b |
      (if $mode == "zero" then []
       elif $mode == "prefix" then
         [component($anchor;$family;$root;$full_a;[$c3,$c4];$rich_a[2:])]
       elif $mode == "dense" then
         [component($anchor;$family;$root;$full_a;[$c1,$c2,$c3,$c4];$rich_dense)]
       elif $mode == "multi" then
         [component($anchor;$family;$root;$full_a[0:2];[$c2];[$rich_a[1]]),
          component($anchor_b;$family_b;$root_b;$full_b;[$b2];$rich_b)] |
         sort_by(.anchor_txid,.anchor_vout,.family,.root_txid)
       else
         [component($anchor;$family;$root;$full_a;[$c1,$c2,$c3,$c4];$rich_a)]
       end) as $components |
      (if $mode == "dense" then 3 else 4 end) as $sample_count |
      (if $mode == "dense" then [$tip1,$tip2,$tip3]
       else [$tip1,$tip2,$tip3,$tip4] end) as $progress_tips |
      ([$components[].newly_authored_txids[]] | sort) as $candidate_txids |
      ([$components[] | {txid:.anchor_txid,vout:.anchor_vout}] |
        sort_by(.txid,.vout) | unique_by(.txid,.vout)) as $anchors |
      {schema:6,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
       observation_sample_count:$sample_count,
       final_order:["tip-proof","pow-stop-joined","wallet-claim-mempool-observer-proof",
        "wallet-locked","candidate-clean-stop","logs-complete-through-stop"],
       pow_worker_joined:true,final_pow_enabled:false,
       final_pow_hashrate:0,logs_complete_through_stop:true,wallet_locked:true,
       candidate_cleanly_stopped:true,candidate_stopped_receipt_sha256:$rpc,
       candidate_complete_log_sha256:$rpc,candidate_post_stop_log_receipt_sha256:$rpc,
       external_receive_evidence_sha256:$rpc,external_receive_evidence_bound:true,
       observer_terminal_proof_sha256:$rpc,final_stable_cut_sha256:$rpc,
       terminal_stable_cut_verified:true,interactive_surfaces_stopped_continuously:true,
       shared_namespace_rpc_auth_boundary_continuously_verified:true,
       rpc_allowlist_enforced:true,unexpected_rpc_methods:[],
       candidate_claims_submitted:0,
       candidate_mining_gate_coherent:true,candidate_mining_gate_database_ambiguous:false,
       candidate_mining_gate_unsafe_claims:0,candidate_mining_gate_unsafe_components:0,
       candidate_recovery_database_ambiguous:false,hard_staking_disabled_continuously:true,
       retired_claim_objects:0,retired_components:0,candidate_retired_member_txids:[],
       coinstake_created_txids:[],network_visible_candidate_authored_txids:[],fee_payments_authorized:false,
       automatic_recovery_authorized:false,recovery_rpc_invoked:false,
       sendrawtransaction_invoked:false,abandontransaction_invoked:false,
       payout_rotation_invoked:false,forbidden_rpc_methods:[],rpc_methods_sha256:$rpc,
       payout_address_before:$payout,payout_address_after:$payout,
       payout_address_after_owned:true,payout_address_transition_valid:true,
       quantum_key_count_before:2,
       quantum_key_count_after:2,quantum_inventory_sha256_before:$quantum,
       quantum_inventory_sha256_after:$quantum,
       quantum_label_evidence_sha256_before:$quantum,
       quantum_label_evidence_sha256_after:$quantum,
       quantum_inventory_transition_valid:true,
       resolution_txids_before:[],
       resolution_txids_after:[],component_resolution_txids_before:[],
       component_resolution_txids_after:[],candidate_created_qqsproof_txids:$candidate_txids,
       external_receive_txids:[],
       candidate_created_qqsproof_mempool_txids:[],candidate_created_qqsproof_confirmed_txids:[],
       candidate_created_qqsproof_observer_txids:[],candidate_created_qqsproof_unclassifiable_txids:[],
       observer_status:"observed_absent",observer_samples:$sample_count,
       continuous_absence_verified:true,
       initial_atomic_reservation_verified:true,new_nonclaim_wallet_transactions:[],
       abandoned_wallet_txids:[],legacy_baseline_wallet_authority_preserved:true,
       legacy_baseline_wallet_authority_mutations:[],
       progress_tips:$progress_tips,
       claim_sample_tips:$progress_tips,claim_samples_monotonic:true,
       visibility_samples_bound_to_progress:true,observation_series_bound:true,
       candidate_authorship_mapped_exactly:true,candidate_txids_mapped_once:true,
       candidate_authored_suffixes_authenticated:true,
       new_wallet_txids_exclusive_to_authenticated_authored_claims_or_external_receives:true,
       final_claim_sample_complete:true,
       removed_outpoints_subset_of_authenticated_anchors:true,
       added_outpoints_exclusive_to_external_receives:true,
       authored_components:$components,authenticated_anchors:$anchors,
       removed_wallet_outpoints:$anchors,added_wallet_outpoints:[],
       txid_differential_classified:true,
       mempool_differential_classified:true,wallet_outpoint_differential_classified:true}
    ' >"$output"
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
      --arg body "$HOTFIX_CANDIDATE_ENTRYPOINT_BODY_SHA256" --arg anchor "$ANCHOR" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" '
      {schema:2,result:"REWIND_SAFE",run_nonce:$nonce,candidate_source_sha:$source,
       observation_sample_count:4,
       candidate_image_id:$id,candidate_image_ref:$ref,candidate_manifest_digest:$manifest,
       candidate_blackcoin_qt_sha256:$hash,
       tooling_commit:"1234567890123456789012345678901234567890",
       phase_a_tooling_identity_sha256:$hash,package_sha256sums_sha256:$hash,
       phase_a_script_sha256:$hash,phase_b_script_sha256:$hash,
       verifier_sha256:$hash,typed_contract_sha256:$hash,
       entrypoint_body_sha256:$body,invocation_sha256:$hash,helper_audit_sha256:$hash,
       nonpublication_sha256:$hash,snapshot_set_sha256:$hash,progress_sha256:$hash,
       claim_proof_sha256:$hash,authored_components_sha256:$hash,
       logs_sha256:$hash,rpc_journal_sha256:$hash,
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
       observer_anchors_unspent_sha256:$hash,observer_tx_absence_sha256:$hash,
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
       candidate_created_qqsproof_txids:([$c1,$c2,$c3,$c4] | sort),
       authenticated_anchors:[{txid:$anchor,vout:0}],
       network_visible_candidate_authored_txids:[],confirmed_candidate_txids:[],
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
      {schema:2,run_nonce:$nonce,source_sha:$source,image:$image,image_id:$id,
       hard_quarantine_flags_verified:true,wallet_locked:true,pow_enabled:false,pos_enabled:false,
       walletbroadcast:false,chain:{chain:"main",initialblockdownload:false,blocks:104,headers:104,
        bestblockhash:$tip,chainwork:$work},chain_after:{chain:"main",initialblockdownload:false,
        blocks:104,headers:104,bestblockhash:$tip,chainwork:$work},
       phase_a_terminal_chainwork:$work,
       phase_a_terminal_tip:$tip,chainwork_at_least_phase_a:true,terminal_tip_active:true,
       terminal_tip_superseded_by_greater_work:false,wallet:$wallet,recovery:$recovery,
       staking:$staking,pow:$pow,network:$network,wallets:[""],
       authenticated_anchors:[{txid:$anchor,vout:0,unspent:true,
        txout:{confirmations:100,coinbase:false}}],invocation_sha256:$hash,
       nonpublication_sha256:$hash,observer_cut_sha256:$hash,chain_evidence_sha256:$hash,
       chain_after_evidence_sha256:$hash,recovery_evidence_sha256:$hash,
       wallet_evidence_sha256:$hash,staking_evidence_sha256:$hash,pow_evidence_sha256:$hash,
       network_evidence_sha256:$hash,wallets_evidence_sha256:$hash,
       wallet_transactions_sha256:$hash,mempool_sha256:$hash,
       authenticated_anchors_evidence_sha256:$hash,wallet_processed_tip_current:true,
       candidate_image_not_applied:true,candidate_txids_absent_from_wallet:true,
       candidate_txids_absent_from_mempool:true,authenticated_anchors_unspent:true,
       observer_candidate_txids_absent:true,observer_anchors_unspent:true,
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
      {schema:4,phase:"B",node:27,result:"passed",candidate_source_sha:$source,
       phase_a_result_sha256:$result,promoted_no_rewind_marker_verified:true,
       snapshots_absent_before_launch:true,datasets_preserved:true,candidate_running:true,
       wallet_chain_synchronized_before_unlock:true,normal_unlock_completed:true,
       core_native_pos_intent_configured:true,core_native_pow_intent_configured:true,
       locked_pos_zero_work_observed:true,locked_pow_zero_work_observed:true,
       normal_unlock_only_resume_observed:true,repair_enable_rpcs_used:false,pos_active:true,
       p2p_ready:true,
       typed_gate_safe:true,configured_payout_transition_valid:true,quantum_keys_unchanged:true,
       automatic_recovery_unauthorized_continuously:true,
       candidate_resolution_membership_baseline_bound:true,
       no_new_fee_bearing_recovery_wallet_transaction:true,
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
       candidate_locked_sync_sha256:$hash,
       candidate_locked_resolution_txids_sha256:$hash,
       candidate_final_recovery_sha256:$hash,
       candidate_final_resolution_txids_sha256:$hash}
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
    local package="$TMP/fixture-package" relative adapted_contract
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
    adapted_contract="$package/lib/typed_contract.sh.synthetic"
    adapt_test_identity_contract "$package/lib/typed_contract.sh" "$adapted_contract"
    mv "$adapted_contract" "$package/lib/typed_contract.sh"
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
    jq -S -n '{walletname:"",private_keys_enabled:true,scanning:false,
      unlocked_staking_only:false,unlocked_until:4102444800}' \
        >"$root/baseline-wallet.json"
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
              --arg c4 "$CLAIM4" '[$c1,$c2,$c3,$c4] | sort' >"$root/$name.json"
        else
            jq -n '[]' >"$root/$name.json"
        fi
    done
    jq -n '{}' >"$root/candidate-final-mempool-verbose.json"
    jq -n '{}' >"$root/candidate-final-mempool-verbose-after.json"
    jq -S -n --arg anchor "$ANCHOR" --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" \
      --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" '
      [$c1,$c2,$c3,$c4] | sort |
      map({txid:.,anchor_txid:$anchor,anchor_vout:0})
    ' >"$root/candidate-created-txid-anchor-map.json"
    jq -S -n --arg anchor "$ANCHOR" '[{txid:$anchor,vout:0}]' \
      >"$root/candidate-authenticated-anchors.json"
    mining=$(mining_json refresh_same_anchor)
    printf '%s\n' "$mining" >"$root/baseline-pow.json"
    recovery=$(recovery_json "$TIP4" 9 | jq '
      .component_details[].nodes |= map(if .kind=="claim" then
        .proof_version=3 | .proof_origin_bound=true | .proof_input_bound=false
      else . end)')
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
    goldrush_state_json "$TIP4" 104 >"$root/candidate-final-goldrush-state.json"
    cp "$root/candidate-final-goldrush-state.json" \
        "$root/candidate-final-goldrush-state-after.json"
    jq -S -n --arg nonce "$NONCE" --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg tip "$TIP4" --slurpfile before "$root/prelaunch-wallet-transactions.json" \
      --slurpfile after "$root/candidate-final-wallet-transactions.json" \
      --slurpfile authored "$root/candidate-created-qqsproof-txids.json" '
      ($before[0] | map(.txid) | unique | sort) as $old |
      ($after[0] | map(.txid) | unique | sort) as $final |
      ($authored[0] | unique | sort) as $candidate |
      {schema:1,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
       terminal_tip:$tip,terminal_height:104,prelaunch_wallet_txids:$old,
       final_wallet_txids:$final,new_wallet_txids:($final-$old),
       candidate_authored_txids:$candidate,external_receive_txids:[],records:[],
       sets_disjoint:true,wallet_differential_exhaustive:true}
    ' >"$root/candidate-external-receive-evidence.json"
    jq -S -n '[
      {key:"q1",address:"Qfixture",tiered:false,stored_in_wallet:true},
      {key:"q2",address:"Qother",tiered:false,stored_in_wallet:true}
    ]' >"$root/baseline-quantum-inventory.json"
    cp "$root/baseline-quantum-inventory.json" "$root/candidate-final-quantum-inventory.json"
    jq -S -n '{schema:1,labels:[]}' >"$root/baseline-quantum-labels.json"
    cp "$root/baseline-quantum-labels.json" "$root/candidate-final-quantum-labels.json"
    jq -S -n '{address:"Qfixture",isvalid:true,ismine:true,solvable:true,
      iswatchonly:false,isquantummigration:true,hasquantumkey:true,
      isquantumcoldstake:false}' \
        >"$root/candidate-final-payout-address.json"
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
    jq -S -n --arg tip "$TIP4" \
      --slurpfile authenticated_anchors "$root/candidate-authenticated-anchors.json" \
      --slurpfile mapping "$root/candidate-created-txid-anchor-map.json" \
      --slurpfile chains "$root/observer-final-chain.jsonl" \
      --slurpfile anchors "$root/observer-anchor-unspent.jsonl" \
      --slurpfile absence "$root/observer-tx-absence.jsonl" '
      {schema:2,terminal_tip:$tip,terminal_chainwork:$tip,
       authenticated_anchors:$authenticated_anchors[0],candidate_txid_anchor_map:$mapping[0],
       observer_chains:$chains,observer_anchors:$anchors,tx_absence:$absence,
       observers_stable_and_cover_terminal:true,
       authenticated_anchors_unspent_on_all_observers:true}
    ' >"$root/observer-terminal-proof.json"
    terminal_sha=$(sha_file "$root/observer-terminal-proof.json")
    recovery_authority_sha=$(hotfix_recovery_authority_json_sha256 \
        "$(<"$root/candidate-final-recovery-inventory.json")")
    pow_gate_authority_sha=$(hotfix_pow_gate_authority_json_sha256 \
        "$(<"$root/candidate-final-pow.json")")
    jq -S -n --arg tip "$TIP4" --arg terminal "$terminal_sha" \
      --arg recovery_authority "$recovery_authority_sha" \
      --arg pow_gate_authority "$pow_gate_authority_sha" \
      --arg first_mempool "$(sha_file "$root/candidate-final-mempool-verbose.json")" \
      --arg second_mempool "$(sha_file "$root/candidate-final-mempool-verbose-after.json")" \
      --arg first_goldrush "$(sha_file "$root/candidate-final-goldrush-state.json")" \
      --arg second_goldrush "$(sha_file "$root/candidate-final-goldrush-state-after.json")" \
      --argjson schedule "$(jq -c \
        '{qqp4_activation_disabled,qqp4_activation_height}' \
        "$root/candidate-final-goldrush-state.json")" '
      {schema:4,stable:true,observer_terminal_proof_sha256:$terminal,
       terminal_tip:$tip,terminal_chainwork:$tip,wallet_generation:9,
       recovery_authority_sha256:$recovery_authority,
       pow_gate_authority_sha256:$pow_gate_authority,
       first_observed_epoch:2000000000,second_observed_epoch:2000000001,
       first_goldrush_state_sha256:$first_goldrush,
       second_goldrush_state_sha256:$second_goldrush,
       qqp4_schedule:$schedule,
       first_mempool_verbose_sha256:$first_mempool,
       second_mempool_verbose_sha256:$second_mempool}
    ' >"$root/candidate-final-stable-cut.json"
    : >"$root/tx-visibility-samples.jsonl"
    for sample in 1 2 3 4; do
        case "$sample" in
            1) tip=$TIP1; work=$(hex64 1); height=101 ;;
            2) tip=$TIP2; work=$(hex64 2); height=102 ;;
            3) tip=$TIP3; work=$(hex64 3); height=103 ;;
            4) tip=$TIP4; work=$(hex64 4); height=104 ;;
        esac
        mining=$(mining_json refresh_same_anchor true claim_in_flight true | jq --arg tip "$tip" \
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
    : >"$root/candidate-claim-samples.jsonl"
    for sample in 1 2 3 4; do
        jq -cS . "$root/candidate-claims-sample-${sample}.json" \
            >>"$root/candidate-claim-samples.jsonl"
    done
    make_progress "$root/phase-a-progress.json"
    jq -S -n --arg id "$CANDIDATE_FIXTURE_IMAGE_ID" \
      '{running:false,exit_code:0,image_id:$id}' >"$root/candidate-stopped.json"
    printf '%s\n' 'candidate completed clean stop' >"$root/candidate-complete.log"
    stopped_sha=$(sha_file "$root/candidate-stopped.json")
    log_sha=$(sha_file "$root/candidate-complete.log")
    jq -S -n --arg stopped "$stopped_sha" --arg log "$log_sha" '
      {schema:1,candidate_stopped_receipt_sha256:$stopped,complete_log_sha256:$log,
       captured_after_clean_stop:true,candidate_finished_at:"2026-08-08T00:00:00Z",
       captured_utc:"2026-08-08T00:00:01Z"}
    ' >"$root/candidate-post-stop-log-receipt.json"
    post_sha=$(sha_file "$root/candidate-post-stop-log-receipt.json")
    stable_sha=$(sha_file "$root/candidate-final-stable-cut.json")
    quantum_sha=$(sha_file "$root/baseline-quantum-inventory.json")
    make_claim "$root/phase-a-claim-proof.base.json"
    jq -S --arg rpc "$(sha_file "$root/candidate-rpc-methods-through-proof.log")" \
      --arg stopped "$stopped_sha" --arg log "$log_sha" --arg post "$post_sha" \
      --arg stable "$stable_sha" --arg terminal "$terminal_sha" --arg quantum "$quantum_sha" \
      --arg external "$(sha_file "$root/candidate-external-receive-evidence.json")" \
      --arg quantum_labels "$(sha_file "$root/baseline-quantum-labels.json")" '
      .rpc_methods_sha256=$rpc | .candidate_stopped_receipt_sha256=$stopped |
      .candidate_complete_log_sha256=$log | .candidate_post_stop_log_receipt_sha256=$post |
      .final_stable_cut_sha256=$stable | .observer_terminal_proof_sha256=$terminal |
      .external_receive_evidence_sha256=$external |
      .quantum_inventory_sha256_before=$quantum | .quantum_inventory_sha256_after=$quantum |
      .quantum_label_evidence_sha256_before=$quantum_labels |
      .quantum_label_evidence_sha256_after=$quantum_labels
    ' "$root/phase-a-claim-proof.base.json" >"$root/phase-a-claim-proof.json"
    jq -S '.authored_components' "$root/phase-a-claim-proof.json" \
      >"$root/candidate-authored-components.json"
    rm "$root/phase-a-claim-proof.base.json"
}

build_phase_a_pre_fixture()
{
    local root="$1" hash candidate_ref baseline_policy no_restart
    local recovery_authority_sha pow_gate_authority_sha
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
    jq -S -n --arg anchor "$ANCHOR" \
      '[{txid:$anchor,vout:0,unspent:true,txout:{confirmations:100,coinbase:false}}]' \
      >"$root/base-catchup-anchors.json"
    : >"$root/base-catchup-observer.jsonl"
    local observer
    for observer in blackcoin-v4-gui-26 blackcoin-v4-gui-28; do
        jq -cS -n --arg observer "$observer" --arg tip "$TIP4" \
          --slurpfile anchors "$root/base-catchup-anchors.json" '
          def chain:{chain:"main",initialblockdownload:false,blocks:104,headers:104,
            bestblockhash:$tip,chainwork:$tip};
          {observer:$observer,stable:true,candidate_txids_absent:true,chain_before:chain,
           chain_after:chain,terminal_relation:"same_terminal_tip",mempool:[],
           authenticated_anchors:$anchors[0],authenticated_anchors_unspent:true}
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
      --arg anchors "$(sha_file "$root/base-catchup-anchors.json")" \
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
      .mempool_sha256=$mempool | .authenticated_anchors_evidence_sha256=$anchors |
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
    cp "$root/baseline-quantum-labels.json" "$root/baseline-restored-quantum-labels.json"
    cp "$root/candidate-final-payout-address.json" \
        "$root/baseline-restored-payout-address.json"
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
      --arg authored "$(jq -cS '.authored_components' \
        "$root/phase-a-claim-proof.json" | sha256sum | awk '{print $1}')" \
      --argjson anchors "$(jq -c '.authenticated_anchors' \
        "$root/phase-a-claim-proof.json")" \
      --argjson txids "$(jq -c '.candidate_created_qqsproof_txids' \
        "$root/phase-a-claim-proof.json")" \
      --argjson sample_count "$(jq -c '.observation_sample_count' \
        "$root/phase-a-progress.json")" \
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
      .claim_proof_sha256=$claim | .authored_components_sha256=$authored |
      .authenticated_anchors=$anchors | .candidate_created_qqsproof_txids=$txids |
      .observation_sample_count=$sample_count |
      .logs_sha256=$logs | .rpc_journal_sha256=$rpc |
      .locks_sha256=$locks | .guard_sources_sha256=$guard | .pre_rewind_state_sha256=$state |
      .maintenance_marker_sha256=$maintenance | .offline_verifier_receipt_sha256=$receipt |
      .baseline_runtime_identity_sha256=$baseline | .candidate_bundle_manifest_sha256=$bundle |
      .candidate_oci_identity_sha256=$oci | .candidate_binary_sha256sums_sha256=$binaries |
      .candidate_loaded_image_sha256=$loaded | .pre_rewind_manifest_sha256=$pre |
      .phase_a_tooling_identity_sha256=$tooling_identity | .tooling_commit=$tooling |
      .package_sha256sums_sha256=$package | .phase_a_script_sha256=$phase_a |
      .phase_b_script_sha256=$phase_b | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract |
      .candidate_final_chain_sha256=$chain | .candidate_final_chain_after_sha256=$chain_after |
      .candidate_final_pow_sha256=$pow | .candidate_final_pow_after_sha256=$pow_after |
      .candidate_final_staking_sha256=$staking |
      .candidate_final_staking_after_sha256=$staking_after |
      .candidate_final_recovery_sha256=$recovery |
      .candidate_final_recovery_after_sha256=$recovery_after |
      .candidate_final_wallet_transactions_sha256=$wallet_tx |
      .candidate_final_mempool_sha256=$mempool |
      .observer_terminal_proof_sha256=$terminal | .observer_final_chain_sha256=$observer_chain |
      .observer_anchors_unspent_sha256=$observer_anchor |
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
    local pre="$1" root="$2" hash no_restart
    local invocation isolation observer anchors canonical stage snapshot position suffix prefix
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
    canonical=$(sha_file "$root/candidate-authenticated-anchors.json")
    : >"$root/snapshot-destroy-authority-rechecks.jsonl"
    local index
    for index in {1..10}; do
        snapshot=''
        if (( index == 1 )); then
            stage=initial
        elif (( index == 10 )); then
            stage=final
        else
            position=$(( (index - 2) / 2 + 1 ))
            snapshot=$(jq -r '.snapshots[].snapshot' "$root/snapshot-set.json" |
                awk '{d=$0; sub(/@[^@]+$/, "", d); depth=gsub(/\//,"/",d);
                  print depth "\t" $0}' |
                sort -t $'\t' -k1,1nr -k2,2 | cut -f2 | sed -n "${position}p")
            if (( index % 2 == 0 )); then stage='before-release'
            else stage='before-destroy'
            fi
        fi
        printf -v suffix '%02d' "$index"
        prefix="$root/base-destroy-recheck-${suffix}"
        cp "$root/base-quarantine-invocation-current.json" "${prefix}-invocation.json"
        make_nonpublication "${prefix}-nonpublication.json"
        cp "$root/base-catchup-anchors.json" "${prefix}-anchors.json"
        jq -cS --argjson sequence "$index" --arg stage "$stage" --arg snapshot "$snapshot" '
          . + {authority_sequence:$sequence,authority_stage:$stage,
            authority_snapshot:(if $snapshot == "" then null else $snapshot end)}
        ' "$root/base-catchup-observer.jsonl" >"${prefix}-observers.jsonl"
        invocation=$(sha_file "${prefix}-invocation.json")
        isolation=$(sha_file "${prefix}-nonpublication.json")
        anchors=$(sha_file "${prefix}-anchors.json")
        observer=$(sha_file "${prefix}-observers.jsonl")
        jq -cS -n --arg tip "$TIP4" --arg invocation "$invocation" \
          --arg isolation "$isolation" --arg observer "$observer" \
          --arg anchors "$anchors" --arg canonical "$canonical" \
          --arg stage "$stage" --arg snapshot "$snapshot" --argjson index "$index" '
          {schema:2,sequence:$index,stage:$stage,
           snapshot:(if $snapshot == "" then null else $snapshot end),
           authenticated_anchors_unspent:true,authority_valid:true,
           candidate_txids_absent:true,observer_candidate_txids_absent:true,
           observer_anchors_unspent:true,chain_tip:$tip,chainwork:$tip,
           invocation_sha256:$invocation,nonpublication_sha256:$isolation,
           canonical_authenticated_anchors_sha256:$canonical,
           local_anchor_evidence_sha256:$anchors,
           observed_utc:("2026-08-08T00:00:"+
             (if $index<10 then "0" else "" end)+($index|tostring)+"Z"),
           observer_cut_sha256:$observer,pos_disabled:true,pow_disabled:true,
           terminal_relation:"terminal-tip-active",wallet_locked:true}
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
      --arg base_stop "$(sha_file "$root/base-quarantine-stop-authority.json")" \
      --arg restored_container "$(sha_file "$root/baseline-restored-container.json")" \
      --arg manifest "$(sha_file "$root/POST_REWIND_SHA256SUMS")" '
      .rewind_safe_sha256=$cert | .catchup_proof_sha256=$catchup |
      .snapshot_absence_sha256=$absence | .evidence_sha256sums_sha256=$manifest |
      .phase_a_tooling_identity_sha256=$tooling_identity | .tooling_commit=$tooling |
      .package_sha256sums_sha256=$package | .phase_a_script_sha256=$phase_a |
      .phase_b_script_sha256=$phase_b | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract |
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
    local output="$1" sample tip height mining recovery staking wallet chain network goldrush
    local samples='[]'
    for sample in 1 2 3 4; do
        case "$sample" in
            1) tip=$TIP1; height=101 ;;
            2) tip=$TIP2; height=102 ;;
            3) tip=$TIP3; height=103 ;;
            4) tip=$TIP4; height=104 ;;
        esac
        mining=$(mining_json refresh_same_anchor true claim_in_flight true | jq --arg tip "$tip" \
          --argjson height "$height" '
          .claim_inventory_tip=$tip | .current_height=$height |
          .hashrate=5 | .state="hashing"')
        recovery=$(recovery_json "$tip" 9 | jq --argjson height "$height" \
          '.active_height=$height | .wallet_processed_height=$height')
        staking=$(staking_active "$height" true)
        wallet=$(jq -cn '{walletname:"",private_keys_enabled:true,scanning:false,
          unlocked_staking_only:false,unlocked_until:4102444800}')
        chain=$(jq -cn --arg tip "$tip" --argjson height "$height" \
          '{chain:"main",initialblockdownload:false,blocks:$height,headers:$height,
            bestblockhash:$tip,chainwork:$tip}')
        network=$(jq -cn '{networkactive:true,connections_out:4}')
        goldrush=$(goldrush_state_json "$tip" "$height")
        samples=$(jq -cn --argjson existing "$samples" --argjson sample "$sample" \
          --argjson chain "$chain" --argjson network "$network" --argjson wallet "$wallet" \
          --argjson staking "$staking" --argjson pow "$mining" \
          --argjson recovery "$recovery" --argjson goldrush "$goldrush" '
          $existing+[{sample:$sample,observed_epoch:(2000000000+$sample),chain:$chain,network:$network,
            wallet:$wallet,staking:$staking,pow:$pow,recovery:$recovery,
            goldrush_state:$goldrush,mempool_verbose:{}}]
        ')
    done
    jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" \
      --arg nonce 'fedcba9876543210fedcba9876543210' --argjson samples "$samples" '
      ($samples | length) as $count |
      {schema:4,phase:"B",candidate_source_sha:$source,promotion_nonce:$nonce,
       observation_sample_count:$count,samples:$samples,tip_changes:($count - 1),
       wallet_chain_synchronized_continuously:true,
       pos_active_continuously:true,p2p_ready_continuously:true,
       same_tip_or_submit_no_progress_transition_budget:1}
    ' >"$output"
}

set_phase_b_sample_action()
{
    local file="$1" index="$2" action="$3" fingerprint="$4" hashrate="${5:-0}"
    local temporary="${file}.action"
    jq -S --argjson index "$index" --arg action "$action" --arg fp "$fingerprint" \
      --arg head "$CLAIM4" --arg zero "$HOTFIX_ZERO_TXID" --argjson hash "$hashrate" '
      .samples[$index] |= (
        .observed_epoch as $observed | .chain.blocks as $height |
        .pow.mining_gate_action=$action |
        .pow.mining_gate_candidate_state_fingerprint=$fp |
        .pow.hashrate=$hash |
        .pow.state=(if ($action == "wait_for_live" or
          $action == "wait_for_next_tip" or $action == "relay_existing")
          then "claim_in_flight" elif $hash > 0 then "hashing" else "ready" end) |
        .pow.mining_gate_can_submit=
          ($action == "create_new_anchor" or $action == "refresh_same_anchor" or
           $action == "wait_for_next_tip") |
        .pow.mining_gate_relay_txid=
          (if $action == "relay_existing" then $head else $zero end) |
        .pow.mining_gate_live_claims=
          (if $action == "wait_for_live" then 1 else 0 end) |
        .pow.live_claims=.pow.mining_gate_live_claims |
        .pow.mining_gate_eligible_claims=
          (if $action == "relay_existing" then 1 else 0 end) |
        .recovery.component_details[0].nodes |= map(
          .in_mempool=false | .relay_ttl_expired=false | .relay_expiry_time=0 |
          if .txid == $head then
            .in_mempool=($action == "wait_for_live") |
            .disposition=(if $action == "relay_existing" then "eligible"
              else "origin_expired" end) |
            .relay_expiry_time=(if $action == "relay_existing"
              then ($observed + 600) else 0 end)
          else . end) |
        .recovery.live_claim_objects=
          (if $action == "wait_for_live" then 1 else 0 end) |
        .recovery.component_details[0].classification=
          (if $action == "wait_for_live" then "live"
           else "current_branch_ineligible" end) |
        .mempool_verbose=(if $action == "wait_for_live" then
          {($head):{time:($observed - 10),height:$height}} else {} end) |
        if $action == "create_new_anchor" then
          .pow.mining_gate_lineage_head_txid=$zero |
          .pow.mining_gate_family_claims=0 |
          .pow.mining_gate_unresolved_components=0 |
          .pow.actionable_quarantined_claims=0 |
          .pow.blocking_quarantined_claims=0 |
          .pow.quarantined_claims=0 | .pow.raw_quarantined_claims=0 |
          .pow.unresolved_claims=0 | .pow.claim_components=0 |
          .recovery.actionable_quarantined_claims=0 |
          .recovery.blocking_quarantined_claims=0 |
          .recovery.quarantined_claim_objects=0 |
          .recovery.raw_claim_objects=0 | .recovery.raw_quarantined_claims=0 |
          .recovery.blocking_components=0 | .recovery.components=0 |
          .recovery.component_details=[]
        else . end
      )
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

set_phase_b_sample_relay_member()
{
    local file="$1" index="$2" txid="$3" temporary
    temporary="${file}.relay-member"
    jq -S --argjson index "$index" --arg txid "$txid" '
      .samples[$index] |= (
        .observed_epoch as $observed |
        .pow.mining_gate_relay_txid=$txid |
        .recovery.component_details[0].nodes |= map(
          .in_mempool=false | .relay_ttl_expired=false |
          if .txid == $txid then
            .disposition="eligible" | .relay_expiry_time=($observed + 600)
          else .disposition="origin_expired" | .relay_expiry_time=0 end) |
        .mempool_verbose={}
      )
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

set_phase_b_sample_live_member()
{
    local file="$1" index="$2" txid="$3" temporary
    temporary="${file}.live-member"
    jq -S --argjson index "$index" --arg txid "$txid" '
      .samples[$index] |= (
        .observed_epoch as $observed | .chain.blocks as $height |
        .recovery.component_details[0].nodes |= map(
          .in_mempool=(.txid == $txid) | .relay_ttl_expired=false |
          .relay_expiry_time=0 | .disposition="origin_expired") |
        .mempool_verbose={($txid):{time:($observed - 10),height:$height}}
      )
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

set_phase_b_sample_family_b()
{
    local file="$1" index="$2" temporary
    temporary="${file}.family-b"
    jq -S --argjson index "$index" --arg family "$FAMILY_B" \
      --arg anchor "$ANCHOR_B" --arg b1 "$CLAIM_B1" --arg b2 "$CLAIM_B2" \
      --arg b3 "$CLAIM_B3" --arg b4 "$CLAIM_B4" --arg zero "$HOTFIX_ZERO_TXID" '
      ([$b1,$b2,$b3,$b4]) as $claims |
      .samples[$index] |= (
        .pow.mining_gate_candidate_state_fingerprint=$family |
        .pow.mining_gate_lineage_head_txid=$b4 |
        .recovery.component_details[0] |= (
          .anchor.txid=$anchor | .component_fingerprint=$family |
          .generation_fingerprint=$family | .claim_txids=$claims |
          .root_claim_txids=$claims |
          .nodes |= map(
            .lineage_ordinal as $ordinal |
            .txid=$claims[$ordinal] |
            .lineage_family_fingerprint=$family |
            .lineage_root_txid=$b1 |
            .lineage_parent_txid=(if $ordinal == 0 then $zero
              else $claims[$ordinal - 1] end))))
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

add_phase_b_sample_family_b_live()
{
    local file="$1" index="$2" temporary
    temporary="${file}.family-b-live"
    jq -S --argjson index "$index" --arg family "$FAMILY_B" \
      --arg anchor "$ANCHOR_B" --arg b1 "$CLAIM_B1" --arg b2 "$CLAIM_B2" \
      --arg b3 "$CLAIM_B3" --arg b4 "$CLAIM_B4" --arg zero "$HOTFIX_ZERO_TXID" '
      ([$b1,$b2,$b3,$b4]) as $claims |
      .samples[$index] |= (
        .observed_epoch as $observed | .chain.blocks as $height |
        .recovery.component_details[0] as $template |
        ($template |
          .anchor.txid=$anchor | .component_fingerprint=$family |
          .generation_fingerprint=$family | .claim_txids=$claims |
          .root_claim_txids=$claims | .classification="live" |
          .nodes |= map(
            .lineage_ordinal as $ordinal |
            .txid=$claims[$ordinal] |
            .lineage_family_fingerprint=$family |
            .lineage_root_txid=$b1 |
            .lineage_parent_txid=(if $ordinal == 0 then $zero
              else $claims[$ordinal - 1] end) |
            .in_mempool=($ordinal == 3) | .disposition="origin_expired" |
            .relay_ttl_expired=false | .relay_expiry_time=0)) as $family_b |
        .recovery.component_details += [$family_b] |
        .recovery.components=2 | .recovery.blocking_components=2 |
        .recovery.actionable_quarantined_claims=8 |
        .recovery.blocking_quarantined_claims=8 |
        .recovery.quarantined_claim_objects=8 |
        .recovery.raw_claim_objects=8 | .recovery.raw_quarantined_claims=8 |
        .recovery.live_claim_objects += 1 |
        .pow.claim_components=2 | .pow.actionable_quarantined_claims=8 |
        .pow.blocking_quarantined_claims=8 | .pow.quarantined_claims=8 |
        .pow.raw_quarantined_claims=8 | .pow.unresolved_claims=8 |
        .pow.mining_gate_unresolved_components=2 |
        .pow.mining_gate_family_claims=8 |
        .pow.mining_gate_live_claims += 1 | .pow.live_claims += 1 |
        .mempool_verbose += {($b4):{time:($observed - 10),height:$height}}
      )
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

truncate_phase_b_sample_family()
{
    local file="$1" index="$2" count="$3" temporary
    temporary="${file}.family"
    jq -S --argjson index "$index" --argjson count "$count" \
      --arg c1 "$CLAIM1" --arg c2 "$CLAIM2" --arg c3 "$CLAIM3" --arg c4 "$CLAIM4" '
      ([$c1,$c2,$c3,$c4][0:$count]) as $claims |
      .samples[$index] |= (
        .pow.mining_gate_lineage_head_txid=$claims[-1] |
        .pow.mining_gate_family_claims=$count |
        .pow.actionable_quarantined_claims=$count |
        .pow.blocking_quarantined_claims=$count |
        .pow.quarantined_claims=$count |
        .pow.raw_quarantined_claims=$count |
        .pow.unresolved_claims=$count |
        .recovery.component_details[0].nodes |= map(select(.txid as $txid |
          $claims | index($txid))) |
        .recovery.component_details[0].claim_txids=$claims |
        .recovery.actionable_quarantined_claims=$count |
        .recovery.blocking_quarantined_claims=$count |
        .recovery.quarantined_claim_objects=$count |
        .recovery.raw_claim_objects=$count |
        .recovery.raw_quarantined_claims=$count
      )
    ' "$file" >"$temporary" || return 1
    mv -f -- "$temporary" "$file"
}

make_phase_b_wallet_delta()
{
    local root="$1" coinstake payout foreign foreign_ordinary coin_block payout_block coinbase claim_row
    local recovery raw_sha baseline_sha final_sha recovery_sha baseline_recovery_sha progress_sha
    coinstake=$(printf 'a%.0s' {1..64})
    payout=$(printf '6%.0s' {1..64})
    coin_block=$(printf 'b%.0s' {1..64})
    payout_block=$(printf 'c%.0s' {1..64})
    coinbase=$(printf '0%.0s' {1..63}; printf '1')
    foreign=$(printf 'd%.0s' {1..64})
    foreign_ordinary=$(printf '0%.0s' {1..62}; printf '42')
    jq -S -n --arg old "$ANCHOR" '
      [{txid:$old,category:"receive",amount:1000,confirmations:100,abandoned:false}]
    ' >"$root/baseline-wallet-transactions.json"
    claim_row=$(make_claim_wallet_row "$CLAIM1" 0 "$HOTFIX_ZERO_TXID" "$TIP4")
    jq -S -n --slurpfile baseline "$root/baseline-wallet-transactions.json" \
      --arg coinstake "$coinstake" --arg payout "$payout" --arg coin_block "$coin_block" \
      --arg payout_block "$payout_block" --arg foreign "$foreign" --argjson claim "$claim_row" '
       $baseline[0]+[
       {txid:$coinstake,generated:true,category:"generate",abandoned:false,
        blockhash:$coin_block,confirmations:1,amount:1.5},$claim,
       {txid:$payout,qq_synthetic_goldrush_payout:"1",generated:true,category:"generate",
        abandoned:false,blockhash:$payout_block,confirmations:1,amount:1.5,
        vout:0,address:"Qfixture"},
       {txid:$foreign,category:"receive",amount:2,confirmations:0,abandoned:false,
        involvesWatchonly:true}]
    ' >"$root/candidate-final-wallet-transactions.json"
    recovery=$(jq -c --arg foreign "$foreign" \
      --arg ordinary "$foreign_ordinary" --arg zero "$HOTFIX_ZERO_TXID" '
      .component_details[0] as $template |
      ($template.nodes[0] |
        .txid=$foreign | .kind="claim" | .provenance="unknown" |
        .wallet_authored=false | .wallet_from_me=false |
        .authored_metadata_valid=false | .lineage_metadata_present=false |
        .lineage_metadata_valid=false | .lineage_family_fingerprint=$zero |
        .lineage_root_txid=$zero | .lineage_parent_txid=$zero |
        .lineage_ordinal=0) as $foreign_claim |
      ($template.nodes[0] |
        .txid=$ordinary | .kind="ordinary" | .provenance="unknown" |
        .wallet_authored=false | .wallet_from_me=false |
        .authored_metadata_valid=false | .lineage_metadata_present=false |
        .lineage_metadata_valid=false | .lineage_family_fingerprint=$zero |
        .lineage_root_txid=$zero | .lineage_parent_txid=$zero |
        .lineage_ordinal=0) as $foreign_ordinary |
      ($template |
        .anchor.amount=0 | .anchor.scriptPubKey="" | .anchor.txid=$ordinary |
        .anchor_authenticated=false | .anchor_unspent=false |
        .anchor_user_locked=false | .classification="indeterminate" |
        .generation_fingerprint=$foreign | .component_fingerprint=$foreign |
        .claim_txids=[$foreign] | .root_claim_txids=[$foreign] |
        .descendant_claims=0 | .resolution_txids=[] |
        .ordinary_or_mixed_txids=[$ordinary] |
        .nodes=[$foreign_claim,$foreign_ordinary] |
        .all_claims_explicitly_provenanced=false) as $audit |
      .component_details += [$audit] | .unanchored_claim_txids=[$foreign] |
      .raw_claim_objects+=1' "$root/baseline-recovery.json")
    printf '%s\n' "$recovery" >"$root/candidate-final-recovery.json"
    baseline_sha=$(sha_file "$root/baseline-wallet-transactions.json")
    final_sha=$(sha_file "$root/candidate-final-wallet-transactions.json")
    recovery_sha=$(sha_file "$root/candidate-final-recovery.json")
    baseline_recovery_sha=$(sha_file "$root/baseline-recovery.json")
    progress_sha=$(sha_file "$root/phase-b-progress.json")
    jq -S -n --arg baseline "$baseline_sha" --arg final "$final_sha" \
      --arg recovery "$recovery_sha" --arg baseline_recovery "$baseline_recovery_sha" \
      --arg progress "$progress_sha" --arg coinstake "$coinstake" --arg claim "$CLAIM1" \
      --arg payout "$payout" --arg foreign "$foreign" \
      --arg coin_block "$coin_block" --arg payout_block "$payout_block" \
      --arg coinbase "$coinbase" --arg family "$FAMILY" --arg address Qfixture \
      --slurpfile wallet "$root/candidate-final-wallet-transactions.json" \
      --slurpfile inventory "$root/candidate-final-recovery.json" \
      --slurpfile baseline_inventory "$root/baseline-recovery.json" \
      --slurpfile progress_inventory "$root/phase-b-progress.json" '
      def rows($id):[$wallet[0][]|select(.txid==$id)];
      def matches($id):[$inventory[0].component_details[] as $component |
        $component.nodes[]|select(.txid==$id)|{component:$component,node:.}];
      def prior($id):
        def from($source;$sample;$observed;$recovery):
          [$recovery.component_details[] as $component |
           $component.nodes[]|select(.txid==$id)|
           {source:$source,sample:$sample,observed_epoch:$observed,
            active_tip:$recovery.active_tip,wallet_processed_tip:$recovery.wallet_processed_tip,
            component:$component,node:.}];
        (from("baseline";null;null;$baseline_inventory[0]) +
         [$progress_inventory[0].samples[] |
           from("phase_b_progress";.sample;.observed_epoch;.recovery)[]]) |
        sort_by(if .source=="baseline" then 0 else 1 end,
                (.sample//0),.component.component_fingerprint,.node.txid);
      def gettx($id;$amount;$details):
        {txid:$id,hex:"00",decoded:{txid:$id},amount:$amount,
         confirmations:0,details:$details};
      {schema:4,baseline_wallet_transactions_sha256:$baseline,
       final_wallet_transactions_sha256:$final,recovery_inventory_sha256:$recovery,
       baseline_recovery_sha256:$baseline_recovery,phase_b_progress_sha256:$progress,
       recovery_unanchored_claim_txids:$inventory[0].unanchored_claim_txids,
       records:([
        {txid:$payout,class:"authenticated_qq_claim_payout",wallet_rows:rows($payout),
         recovery_matches:matches($claim),prior_recovery_authority:prior($claim),
         blockhash:$payout_block,source_claim_txid:$claim,
         getblock_response:{hash:$payout_block,confirmations:1,height:104,tx:[$coinbase,$claim]},
         getblockhash_response:$payout_block,
         gettransaction_response:{txid:$payout,hex:"00",amount:1.5,confirmations:1,
          blockhash:$payout_block,decoded:{txid:$payout,vout:[{n:0,
           scriptPubKey:{hex:"51",address:$address}}]},details:rows($payout)},
         getshadowtransaction_response:{
          schema:"blackcoin.shadow.transaction.v1",synthetic:true,merkle_included:false,
          synthetic_txid:$payout,mode:"pow",base_anchor:{blockhash:$payout_block,height:104,
           claim_index:1,time:2000000000},confirmations:1,vout:0,scriptPubKey:"51",
          address:$address,status:"spent",lifecycle_category:"spent",
          nominal_amount:1.5,effective_amount:1.5,decayed_amount:0,
          valuation_status:"recorded_at_spend",
          lifecycle:{coinbase_maturity:500,gold_rush_phase_locked:false,
           earliest_spend_height_exact:true,consensus_spendable_next_block:true,
           ordinary_spendable_next_block:true,spendable_next_block:true,
           permanently_locked:false,maturity_height:604,mature:false,
           earliest_spend_height:604,earliest_spend_mtp:null},
          demurrage:{active:false,exempt:true,locked:false,inactive_blocks:0,
           remaining_ppm:1000000,valuation_height:104},
          units:{display:"BLK",atomic_decimals:8,
           amount_encoding:"JSON number in BLK; atomic integer amounts are exact internally"},
          spend:{txid:("f"*64),blockhash:("9"*64),height:105,tx_index:1,input_index:0},
          pow_claim_source:{proof_version:3,origin_bound:true,input_bound:false,
           claim_outpoint:null,vout:0,disposition:"winner",txid:$claim,
           logical_proof_id:("7"*64),canonical_rank:("8"*64),base_fee_known:true,
           base_fee:0,inclusion_height:104,origin_height:104,origin_age:0,
           origin_previous_block_hash:("5"*64)}}},
        {txid:$coinstake,class:"confirmed_coinstake",wallet_rows:rows($coinstake),
         recovery_matches:[],prior_recovery_authority:[],blockhash:$coin_block,source_claim_txid:null,
         getblock_response:{hash:$coin_block,confirmations:1,tx:[$coinbase,$coinstake]},
         getblockhash_response:null,gettransaction_response:{txid:$coinstake,hex:"00",
          decoded:{txid:$coinstake},amount:1.5,confirmations:1,blockhash:$coin_block,
          details:rows($coinstake)},
         getshadowtransaction_response:null},
        {txid:$claim,class:"authenticated_qq_claim",wallet_rows:rows($claim),
         recovery_matches:matches($claim),prior_recovery_authority:prior($claim),
         blockhash:null,source_claim_txid:null,
         getblock_response:null,getblockhash_response:null,
         gettransaction_response:(gettx($claim;-1;rows($claim)) +
           (rows($claim)[0] | with_entries(select(.key|startswith("qq_"))))),
         getshadowtransaction_response:null},
        {txid:$foreign,class:"external_receive",wallet_rows:rows($foreign),
         recovery_matches:matches($foreign),prior_recovery_authority:[],
         blockhash:null,source_claim_txid:null,
         getblock_response:null,getblockhash_response:null,
         gettransaction_response:gettx($foreign;2;rows($foreign)),
         getshadowtransaction_response:null}]|sort_by(.txid)),complete:true}
    ' >"$root/phase-b-wallet-delta-raw.json"
    raw_sha=$(sha_file "$root/phase-b-wallet-delta-raw.json")
    jq -S -n --arg old "$ANCHOR" --arg coinstake "$coinstake" --arg claim "$CLAIM1" \
      --arg payout "$payout" --arg foreign "$foreign" --arg address Qfixture \
      --arg coin_block "$coin_block" --arg payout_block "$payout_block" \
      --arg raw "$raw_sha" '
      {schema:4,baseline_txids:[$old],new_txids:([$payout,$coinstake,$claim,$foreign]|sort),removed_txids:[],
       allowed_classes:["confirmed_coinstake","authenticated_qq_claim",
        "authenticated_qq_claim_payout","external_receive"],classifications:([
         {txid:$payout,class:"authenticated_qq_claim_payout",blockhash:$payout_block,
          source_claim_txid:$claim,payout_address:$address},
         {txid:$coinstake,class:"confirmed_coinstake",blockhash:$coin_block},
         {txid:$claim,class:"authenticated_qq_claim"},
         {txid:$foreign,class:"external_receive",blockhash:null}]|sort_by(.txid)),
       rejected_txids:[],complete:true,
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
    local chain network wallet staking pow recovery observed locked_sync_sha
    local locked_resolution_sha final_recovery_sha final_resolution_sha
    local baseline_resolution_sha baseline_resolution_raw_sha locked_resolution_raw_sha
    local final_resolution_raw_sha final_payout_sha
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
    goldrush_state_json "$TIP4" 104 >"$root/baseline-goldrush-state.json"
    cp "$root/baseline-goldrush-state.json" "$root/candidate-final-goldrush-state.json"
    jq -n '{}' >"$root/candidate-final-mempool-verbose.json"
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
    staking=$(staking_active 104 true)
    printf '%s\n' "$staking" >"$root/candidate-final-staking.json"
    pow=$(mining_json refresh_same_anchor)
    printf '%s\n' "$pow" >"$root/baseline-pow.json"
    pow=$(mining_json refresh_same_anchor true claim_in_flight true)
    printf '%s\n' "$pow" >"$root/candidate-final-pow.json"
    recovery=$(recovery_json "$TIP4" 9)
    printf '%s\n' "$recovery" >"$root/baseline-recovery.json"
    make_phase_b_progress "$root/phase-b-progress.json"
    make_phase_b_wallet_delta "$root"
    recovery=$(<"$root/candidate-final-recovery.json")
    jq -S -n '[
      {key:"q1",address:"Qfixture",tiered:false,stored_in_wallet:true},
      {key:"q2",address:"Qother",tiered:false,stored_in_wallet:true}
    ]' >"$root/baseline-quantum.json"
    cp "$root/baseline-quantum.json" "$root/candidate-final-quantum.json"
    jq -S -n '{schema:1,labels:[]}' >"$root/baseline-quantum-labels.json"
    cp "$root/baseline-quantum-labels.json" "$root/candidate-final-quantum-labels.json"
    jq -n '[""]' >"$root/baseline-loaded-wallets.json"
    cp "$root/baseline-loaded-wallets.json" "$root/candidate-final-loaded-wallets.json"
    jq -S -n '{address:"Qfixture",ismine:true,solvable:true,iswatchonly:false,
      isquantummigration:true,hasquantumkey:true,isquantumcoldstake:false}' \
      >"$root/baseline-payout-address.json"
    jq -S -n --argjson observed "$observed" --arg tip "$TIP4" \
      --arg goldrush "$(sha_file "$root/baseline-goldrush-state.json")" '
      {schema:2,observed_epoch:$observed,stable_tip:$tip,
       goldrush_state_sha256:$goldrush,main_chain_ready:true,p2p_ready:true,
       wallet_normally_unlocked:true,exact_loaded_wallets:[""],staking_active:true,
       payout_address:"Qfixture",payout_owned:true,quantum_key_count:2,
       recovery_database_unambiguous:true,recovery_policy_nonautomatic:true,
       irreversible_marker_allowed:true}
    ' >"$root/baseline-precondition.json"
    jq -S -n --argjson chain "$chain" --argjson recovery "$recovery" \
      --argjson staking "$(staking_locked 104)" \
      --argjson pow "$(mining_json refresh_same_anchor true wallet_locked_or_staking_only true)" '
      {schema:2,synchronized:true,chain:$chain,recovery:$recovery,
       wallet:{walletname:"",private_keys_enabled:true,scanning:false,unlocked_until:0,
        unlocked_staking_only:false},loaded_wallets:[""],staking:$staking,pow:$pow,
       wallet_locked:true,normal_unlock_called:false,pos_intent_retained:true,
       pow_intent_retained:true,locked_pos_zero_work:true,locked_pow_zero_work:true}
    ' >"$root/candidate-chain-wallet-synchronized.json"
    jq -S '[.recovery.component_details[]?.resolution_txids[]?] | unique | sort' \
        "$root/candidate-chain-wallet-synchronized.json" \
        >"$root/candidate-locked-resolution-txids.json"
    jq -S '[.component_details[]?.resolution_txids[]?] | unique | sort' \
        "$root/candidate-final-recovery.json" \
        >"$root/candidate-final-resolution-txids.json"
    jq -S '[.[] | select(has("qq_shadow_pow_cleanup_for") or
      has("qq_shadow_pow_resolution_schema") or
      has("qq_shadow_pow_resolution_anchor_txid") or
      has("qq_shadow_pow_resolution_origin")) | .txid] | unique | sort' \
        "$root/baseline-wallet-transactions.json" \
        >"$root/baseline-wallet-resolution-txids.json"
    jq -S -n '[]' >"$root/baseline-wallet-resolution-raw.json"
    jq -S -n '[]' >"$root/candidate-locked-resolution-raw.json"
    jq -S -n '[]' >"$root/candidate-final-resolution-raw.json"
    jq -S -n '{address:"Qfixture",isvalid:true,ismine:true,solvable:true,
      iswatchonly:false,isquantummigration:true,hasquantumkey:true,
      isquantumcoldstake:false}' \
        >"$root/candidate-final-payout-address.json"
    locked_sync_sha=$(sha_file "$root/candidate-chain-wallet-synchronized.json")
    locked_resolution_sha=$(sha_file "$root/candidate-locked-resolution-txids.json")
    final_recovery_sha=$(sha_file "$root/candidate-final-recovery.json")
    final_resolution_sha=$(sha_file "$root/candidate-final-resolution-txids.json")
    baseline_resolution_sha=$(sha_file "$root/baseline-wallet-resolution-txids.json")
    baseline_resolution_raw_sha=$(sha_file "$root/baseline-wallet-resolution-raw.json")
    locked_resolution_raw_sha=$(sha_file "$root/candidate-locked-resolution-raw.json")
    final_resolution_raw_sha=$(sha_file "$root/candidate-final-resolution-raw.json")
    final_payout_sha=$(sha_file "$root/candidate-final-payout-address.json")
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
      --slurpfile goldrush "$root/candidate-final-goldrush-state.json" \
      --slurpfile mempool "$root/candidate-final-mempool-verbose.json" \
      --arg locked_sync "$locked_sync_sha" --arg locked_resolution "$locked_resolution_sha" \
      --arg baseline_resolution "$baseline_resolution_sha" \
      --arg baseline_resolution_raw "$baseline_resolution_raw_sha" \
      --arg locked_resolution_raw "$locked_resolution_raw_sha" \
      --arg final_recovery "$final_recovery_sha" --arg final_resolution "$final_resolution_sha" \
      --arg final_resolution_raw "$final_resolution_raw_sha" \
      --arg final_goldrush "$(sha_file "$root/candidate-final-goldrush-state.json")" \
      --arg final_payout "$final_payout_sha" \
      --arg quantum_before "$(sha_file "$root/baseline-quantum.json")" \
      --arg quantum_after "$(sha_file "$root/candidate-final-quantum.json")" \
      --arg quantum_labels_before "$(sha_file "$root/baseline-quantum-labels.json")" \
      --arg quantum_labels_after "$(sha_file "$root/candidate-final-quantum-labels.json")" \
      --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg raw "$(sha_file "$root/phase-b-wallet-delta-raw.json")" '
      {schema:2,observed_epoch:$observed,stable_tip:$tip,chain:$chain,chain_after:$chain,
       network:$network,wallet:$wallet,staking:$staking,pow:$pow,recovery:$recovery,
       goldrush_state:$goldrush[0],mempool_verbose:$mempool[0],
       loaded_wallets:[""],pow_mode:"active",chain_before_after_identical:true,
       chain_recovery_pow_tip_bound:true,wallet_unlock_current:true,exact_loaded_wallets:[""],
       automatic_recovery_unauthorized:true,
       baseline_wallet_resolution_txids_sha256:$baseline_resolution,
       baseline_wallet_resolution_raw_sha256:$baseline_resolution_raw,
       candidate_locked_sync_sha256:$locked_sync,
       candidate_locked_resolution_txids_sha256:$locked_resolution,
       candidate_locked_resolution_raw_sha256:$locked_resolution_raw,
       candidate_final_recovery_sha256:$final_recovery,
       candidate_final_goldrush_state_sha256:$final_goldrush,
       candidate_final_payout_address_sha256:$final_payout,
       candidate_configured_payout_transition_valid:true,
       baseline_quantum_sha256:$quantum_before,
       candidate_final_quantum_sha256:$quantum_after,
       baseline_quantum_labels_sha256:$quantum_labels_before,
       candidate_final_quantum_labels_sha256:$quantum_labels_after,
       candidate_quantum_inventory_transition_valid:true,
       candidate_final_resolution_txids_sha256:$final_resolution,
       candidate_final_resolution_raw_sha256:$final_resolution_raw,
       candidate_resolution_membership_baseline_bound:true,
       legacy_baseline_wallet_txids_preserved:true,
       no_new_fee_bearing_recovery_wallet_transaction:true,
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
      --arg locked_sync "$locked_sync_sha" --arg locked_resolution "$locked_resolution_sha" \
      --arg final_recovery "$final_recovery_sha" --arg final_resolution "$final_resolution_sha" \
      --arg tooling_id "$(sha_file "$root/phase-b-tooling-identity.json")" \
      --arg tooling "$(jq -er '.tooling_commit' "$root/phase-b-tooling-identity.json")" \
      --arg package "$package_sha" --arg script "$script_sha" --arg verifier "$verifier_sha" \
      --arg contract "$contract_sha" '
      .marker_sha256=$marker | .invocation_sha256=$invocation |
      .live_dataset_identity_sha256=$datasets | .storage_absence_recheck_sha256=$absence |
      .phase_b_progress_sha256=$progress | .pre_result_manifest_sha256=$pre |
      .final_container_sha256=$container | .final_envelope_sha256=$envelope |
      .wallet_delta_sha256=$delta | .wallet_delta_raw_sha256=$raw |
      .baseline_precondition_sha256=$baseline | .baseline_cutover_stop_sha256=$cutover |
      .candidate_locked_sync_sha256=$locked_sync |
      .candidate_locked_resolution_txids_sha256=$locked_resolution |
      .candidate_final_recovery_sha256=$final_recovery |
      .candidate_final_resolution_txids_sha256=$final_resolution |
      .tooling_commit=$tooling |
      .phase_b_tooling_identity_sha256=$tooling_id | .package_sha256sums_sha256=$package |
      .phase_b_script_sha256=$script | .verifier_sha256=$verifier |
      .typed_contract_sha256=$contract
    ' "$root/RESULT.base.json" >"$root/RESULT.json"
    rm "$root/RESULT.base.json"
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

reseal_phase_b_fixture()
{
    local root="$1" raw_sha locked_sync_sha locked_resolution_sha
    local final_recovery_sha final_resolution_sha baseline_wallet_sha final_wallet_sha
    jq -S '[.component_details[]?.resolution_txids[]?] | unique | sort' \
        "$root/candidate-final-recovery.json" \
        >"$root/candidate-final-resolution-txids.json"
    baseline_wallet_sha=$(sha_file "$root/baseline-wallet-transactions.json")
    final_wallet_sha=$(sha_file "$root/candidate-final-wallet-transactions.json")
    final_recovery_sha=$(sha_file "$root/candidate-final-recovery.json")
    final_resolution_sha=$(sha_file "$root/candidate-final-resolution-txids.json")
    locked_sync_sha=$(sha_file "$root/candidate-chain-wallet-synchronized.json")
    locked_resolution_sha=$(sha_file "$root/candidate-locked-resolution-txids.json")
    jq -S --arg baseline "$baseline_wallet_sha" --arg final "$final_wallet_sha" \
      --arg recovery "$final_recovery_sha" \
      --arg baseline_recovery "$(sha_file "$root/baseline-recovery.json")" \
      --arg progress "$(sha_file "$root/phase-b-progress.json")" '
      .baseline_wallet_transactions_sha256=$baseline |
      .final_wallet_transactions_sha256=$final |
      .recovery_inventory_sha256=$recovery |
      .baseline_recovery_sha256=$baseline_recovery |
      .phase_b_progress_sha256=$progress
    ' "$root/phase-b-wallet-delta-raw.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-wallet-delta-raw.json"
    raw_sha=$(sha_file "$root/phase-b-wallet-delta-raw.json")
    jq -S --arg raw "$raw_sha" '.raw_evidence_sha256=$raw' \
        "$root/phase-b-wallet-delta.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-wallet-delta.json"
    jq -S --arg raw "$raw_sha" --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg locked_sync "$locked_sync_sha" --arg locked_resolution "$locked_resolution_sha" \
      --arg final_recovery "$final_recovery_sha" --arg final_resolution "$final_resolution_sha" \
      --slurpfile recovery "$root/candidate-final-recovery.json" \
      --slurpfile pow "$root/candidate-final-pow.json" '
      .wallet_delta_raw_sha256=$raw | .wallet_delta_sha256=$delta |
      .candidate_locked_sync_sha256=$locked_sync |
      .candidate_locked_resolution_txids_sha256=$locked_resolution |
      .candidate_final_recovery_sha256=$final_recovery |
      .candidate_final_resolution_txids_sha256=$final_resolution |
      .recovery=$recovery[0] | .pow=$pow[0]
    ' "$root/phase-b-final-envelope.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-final-envelope.json"
    seal_manifest "$root" PRE_RESULT_SHA256SUMS SHA256SUMS RESULT.json
    jq -S --arg raw "$raw_sha" --arg delta "$(sha_file "$root/phase-b-wallet-delta.json")" \
      --arg envelope "$(sha_file "$root/phase-b-final-envelope.json")" \
      --arg progress "$(sha_file "$root/phase-b-progress.json")" \
      --arg locked_sync "$locked_sync_sha" --arg locked_resolution "$locked_resolution_sha" \
      --arg final_recovery "$final_recovery_sha" --arg final_resolution "$final_resolution_sha" \
      --arg pre "$(sha_file "$root/PRE_RESULT_SHA256SUMS")" '
      .wallet_delta_raw_sha256=$raw | .wallet_delta_sha256=$delta |
      .final_envelope_sha256=$envelope | .phase_b_progress_sha256=$progress |
      .pre_result_manifest_sha256=$pre |
      .candidate_locked_sync_sha256=$locked_sync |
      .candidate_locked_resolution_txids_sha256=$locked_resolution |
      .candidate_final_recovery_sha256=$final_recovery |
      .candidate_final_resolution_txids_sha256=$final_resolution
    ' "$root/RESULT.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/RESULT.json"
    seal_manifest "$root" SHA256SUMS
    secure_fixture_tree "$root"
}

rebind_phase_b_raw_recovery_matches()
{
    local root="$1"
    jq -S --slurpfile recovery "$root/candidate-final-recovery.json" \
      --slurpfile baseline "$root/baseline-recovery.json" \
      --slurpfile progress "$root/phase-b-progress.json" '
      def matches($id):
        [$recovery[0].component_details[] as $component |
          $component.nodes[] | select(.txid==$id) | {component:$component,node:.}];
      def prior($id):
        def from($source;$sample;$observed;$inventory):
          [$inventory.component_details[] as $component |
           $component.nodes[] | select(.txid==$id) |
           {source:$source,sample:$sample,observed_epoch:$observed,
            active_tip:$inventory.active_tip,
            wallet_processed_tip:$inventory.wallet_processed_tip,
            component:$component,node:.}];
        (from("baseline";null;null;$baseline[0]) +
         [$progress[0].samples[] |
           from("phase_b_progress";.sample;.observed_epoch;.recovery)[]]) |
        sort_by(if .source=="baseline" then 0 else 1 end,
                (.sample//0),.component.component_fingerprint,.node.txid);
      .records |= map(
        if .class=="authenticated_qq_claim" then
          .recovery_matches=matches(.txid) | .prior_recovery_authority=prior(.txid)
        elif .class=="authenticated_qq_claim_payout" then
          .recovery_matches=matches(.source_claim_txid) |
          .prior_recovery_authority=prior(.source_claim_txid)
        else .recovery_matches=matches(.txid) |
          .prior_recovery_authority=prior(.txid) end) |
      .records |= sort_by(.txid) |
      .recovery_unanchored_claim_txids=$recovery[0].unanchored_claim_txids
    ' "$root/phase-b-wallet-delta-raw.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/phase-b-wallet-delta-raw.json"
}

rebind_phase_b_recovery_views()
{
    local root="$1"
    cp "$root/candidate-final-recovery.json" "$root/baseline-recovery.json"
    jq -S --slurpfile recovery "$root/candidate-final-recovery.json" \
        '.recovery=$recovery[0]' \
        "$root/candidate-chain-wallet-synchronized.json" >"$root/mutation.tmp"
    mv "$root/mutation.tmp" "$root/candidate-chain-wallet-synchronized.json"
    rebind_phase_b_raw_recovery_matches "$root"
}

rebuild_phase_b_delta_summary()
{
    local root="$1" raw_sha
    raw_sha=$(sha_file "$root/phase-b-wallet-delta-raw.json") || return 1
    jq -S -n --arg raw "$raw_sha" \
      --slurpfile baseline "$root/baseline-wallet-transactions.json" \
      --slurpfile final "$root/candidate-final-wallet-transactions.json" \
      --slurpfile evidence "$root/phase-b-wallet-delta-raw.json" '
      ($baseline[0]|map(.txid)|unique) as $old |
      ($final[0]|map(.txid)|unique) as $current |
      ($current|map(select(. as $txid|($old|index($txid)|not)))) as $new |
      {schema:4,baseline_txids:$old,new_txids:$new,removed_txids:[],
       allowed_classes:["confirmed_coinstake","authenticated_qq_claim",
         "authenticated_qq_claim_payout","external_receive"],
       classifications:([$evidence[0].records[] |
         if .class=="confirmed_coinstake" then {txid,class,blockhash}
         elif .class=="authenticated_qq_claim" then {txid,class}
         elif .class=="authenticated_qq_claim_payout" then
           {txid,class,blockhash,source_claim_txid,
            payout_address:.getshadowtransaction_response.address}
         elif .class=="external_receive" then {txid,class,blockhash}
         else error("class") end] | sort_by(.txid)),
       rejected_txids:[],complete:true,raw_evidence_sha256:$raw}
    ' >"$root/phase-b-wallet-delta.json"
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
PROGRESS_N3="$TMP/progress-n3.json"
PROGRESS_N6="$TMP/progress-n6.json"
PROGRESS_B_SHORT="$TMP/progress-b-short.json"
PROGRESS_B_N3="$TMP/progress-b-n3.json"
PROGRESS_B_NEXT="$TMP/progress-b-next.json"
PROGRESS_B_RELAY_HIGHEST="$TMP/progress-b-relay-highest.json"
PROGRESS_B_RELAY_LOWER="$TMP/progress-b-relay-lower.json"
PROGRESS_B_NEXT_RELAY_HIGHEST="$TMP/progress-b-next-relay-highest.json"
PROGRESS_B_NEXT_RELAY_LOWER="$TMP/progress-b-next-relay-lower.json"
PROGRESS_B_STALE_LIVE="$TMP/progress-b-stale-live.json"
PROGRESS_B_STALE_RELAY="$TMP/progress-b-stale-relay.json"
PROGRESS_B_STALE_NEXT="$TMP/progress-b-stale-next.json"
PROGRESS_B_ALTERNATING="$TMP/progress-b-alternating.json"
PROGRESS_B_REPLAY="$TMP/progress-b-replay.json"
PROGRESS_B_STALE_REFRESH="$TMP/progress-b-stale-refresh.json"
PROGRESS_B_STALE_CREATE="$TMP/progress-b-stale-create.json"
PROGRESS_B_LIVE_PROGRESS="$TMP/progress-b-live-progress.json"
PROGRESS_B_OLDER_LIVE_PROGRESS="$TMP/progress-b-older-live-progress.json"
PROGRESS_B_LIVE_REPLAY="$TMP/progress-b-live-replay.json"
PROGRESS_B_LIVE_SIBLING_TOGGLE="$TMP/progress-b-live-sibling-toggle.json"
PROGRESS_B_NEW_SIBLING_LIVE="$TMP/progress-b-new-sibling-live.json"
PROGRESS_B_SEEN_DURING_PROGRESS="$TMP/progress-b-seen-during-progress.json"
PROGRESS_B_COUNTER_PROGRESS="$TMP/progress-b-counter-progress.json"
PROGRESS_B_CREATE_SHORT="$TMP/progress-b-create-short.json"
PROGRESS_B_MIDDLE_REPLAY="$TMP/progress-b-middle-replay.json"
PROGRESS_B_GENERATION_CHURN="$TMP/progress-b-generation-churn.json"
PROGRESS_B_INTERLEAVED="$TMP/progress-b-interleaved.json"
PROGRESS_B_INTERLEAVED_STALE="$TMP/progress-b-interleaved-stale.json"
PROGRESS_B_INTERLEAVED_REWRITE="$TMP/progress-b-interleaved-rewrite.json"
PROGRESS_B_MULTI_FAMILY="$TMP/progress-b-multi-family.json"
PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT="$TMP/progress-b-multi-relay-wrong-component.json"
PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT="$TMP/progress-b-multi-next-wrong-component.json"
PROGRESS_B_MULTI_LIVE_SAME_FAMILY="$TMP/progress-b-multi-live-same-family.json"
PROGRESS_B_WAIT_POSITIVE_HASH="$TMP/progress-b-wait-positive-hash.json"
PROGRESS_B_STALE_WAIT_POSITIVE_HASH="$TMP/progress-b-stale-wait-positive-hash.json"
PROGRESS_B_SAME_TIP_EXTENSION="$TMP/progress-b-same-tip-extension.json"
PROGRESS_B_SAME_TIP_OTHER_FAMILY="$TMP/progress-b-same-tip-other-family.json"
PROGRESS_B_SAME_TIP_FIRST_SEEN="$TMP/progress-b-same-tip-first-seen.json"
PROGRESS_B_SAME_TIP_DUPLICATE="$TMP/progress-b-same-tip-duplicate.json"
PROGRESS_B_SAME_TIP_HASH_START="$TMP/progress-b-same-tip-hash-start.json"
PROGRESS_B_SAME_TIP_WAIT="$TMP/progress-b-same-tip-wait.json"
PROGRESS_B_OBSERVATION_WINDOW="$TMP/progress-b-observation-window.json"
PROGRESS_B_OLD_TIP_REPLAY="$TMP/progress-b-old-tip-replay.json"
PROGRESS_B_CONTINUOUS_HASH="$TMP/progress-b-continuous-hash.json"
PROGRESS_B_FAMILYLESS_WAIT="$TMP/progress-b-familyless-wait.json"
PROGRESS_B_FAMILYLESS_STALE="$TMP/progress-b-familyless-stale.json"
PROGRESS_B_TWO_ZERO_REFRESH="$TMP/progress-b-two-zero-refresh.json"
PROGRESS_B_TWO_ZERO_CREATE="$TMP/progress-b-two-zero-create.json"
PROGRESS_B_FROZEN_TIP_WATCHDOG="$TMP/progress-b-frozen-tip-watchdog.json"
CLAIM="$TMP/claim.json"
CLAIM_ZERO="$TMP/claim-zero.json"
CLAIM_PREFIX="$TMP/claim-prefix.json"
CLAIM_MULTI="$TMP/claim-multi.json"
CLAIM_DENSE="$TMP/claim-dense.json"
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
make_progress "$PROGRESS_N3" 3
make_progress "$PROGRESS_N6" 6
make_phase_b_progress "$PROGRESS_B_SHORT"
make_phase_b_progress "$PROGRESS_B_CONTINUOUS_HASH"
make_phase_b_progress "$PROGRESS_B_FAMILYLESS_WAIT"
set_phase_b_sample_action "$PROGRESS_B_FAMILYLESS_WAIT" 1 create_new_anchor "$FINGERPRINT"
mutate "$PROGRESS_B_FAMILYLESS_WAIT" "${PROGRESS_B_FAMILYLESS_WAIT}.wait" '
  .samples[1].pow |= (.mining_gate_action="wait_for_next_tip" |
    .mining_gate_can_submit=true | .state="claim_in_flight")'
mv -f -- "${PROGRESS_B_FAMILYLESS_WAIT}.wait" "$PROGRESS_B_FAMILYLESS_WAIT"
make_phase_b_progress "$PROGRESS_B_FAMILYLESS_STALE"
for index in 0 1 2 3; do
    set_phase_b_sample_action "$PROGRESS_B_FAMILYLESS_STALE" "$index" \
        create_new_anchor "$FINGERPRINT"
done
mutate "$PROGRESS_B_FAMILYLESS_STALE" "${PROGRESS_B_FAMILYLESS_STALE}.wait" '
  .samples[].pow |= (.mining_gate_action="wait_for_next_tip" |
    .mining_gate_can_submit=true | .state="claim_in_flight")'
mv -f -- "${PROGRESS_B_FAMILYLESS_STALE}.wait" "$PROGRESS_B_FAMILYLESS_STALE"
set_phase_b_sample_action "$PROGRESS_B_SHORT" 0 refresh_same_anchor "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_SHORT" 1 wait_for_live "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_SHORT" 2 refresh_same_anchor "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_SHORT" 3 relay_existing "$FINGERPRINT"
mutate "$PROGRESS_B_SHORT" "$PROGRESS_B_N3" '
  .observation_sample_count=3 | .samples=.samples[0:3] | .tip_changes=2'
cp "$PROGRESS_B_N3" "$PROGRESS_B_TWO_ZERO_REFRESH"
set_phase_b_sample_action "$PROGRESS_B_TWO_ZERO_REFRESH" 0 \
    refresh_same_anchor "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_TWO_ZERO_REFRESH" 1 \
    refresh_same_anchor "$FINGERPRINT"
mutate "$PROGRESS_B_TWO_ZERO_REFRESH" "${PROGRESS_B_TWO_ZERO_REFRESH}.two" '
  .observation_sample_count=2 | .samples=.samples[0:2] | .tip_changes=1'
mv -f -- "${PROGRESS_B_TWO_ZERO_REFRESH}.two" "$PROGRESS_B_TWO_ZERO_REFRESH"
cp "$PROGRESS_B_N3" "$PROGRESS_B_TWO_ZERO_CREATE"
set_phase_b_sample_action "$PROGRESS_B_TWO_ZERO_CREATE" 0 \
    create_new_anchor "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_TWO_ZERO_CREATE" 1 \
    create_new_anchor "$FINGERPRINT"
mutate "$PROGRESS_B_TWO_ZERO_CREATE" "${PROGRESS_B_TWO_ZERO_CREATE}.two" '
  .observation_sample_count=2 | .samples=.samples[0:2] | .tip_changes=1'
mv -f -- "${PROGRESS_B_TWO_ZERO_CREATE}.two" "$PROGRESS_B_TWO_ZERO_CREATE"
cp "$PROGRESS_B_N3" "$PROGRESS_B_FROZEN_TIP_WATCHDOG"
# Keep a real advancing tip and positive submit-capable hashing, but delay its
# observation beyond the independent ten-minute active-tip watchdog.
mutate "$PROGRESS_B_FROZEN_TIP_WATCHDOG" \
    "${PROGRESS_B_FROZEN_TIP_WATCHDOG}.watchdog" '
  .observation_sample_count=2 | .samples=.samples[0:2] | .tip_changes=1 |
  .samples[1].observed_epoch=(.samples[0].observed_epoch+601)'
mv -f -- "${PROGRESS_B_FROZEN_TIP_WATCHDOG}.watchdog" \
    "$PROGRESS_B_FROZEN_TIP_WATCHDOG"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_WAIT_POSITIVE_HASH"
set_phase_b_sample_action "$PROGRESS_B_WAIT_POSITIVE_HASH" 1 wait_for_live \
    "$FINGERPRINT" 3
make_phase_b_progress "$PROGRESS_B_NEXT"
set_phase_b_sample_action "$PROGRESS_B_NEXT" 0 refresh_same_anchor "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_NEXT" 1 wait_for_next_tip "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_NEXT" 2 refresh_same_anchor "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_NEXT" 3 wait_for_next_tip "$FINGERPRINT"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_RELAY_HIGHEST"
# shellcheck disable=SC2016 # $observed is a jq variable; claim ids are intentionally spliced.
mutate "$PROGRESS_B_RELAY_HIGHEST" "${PROGRESS_B_RELAY_HIGHEST}.candidates" '
  .samples[3] |= (
    .observed_epoch as $observed |
    .pow.mining_gate_eligible_claims=2 |
    .recovery.component_details[0].nodes |= map(
      if (.txid == "'"$CLAIM3"'" or .txid == "'"$CLAIM4"'") then
        .disposition="eligible" | .in_mempool=false |
        .relay_ttl_expired=false | .relay_expiry_time=($observed + 600)
      else . end))'
mv -f -- "${PROGRESS_B_RELAY_HIGHEST}.candidates" \
    "$PROGRESS_B_RELAY_HIGHEST"
cp "$PROGRESS_B_RELAY_HIGHEST" "$PROGRESS_B_RELAY_LOWER"
mutate "$PROGRESS_B_RELAY_LOWER" "${PROGRESS_B_RELAY_LOWER}.lower" \
    '.samples[3].pow.mining_gate_relay_txid="'"$CLAIM3"'"'
mv -f -- "${PROGRESS_B_RELAY_LOWER}.lower" "$PROGRESS_B_RELAY_LOWER"
cp "$PROGRESS_B_NEXT" "$PROGRESS_B_NEXT_RELAY_HIGHEST"
# shellcheck disable=SC2016 # $observed is a jq variable; claim ids are intentionally spliced.
mutate "$PROGRESS_B_NEXT_RELAY_HIGHEST" \
    "${PROGRESS_B_NEXT_RELAY_HIGHEST}.candidates" '
  .samples[1] |= (
    .observed_epoch as $observed |
    .pow.mining_gate_can_submit=false |
    .pow.mining_gate_relay_txid="'"$CLAIM4"'" |
    .pow.mining_gate_eligible_claims=2 |
    .recovery.component_details[0].nodes |= map(
      if (.txid == "'"$CLAIM3"'" or .txid == "'"$CLAIM4"'") then
        .disposition="eligible" | .in_mempool=false |
        .relay_ttl_expired=false | .relay_expiry_time=($observed + 600)
      else . end))'
mv -f -- "${PROGRESS_B_NEXT_RELAY_HIGHEST}.candidates" \
    "$PROGRESS_B_NEXT_RELAY_HIGHEST"
cp "$PROGRESS_B_NEXT_RELAY_HIGHEST" "$PROGRESS_B_NEXT_RELAY_LOWER"
mutate "$PROGRESS_B_NEXT_RELAY_LOWER" \
    "${PROGRESS_B_NEXT_RELAY_LOWER}.lower" \
    '.samples[1].pow.mining_gate_relay_txid="'"$CLAIM3"'"'
mv -f -- "${PROGRESS_B_NEXT_RELAY_LOWER}.lower" \
    "$PROGRESS_B_NEXT_RELAY_LOWER"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_MULTI_FAMILY"
for index in 0 1 2 3; do
    add_phase_b_sample_family_b_live "$PROGRESS_B_MULTI_FAMILY" "$index"
done
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_SAME_TIP_EXTENSION"
jq -S --arg claim "$CLAIM5" --arg zero "$HOTFIX_ZERO_TXID" '
  .samples[-1] as $previous |
  ($previous |
    .sample=5 | .observed_epoch+=1 |
    .pow.mining_gate_action="refresh_same_anchor" |
    .pow.mining_gate_can_submit=true | .pow.mining_gate_relay_txid=$zero |
    .pow.mining_gate_lineage_head_txid=$claim |
    .pow.mining_gate_eligible_claims=0 | .pow.hashrate=0 | .pow.state="ready" |
    .pow.claims_submitted+=1 | .pow.mining_gate_family_claims+=1 |
    .recovery.component_details[0].nodes[-1] as $template |
    .recovery.component_details[0].claim_txids += [$claim] |
    .recovery.component_details[0].root_claim_txids += [$claim] |
    .recovery.component_details[0].nodes += [($template |
      .txid=$claim | .lineage_ordinal=4 | .lineage_parent_txid="'"$CLAIM4"'" |
      .in_mempool=false | .disposition="origin_expired" |
      .relay_ttl_expired=false | .relay_expiry_time=0)] |
    .recovery.raw_claim_objects+=1 |
    .recovery.quarantined_claim_objects+=1 |
    .recovery.raw_quarantined_claims+=1) as $same_tip |
  .samples += [$same_tip] | .observation_sample_count=5 | .tip_changes=3
' "$PROGRESS_B_SAME_TIP_EXTENSION" >"${PROGRESS_B_SAME_TIP_EXTENSION}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_EXTENSION}.new" "$PROGRESS_B_SAME_TIP_EXTENSION"
cp "$PROGRESS_B_MULTI_FAMILY" "$PROGRESS_B_SAME_TIP_OTHER_FAMILY"
jq -S --arg head "$CLAIM_B4" --arg zero "$HOTFIX_ZERO_TXID" '
  .samples[0] as $first |
  ($first | .sample=2 | .observed_epoch+=1 |
    .pow.mining_gate_action="refresh_same_anchor" |
    .pow.mining_gate_can_submit=true | .pow.mining_gate_relay_txid=$zero |
    .pow.mining_gate_lineage_head_txid=$head |
    .pow.mining_gate_live_claims=0 | .pow.live_claims=0 |
    .pow.hashrate=5 | .pow.state="hashing" |
    .recovery.component_details[1] |= (
      .classification="current_branch_ineligible" |
      .nodes |= map(.in_mempool=false)) |
    .recovery.live_claim_objects=0 | .mempool_verbose={}) as $same_tip |
  .samples = [(.samples[0] | .sample=1),$same_tip] +
    [.samples[1:][] | .sample+=1 | .observed_epoch+=1] |
  .observation_sample_count=(.samples|length) | .tip_changes=3
' "$PROGRESS_B_SAME_TIP_OTHER_FAMILY" >"${PROGRESS_B_SAME_TIP_OTHER_FAMILY}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_OTHER_FAMILY}.new" "$PROGRESS_B_SAME_TIP_OTHER_FAMILY"
cp "$PROGRESS_B_SAME_TIP_OTHER_FAMILY" "$PROGRESS_B_SAME_TIP_FIRST_SEEN"
jq -S '.samples[1:] |= map(.pow.claims_submitted=0)' \
  "$PROGRESS_B_SAME_TIP_FIRST_SEEN" >"${PROGRESS_B_SAME_TIP_FIRST_SEEN}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_FIRST_SEEN}.new" "$PROGRESS_B_SAME_TIP_FIRST_SEEN"
mutate "$PROGRESS_B_SAME_TIP_FIRST_SEEN" \
    "${PROGRESS_B_SAME_TIP_FIRST_SEEN}.no-hash" \
    '.samples[1].pow.hashrate=0 | .samples[1].pow.state="ready"'
mv -f -- "${PROGRESS_B_SAME_TIP_FIRST_SEEN}.no-hash" \
    "$PROGRESS_B_SAME_TIP_FIRST_SEEN"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_SAME_TIP_DUPLICATE"
jq -S '.samples[0] as $first |
  .samples = [$first,($first | .sample=2 | .observed_epoch+=1)] +
    [.samples[1:][] | .sample+=1 | .observed_epoch+=1] |
  .observation_sample_count=(.samples|length) | .tip_changes=3
' "$PROGRESS_B_SAME_TIP_DUPLICATE" >"${PROGRESS_B_SAME_TIP_DUPLICATE}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_DUPLICATE}.new" "$PROGRESS_B_SAME_TIP_DUPLICATE"
cp "$PROGRESS_B_SAME_TIP_DUPLICATE" "$PROGRESS_B_SAME_TIP_HASH_START"
jq -S '.samples[0].pow.hashrate=0 | .samples[0].pow.state="ready"' \
  "$PROGRESS_B_SAME_TIP_HASH_START" >"${PROGRESS_B_SAME_TIP_HASH_START}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_HASH_START}.new" "$PROGRESS_B_SAME_TIP_HASH_START"
cp "$PROGRESS_B_SAME_TIP_DUPLICATE" "$PROGRESS_B_SAME_TIP_WAIT"
jq -S --arg zero "$HOTFIX_ZERO_TXID" '.samples[1] |= (
  .pow.mining_gate_action="wait_for_next_tip" |
  .pow.mining_gate_can_submit=false | .pow.mining_gate_relay_txid=$zero |
  .pow.hashrate=0 | .pow.state="claim_in_flight")' \
  "$PROGRESS_B_SAME_TIP_WAIT" >"${PROGRESS_B_SAME_TIP_WAIT}.new"
mv -f -- "${PROGRESS_B_SAME_TIP_WAIT}.new" "$PROGRESS_B_SAME_TIP_WAIT"
set_phase_b_sample_action "$PROGRESS_B_SAME_TIP_FIRST_SEEN" 2 \
    wait_for_next_tip "$FINGERPRINT"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_OBSERVATION_WINDOW"
jq -S '.samples[-1].observed_epoch=(.samples[0].observed_epoch+2701)' \
  "$PROGRESS_B_OBSERVATION_WINDOW" >"${PROGRESS_B_OBSERVATION_WINDOW}.new"
mv -f -- "${PROGRESS_B_OBSERVATION_WINDOW}.new" "$PROGRESS_B_OBSERVATION_WINDOW"
cp "$PROGRESS_B_SHORT" "$PROGRESS_B_OLD_TIP_REPLAY"
jq -S --arg old "$TIP1" --arg work "$(printf 'f%.0s' {1..64})" '
  .samples[-1] |= (
    .chain.bestblockhash=$old | .chain.chainwork=$work |
    .pow.claim_inventory_tip=$old |
    .recovery.active_tip=$old | .recovery.wallet_processed_tip=$old)
' "$PROGRESS_B_OLD_TIP_REPLAY" >"${PROGRESS_B_OLD_TIP_REPLAY}.new"
mv -f -- "${PROGRESS_B_OLD_TIP_REPLAY}.new" "$PROGRESS_B_OLD_TIP_REPLAY"
cp "$PROGRESS_B_MULTI_FAMILY" "$PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT"
# shellcheck disable=SC2016 # $observed is a jq variable; claim ids are intentionally spliced.
mutate "$PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT" \
    "${PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT}.wrong" '
  .samples[3] |= (
    .observed_epoch as $observed |
    .pow.mining_gate_relay_txid="'"$CLAIM_B3"'" |
    .pow.mining_gate_eligible_claims=2 |
    .recovery.component_details[1].nodes |= map(
      if .txid == "'"$CLAIM_B3"'" then
        .disposition="eligible" | .in_mempool=false |
        .relay_ttl_expired=false | .relay_expiry_time=($observed + 600)
      else . end))'
mv -f -- "${PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT}.wrong" \
    "$PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT"
cp "$PROGRESS_B_NEXT_RELAY_HIGHEST" "$PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT"
for index in 0 1 2 3; do
    add_phase_b_sample_family_b_live "$PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT" "$index"
done
# shellcheck disable=SC2016 # $observed is a jq variable; claim ids are intentionally spliced.
mutate "$PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT" \
    "${PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT}.wrong" '
  .samples[1] |= (
    .observed_epoch as $observed |
    .pow.mining_gate_relay_txid="'"$CLAIM_B3"'" |
    .pow.mining_gate_eligible_claims=3 |
    .recovery.component_details[1].nodes |= map(
      if .txid == "'"$CLAIM_B3"'" then
        .disposition="eligible" | .in_mempool=false |
        .relay_ttl_expired=false | .relay_expiry_time=($observed + 600)
      else . end))'
mv -f -- "${PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT}.wrong" \
    "$PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT"
make_phase_b_progress "$PROGRESS_B_STALE_LIVE"
make_phase_b_progress "$PROGRESS_B_STALE_RELAY"
make_phase_b_progress "$PROGRESS_B_STALE_NEXT"
make_phase_b_progress "$PROGRESS_B_ALTERNATING"
make_phase_b_progress "$PROGRESS_B_STALE_REFRESH"
make_phase_b_progress "$PROGRESS_B_STALE_CREATE"
make_phase_b_progress "$PROGRESS_B_LIVE_PROGRESS"
make_phase_b_progress "$PROGRESS_B_OLDER_LIVE_PROGRESS"
make_phase_b_progress "$PROGRESS_B_LIVE_REPLAY"
make_phase_b_progress "$PROGRESS_B_LIVE_SIBLING_TOGGLE"
make_phase_b_progress "$PROGRESS_B_NEW_SIBLING_LIVE"
make_phase_b_progress "$PROGRESS_B_SEEN_DURING_PROGRESS"
make_phase_b_progress "$PROGRESS_B_COUNTER_PROGRESS"
make_phase_b_progress "$PROGRESS_B_CREATE_SHORT"
make_phase_b_progress "$PROGRESS_B_MIDDLE_REPLAY"
make_phase_b_progress "$PROGRESS_B_GENERATION_CHURN"
make_phase_b_progress "$PROGRESS_B_INTERLEAVED"
for index in 0 1 2 3; do
    set_phase_b_sample_action "$PROGRESS_B_STALE_LIVE" "$index" wait_for_live \
        "$FINGERPRINT"
    set_phase_b_sample_action "$PROGRESS_B_STALE_RELAY" "$index" relay_existing \
        "$FINGERPRINT"
    set_phase_b_sample_action "$PROGRESS_B_STALE_NEXT" "$index" wait_for_next_tip \
        "$FINGERPRINT"
    set_phase_b_sample_action "$PROGRESS_B_STALE_REFRESH" "$index" \
        refresh_same_anchor "$(hex64 $((20 + index)))"
    set_phase_b_sample_action "$PROGRESS_B_STALE_CREATE" "$index" \
        create_new_anchor "$(hex64 $((30 + index)))"
    set_phase_b_sample_action "$PROGRESS_B_COUNTER_PROGRESS" "$index" \
        refresh_same_anchor "$FINGERPRINT"
    set_phase_b_sample_action "$PROGRESS_B_CREATE_SHORT" "$index" \
        create_new_anchor "$FINGERPRINT"
    set_phase_b_sample_action "$PROGRESS_B_MIDDLE_REPLAY" "$index" \
        refresh_same_anchor "$FINGERPRINT" 5
    set_phase_b_sample_action "$PROGRESS_B_GENERATION_CHURN" "$index" \
        refresh_same_anchor "$(hex64 $((70 + index)))"
done
cp "$PROGRESS_B_STALE_LIVE" "$PROGRESS_B_STALE_WAIT_POSITIVE_HASH"
mutate "$PROGRESS_B_STALE_WAIT_POSITIVE_HASH" \
    "${PROGRESS_B_STALE_WAIT_POSITIVE_HASH}.hash" \
    '.samples[].pow |= (.hashrate=3 | .state="hashing")'
mv -f -- "${PROGRESS_B_STALE_WAIT_POSITIVE_HASH}.hash" \
    "$PROGRESS_B_STALE_WAIT_POSITIVE_HASH"
set_phase_b_sample_action "$PROGRESS_B_INTERLEAVED" 0 refresh_same_anchor \
    "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_INTERLEAVED" 1 refresh_same_anchor \
    "$FAMILY_B"
set_phase_b_sample_family_b "$PROGRESS_B_INTERLEAVED" 1
set_phase_b_sample_action "$PROGRESS_B_INTERLEAVED" 2 refresh_same_anchor \
    "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_INTERLEAVED" 3 refresh_same_anchor \
    "$FAMILY_B" 5
set_phase_b_sample_family_b "$PROGRESS_B_INTERLEAVED" 3
cp "$PROGRESS_B_INTERLEAVED" "$PROGRESS_B_INTERLEAVED_STALE"
mutate "$PROGRESS_B_INTERLEAVED_STALE" \
    "${PROGRESS_B_INTERLEAVED_STALE}.zero" \
    '.samples[2].pow.hashrate=0 | .samples[2].pow.state="ready"'
mv -f -- "${PROGRESS_B_INTERLEAVED_STALE}.zero" \
    "$PROGRESS_B_INTERLEAVED_STALE"
cp "$PROGRESS_B_INTERLEAVED" "$PROGRESS_B_INTERLEAVED_REWRITE"
mutate "$PROGRESS_B_INTERLEAVED_REWRITE" \
    "${PROGRESS_B_INTERLEAVED_REWRITE}.rewrite" '
  .samples[2].recovery.component_details[0] |= (
    .claim_txids |= map(if . == "'"$CLAIM3"'" then "'"$(hex64 61)"'" else . end) |
    .nodes |= map(
      if .txid == "'"$CLAIM3"'" then .txid="'"$(hex64 61)"'"
      elif .txid == "'"$CLAIM4"'" then
        .lineage_parent_txid="'"$(hex64 61)"'"
      else . end))'
mv -f -- "${PROGRESS_B_INTERLEAVED_REWRITE}.rewrite" \
    "$PROGRESS_B_INTERLEAVED_REWRITE"
set_phase_b_sample_action "$PROGRESS_B_ALTERNATING" 0 wait_for_live "$(hex64 5)"
set_phase_b_sample_action "$PROGRESS_B_ALTERNATING" 1 relay_existing "$(hex64 6)"
set_phase_b_sample_action "$PROGRESS_B_ALTERNATING" 2 wait_for_live "$(hex64 7)"
set_phase_b_sample_action "$PROGRESS_B_ALTERNATING" 3 relay_existing "$(hex64 8)"
set_phase_b_sample_action "$PROGRESS_B_LIVE_PROGRESS" 0 relay_existing "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_LIVE_PROGRESS" 1 wait_for_live "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_LIVE_PROGRESS" 2 wait_for_next_tip "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_LIVE_PROGRESS" 3 refresh_same_anchor \
    "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_OLDER_LIVE_PROGRESS" 0 relay_existing \
    "$FINGERPRINT"
set_phase_b_sample_relay_member "$PROGRESS_B_OLDER_LIVE_PROGRESS" 0 "$CLAIM3"
set_phase_b_sample_action "$PROGRESS_B_OLDER_LIVE_PROGRESS" 1 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_live_member "$PROGRESS_B_OLDER_LIVE_PROGRESS" 1 "$CLAIM3"
set_phase_b_sample_action "$PROGRESS_B_OLDER_LIVE_PROGRESS" 2 wait_for_next_tip \
    "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_OLDER_LIVE_PROGRESS" 3 refresh_same_anchor \
    "$FINGERPRINT" 5
set_phase_b_sample_action "$PROGRESS_B_LIVE_REPLAY" 0 relay_existing "$(hex64 40)"
set_phase_b_sample_action "$PROGRESS_B_LIVE_REPLAY" 1 wait_for_live "$(hex64 41)"
set_phase_b_sample_action "$PROGRESS_B_LIVE_REPLAY" 2 relay_existing "$(hex64 42)"
set_phase_b_sample_action "$PROGRESS_B_LIVE_REPLAY" 3 wait_for_live "$(hex64 43)"
for index in 0 1 2 3; do
    set_phase_b_sample_action "$PROGRESS_B_LIVE_SIBLING_TOGGLE" "$index" \
        wait_for_live "$(hex64 $((50 + index)))"
done
set_phase_b_sample_live_member "$PROGRESS_B_LIVE_SIBLING_TOGGLE" 0 "$CLAIM3"
set_phase_b_sample_live_member "$PROGRESS_B_LIVE_SIBLING_TOGGLE" 1 "$CLAIM4"
set_phase_b_sample_live_member "$PROGRESS_B_LIVE_SIBLING_TOGGLE" 2 "$CLAIM3"
set_phase_b_sample_live_member "$PROGRESS_B_LIVE_SIBLING_TOGGLE" 3 "$CLAIM4"
set_phase_b_sample_action "$PROGRESS_B_NEW_SIBLING_LIVE" 0 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_live_member "$PROGRESS_B_NEW_SIBLING_LIVE" 0 "$CLAIM3"
set_phase_b_sample_action "$PROGRESS_B_NEW_SIBLING_LIVE" 1 wait_for_live \
    "$FINGERPRINT"
mutate "$PROGRESS_B_NEW_SIBLING_LIVE" "${PROGRESS_B_NEW_SIBLING_LIVE}.growth" '
  .samples[1] |= (
    .pow.mining_gate_live_claims=1 | .pow.live_claims=1 |
    .recovery.live_claim_objects=1 |
    .recovery.component_details[0].nodes |= map(
      .in_mempool=(.txid == "'"$CLAIM4"'") |
      .relay_ttl_expired=false | .relay_expiry_time=0 |
      .disposition="origin_expired") |
    .mempool_verbose={
      ("'"$CLAIM4"'"):{time:(.observed_epoch - 10),height:.chain.blocks}})'
mv -f -- "${PROGRESS_B_NEW_SIBLING_LIVE}.growth" \
    "$PROGRESS_B_NEW_SIBLING_LIVE"
set_phase_b_sample_action "$PROGRESS_B_NEW_SIBLING_LIVE" 2 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_live_member "$PROGRESS_B_NEW_SIBLING_LIVE" 2 "$CLAIM3"
set_phase_b_sample_action "$PROGRESS_B_NEW_SIBLING_LIVE" 3 refresh_same_anchor \
    "$FINGERPRINT" 5
cp "$PROGRESS_B_NEW_SIBLING_LIVE" "$PROGRESS_B_MULTI_LIVE_SAME_FAMILY"
mutate "$PROGRESS_B_MULTI_LIVE_SAME_FAMILY" \
    "${PROGRESS_B_MULTI_LIVE_SAME_FAMILY}.two-live" '
  .samples[1] |= (
    .pow.mining_gate_live_claims=2 | .pow.live_claims=2 |
    .recovery.live_claim_objects=2 |
    .recovery.component_details[0].nodes |= map(
      .in_mempool=(.txid == "'"$CLAIM3"'" or .txid == "'"$CLAIM4"'") |
      .relay_ttl_expired=false | .relay_expiry_time=0 |
      .disposition="origin_expired") |
    .mempool_verbose={
      ("'"$CLAIM3"'"):{time:(.observed_epoch - 10),height:.chain.blocks},
      ("'"$CLAIM4"'"):{time:(.observed_epoch - 10),height:.chain.blocks}})'
mv -f -- "${PROGRESS_B_MULTI_LIVE_SAME_FAMILY}.two-live" \
    "$PROGRESS_B_MULTI_LIVE_SAME_FAMILY"
set_phase_b_sample_action "$PROGRESS_B_SEEN_DURING_PROGRESS" 0 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_live_member "$PROGRESS_B_SEEN_DURING_PROGRESS" 0 "$CLAIM3"
set_phase_b_sample_action "$PROGRESS_B_SEEN_DURING_PROGRESS" 1 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_SEEN_DURING_PROGRESS" 2 relay_existing \
    "$FINGERPRINT"
set_phase_b_sample_action "$PROGRESS_B_SEEN_DURING_PROGRESS" 3 wait_for_live \
    "$FINGERPRINT"
set_phase_b_sample_live_member "$PROGRESS_B_SEEN_DURING_PROGRESS" 3 "$CLAIM4"
mutate "$PROGRESS_B_SEEN_DURING_PROGRESS" \
    "${PROGRESS_B_SEEN_DURING_PROGRESS}.seen" '
  .samples[1] |= (
    .pow.claims_submitted=1 | .pow.mining_gate_live_claims=1 | .pow.live_claims=1 |
    .recovery.live_claim_objects=1 |
    .recovery.component_details[0].nodes |= map(
      .in_mempool=(.txid == "'"$CLAIM4"'") |
      .relay_ttl_expired=false | .relay_expiry_time=0 |
      .disposition="origin_expired") |
    .mempool_verbose={
      ("'"$CLAIM4"'"):{time:(.observed_epoch - 10),height:.chain.blocks}}) |
  .samples[2].pow.claims_submitted=1 |
  .samples[3].pow.claims_submitted=1'
mv -f -- "${PROGRESS_B_SEEN_DURING_PROGRESS}.seen" \
    "$PROGRESS_B_SEEN_DURING_PROGRESS"
mutate "$PROGRESS_B_CREATE_SHORT" "${PROGRESS_B_CREATE_SHORT}.hash" \
    '.samples[2].pow.hashrate=5 | .samples[2].pow.state="hashing" |
     .samples[3].pow.hashrate=5 | .samples[3].pow.state="hashing"'
mv -f -- "${PROGRESS_B_CREATE_SHORT}.hash" "$PROGRESS_B_CREATE_SHORT"
mutate "$PROGRESS_B_COUNTER_PROGRESS" "${PROGRESS_B_COUNTER_PROGRESS}.counts" '
  .samples[1].pow.claims_submitted=1 |
  .samples[2].pow.claims_submitted=1 |
  .samples[3].pow.claims_submitted=2'
mv -f -- "${PROGRESS_B_COUNTER_PROGRESS}.counts" "$PROGRESS_B_COUNTER_PROGRESS"
mutate "$PROGRESS_B_MIDDLE_REPLAY" "${PROGRESS_B_MIDDLE_REPLAY}.middle" '
  .samples[2].recovery.component_details[0] |= (
    .claim_txids |= map(if . == "'"$CLAIM3"'" then "'"$(hex64 60)"'" else . end) |
    .nodes |= map(
      if .txid == "'"$CLAIM3"'" then .txid="'"$(hex64 60)"'"
      elif .txid == "'"$CLAIM4"'" then
        .lineage_parent_txid="'"$(hex64 60)"'"
      else . end))'
mv -f -- "${PROGRESS_B_MIDDLE_REPLAY}.middle" "$PROGRESS_B_MIDDLE_REPLAY"
for index in 0 1 2 3; do
    mutate "$PROGRESS_B_GENERATION_CHURN" \
        "${PROGRESS_B_GENERATION_CHURN}.generation" \
        '.samples['"$index"'].recovery.component_details[0] |= (
          .generation_fingerprint="'"$(hex64 $((80 + index)))"'" |
          .nodes |= map(.lineage_family_fingerprint=
            "'"$(hex64 $((80 + index)))"'"))'
    mv -f -- "${PROGRESS_B_GENERATION_CHURN}.generation" \
        "$PROGRESS_B_GENERATION_CHURN"
done
make_phase_b_progress "$PROGRESS_B_REPLAY"
for index in 0 1 2 3; do
    set_phase_b_sample_action "$PROGRESS_B_REPLAY" "$index" refresh_same_anchor \
        "$FINGERPRINT" 5
done
truncate_phase_b_sample_family "$PROGRESS_B_REPLAY" 0 3
truncate_phase_b_sample_family "$PROGRESS_B_REPLAY" 1 4
truncate_phase_b_sample_family "$PROGRESS_B_REPLAY" 2 3
truncate_phase_b_sample_family "$PROGRESS_B_REPLAY" 3 4
make_claim "$CLAIM"
make_claim "$CLAIM_ZERO" zero
make_claim "$CLAIM_PREFIX" prefix
make_claim "$CLAIM_MULTI" multi
make_claim "$CLAIM_DENSE" dense
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

ok 'deterministic test adapter source/release identity is exact' hotfix_candidate_identity_is_resolved
ok 'test adapter prefix is exactly derived' test "$HOTFIX_CANDIDATE_PREFIX" = \
    "Blackcoin-30.1.5-candidate-${TEST_CANDIDATE_SOURCE_SHA:0:12}"
ok 'test adapter archive name is exactly derived' test "$HOTFIX_CANDIDATE_OCI_ARCHIVE_NAME" = \
    "blackcoin-v4-gui-30.1.5-candidate-${TEST_CANDIDATE_SOURCE_SHA:0:12}.oci.tar"
ok 'test adapter image tag is exactly derived' test "$HOTFIX_CANDIDATE_IMAGE_TAG" = \
    "30.1.5-candidate-${TEST_CANDIDATE_SOURCE_SHA:0:12}-ci1"
ok 'candidate artifact name is exact and workflow-attempt-bound' test \
    "$(hotfix_candidate_artifact_name 7)" = \
    "v${HOTFIX_CANDIDATE_RELEASE_VERSION}-candidate-linux-x86_64-${HOTFIX_CANDIDATE_SOURCE_SHA}-attempt-7"
reject 'zero workflow attempt cannot derive a candidate artifact' hotfix_candidate_artifact_name 0
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'unrepinned production identity defaults fail closed' \
    /usr/bin/env -u HOTFIX_CANDIDATE_SOURCE_SHA -u HOTFIX_CANDIDATE_RELEASE_VERSION \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$ROOT/lib/typed_contract.sh"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
ok 'synthetic test adapter resolves only its exact H and release' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA="$TEST_CANDIDATE_SOURCE_SHA" \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.5 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$TEST_TYPED_CONTRACT"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'alternate valid candidate source override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.5 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$TEST_TYPED_CONTRACT"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'immutable v30.1.4 source override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA="$IMMUTABLE_V3014_SOURCE_SHA" \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.5 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$TEST_TYPED_CONTRACT"
# shellcheck disable=SC2016 # The contract path is passed to isolated child shells.
reject 'nonexact release override is rejected' \
    /usr/bin/env HOTFIX_CANDIDATE_SOURCE_SHA="$HOTFIX_EXPECTED_CANDIDATE_SOURCE_SHA" \
        HOTFIX_CANDIDATE_RELEASE_VERSION=30.1.4 \
        /bin/bash -c 'source "$1"; hotfix_candidate_identity_is_resolved' \
        _ "$TEST_TYPED_CONTRACT"
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
for action in wait_for_live wait_for_next_tip relay_existing refresh_same_anchor; do
    ok "retained ${action} accepts an empty configured-future payout" \
        hotfix_candidate_pow_json_is_valid \
            "$(mining_json "$action" | jq -c '.payout_address=""')" active
done
reject 'create_new_anchor requires a configured-future payout' \
    hotfix_candidate_pow_json_is_valid \
        "$(mining_json create_new_anchor | jq -c '.payout_address=""')" active
ok 'zero-relay wait_for_next_tip accepts a non-submit fresh deferral' \
    hotfix_candidate_pow_json_is_valid \
        "$(mining_json wait_for_next_tip | jq -c '.mining_gate_can_submit=false')" active
FAMILYLESS_WAIT_POW=$(mining_json create_new_anchor | jq -c '
  .mining_gate_action="wait_for_next_tip" | .state="claim_in_flight" | .hashrate=0')
ok 'familyless wallet-wide wait_for_next_tip retains fresh new-anchor authority' \
    hotfix_candidate_pow_json_is_valid "$FAMILYLESS_WAIT_POW" active
ok 'familyless wallet-wide wait binds a zero-head observation without host selection' \
    test_pow_observation_json_is_valid "$FAMILYLESS_WAIT_POW" \
        "$(recovery_json)" '{}' "$TIP4" 104 2000000000
reject 'familyless wallet-wide wait cannot report unresolved selected families' \
    hotfix_candidate_pow_json_is_valid \
        "$(jq -c '.mining_gate_unresolved_components=1' <<<"$FAMILYLESS_WAIT_POW")" active
reject 'create_new_anchor rejects an authoritative unresolved component' \
    hotfix_candidate_pow_json_is_valid \
        "$(mining_json create_new_anchor | jq -c '.mining_gate_unresolved_components=1')" active
ok 'legacy PoW inventory counters are independently typed telemetry' \
    hotfix_candidate_pow_json_is_valid \
        "$(mining_json wait_for_live | jq -c '
          .unresolved_claims=0 | .live_claims=7 |
          .quarantined_claims=9 | .raw_quarantined_claims=0 |
          .blocking_quarantined_claims=1 | .actionable_quarantined_claims=8 |
          .indeterminate_quarantined_claims=4')" active
RECOVERY_TELEMETRY_DRIFT=$(recovery_json | jq -c '
  .raw_quarantined_claims=0 | .blocking_quarantined_claims=7 |
  .actionable_quarantined_claims=2 | .indeterminate_quarantined_claims=9')
ok 'recovery quarantine counters are independently typed telemetry' \
    hotfix_candidate_recovery_json_is_valid "$RECOVERY_TELEMETRY_DRIFT"
ok 'legacy inventory counters may differ across same-cut RPC views' \
    test_pow_observation_json_is_valid \
        "$(mining_json refresh_same_anchor | jq -c '
          .raw_quarantined_claims=90 | .blocking_quarantined_claims=80 |
          .actionable_quarantined_claims=70 | .indeterminate_quarantined_claims=60 |
          .resolved_on_active_chain_claims=50 | .claim_components=40')" \
        "$RECOVERY_TELEMETRY_DRIFT" '{}' "$TIP4" 104 2000000000
ok 'Core-selected direct-sibling graph roots bind every family claim' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(recovery_json)" '{}' "$TIP4" 104 2000000000
reject 'Core-selected family rejects a missing direct-sibling graph root' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(recovery_json | jq -c '
          .component_details[0].root_claim_txids =
            [.component_details[0].claim_txids[0]]')" '{}' "$TIP4" 104 2000000000
reject 'Core-selected family rejects transaction-graph descendants' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(recovery_json | jq -c '.component_details[0].descendant_claims=1')" \
        '{}' "$TIP4" 104 2000000000
# shellcheck disable=SC2016 # $head is a jq variable in each literal filter.
for filter in \
    '.component_details[0].nodes |= map(if .txid==$head then .active_chain_confirmed=true else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .abandoned=true | .expired_locally_retired=false else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .in_mempool=false | .quarantined=false else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .proof_mode="pos" else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .proof_version=3 | .proof_origin_bound=false | .proof_input_bound=false else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .proof_evaluation_skipped_resolved_anchor=true else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .proof_may_revalidate_on_descendant=true | .disposition="origin_expired" else . end)' \
    '.component_details[0].nodes |= map(if .txid==$head then .disposition="local_state_error" else . end)'; do
    reject "Core-selected claim rejects unsafe node mutation ${filter}" \
        test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
            "$(jq -c --arg head "$CLAIM4" "$filter" <<<"$(recovery_json)")" \
            '{}' "$TIP4" 104 2000000000
done
for filter in \
    '.component_details[0].ordinary_or_mixed_txids=[("a"*64)]' \
    '.component_details[0].resolution_txids=[("a"*64)]' \
    '.component_details[0].classification="retired_on_active_branch"' \
    '.component_details[0].classification="resolved_on_active_chain"' \
    '.component_details[0].all_claims_explicitly_provenanced=false'; do
    reject "Core-selected component rejects nonoperational shape ${filter}" \
        test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
            "$(jq -c "$filter" <<<"$(recovery_json)")" '{}' "$TIP4" 104 2000000000
done
for filter in \
    '.component_details[0].anchor.txid=("0"*64)' \
    '.component_details[0].anchor.vout=4294967295' \
    '.component_details[0].anchor.amount=0' \
    '.component_details[0].anchor.scriptPubKey=""'; do
    reject "Core-selected component rejects unauthenticated anchor shape ${filter}" \
        test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
            "$(jq -c "$filter" <<<"$(recovery_json)")" '{}' "$TIP4" 104 2000000000
done
LOCKED_WAIT_POW=$(mining_json wait_for_next_tip | jq -c '.mining_gate_can_submit=false')
LOCKED_WAIT_RECOVERY=$(recovery_json | jq -c '.component_details[0].anchor_user_locked=true')
ok 'user-locked selected anchor binds a zero-relay wait_for_next_tip' \
    test_pow_observation_json_is_valid "$LOCKED_WAIT_POW" \
        "$LOCKED_WAIT_RECOVERY" '{}' "$TIP4" 104 2000000000
reject 'user-locked selected anchor cannot authorize refresh_same_anchor' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$LOCKED_WAIT_RECOVERY" '{}' "$TIP4" 104 2000000000
reject 'user-locked selected anchor cannot expose cached submit authority' \
    test_pow_observation_json_is_valid "$(mining_json wait_for_next_tip)" \
        "$LOCKED_WAIT_RECOVERY" '{}' "$TIP4" 104 2000000000
reject 'user-locked selected anchor cannot expose a relay target' \
    test_pow_observation_json_is_valid \
        "$(mining_json relay_existing | jq -c '.mining_gate_action="wait_for_next_tip"')" \
        "$(jq -c --arg relay "$CLAIM4" '.component_details[0].anchor_user_locked=true |
          .component_details[0].nodes |= map(if .txid==$relay then
            .disposition="eligible" | .relay_expiry_time=2000000600 else . end)' \
          <<<"$(recovery_json)")" '{}' "$TIP4" 104 2000000000
reject 'recovery component requires the final Core anchor_user_locked field' \
    hotfix_candidate_recovery_json_is_valid \
        "$(recovery_json | jq -c 'del(.component_details[0].anchor_user_locked)')"
reject 'recovery component anchor_user_locked must be boolean' \
    hotfix_candidate_recovery_json_is_valid \
        "$(recovery_json | jq -c '.component_details[0].anchor_user_locked="false"')"
TERMINAL_POW=$(mining_json refresh_same_anchor false disabled)
TERMINAL_RECOVERY=$(recovery_json)
ok 'terminal authority ignores audit inventory and candidate fingerprint telemetry' \
    terminal_authority_equal "$TERMINAL_POW" "$TERMINAL_RECOVERY" \
        "$(jq -c '.mining_gate_candidate_state_fingerprint=("d"*64) |
          .raw_quarantined_claims=99' <<<"$TERMINAL_POW")" \
        "$(jq -c '.component_details[0].nodes[0].disposition="eligible" |
          .unanchored_claim_txids=[("a"*64)] | .raw_claim_objects=99' \
          <<<"$TERMINAL_RECOVERY")"
for filter in \
    '.mining_gate_action="relay_existing"' \
    '.mining_gate_can_submit=false' \
    '.mining_gate_lineage_head_txid=("a"*64)' \
    '.mining_gate_relay_txid=("a"*64)' \
    '.mining_gate_unsafe_claims=1' \
    '.mining_gate_database_ambiguous=true' \
    '.mining_gate_eligible_claims=2' \
    '.mining_gate_unresolved_components=2'; do
    reject "terminal authority rejects operational PoW drift ${filter}" \
        terminal_authority_equal "$TERMINAL_POW" "$TERMINAL_RECOVERY" \
            "$(jq -c "$filter" <<<"$TERMINAL_POW")" "$TERMINAL_RECOVERY"
done
for filter in \
    '.active_tip=("a"*64)' \
    '.wallet_generation=10' \
    '.database_outcome_ambiguous=true' \
    '.policy_authoritative=false' \
    '.policy.automatic_enabled=true' \
    '.policy.automatic_authorized=true'; do
    reject "terminal authority rejects recovery-policy/cut drift ${filter}" \
        terminal_authority_equal "$TERMINAL_POW" "$TERMINAL_RECOVERY" \
            "$TERMINAL_POW" "$(jq -c "$filter" <<<"$TERMINAL_RECOVERY")"
done
IMPLICIT_ROOT_RECOVERY=$(recovery_json | jq -c --arg root "$CLAIM1" \
  --arg zero "$HOTFIX_ZERO_TXID" '
  .component_details[0].nodes |= map(
    if .txid == $root then
      .lineage_metadata_present=false | .lineage_metadata_valid=false |
      .lineage_ordinal=0 | .lineage_family_fingerprint=$zero |
      .lineage_root_txid=$zero | .lineage_parent_txid=$zero |
      .proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
      .disposition="unbound_proof_may_revalidate" |
      .proof_may_revalidate_on_descendant=true |
      .proof_evaluation_skipped_resolved_anchor=false |
      .authored_tip_active_branch_bound=true
    else . end)')
ok 'exact explicitly authored QQP2 implicit root is accepted' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_ROOT_RECOVERY" '{}' "$TIP4" 104 2000000000
IMPLICIT_V3_RECOVERY=$(jq -c --arg root "$CLAIM1" '
  .component_details[0].nodes |= map(
    if .txid==$root then
      .proof_version=3 | .proof_origin_bound=true | .proof_input_bound=false |
      .disposition="origin_expired" | .proof_may_revalidate_on_descendant=false
    else . end)' <<<"$IMPLICIT_ROOT_RECOVERY")
ok 'exact explicitly authored QQP3 implicit root is accepted' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V3_RECOVERY" '{}' "$TIP4" 104 2000000000
IMPLICIT_V4_RECOVERY=$(jq -c --arg root "$CLAIM1" '
  .component_details[0].nodes |= map(
    if .txid==$root then
      .proof_version=4 | .proof_origin_bound=true | .proof_input_bound=true |
      .disposition="origin_expired" | .proof_may_revalidate_on_descendant=false
    else . end)' <<<"$IMPLICIT_ROOT_RECOVERY")
ok 'exact explicitly authored QQP4 implicit root is accepted' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V4_RECOVERY" '{}' "$TIP4" 104 2000000000
QQP4_NEXT_STATE=$(goldrush_state_json "$TIP4" 104 false 105)
QQP4_NOT_NEXT_STATE=$(goldrush_state_json "$TIP4" 104 false 106)
IMPLICIT_V2_UNSUPPORTED=$(jq -c --arg root "$CLAIM1" '
  .component_details[0].nodes |= map(
    if .txid==$root then
      .disposition="unsupported_version" |
      .proof_may_revalidate_on_descendant=false
    else . end)' <<<"$IMPLICIT_ROOT_RECOVERY")
IMPLICIT_V3_UNSUPPORTED=$(jq -c --arg root "$CLAIM1" '
  .component_details[0].nodes |= map(
    if .txid==$root then
      .disposition="unsupported_version" |
      .proof_may_revalidate_on_descendant=false
    else . end)' <<<"$IMPLICIT_V3_RECOVERY")
ok 'QQP4-next receipt permits an otherwise authenticated QQP2 unsupported root' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V2_UNSUPPORTED" '{}' "$TIP4" 104 2000000000 "$QQP4_NEXT_STATE"
ok 'QQP4-next receipt permits an otherwise authenticated QQP3 unsupported root' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V3_UNSUPPORTED" '{}' "$TIP4" 104 2000000000 "$QQP4_NEXT_STATE"
reject 'disabled QQP4 schedule cannot authorize a QQP2 unsupported root' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V2_UNSUPPORTED" '{}' "$TIP4" 104 2000000000 \
        "$(goldrush_state_json "$TIP4" 104)"
reject 'pre-activation QQP4 schedule cannot authorize a QQP3 unsupported root' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$IMPLICIT_V3_UNSUPPORTED" '{}' "$TIP4" 104 2000000000 \
        "$QQP4_NOT_NEXT_STATE"
reject 'QQP4 unsupported_version is never a legacy activation exception' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .disposition="unsupported_version" else . end)' \
          <<<"$IMPLICIT_V4_RECOVERY")" '{}' "$TIP4" 104 2000000000 \
        "$QQP4_NEXT_STATE"
ok 'exact QQP4 activation receipt binds the active cut' \
    hotfix_goldrush_state_json_is_valid "$QQP4_NEXT_STATE" "$TIP4" 104
reject 'QQP4 activation receipt rejects a mismatched tip' \
    hotfix_goldrush_state_json_is_valid "$QQP4_NEXT_STATE" "$TIP3" 104
reject 'QQP4 activation receipt rejects a mismatched height' \
    hotfix_goldrush_state_json_is_valid "$QQP4_NEXT_STATE" "$TIP4" 103
reject 'disabled QQP4 receipt rejects an enabled activation height' \
    hotfix_goldrush_state_json_is_valid \
        "$(jq -c '.qqp4_activation_height=105' \
          <<<"$(goldrush_state_json "$TIP4" 104)")" "$TIP4" 104
reject 'QQP4 activation receipt rejects a missing projected field' \
    hotfix_goldrush_state_json_is_valid \
        "$(jq -c 'del(.qqp4_active)' <<<"$QQP4_NEXT_STATE")" "$TIP4" 104
reject 'QQP4 activation receipt rejects an extra projected field' \
    hotfix_goldrush_state_json_is_valid \
        "$(jq -c '.extra=false' <<<"$QQP4_NEXT_STATE")" "$TIP4" 104
reject 'QQP4 activation receipt rejects a wrong boolean type' \
    hotfix_goldrush_state_json_is_valid \
        "$(jq -c '.qqp4_active_next_block="true"' <<<"$QQP4_NEXT_STATE")" \
        "$TIP4" 104
reject 'QQP4 activation receipt rejects a zero enabled activation height' \
    hotfix_goldrush_state_json_is_valid \
        "$(goldrush_state_json "$TIP4" 104 false 0)" "$TIP4" 104
reject 'QQP4 activation receipt rejects a forged next-block active flag' \
    hotfix_goldrush_state_json_is_valid \
        "$(jq -c '.qqp4_active_next_block=false' <<<"$QQP4_NEXT_STATE")" "$TIP4" 104
reject 'implicit root cannot claim legacy-wallet-authored provenance' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid == $root then .provenance="legacy_wallet_authored" else . end)' \
          <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
reject 'implicit root outside QQP2/3/4 is rejected' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid == $root then .proof_version=1 else . end)' \
          <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
reject 'QQP3 implicit root requires its origin-bound proof tuple' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .proof_origin_bound=false else . end)' \
          <<<"$IMPLICIT_V3_RECOVERY")" '{}' "$TIP4" 104 2000000000
# shellcheck disable=SC2016 # $root is a jq variable in each literal filter.
for filter in \
    '.component_details[0].nodes |= map(if .txid==$root then .lineage_family_fingerprint=("a"*64) else . end)' \
    '.component_details[0].nodes |= map(if .txid==$root then .lineage_root_txid=("a"*64) else . end)' \
    '.component_details[0].nodes |= map(if .txid==$root then .lineage_parent_txid=("a"*64) else . end)'; do
    reject "implicit root rejects nonzero default descriptor ${filter}" \
        test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
            "$(jq -c --arg root "$CLAIM1" "$filter" \
              <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
done
reject 'implicit root rejects a disposition outside the exact Core enum' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .disposition="forged-root" else . end)' \
          <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
reject 'implicit root revalidation flag must match its disposition' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .proof_may_revalidate_on_descendant=false else . end)' \
          <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
reject 'implicit root on an unspent anchor cannot claim skipped proof evaluation' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .proof_evaluation_skipped_resolved_anchor=true else . end)' \
          <<<"$IMPLICIT_ROOT_RECOVERY")" '{}' "$TIP4" 104 2000000000
IMPLICIT_SINGLETON_RECOVERY=$(jq -c --arg root "$CLAIM1" '
  .component_details[0] |=
    (.nodes=[.nodes[] | select(.txid==$root)] |
     .claim_txids=[$root] | .root_claim_txids=[$root] | .descendant_claims=0) |
  .raw_claim_objects=1 | .quarantined_claim_objects=1 |
  .raw_quarantined_claims=1 | .blocking_quarantined_claims=1 |
  .actionable_quarantined_claims=1 | .live_claim_objects=0
' <<<"$IMPLICIT_ROOT_RECOVERY")
IMPLICIT_SINGLETON_POW=$(mining_json refresh_same_anchor | jq -c --arg root "$CLAIM1" '
  .mining_gate_lineage_head_txid=$root | .mining_gate_family_claims=1 |
  .unresolved_claims=1 | .quarantined_claims=1 | .raw_quarantined_claims=1 |
  .blocking_quarantined_claims=1 | .actionable_quarantined_claims=1')
ok 'singleton QQP2 implicit root binds its authored tip and safe disposition' \
    test_pow_observation_json_is_valid "$IMPLICIT_SINGLETON_POW" \
        "$IMPLICIT_SINGLETON_RECOVERY" '{}' "$TIP4" 104 2000000000
reject 'singleton QQP2 implicit root requires an active-branch-authored tip' \
    test_pow_observation_json_is_valid "$IMPLICIT_SINGLETON_POW" \
        "$(jq -c --arg root "$CLAIM1" '
          .component_details[0].nodes |= map(
            if .txid==$root then .authored_tip_active_branch_bound=false else . end)' \
          <<<"$IMPLICIT_SINGLETON_RECOVERY")" '{}' "$TIP4" 104 2000000000
RETAINED_SELECTED_RECOVERY=$(recovery_json | jq -c --arg old "$CLAIM1" '
  .retired_claim_objects=1 | .retired_components=1 |
  .component_details[0].nodes |= map(
    if .txid==$old then .expired_locally_retired=true | .abandoned=true else . end) |
  .component_details[0].all_claims_zero_payment_retirable=true')
ok 'selected-family retired and abandoned history does not override zero-unsafe Core authority' \
    test_pow_observation_json_is_valid "$(mining_json refresh_same_anchor)" \
        "$RETAINED_SELECTED_RECOVERY" '{}' "$TIP4" 104 2000000000
MULTI_FAMILY_RECOVERY=$(jq -ce '.samples[0].recovery' "$PROGRESS_B_MULTI_FAMILY")
ok 'recovery inventory accepts an exact two-component verbose partition' \
    hotfix_candidate_recovery_json_is_valid "$MULTI_FAMILY_RECOVERY"
ok 'compatibility component telemetry may differ from full verbose inventory' \
    hotfix_candidate_recovery_json_is_valid \
        "$(jq -c '.components=1' <<<"$MULTI_FAMILY_RECOVERY")"
ok 'audit-only unanchored component may retain an empty anchor script' \
    hotfix_candidate_recovery_json_is_valid \
        "$(jq -c '.component_details[1].anchor.scriptPubKey="" |
          .component_details[1].anchor_authenticated=false' \
          <<<"$MULTI_FAMILY_RECOVERY")"
reject 'one recovery node txid cannot belong to two components' \
    hotfix_candidate_recovery_json_is_valid \
        "$(jq -c --arg duplicate "$CLAIM1" '
          .component_details[1].claim_txids[0]=$duplicate |
          .component_details[1].nodes[0].txid=$duplicate' \
          <<<"$MULTI_FAMILY_RECOVERY")"
ok 'transient wait gate with ready worker state is accepted' \
    hotfix_candidate_pow_json_is_valid "$(mining_json wait_for_live true ready)" active
ok 'transient relay gate with hashing worker state and zero hash is accepted' \
    hotfix_candidate_pow_json_is_valid "$(mining_json relay_existing true hashing)" active
ok 'non-submit wait action may report transient positive hashrate' \
    hotfix_candidate_pow_json_is_valid \
        "$(mining_json wait_for_live true hashing | jq '.hashrate=3')" active
reject 'malfunctional active worker state is rejected' \
    hotfix_candidate_pow_json_is_valid "$(mining_json wait_for_live true error)" active
reject 'disabled worker state is rejected while the worker is enabled' \
    hotfix_candidate_pow_json_is_valid "$(mining_json wait_for_live true disabled)" active
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

ok 'four-sample Phase-A worker progress accepted' \
    hotfix_phase_a_progress_file_is_valid "$PROGRESS"
ok 'minimum three-sample Phase-A worker progress accepted' \
    hotfix_phase_a_progress_file_is_valid "$PROGRESS_N3"
mutate "$PROGRESS_N3" "$TMP/progress-named-wallet.json" '
  .envelopes[].wallet.walletname="default_wallet" |
  .envelopes[].wallets=["default_wallet"]'
ok 'Phase-A progress binds a stable nonempty wallet name' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-named-wallet.json"
mutate "$TMP/progress-named-wallet.json" "$TMP/progress-wallet-drift.json" \
    '.envelopes[1].wallet.walletname="other_wallet"'
reject 'Phase-A progress rejects wallet-name drift' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-wallet-drift.json"
mutate "$TMP/progress-named-wallet.json" "$TMP/progress-wallet-multiple.json" \
    '.envelopes[1].wallets=["default_wallet","other_wallet"]'
reject 'Phase-A progress rejects multiple loaded wallets' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-wallet-multiple.json"
mutate "$TMP/progress-named-wallet.json" "$TMP/progress-wallet-missing.json" \
    '.envelopes[1].wallets=[]'
reject 'Phase-A progress rejects a missing loaded wallet' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-wallet-missing.json"
ok 'Phase-A worker progress accepts more than four observations' \
    hotfix_phase_a_progress_file_is_valid "$PROGRESS_N6"
mutate "$PROGRESS_N3" "$TMP/progress-n2.json" '
  .observation_sample_count=2 | .envelopes=.envelopes[0:2] |
  .tip_changes=1 | .post_restart_advancing_observations=1 |
  .isolation_sample_sha256s=.isolation_sample_sha256s[0:2] |
  .visibility_sample_sha256s=.visibility_sample_sha256s[0:2]'
reject 'Phase-A progress rejects fewer than three observations' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-n2.json"
for filter in '.tip_changes=2' '.pos_disabled_continuous=false' \
    '.nonpublication_continuous=false' '.envelopes[2].staking.enabled=true' \
    '.envelopes[3].chain_before.chainwork=.envelopes[2].chain_before.chainwork' \
    '.envelopes[1].mining_after.mining_gate_database_ambiguous=true' \
    '.envelopes[1].recovery_after.confirmed_automatic_resolutions=1' \
    '.envelopes[1].recovery_after.claims_recycled=1'; do
    mutate "$PROGRESS" "$TMP/m.json" "$filter"
    reject "progress hostile mutation ${filter}" hotfix_phase_a_progress_file_is_valid "$TMP/m.json"
done
mutate "$PROGRESS" "$TMP/progress-nonzero-history.json" '
  .envelopes |= map(
    .mining_before |= (
      .resolved_on_active_chain_claims=7 | .pending_manual_resolutions=2 |
      .pending_automatic_resolutions=1 | .claims_auto_resolved=3 |
      .claims_recycled=4 | .cumulative_resolution_fees=0.25) |
    .mining_after=.mining_before |
    .recovery_before |= (
      .resolved_on_active_chain_claims=7 | .pending_manual_resolutions=2 |
      .pending_automatic_resolutions=1 | .confirmed_automatic_resolutions=3 |
      .claims_recycled=4 | .confirmed_resolution_fees=0.25 |
      .confirmed_manual_resolutions=6 | .automatic_actions_in_window=5 |
      .automatic_fee_exposure_in_window=0.1 | .reconciled_descendant_claims=7 |
      .retired_claim_objects=9 | .retired_components=8 |
      .resolved_components=8 |
      .unanchored_claim_txids=["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]) |
    .recovery_after=.recovery_before)'
ok 'Phase-A accepts coherent nonzero retained-history and recovery telemetry' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-nonzero-history.json"
mutate "$PROGRESS_N3" "$TMP/progress-qqp4-schedule-drift.json" '
  .envelopes[1].goldrush_state |= (
    .qqp4_activation_disabled=false | .qqp4_activation_height=103 |
    .qqp4_active=false | .qqp4_active_next_block=true)'
reject 'Phase-A rejects QQP4 activation schedule drift across operational cuts' \
    hotfix_phase_a_progress_file_is_valid "$TMP/progress-qqp4-schedule-drift.json"
mutate "$TMP/progress-nonzero-history.json" "$TMP/m.json" \
    '.envelopes[1].mining_after.pending_manual_resolutions=3'
reject 'Phase-A rejects incoherent same-cut PoW/recovery counters' \
    hotfix_phase_a_progress_file_is_valid "$TMP/m.json"
mutate "$PROGRESS" "$TMP/m.json" '.same_tip_or_submit_no_progress_transition_budget=2'
reject 'Phase-A cannot relax the one-transition zero-hash no-progress bound' \
    hotfix_phase_a_progress_file_is_valid "$TMP/m.json"

ok 'one-tip live/relay waits accept unchanged fingerprint around real hashing progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SHORT" \
        fedcba9876543210fedcba9876543210 active
reject 'Phase-B progress cannot certify disabled candidate PoW' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SHORT" \
        fedcba9876543210fedcba9876543210 off
ok 'minimum three-sample Phase-B worker progress accepted' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_N3" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_N3" "$TMP/progress-b-qqp4-schedule-drift.json" '
  .samples[1].goldrush_state |= (
    .qqp4_activation_disabled=false | .qqp4_activation_height=103 |
    .qqp4_active=false | .qqp4_active_next_block=true)'
reject 'Phase-B rejects QQP4 activation schedule drift across operational cuts' \
    hotfix_phase_b_progress_file_is_valid "$TMP/progress-b-qqp4-schedule-drift.json" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_N3" "$TMP/progress-b-n2.json" '
  .observation_sample_count=2 | .samples=.samples[0:2] | .tip_changes=1'
ok 'Phase-B accepts two observations when they contain one real chain advance' \
    hotfix_phase_b_progress_file_is_valid "$TMP/progress-b-n2.json" \
        fedcba9876543210fedcba9876543210 active
reject 'one tip advance cannot substitute for final zero-hash refresh liveness' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_TWO_ZERO_REFRESH" \
        fedcba9876543210fedcba9876543210 active
reject 'one tip advance cannot substitute for final zero-hash create liveness' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_TWO_ZERO_CREATE" \
        fedcba9876543210fedcba9876543210 active
reject 'positive hashing cannot mask an active tip frozen beyond ten minutes' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_FROZEN_TIP_WATCHDOG" \
        fedcba9876543210fedcba9876543210 active
# shellcheck disable=SC2016 # $first is a jq variable.
mutate "$TMP/progress-b-n2.json" "$TMP/progress-b-no-chain-advance.json" '
  .samples[0] as $first | .samples[1] |= (
    .chain=$first.chain | .pow=$first.pow | .recovery=$first.recovery |
    .mempool_verbose=$first.mempool_verbose) | .tip_changes=0'
reject 'same-tip work evidence cannot substitute for one real chain advance' \
    hotfix_phase_b_progress_file_is_valid "$TMP/progress-b-no-chain-advance.json" \
        fedcba9876543210fedcba9876543210 active
ok 'bounded wait accepts transient positive hash without treating it as submission progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_WAIT_POSITIVE_HASH" \
        fedcba9876543210fedcba9876543210 active
ok 'one-tip wait_for_next_tip accepts unchanged fingerprint around real hashing progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_NEXT" \
        fedcba9876543210fedcba9876543210 active
ok 'relay_existing binds an eligible absent member selected by Core' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_RELAY_HIGHEST" \
        fedcba9876543210fedcba9876543210 active
ok 'relay_existing accepts a lower eligible member when Core suppresses another txid' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_RELAY_LOWER" \
        fedcba9876543210fedcba9876543210 active
ok 'wait_for_next_tip binds an eligible absent relay member selected by Core' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_NEXT_RELAY_HIGHEST" \
        fedcba9876543210fedcba9876543210 active
ok 'wait_for_next_tip accepts a lower eligible member after per-tx suppression' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_NEXT_RELAY_LOWER" \
        fedcba9876543210fedcba9876543210 active
ok 'relay and refresh accept aggregate live claims from a simultaneous safe family' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_MULTI_FAMILY" \
        fedcba9876543210fedcba9876543210 active
reject 'relay_existing rejects an eligible txid outside the Core-selected component' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_MULTI_RELAY_WRONG_COMPONENT" \
        fedcba9876543210fedcba9876543210 active
reject 'wait_for_next_tip rejects a relay txid outside the Core-selected component' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_MULTI_NEXT_WRONG_COMPONENT" \
        fedcba9876543210fedcba9876543210 active
ok 'first authoritative relay-to-live transition resets the bounded wait once' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_LIVE_PROGRESS" \
        fedcba9876543210fedcba9876543210 active
ok 'an older authenticated relay member becoming live resets the bounded wait once' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_OLDER_LIVE_PROGRESS" \
        fedcba9876543210fedcba9876543210 active
ok 'a new live member resets once after the prior family member leaves' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_NEW_SIBLING_LIVE" \
        fedcba9876543210fedcba9876543210 active
reject 'multiple live siblings in one selected family contradict Core zero-unsafe authority' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_MULTI_LIVE_SAME_FAMILY" \
        fedcba9876543210fedcba9876543210 active
ok 'same-tip strict lineage extension is retained as concrete family progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_EXTENSION" \
        fedcba9876543210fedcba9876543210 active
ok 'same-tip positive hashing on another selected safe family is concrete progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_OTHER_FAMILY" \
        fedcba9876543210fedcba9876543210 active
ok 'one first-seen family cut is tolerated only within the bounded same-tip defer' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_FIRST_SEEN" \
        fedcba9876543210fedcba9876543210 active
reject 'repeated same-tip positive-hash polls are one witness, not infinite progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_DUPLICATE" \
        fedcba9876543210fedcba9876543210 active
ok 'same-tip transition into positive submit-capable hashing is one concrete witness' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_HASH_START" \
        fedcba9876543210fedcba9876543210 active
ok 'one changed same-tip wait cut consumes but does not exceed the bounded defer budget' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SAME_TIP_WAIT" \
        fedcba9876543210fedcba9876543210 active
ok 'continuous positive submit-capable hashing remains healthy across advancing tips' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_CONTINUOUS_HASH" \
        fedcba9876543210fedcba9876543210 active
ok 'one bounded familyless wait_for_next_tip transition is accepted' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_FAMILYLESS_WAIT" \
        fedcba9876543210fedcba9876543210 active
ok 'familyless wait_for_next_tip remains operational across advancing tips' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_FAMILYLESS_STALE" \
        fedcba9876543210fedcba9876543210 active
reject 'Phase-B liveness evidence cannot exceed its 2700-second capture budget' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_OBSERVATION_WINDOW" \
        fedcba9876543210fedcba9876543210 active
reject 'a previously compressed tip cannot replay nonconsecutively at greater apparent work' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_OLD_TIP_REPLAY" \
        fedcba9876543210fedcba9876543210 active
ok 'increased worker submission counter resets a bounded zero-hash interval' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_COUNTER_PROGRESS" \
        fedcba9876543210fedcba9876543210 active
ok 'empty-family create sentinel survives parsing and one bounded zero-hash transition' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_CREATE_SHORT" \
        fedcba9876543210fedcba9876543210 active
ok 'A-to-B-to-A scheduling preserves latest prior per-family continuity' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_INTERLEAVED" \
        fedcba9876543210fedcba9876543210 active
reject 'family switching and return do not count as zero-hash progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_INTERLEAVED_STALE" \
        fedcba9876543210fedcba9876543210 active
reject 'A-to-B-to-rewritten-A return violates per-family continuity' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_INTERLEAVED_REWRITE" \
        fedcba9876543210fedcba9876543210 active
ok 'wait_for_live may remain zero-hash while the active chain advances' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_LIVE" \
        fedcba9876543210fedcba9876543210 active
ok 'transient wait_for_live hash does not block independently advancing chain evidence' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_WAIT_POSITIVE_HASH" \
        fedcba9876543210fedcba9876543210 active
ok 'relay_existing may remain zero-hash while the active chain advances' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_RELAY" \
        fedcba9876543210fedcba9876543210 active
ok 'wait_for_next_tip may remain zero-hash across advancing tips' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_NEXT" \
        fedcba9876543210fedcba9876543210 active
ok 'audit/action churn is nonprogress but does not block advancing safe-wait evidence' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_ALTERNATING" \
        fedcba9876543210fedcba9876543210 active
ok 'live replay is nonprogress but advancing safe-wait evidence remains operational' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_LIVE_REPLAY" \
        fedcba9876543210fedcba9876543210 active
ok 'live-sibling switching is nonprogress but does not veto advancing safe waits' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_LIVE_SIBLING_TOGGLE" \
        fedcba9876543210fedcba9876543210 active
ok 'previously seen live sibling is nonprogress but advancing safe waits remain valid' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_SEEN_DURING_PROGRESS" \
        fedcba9876543210fedcba9876543210 active
reject 'zero-hash refresh cannot remain unchanged across two tip transitions' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_REFRESH" \
        fedcba9876543210fedcba9876543210 active
reject 'zero-hash create cannot remain unchanged across two tip transitions' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_STALE_CREATE" \
        fedcba9876543210fedcba9876543210 active
reject 'lineage head regression after an observed descendant is replay, not progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_REPLAY" \
        fedcba9876543210fedcba9876543210 active
reject 'same head and ordinal cannot conceal a rewritten middle lineage member' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_MIDDLE_REPLAY" \
        fedcba9876543210fedcba9876543210 active
reject 'generation-fingerprint churn cannot redefine one stable family as progress' \
    hotfix_phase_b_progress_file_is_valid "$PROGRESS_B_GENERATION_CHURN" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_SHORT" "$TMP/m.json" \
    '.samples[1].mempool_verbose[.samples[1].pow.mining_gate_lineage_head_txid].height =
      (.samples[1].chain.blocks - 2)'
ok 'wait_for_live accepts canonical raw mempool membership without an absolute block-age veto' \
    hotfix_phase_b_progress_file_is_valid "$TMP/m.json" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_SHORT" "$TMP/m.json" \
    'del(.samples[1].mempool_verbose[.samples[1].pow.mining_gate_lineage_head_txid])'
reject 'wait_for_live rejects missing raw mempool-entry evidence' \
    hotfix_phase_b_progress_file_is_valid "$TMP/m.json" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_SHORT" "$TMP/m.json" \
    '.samples[3].recovery.component_details[0].nodes |= map(
      if .txid == "'"$CLAIM4"'" then .relay_expiry_time=2000000000 else . end)'
reject 'relay_existing rejects a relay TTL that is not future-bound to observation time' \
    hotfix_phase_b_progress_file_is_valid "$TMP/m.json" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_SHORT" "$TMP/m.json" \
    '.same_tip_or_submit_no_progress_transition_budget=2'
reject 'Phase-B cannot relax the one-transition zero-hash no-progress bound' \
    hotfix_phase_b_progress_file_is_valid "$TMP/m.json" \
        fedcba9876543210fedcba9876543210 active
mutate "$PROGRESS_B_STALE_LIVE" "$TMP/m.json" \
    '.samples[].pow.state="ready"'
ok 'safe wait state telemetry may drift while chain progress remains authoritative' \
    hotfix_phase_b_progress_file_is_valid "$TMP/m.json" \
        fedcba9876543210fedcba9876543210 active

ok 'authenticated authored-component claim proof accepted' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM"
PHASE_A_EXTERNAL="$TMP/phase-a-external-receive.json"
EXTERNAL_TXID=$(hex64 88)
jq -S -n --arg source "$HOTFIX_CANDIDATE_SOURCE_SHA" --arg nonce "$NONCE" \
  --arg tip "$TIP4" --arg baseline "$ANCHOR" --arg txid "$EXTERNAL_TXID" '
  def wallet_tx:
    {txid:$txid,hex:"aa",decoded:{txid:$txid},amount:2,confirmations:0,
     involvesWatchonly:true,
     details:[{txid:$txid,vout:0,address:"Qwatch",category:"receive",amount:2,
       abandoned:false,involvesWatchonly:true}]};
  {schema:1,phase:"A",run_nonce:$nonce,candidate_source_sha:$source,
   terminal_tip:$tip,terminal_height:104,prelaunch_wallet_txids:[$baseline],
   final_wallet_txids:[$baseline,$txid]|sort,new_wallet_txids:[$txid],
   candidate_authored_txids:[],external_receive_txids:[$txid],
   records:[{txid:$txid,classification:"external_receive",confirmation_state:"unconfirmed",
     gettransaction_response:wallet_tx,recovery_matches:[],recovery_match_count:0,
     getblock_response:null,getblockhash_response:null,active_chain_bound:false,
     unconfirmed_recovery_bound:true}],sets_disjoint:true,wallet_differential_exhaustive:true}
' >"$PHASE_A_EXTERNAL"
ok 'Phase-A unconfirmed watch-only external receive is accepted without a recovery match' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$PHASE_A_EXTERNAL"
mutate "$PHASE_A_EXTERNAL" "$TMP/phase-a-external-fee.json" \
    '.records[0].gettransaction_response.fee=0'
reject 'Phase-A external receive rejects a wallet-debit fee field' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/phase-a-external-fee.json"
mutate "$PHASE_A_EXTERNAL" "$TMP/phase-a-external-send.json" \
    '.records[0].gettransaction_response.details[0].category="send"'
reject 'Phase-A external receive rejects a send detail' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/phase-a-external-send.json"
mutate "$PHASE_A_EXTERNAL" "$TMP/phase-a-external-control.json" \
    '.records[0].gettransaction_response.qq_shadow_pow_authored="1"'
reject 'Phase-A external receive rejects local claim-control metadata' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/phase-a-external-control.json"
# shellcheck disable=SC2016 # jq variables are intentionally shell-quoted arguments.
cp "$PHASE_A_EXTERNAL" "$TMP/phase-a-external-audit-component.json"
# shellcheck disable=SC2016 # jq variables are intentionally shell-quoted arguments.
mutate_json_in_place "$TMP/phase-a-external-audit-component.json" \
  --arg txid "$EXTERNAL_TXID" --arg zero "$HOTFIX_ZERO_TXID" '
  .records[0].recovery_matches=[{
    anchor:{txid:$zero,vout:4294967295,amount:0,scriptPubKey:""},
    anchor_authenticated:false,anchor_unspent:false,anchor_user_locked:false,
    claim_txids:[$txid],nodes:[{txid:$txid,kind:"claim",provenance:"unknown",
      wallet_authored:false,wallet_from_me:false}]}] |
  .records[0].recovery_match_count=1'
ok 'Phase-A unconfirmed external receive accepts one exact audit-only component' \
    hotfix_phase_a_external_receive_evidence_file_is_valid \
        "$TMP/phase-a-external-audit-component.json"
for filter in \
    '.records[0].recovery_matches[0].anchor_authenticated=true' \
    '.records[0].recovery_matches[0].anchor_unspent=true' \
    '.records[0].recovery_matches[0].anchor_user_locked=true' \
    '.records[0].recovery_matches[0].nodes[0].wallet_authored=true' \
    '.records[0].recovery_matches[0].nodes[0].wallet_from_me=true' \
    '.records[0].recovery_matches[0].nodes[0].provenance="explicit_authored"'; do
    mutate "$TMP/phase-a-external-audit-component.json" "$TMP/m.json" "$filter"
    reject "Phase-A external receive rejects non-audit recovery shape ${filter}" \
        hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/m.json"
done
# shellcheck disable=SC2016 # $tip is a jq variable.
cp "$PHASE_A_EXTERNAL" "$TMP/phase-a-confirmed-external.json"
# shellcheck disable=SC2016 # $tip is a jq variable.
mutate_json_in_place "$TMP/phase-a-confirmed-external.json" --arg tip "$TIP4" '
  .records[0] |= (.confirmation_state="confirmed_active_chain" |
    .gettransaction_response.confirmations=1 |
    .gettransaction_response.blockhash=$tip |
    .gettransaction_response.blockheight=104 |
    .gettransaction_response.blockindex=0 |
    .gettransaction_response.details[0].confirmations=1 |
    .gettransaction_response.details[0].blockhash=$tip |
    .getblock_response={hash:$tip,height:104,confirmations:1,tx:[.txid]} |
    .getblockhash_response=$tip | .active_chain_bound=true |
    .unconfirmed_recovery_bound=false)'
ok 'Phase-A confirmed external receive binds exact active-chain membership' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/phase-a-confirmed-external.json"
mutate "$TMP/phase-a-confirmed-external.json" "$TMP/phase-a-confirmed-unbound.json" \
    '.records[0].getblock_response.tx=[]'
reject 'Phase-A confirmed external receive rejects missing block membership' \
    hotfix_phase_a_external_receive_evidence_file_is_valid "$TMP/phase-a-confirmed-unbound.json"
mutate "$CLAIM" "$TMP/claim-extra-top-level-field.json" '.stale_schema_field=true'
reject 'claim proof rejects untyped top-level schema fields' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-extra-top-level-field.json"
ok 'zero-created bounded observation claim proof accepted' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_ZERO"
ok 'preexisting component prefix plus newly authored contiguous suffix accepted' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_PREFIX"
CLAIM_IMPLICIT_ROOT="$TMP/claim-implicit-legacy-root.json"
# shellcheck disable=SC2016 # $zero is a jq variable.
cp "$CLAIM_PREFIX" "$CLAIM_IMPLICIT_ROOT"
# shellcheck disable=SC2016 # $zero is a jq variable.
mutate_json_in_place "$CLAIM_IMPLICIT_ROOT" --arg zero "$HOTFIX_ZERO_TXID" '
  .authored_components[0].full_members[0] |= (
    .lineage_metadata_present=false | .lineage_metadata_valid=false |
    .family=$zero | .root_txid=$zero | .parent_txid=$zero)'
ok 'legacy implicit root plus authenticated lineaged descendants is accepted' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_IMPLICIT_ROOT"
for filter in \
    '.authored_components[0].full_members[0].family=("a"*64)' \
    '.authored_components[0].full_members[0].root_txid=("a"*64)' \
    '.authored_components[0].full_members[0].parent_txid=("a"*64)' \
    '.authored_components[0].full_members[0].proof_input_bound=true' \
    '.authored_components[0].full_members[1].parent_txid=("a"*64)' \
    '.authored_components[0].full_members[1].family=("a"*64)' \
    '.authored_components[0].full_members[1].root_txid=("a"*64)' \
    '.authored_components[0].full_members[1].lineage_metadata_present=false |
      .authored_components[0].full_members[1].lineage_metadata_valid=false |
      .authored_components[0].full_members[1].family=("0"*64) |
      .authored_components[0].full_members[1].root_txid=("0"*64) |
      .authored_components[0].full_members[1].parent_txid=("0"*64)'; do
    mutate "$CLAIM_IMPLICIT_ROOT" "$TMP/m.json" "$filter"
    reject "implicit-root authored component rejects ${filter}" \
        hotfix_phase_a_claim_proof_file_is_valid "$TMP/m.json"
done
ok 'multiple independent authenticated authored components accepted' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_MULTI"
ok 'three observations may authenticate more than three created txids on shared sampled tips' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_DENSE"
QUANTUM_BEFORE="$TMP/quantum-before.json"
QUANTUM_AFTER="$TMP/quantum-after.json"
QUANTUM_LABELS_BEFORE="$TMP/quantum-labels-before.json"
QUANTUM_LABELS_AFTER="$TMP/quantum-labels-after.json"
jq -S -n '{total:1,backup_verified:1,backup_unverified:0,
  all_durably_stored:true,all_backed_up:true,warning:"ok",
  keys:[{address:"Qfixture",witness_version:4,witness_program:"aa",public_key:"bb",
    timestamp:1,encrypted:true,stored_in_wallet:true,backup_verified:true,tiered:false,
    label:"Quantum PoW Reward Address"}]}' >"$QUANTUM_BEFORE"
jq -S '.keys[0].label="PoW - Quantum Claim Address"' "$QUANTUM_BEFORE" >"$QUANTUM_AFTER"
jq -S -n '{schema:1,labels:[{label:"Quantum PoW Reward Address",
  addresses:{Qfixture:{purpose:"receive"}}}]}' >"$QUANTUM_LABELS_BEFORE"
jq -S -n '{schema:1,labels:[{label:"PoW - Quantum Claim Address",
  addresses:{Qfixture:{purpose:"receive"}}}]}' >"$QUANTUM_LABELS_AFTER"
ok 'same-key receive-purpose legacy payout label normalizes canonically' \
    hotfix_quantum_inventory_transition_is_valid "$QUANTUM_BEFORE" "$QUANTUM_AFTER" \
        "$QUANTUM_LABELS_BEFORE" "$QUANTUM_LABELS_AFTER"
QUANTUM_PAYOUT_INFO="$TMP/quantum-payout-address.json"
jq -S -n '{address:"Qfixture",ismine:true,solvable:true,iswatchonly:false,
  isquantummigration:true,hasquantumkey:true,isquantumcoldstake:false}' \
  >"$QUANTUM_PAYOUT_INFO"
ok 'configured future payout binds an exact preexisting quantum key' \
    hotfix_quantum_payout_address_is_valid \
        "$QUANTUM_PAYOUT_INFO" "$QUANTUM_BEFORE" Qfixture
for filter in '.ismine=false' '.solvable=false' '.iswatchonly=true' \
    '.isquantummigration=false' '.hasquantumkey=false' \
    '.isquantumcoldstake=true' '.address="Qother"'; do
    mutate "$QUANTUM_PAYOUT_INFO" "$TMP/quantum-payout-hostile.json" "$filter"
    reject "configured payout rejects quantum authority mutation ${filter}" \
        hotfix_quantum_payout_address_is_valid \
            "$TMP/quantum-payout-hostile.json" "$QUANTUM_BEFORE" Qfixture
done
for filter in '.keys[0].tiered=true' '.keys[0].stored_in_wallet=false' \
    '.keys[0].address="Qother"' '.keys += [.keys[0]]'; do
    mutate "$QUANTUM_BEFORE" "$TMP/quantum-payout-inventory-hostile.json" "$filter"
    reject "configured payout rejects inventory mutation ${filter}" \
        hotfix_quantum_payout_address_is_valid \
            "$QUANTUM_PAYOUT_INFO" "$TMP/quantum-payout-inventory-hostile.json" Qfixture
done
mutate "$QUANTUM_LABELS_BEFORE" "$TMP/quantum-wrong-purpose.json" \
    '.labels[0].addresses.Qfixture.purpose="send"'
reject 'legacy payout relabel rejects a non-receive prior purpose' \
    hotfix_quantum_inventory_transition_is_valid "$QUANTUM_BEFORE" "$QUANTUM_AFTER" \
        "$TMP/quantum-wrong-purpose.json" "$QUANTUM_LABELS_AFTER"
mutate "$QUANTUM_AFTER" "$TMP/quantum-address-drift.json" '.keys[0].address="Qother"'
reject 'payout relabel cannot rotate the quantum address' \
    hotfix_quantum_inventory_transition_is_valid "$QUANTUM_BEFORE" \
        "$TMP/quantum-address-drift.json" "$QUANTUM_LABELS_BEFORE" "$QUANTUM_LABELS_AFTER"
mutate "$QUANTUM_AFTER" "$TMP/quantum-key-growth.json" '.keys += [.keys[0]] | .total=2'
reject 'payout relabel cannot add a quantum key' \
    hotfix_quantum_inventory_transition_is_valid "$QUANTUM_BEFORE" \
        "$TMP/quantum-key-growth.json" "$QUANTUM_LABELS_BEFORE" "$QUANTUM_LABELS_AFTER"
for filter in \
    '.candidate_created_qqsproof_txids=[]' \
    '.candidate_created_qqsproof_mempool_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_confirmed_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_observer_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.candidate_created_qqsproof_unclassifiable_txids=[.candidate_created_qqsproof_txids[0]]' \
    '.observer_status="unknown"' '.new_nonclaim_wallet_transactions=["x"]' \
    '.coinstake_created_txids=["x"]' \
    '.authored_components[0].contiguous_parents=false' \
    '.authored_components[0].full_members[1].ordinal=2' \
    '.authored_components[0].newly_authored_members[0].quarantine_marker="0"' \
    '.authored_components[0].newly_authored_members[0].proof_origin_bound=false' \
    '.authored_components[0].newly_authored_members[0].proof_input_bound=true' \
    '.authored_components[0].full_members[1].parent_txid=.authored_components[0].full_members[2].txid' \
    '.authored_components[0].component_claim_txids=[]' \
    '.authenticated_anchors=[]' '.initial_atomic_reservation_verified=false' \
    '.candidate_claims_submitted=1'; do
    mutate "$CLAIM" "$TMP/m.json" "$filter"
    reject "claim hostile mutation ${filter}" hotfix_phase_a_claim_proof_file_is_valid "$TMP/m.json"
done
CLAIM_RETAINED="$TMP/claim-retained-history.json"
mutate "$CLAIM" "$CLAIM_RETAINED" '
  .authored_components[0].all_claims_zero_payment_retirable=true |
  .authored_components[0].all_claims_expired_locally_retired=false |
  .authored_components[0].newly_authored_members[0].expired_locally_retired=true |
  .authored_components[0].newly_authored_members[0].abandoned=true |
  .candidate_retired_member_txids=[.authored_components[0].newly_authored_members[0].txid] |
  .abandoned_wallet_txids=[.authored_components[0].newly_authored_members[0].txid]'
ok 'retired abandoned authored-member status remains authenticated telemetry' \
    hotfix_phase_a_claim_proof_file_is_valid "$CLAIM_RETAINED"
mutate "$CLAIM" "$TMP/claim-duplicate-candidate.json" '
  .candidate_created_qqsproof_txids += [.candidate_created_qqsproof_txids[0]]'
reject 'duplicate candidate-created mapping is rejected' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-duplicate-candidate.json"
mutate "$CLAIM" "$TMP/claim-missing-mapping.json" \
    'del(.candidate_created_qqsproof_txids[-1])'
reject 'missing candidate-created component mapping is rejected' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-missing-mapping.json"
mutate "$CLAIM_MULTI" "$TMP/claim-duplicate-component-member.json" '
  .authored_components[1].component_claim_txids[0]=
    .authored_components[0].component_claim_txids[0]'
reject 'one claim txid cannot be mapped into two authored components' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-duplicate-component-member.json"
# shellcheck disable=SC2016 # $full is a jq variable.
mutate "$CLAIM_PREFIX" "$TMP/claim-noncontiguous-suffix.json" '
  .authored_components[0] |= (
    .newly_authored_txids=[.component_claim_txids[0],.component_claim_txids[2],
      .component_claim_txids[3]] |
    .newly_authored_members=[.full_members[0] as $full |
      .newly_authored_members[0] |
      .txid=$full.txid | .ordinal=$full.ordinal | .parent_txid=$full.parent_txid] +
      .newly_authored_members) |
  .candidate_created_qqsproof_txids=
    ([.authored_components[].newly_authored_txids[]] | sort)'
reject 'noncontiguous newly authored component suffix is rejected' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-noncontiguous-suffix.json"
mutate "$CLAIM_ZERO" "$TMP/claim-zero-with-anchor.json" \
    '.authenticated_anchors=[{txid:("c"*64),vout:0}]'
reject 'zero-created proof cannot retain an unauthored anchor descriptor' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-zero-with-anchor.json"
mutate "$CLAIM_MULTI" "$TMP/claim-duplicate-anchor.json" '
  .authenticated_anchors += [.authenticated_anchors[0]]'
reject 'duplicate authenticated anchor descriptors are rejected' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-duplicate-anchor.json"
mutate "$CLAIM" "$TMP/claim-removed-outpoint-array.json" '
  .removed_wallet_outpoints=[[.removed_wallet_outpoints[0].txid,
    .removed_wallet_outpoints[0].vout]]'
reject 'removed outpoints require canonical txid-vout descriptors' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-removed-outpoint-array.json"
mutate "$CLAIM" "$TMP/claim-duplicate-removed-outpoint.json" '
  .removed_wallet_outpoints += [.removed_wallet_outpoints[0]]'
reject 'duplicate removed outpoint descriptors are rejected' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-duplicate-removed-outpoint.json"
mutate "$CLAIM" "$TMP/claim-added-outpoint.json" '
  .added_wallet_outpoints=[.removed_wallet_outpoints[0]]'
reject 'candidate phase cannot add a wallet outpoint' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-added-outpoint.json"
mutate "$CLAIM" "$TMP/claim-retained-history.json" \
    '.retired_claim_objects=9 | .retired_components=3'
ok 'global retired history does not invalidate a non-retired candidate family' \
    hotfix_phase_a_claim_proof_file_is_valid "$TMP/claim-retained-history.json"

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
mutate "$CERT" "$TMP/cert-zero-created.json" \
    '.candidate_created_qqsproof_txids=[] | .authenticated_anchors=[]'
ok 'zero-created REWIND_SAFE certificate accepted' \
    hotfix_rewind_safe_file_is_valid "$TMP/cert-zero-created.json" "$NONCE"
for filter in '.result="UNKNOWN"' '.candidate_stopped=false' '.pow_worker_joined=false' \
    '.pos_disabled_continuously=false' '.observer_absence_verified=false' \
    '.unknown_or_ambiguous=true' '.coinstake_or_wallet_escape_detected=true' \
    '.promotion_marker_absent=false' '.snapshots_held=false' \
    '.observation_sample_count=2' '.authenticated_anchors=[]' \
    '.authored_components_sha256="bad"'; do
    mutate "$CERT" "$TMP/m.json" "$filter"
    reject "certificate hostile mutation ${filter}" hotfix_rewind_safe_file_is_valid "$TMP/m.json" "$NONCE"
done

mutate "$CERT" "$TMP/cert-duplicate-candidate.json" '
  .candidate_created_qqsproof_txids += [.candidate_created_qqsproof_txids[0]]'
reject 'REWIND_SAFE rejects duplicate candidate transaction identities' \
    hotfix_rewind_safe_file_is_valid "$TMP/cert-duplicate-candidate.json" "$NONCE"
mutate "$CERT" "$TMP/cert-more-candidates-than-observations.json" '
  .observation_sample_count=3 |
  .candidate_created_qqsproof_txids=[
    ("1"*64),("2"*64),("3"*64),("4"*64),("5"*64)]'
ok 'REWIND_SAFE does not cap created txids at the observation count' \
    hotfix_rewind_safe_file_is_valid \
        "$TMP/cert-more-candidates-than-observations.json" "$NONCE"
mutate "$CERT" "$TMP/cert-duplicate-anchor.json" '
  .authenticated_anchors += [.authenticated_anchors[0]]'
reject 'REWIND_SAFE rejects duplicate authenticated anchors' \
    hotfix_rewind_safe_file_is_valid "$TMP/cert-duplicate-anchor.json" "$NONCE"

ok 'base hard-quarantine catch-up accepted' hotfix_base_catchup_file_is_valid "$CATCHUP" "$NONCE"
mutate "$CATCHUP" "$TMP/catchup-zero-anchor.json" '.authenticated_anchors=[]'
ok 'base catch-up accepts an exact empty authenticated-anchor set' \
    hotfix_base_catchup_file_is_valid "$TMP/catchup-zero-anchor.json" "$NONCE"
mutate "$CATCHUP" "$TMP/catchup-multiple-anchors.json" '
  .authenticated_anchors += [{
    txid:("4"*64),vout:1,unspent:true,txout:{confirmations:50,coinbase:false}}] |
  .authenticated_anchors |= sort_by(.txid,.vout)'
ok 'base catch-up accepts multiple canonical authenticated anchors' \
    hotfix_base_catchup_file_is_valid "$TMP/catchup-multiple-anchors.json" "$NONCE"
for filter in '.wallet_locked=false' '.pos_enabled=true' '.pow_enabled=true' \
    '.walletbroadcast=true' '.chain.initialblockdownload=true' \
    '.chainwork_at_least_phase_a=false' \
    '.terminal_tip_active=false|.terminal_tip_superseded_by_greater_work=false' \
    '.wallet.scanning=true' '.wallet_processed_tip_current=false' \
    '.authenticated_anchors[0].unspent=false' \
    '.authenticated_anchors_evidence_sha256="bad"' \
    '.authenticated_anchors_unspent=false' '.observer_anchors_unspent=false'; do
    mutate "$CATCHUP" "$TMP/m.json" "$filter"
    reject "catch-up hostile mutation ${filter}" hotfix_base_catchup_file_is_valid "$TMP/m.json" "$NONCE"
done
mutate "$CATCHUP" "$TMP/catchup-duplicate-anchor.json" '
  .authenticated_anchors += [.authenticated_anchors[0]]'
reject 'base catch-up rejects duplicate authenticated anchors' \
    hotfix_base_catchup_file_is_valid "$TMP/catchup-duplicate-anchor.json" "$NONCE"
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
    '.wallet_chain_synchronized_before_unlock=false' \
    '.core_native_pos_intent_configured=false' '.core_native_pow_intent_configured=false' \
    '.locked_pos_zero_work_observed=false' '.locked_pow_zero_work_observed=false' \
    '.normal_unlock_only_resume_observed=false' '.repair_enable_rpcs_used=true' \
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
# shellcheck disable=SC2016 # These are intentional child-shell fixture bodies; $1 expands there.
ok 'Phase-B starts with Core-native PoS and regular-PoW intent in exact source order' \
    /bin/bash -c '
      got=$(sed -n "/^[[:space:]]*command:/,/^EOF/p" "$1" |
        grep -E "^[[:space:]]+- -(walletbroadcast|autostartstaking|powmining|powminingthreads|powminingcpu)=" |
        sed "s/^[[:space:]]*- //" | paste -sd " " -)
      expected="-walletbroadcast=1 -autostartstaking=1 -powmining=1 -powminingthreads=1 -powminingcpu=1"
      [[ "$got" == "$expected" ]]
    ' _ "$PHASE_B"
# shellcheck disable=SC2016 # $1 expands only in the isolated child shell.
ok 'Phase-B resumes Core-native workers through normal unlock without repair-enable RPCs' \
    /bin/bash -c '
      grep -Fq "run_unlock_helper || fail" "$1" &&
        ! grep -Eq "rpc[[:space:]]+(staking[[:space:]]+true|setpowmining[[:space:]]+true)" "$1"
    ' _ "$PHASE_B"
# shellcheck disable=SC2016 # The phase paths are passed to the isolated child shell.
ok 'both phase producers bind verbose mempool cuts and the exact liveness bound' \
    /bin/bash -c '
      for file in "$1" "$2"; do
        grep -Fq "getrawmempool true" "$file" &&
          grep -Fq "same_tip_or_submit_no_progress_transition_budget:1" "$file" || exit 1
      done
    ' _ "$PHASE_A" "$PHASE_B"
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
ok 'Core source audit checkout is the exact signed final H, parent, and tree' /bin/bash -c '
  [[ "$(git -C "$1" rev-parse HEAD)" == "$2" &&
     "$(git -C "$1" rev-parse "HEAD^{tree}")" == "$3" &&
     "$(git -C "$1" rev-parse HEAD^)" == "$4" &&
     "$(git -C "$1" show -s --format=%G? HEAD)" == G &&
     "$(git -C "$1" show -s --format=%GF HEAD)" == "$5" &&
     -z "$(git -C "$1" status --porcelain=v1)" ]]
' _ "$TEST_CORE_SOURCE_ROOT" "$TEST_CORE_AUDIT_SOURCE_SHA" \
    "$TEST_CORE_AUDIT_SOURCE_TREE" "$TEST_CORE_AUDIT_SOURCE_PARENT" \
    "$TEST_CORE_AUDIT_SIGNING_FINGERPRINT"
# shellcheck disable=SC2016 # Exact signed-H source predicates are audited in the child.
ok 'Core source binds QQP4 receipt fields to the next-block family exception' \
    /bin/bash -c '
  rpc="$1/src/rpc/blockchain.cpp"
  gate="$1/src/wallet/shadow_pow_claim_recovery.cpp"
  grep -Fq "obj.pushKV(\"bestblock\"" "$rpc" &&
  grep -Fq "obj.pushKV(\"height\"" "$rpc" &&
  grep -Fq "obj.pushKV(\"qqp4_activation_disabled\", qqp4_disabled)" "$rpc" &&
  grep -Fq "obj.pushKV(\"qqp4_activation_height\"" "$rpc" &&
  grep -Fq "obj.pushKV(\"qqp4_active\"" "$rpc" &&
  grep -Fq "obj.pushKV(\"qqp4_active_next_block\"," "$rpc" &&
  grep -Fq "inventory.active_height + 1" "$gate" &&
  grep -Fq "node.proof_version == 2 || node.proof_version == 3" "$gate" &&
  grep -Fq "ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION" "$gate"
' _ "$TEST_CORE_SOURCE_ROOT"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Core source confirms -staking hard gate' /bin/bash -c '
  grep -R "GetBoolArg(\"-staking\"" "$1/src" >/dev/null &&
  grep -R "CanStake" "$1/src/node" >/dev/null
' _ "$TEST_CORE_SOURCE_ROOT"
# shellcheck disable=SC2016 # Intentional child-shell fixture; $1 expands there.
ok 'Core source confirms blocksonly does not remove RPC relay risk' /bin/bash -c '
  grep -R -- "-blocksonly" "$1/src/init.cpp" "$1/src/wallet/init.cpp" >/dev/null &&
  grep -R "IgnoresIncomingTxs" "$1/src" >/dev/null
' _ "$TEST_CORE_SOURCE_ROOT"

prepare_fixture_verifier
reject 'verifier rejects unknown mode' /bin/bash "$FIXTURE_VERIFIER" unknown "$TMP"
reject 'verifier rejects missing evidence root' \
    /bin/bash "$FIXTURE_VERIFIER" phase-a-final "$TMP/missing"

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

BENIGN_A_EXTERNAL="$TMP/evidence-benign-a-external-watchonly-receive"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_EXTERNAL"
EXTERNAL_A_TXID=$(hex64 88)
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$BENIGN_A_EXTERNAL/candidate-final-wallet-transactions.json" \
  --arg txid "$EXTERNAL_A_TXID" '. + [{txid:$txid,vout:0,address:"Qwatch",
    category:"receive",amount:2,confirmations:0,abandoned:false,involvesWatchonly:true}] |
    sort_by(.txid,.vout,.category)'
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$BENIGN_A_EXTERNAL/candidate-external-receive-evidence.json" \
  --arg txid "$EXTERNAL_A_TXID" '
  .final_wallet_txids += [$txid] | .final_wallet_txids |= (sort|unique) |
  .new_wallet_txids += [$txid] | .new_wallet_txids |= (sort|unique) |
  .external_receive_txids=[$txid] |
  .records=[{txid:$txid,classification:"external_receive",confirmation_state:"unconfirmed",
    gettransaction_response:{txid:$txid,hex:"aa",decoded:{txid:$txid},amount:2,
      confirmations:0,involvesWatchonly:true,
      details:[{txid:$txid,vout:0,address:"Qwatch",category:"receive",amount:2,
        confirmations:0,abandoned:false,involvesWatchonly:true}]},
    recovery_matches:[],recovery_match_count:0,getblock_response:null,
    getblockhash_response:null,active_chain_bound:false,unconfirmed_recovery_bound:true}]'
# shellcheck disable=SC2016 # $txid and $external are jq variables.
mutate_json_in_place "$BENIGN_A_EXTERNAL/phase-a-claim-proof.json" \
  --arg txid "$EXTERNAL_A_TXID" \
  --arg external "$(sha_file "$BENIGN_A_EXTERNAL/candidate-external-receive-evidence.json")" '
  .external_receive_txids=[$txid] | .external_receive_evidence_sha256=$external'
reseal_phase_a_pre_fixture "$BENIGN_A_EXTERNAL"
ok 'resealed Phase-A accepts an authenticated unconfirmed watch-only external receive' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_EXTERNAL"

BENIGN_A_EXTERNAL_CONFIRMED="$TMP/evidence-benign-a-confirmed-external-receive"
clone_fixture_tree "$BENIGN_A_EXTERNAL" "$BENIGN_A_EXTERNAL_CONFIRMED"
# shellcheck disable=SC2016 # $txid and $tip are jq variables.
mutate_json_in_place \
  "$BENIGN_A_EXTERNAL_CONFIRMED/candidate-final-wallet-transactions.json" \
  --arg txid "$EXTERNAL_A_TXID" --arg tip "$TIP4" \
  'map(if .txid==$txid then .confirmations=1 | .blockhash=$tip else . end)'
# shellcheck disable=SC2016 # $txid and $tip are jq variables.
mutate_json_in_place \
  "$BENIGN_A_EXTERNAL_CONFIRMED/candidate-external-receive-evidence.json" \
  --arg txid "$EXTERNAL_A_TXID" --arg tip "$TIP4" '
  .records[0] |= (.confirmation_state="confirmed_active_chain" |
    .gettransaction_response.confirmations=1 |
    .gettransaction_response.blockhash=$tip |
    .gettransaction_response.blockheight=104 |
    .gettransaction_response.blockindex=0 |
    .gettransaction_response.details[0].confirmations=1 |
    .gettransaction_response.details[0].blockhash=$tip |
    .getblock_response={hash:$tip,height:104,confirmations:1,tx:[$txid]} |
    .getblockhash_response=$tip | .active_chain_bound=true |
    .unconfirmed_recovery_bound=false)'
# shellcheck disable=SC2016 # $external is a jq variable.
mutate_json_in_place "$BENIGN_A_EXTERNAL_CONFIRMED/phase-a-claim-proof.json" \
  --arg external "$(sha_file "$BENIGN_A_EXTERNAL_CONFIRMED/candidate-external-receive-evidence.json")" \
  '.external_receive_evidence_sha256=$external'
reseal_phase_a_pre_fixture "$BENIGN_A_EXTERNAL_CONFIRMED"
ok 'resealed Phase-A accepts a confirmed external receive with active-block membership' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_EXTERNAL_CONFIRMED"

HOSTILE_A_EXTERNAL_SEND="$TMP/evidence-hostile-a-external-send-row"
clone_fixture_tree "$BENIGN_A_EXTERNAL" "$HOSTILE_A_EXTERNAL_SEND"
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$HOSTILE_A_EXTERNAL_SEND/candidate-final-wallet-transactions.json" \
  --arg txid "$EXTERNAL_A_TXID" \
  'map(if .txid==$txid then .category="send" | .fee=0 else . end)'
reseal_phase_a_pre_fixture "$HOSTILE_A_EXTERNAL_SEND"
reject 'resealed Phase-A external receive cannot hide a send/debit wallet row' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_EXTERNAL_SEND"

BENIGN_A_METADATA="$TMP/evidence-benign-a-wallet-metadata-reclassification"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_METADATA"
# shellcheck disable=SC2016 # $anchor is a jq variable.
mutate_json_in_place "$BENIGN_A_METADATA/candidate-final-wallet-transactions.json" \
    --arg anchor "$ANCHOR" '
    map(if .txid == $anchor then
      .category="immature" | .address="reclassified" | .amount=999 |
      .confirmations=101 | .comment="candidate-native metadata"
    else . end)'
reseal_phase_a_pre_fixture "$BENIGN_A_METADATA"
ok 'resealed Phase-A accepts baseline wallet metadata reclassification with txid authority intact' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_METADATA"

HOSTILE_A_ABANDONED_BASELINE="$TMP/evidence-hostile-a-abandoned-baseline"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_ABANDONED_BASELINE"
# shellcheck disable=SC2016 # $anchor is a jq variable.
mutate_json_in_place \
    "$HOSTILE_A_ABANDONED_BASELINE/candidate-final-wallet-transactions.json" \
    --arg anchor "$ANCHOR" 'map(if .txid == $anchor then .abandoned=true else . end)'
reseal_phase_a_pre_fixture "$HOSTILE_A_ABANDONED_BASELINE"
ok 'resealed Phase-A permits startup normalization of a preserved baseline transaction status' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_ABANDONED_BASELINE"

HOSTILE_A_NEW_RESOLUTION="$TMP/evidence-hostile-a-new-fee-recovery-transaction"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_NEW_RESOLUTION"
NEW_RESOLUTION_TXID=$(hex64 62)
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place \
    "$HOSTILE_A_NEW_RESOLUTION/candidate-final-wallet-transactions.json" \
    --arg txid "$NEW_RESOLUTION_TXID" '. + [{txid:$txid,category:"send",amount:-1,
      fee:-0.01,confirmations:0,abandoned:false,qq_shadow_pow_resolution_schema:"1"}]'
jq -S -n --arg txid "$NEW_RESOLUTION_TXID" '[$txid]' \
    >"$HOSTILE_A_NEW_RESOLUTION/candidate-final-resolution-txids.json"
reseal_phase_a_pre_fixture "$HOSTILE_A_NEW_RESOLUTION"
reject 'resealed Phase-A rejects an actual new fee-bearing recovery transaction' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_NEW_RESOLUTION"

for marker in qq_shadow_pow_legacy_cleanup_quarantine qq_auto_shadow_stale \
    qq_manual_shadow_abandon qq_reorg_shadow_resubmit; do
    HOSTILE_A_REPAIR_MARKER="$TMP/evidence-hostile-a-repair-marker-${marker}"
    clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_REPAIR_MARKER"
    # shellcheck disable=SC2016 # $txid and $marker are jq variables.
    mutate_json_in_place \
        "$HOSTILE_A_REPAIR_MARKER/candidate-final-wallet-transactions.json" \
        --arg txid "$CLAIM4" --arg marker "$marker" \
        'map(if .txid==$txid then .[$marker]="1" else . end)'
    reseal_phase_a_pre_fixture "$HOSTILE_A_REPAIR_MARKER"
    reject "resealed Phase-A cannot classify a repair-marked authored row ${marker}" \
        run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_REPAIR_MARKER"
done

HOSTILE_CORE_RUN="$TMP/evidence-hostile-core-run"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_RUN"
mutate_core_ci_fixture "$HOSTILE_CORE_RUN" ".run_id=$((HOTFIX_EXPECTED_CORE_CI_RUN_ID - 1))"
reject 'resealed Core-CI evidence rejects a different successful run' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_CORE_RUN"

HOSTILE_CORE_PENDING="$TMP/evidence-hostile-core-pending"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_CORE_PENDING"
mutate_core_ci_fixture "$HOSTILE_CORE_PENDING" '.status="in_progress" | .conclusion=null'
reject 'resealed Core-CI evidence cannot authorize while pending' \
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

HOSTILE_A_DESTROY_MISSING="$TMP/evidence-hostile-a-destroy-missing-row-evidence"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_DESTROY_MISSING"
rm "$HOSTILE_A_DESTROY_MISSING/base-destroy-recheck-03-observers.jsonl"
reseal_phase_a_final_fixture "$HOSTILE_A_DESTROY_MISSING"
reject 'resealed Phase-A destroy ledger rejects missing immutable row evidence' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_DESTROY_MISSING"

HOSTILE_A_DESTROY_STAGE="$TMP/evidence-hostile-a-destroy-stage-reorder"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_DESTROY_STAGE"
mutate_jsonl_in_place "$HOSTILE_A_DESTROY_STAGE/snapshot-destroy-authority-rechecks.jsonl" \
    '.[1].stage="before-destroy"'
reseal_phase_a_final_fixture "$HOSTILE_A_DESTROY_STAGE"
reject 'resealed Phase-A destroy ledger rejects reordered mutation stages' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_DESTROY_STAGE"

HOSTILE_A_DESTROY_OBSERVER="$TMP/evidence-hostile-a-destroy-observer-mempool"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_DESTROY_OBSERVER"
mutate_jsonl_in_place "$HOSTILE_A_DESTROY_OBSERVER/base-destroy-recheck-04-observers.jsonl" \
    '.[0].mempool=["eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'
mutate_jsonl_in_place "$HOSTILE_A_DESTROY_OBSERVER/snapshot-destroy-authority-rechecks.jsonl" \
    '.[3].observer_cut_sha256="'"$(sha_file \
      "$HOSTILE_A_DESTROY_OBSERVER/base-destroy-recheck-04-observers.jsonl")"'"'
reseal_phase_a_final_fixture "$HOSTILE_A_DESTROY_OBSERVER"
reject 'resealed Phase-A destroy ledger rejects observer candidate-txid visibility' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_DESTROY_OBSERVER"

HOSTILE_A_DESTROY_REPLAY="$TMP/evidence-hostile-a-destroy-observer-replay"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_DESTROY_REPLAY"
cp "$HOSTILE_A_DESTROY_REPLAY/base-destroy-recheck-02-observers.jsonl" \
    "$HOSTILE_A_DESTROY_REPLAY/base-destroy-recheck-03-observers.jsonl"
mutate_jsonl_in_place "$HOSTILE_A_DESTROY_REPLAY/snapshot-destroy-authority-rechecks.jsonl" \
    '.[2].observer_cut_sha256="'"$(sha_file \
      "$HOSTILE_A_DESTROY_REPLAY/base-destroy-recheck-03-observers.jsonl")"'"'
reseal_phase_a_final_fixture "$HOSTILE_A_DESTROY_REPLAY"
reject 'resealed Phase-A destroy ledger rejects cross-stage observer replay' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_DESTROY_REPLAY"

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
ok 'Phase-A restored baseline permits chain-derived recovery-counter drift' \
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
ok 'Phase-B final envelope requires active candidate PoW' \
    hotfix_phase_b_final_envelope_file_is_valid \
        "$EVIDENCE_B_FINAL/phase-b-final-envelope.json" active \
        "$EVIDENCE_B_FINAL/phase-b-wallet-delta.json" \
        "$EVIDENCE_B_FINAL/phase-b-wallet-delta-raw.json" \
        "$EVIDENCE_B_FINAL/candidate-chain-wallet-synchronized.json" \
        "$EVIDENCE_B_FINAL/candidate-locked-resolution-txids.json" \
        "$EVIDENCE_B_FINAL/candidate-final-recovery.json" \
        "$EVIDENCE_B_FINAL/candidate-final-resolution-txids.json" \
        "$EVIDENCE_B_FINAL/baseline-wallet-resolution-txids.json" \
        "$EVIDENCE_B_FINAL/baseline-wallet-resolution-raw.json" \
        "$EVIDENCE_B_FINAL/candidate-locked-resolution-raw.json" \
        "$EVIDENCE_B_FINAL/candidate-final-resolution-raw.json" \
        "$EVIDENCE_B_FINAL/candidate-final-payout-address.json" \
        "$EVIDENCE_B_FINAL/baseline-quantum.json" \
        "$EVIDENCE_B_FINAL/candidate-final-quantum.json"
reject 'Phase-B final envelope cannot certify disabled candidate PoW' \
    hotfix_phase_b_final_envelope_file_is_valid \
        "$EVIDENCE_B_FINAL/phase-b-final-envelope.json" off

HOSTILE_B_QQP4_FINAL_SCHEDULE="$TMP/evidence-hostile-b-qqp4-final-schedule"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_QQP4_FINAL_SCHEDULE"
goldrush_state_json "$TIP4" 104 false 105 \
    >"$HOSTILE_B_QQP4_FINAL_SCHEDULE/candidate-final-goldrush-state.json"
# shellcheck disable=SC2016 # $goldrush and $goldrush_sha are jq variables.
mutate_json_in_place "$HOSTILE_B_QQP4_FINAL_SCHEDULE/phase-b-final-envelope.json" \
    --slurpfile goldrush \
      "$HOSTILE_B_QQP4_FINAL_SCHEDULE/candidate-final-goldrush-state.json" \
    --arg goldrush_sha "$(sha_file \
      "$HOSTILE_B_QQP4_FINAL_SCHEDULE/candidate-final-goldrush-state.json")" '
  .goldrush_state=$goldrush[0] |
  .candidate_final_goldrush_state_sha256=$goldrush_sha
'
reseal_phase_b_fixture "$HOSTILE_B_QQP4_FINAL_SCHEDULE"
reject 'Phase-B full verifier rejects final QQP4 schedule drift from baseline and progress' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_QQP4_FINAL_SCHEDULE"

BENIGN_B_BASELINE_POW_OFF="$TMP/evidence-benign-b-baseline-pow-off"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_BASELINE_POW_OFF"
mutate_json_in_place "$BENIGN_B_BASELINE_POW_OFF/baseline-pow.json" '.enabled=false'
reseal_phase_b_fixture "$BENIGN_B_BASELINE_POW_OFF"
ok 'Phase-B enables and proves candidate PoW when immutable v30.1.4 PoW was off' \
    run_fixture_verifier phase-b-final "$BENIGN_B_BASELINE_POW_OFF"

EMPTY_CONFIGURED_PAYOUT="$TMP/phase-b-empty-configured-payout"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$EMPTY_CONFIGURED_PAYOUT"
mutate_json_in_place "$EMPTY_CONFIGURED_PAYOUT/baseline-pow.json" '.payout_address=""'
mutate_json_in_place "$EMPTY_CONFIGURED_PAYOUT/baseline-precondition.json" \
    '.payout_address="" | .payout_owned=false'
printf 'null\n' >"$EMPTY_CONFIGURED_PAYOUT/baseline-payout-address.json"
ok 'Phase-B baseline accepts an empty configured-future payout' \
    hotfix_phase_b_baseline_bundle_is_valid "$EMPTY_CONFIGURED_PAYOUT"
mutate "$EMPTY_CONFIGURED_PAYOUT/baseline-precondition.json" "$TMP/payout-owned.json" \
    '.payout_owned=true'
cp "$TMP/payout-owned.json" "$EMPTY_CONFIGURED_PAYOUT/baseline-precondition.json"
reject 'empty configured-future payout cannot claim address ownership' \
    hotfix_phase_b_baseline_bundle_is_valid "$EMPTY_CONFIGURED_PAYOUT"
CONFIGURED_PAYOUT_UNOWNED="$TMP/phase-b-configured-payout-unowned"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$CONFIGURED_PAYOUT_UNOWNED"
mutate_json_in_place "$CONFIGURED_PAYOUT_UNOWNED/baseline-precondition.json" \
    '.payout_owned=false'
reject 'configured payout still requires exact wallet ownership' \
    hotfix_phase_b_baseline_bundle_is_valid "$CONFIGURED_PAYOUT_UNOWNED"

NAMED_WALLET_B="$TMP/phase-b-named-wallet"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$NAMED_WALLET_B"
mutate_json_in_place "$NAMED_WALLET_B/baseline-wallet.json" \
    '.walletname="default_wallet"'
mutate_json_in_place "$NAMED_WALLET_B/baseline-loaded-wallets.json" \
    '.[0]="default_wallet"'
mutate_json_in_place "$NAMED_WALLET_B/baseline-precondition.json" \
    '.exact_loaded_wallets=["default_wallet"]'
ok 'Phase-B baseline binds an exact nonempty wallet name' \
    hotfix_phase_b_baseline_bundle_is_valid "$NAMED_WALLET_B"
mutate_json_in_place "$NAMED_WALLET_B/candidate-final-wallet.json" \
    '.walletname="default_wallet"'
mutate_json_in_place "$NAMED_WALLET_B/candidate-final-loaded-wallets.json" \
    '.[0]="default_wallet"'
mutate_json_in_place "$NAMED_WALLET_B/candidate-chain-wallet-synchronized.json" \
    '.wallet.walletname="default_wallet" | .loaded_wallets=["default_wallet"]'
NAMED_LOCKED_SYNC_SHA=$(sha_file \
    "$NAMED_WALLET_B/candidate-chain-wallet-synchronized.json")
# shellcheck disable=SC2016 # $locked is a jq variable.
mutate_json_in_place "$NAMED_WALLET_B/phase-b-final-envelope.json" \
    --arg locked "$NAMED_LOCKED_SYNC_SHA" '
  .wallet.walletname="default_wallet" | .loaded_wallets=["default_wallet"] |
  .exact_loaded_wallets=["default_wallet"] |
  .candidate_locked_sync_sha256=$locked'
ok 'Phase-B final envelope preserves the exact named wallet identity' \
    hotfix_phase_b_final_envelope_file_is_valid \
        "$NAMED_WALLET_B/phase-b-final-envelope.json" active \
        "$NAMED_WALLET_B/phase-b-wallet-delta.json" \
        "$NAMED_WALLET_B/phase-b-wallet-delta-raw.json" \
        "$NAMED_WALLET_B/candidate-chain-wallet-synchronized.json" \
        "$NAMED_WALLET_B/candidate-locked-resolution-txids.json" \
        "$NAMED_WALLET_B/candidate-final-recovery.json" \
        "$NAMED_WALLET_B/candidate-final-resolution-txids.json" \
        "$NAMED_WALLET_B/baseline-wallet-resolution-txids.json" \
        "$NAMED_WALLET_B/baseline-wallet-resolution-raw.json" \
        "$NAMED_WALLET_B/candidate-locked-resolution-raw.json" \
        "$NAMED_WALLET_B/candidate-final-resolution-raw.json" \
        "$NAMED_WALLET_B/candidate-final-payout-address.json" \
        "$NAMED_WALLET_B/baseline-quantum.json" \
        "$NAMED_WALLET_B/candidate-final-quantum.json"
mutate "$NAMED_WALLET_B/phase-b-final-envelope.json" "$TMP/wallet-name-drift.json" \
    '.loaded_wallets=["other_wallet"]'
reject 'Phase-B final envelope rejects loaded-wallet name drift' \
    hotfix_phase_b_final_envelope_file_is_valid "$TMP/wallet-name-drift.json" active
mutate "$NAMED_WALLET_B/phase-b-final-envelope.json" "$TMP/wallet-multiple.json" \
    '.loaded_wallets=["default_wallet","other_wallet"]'
reject 'Phase-B final envelope rejects multiple loaded wallets' \
    hotfix_phase_b_final_envelope_file_is_valid "$TMP/wallet-multiple.json" active
mutate "$NAMED_WALLET_B/phase-b-final-envelope.json" "$TMP/wallet-missing.json" \
    '.loaded_wallets=[]'
reject 'Phase-B final envelope rejects a missing loaded wallet' \
    hotfix_phase_b_final_envelope_file_is_valid "$TMP/wallet-missing.json" active

BENIGN_B_RETAINED_PAYOUT="$TMP/evidence-benign-b-retained-family-payout"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_RETAINED_PAYOUT"
mutate_json_in_place "$BENIGN_B_RETAINED_PAYOUT/candidate-final-wallet-transactions.json" '
  map(if .qq_synthetic_goldrush_payout?=="1" then .address="Qretained" else . end)'
mutate_json_in_place "$BENIGN_B_RETAINED_PAYOUT/phase-b-wallet-delta-raw.json" '
  .records |= map(if .class=="authenticated_qq_claim_payout" then
    .wallet_rows[].address="Qretained" |
    .gettransaction_response.details[].address="Qretained" |
    .gettransaction_response.decoded.vout[].scriptPubKey.address="Qretained" |
    .getshadowtransaction_response.address="Qretained"
  else . end)'
rebuild_phase_b_delta_summary "$BENIGN_B_RETAINED_PAYOUT"
reseal_phase_b_fixture "$BENIGN_B_RETAINED_PAYOUT"
ok 'resealed Phase-B retained-family payout need not equal configured-future payout' \
    run_fixture_verifier phase-b-final "$BENIGN_B_RETAINED_PAYOUT"

BENIGN_B_FOREIGN_SYNTHETIC="$TMP/evidence-benign-b-foreign-synthetic-credit"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_FOREIGN_SYNTHETIC"
FOREIGN_PAYOUT_SOURCE=$(hex64 70)
# shellcheck disable=SC2016 # $source is a jq variable.
mutate_json_in_place "$BENIGN_B_FOREIGN_SYNTHETIC/phase-b-wallet-delta-raw.json" \
    --arg source "$FOREIGN_PAYOUT_SOURCE" '
  .records |= map(if .class=="authenticated_qq_claim_payout" then
    .source_claim_txid=$source | .recovery_matches=[] | .prior_recovery_authority=[] |
    .getshadowtransaction_response.pow_claim_source.txid=$source |
    .getblock_response.tx[1]=$source
  else . end)'
rebuild_phase_b_delta_summary "$BENIGN_B_FOREIGN_SYNTHETIC"
reseal_phase_b_fixture "$BENIGN_B_FOREIGN_SYNTHETIC"
ok 'resealed Phase-B accepts an authentic foreign-source synthetic wallet credit' \
    run_fixture_verifier phase-b-final "$BENIGN_B_FOREIGN_SYNTHETIC"

BENIGN_B_QQP2_PAYOUT="$TMP/evidence-benign-b-qqp2-synthetic-credit"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_QQP2_PAYOUT"
mutate_json_in_place "$BENIGN_B_QQP2_PAYOUT/phase-b-wallet-delta-raw.json" '
  .records |= map(if .class=="authenticated_qq_claim_payout" then
    .getshadowtransaction_response.pow_claim_source |= (
      .proof_version=2 | .origin_bound=false | .input_bound=false |
      .claim_outpoint=null | .origin_height=0 | .origin_age=0 |
      .origin_previous_block_hash=null)
  else . end)'
rebuild_phase_b_delta_summary "$BENIGN_B_QQP2_PAYOUT"
reseal_phase_b_fixture "$BENIGN_B_QQP2_PAYOUT"
ok 'resealed Phase-B accepts the exact QQP2 synthetic source tuple' \
    run_fixture_verifier phase-b-final "$BENIGN_B_QQP2_PAYOUT"

BENIGN_B_CONFIRMED_RECEIVE="$TMP/evidence-benign-b-confirmed-external-receive"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_CONFIRMED_RECEIVE"
CONFIRMED_RECEIVE_BLOCK=$(hex64 71)
# shellcheck disable=SC2016 # $foreign and $block are jq variables.
mutate_json_in_place "$BENIGN_B_CONFIRMED_RECEIVE/candidate-final-wallet-transactions.json" \
    --arg foreign "$(printf 'd%.0s' {1..64})" --arg block "$CONFIRMED_RECEIVE_BLOCK" '
  map(if .txid==$foreign then .confirmations=1 | .blockhash=$block else . end)'
# shellcheck disable=SC2016 # $foreign is a jq variable.
mutate_json_in_place "$BENIGN_B_CONFIRMED_RECEIVE/candidate-final-recovery.json" \
    --arg foreign "$(printf 'd%.0s' {1..64})" '
  .component_details |= map(select((.nodes|map(.txid)|index($foreign))==null)) |
  .unanchored_claim_txids=[]'
# shellcheck disable=SC2016 # $foreign and $block are jq variables.
mutate_json_in_place "$BENIGN_B_CONFIRMED_RECEIVE/phase-b-wallet-delta-raw.json" \
    --arg foreign "$(printf 'd%.0s' {1..64})" --arg block "$CONFIRMED_RECEIVE_BLOCK" '
  .records |= map(if .class=="external_receive" then
    .blockhash=$block | .recovery_matches=[] |
    .wallet_rows |= map(.confirmations=1 | .blockhash=$block) |
    .gettransaction_response.confirmations=1 |
    .gettransaction_response.blockhash=$block |
    .gettransaction_response.details |= map(.confirmations=1 | .blockhash=$block) |
    .getblock_response={hash:$block,confirmations:1,height:104,tx:[$foreign]} |
    .getblockhash_response=$block
  else . end)'
rebind_phase_b_raw_recovery_matches "$BENIGN_B_CONFIRMED_RECEIVE"
rebuild_phase_b_delta_summary "$BENIGN_B_CONFIRMED_RECEIVE"
reseal_phase_b_fixture "$BENIGN_B_CONFIRMED_RECEIVE"
ok 'resealed Phase-B accepts an active-chain external receive without recovery inventory' \
    run_fixture_verifier phase-b-final "$BENIGN_B_CONFIRMED_RECEIVE"

BENIGN_B_CONFIRMED_AUTHORED="$TMP/evidence-benign-b-confirmed-disappeared-authored-claim"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_CONFIRMED_AUTHORED"
CONFIRMED_CLAIM_BLOCK=$(hex64 72)
CONFIRMED_CLAIM_ROW=$(make_claim_wallet_row "$CLAIM4" 3 "$CLAIM3" "$TIP4" | \
  jq --arg block "$CONFIRMED_CLAIM_BLOCK" \
    '.confirmations=1 | .blockhash=$block')
# shellcheck disable=SC2016 # jq variables are intentionally shell-quoted arguments.
mutate_json_in_place "$BENIGN_B_CONFIRMED_AUTHORED/candidate-final-wallet-transactions.json" \
    --arg old "$CLAIM1" --argjson row "$CONFIRMED_CLAIM_ROW" '
  (map(select(.txid!=$old)) + [$row]) | sort_by(.txid)'
# shellcheck disable=SC2016 # $head is a jq variable.
mutate_json_in_place "$BENIGN_B_CONFIRMED_AUTHORED/candidate-final-recovery.json" \
    --arg head "$CLAIM4" '
  .component_details[0] |= (
    .claim_txids |= map(select(.!=$head)) |
    .root_claim_txids |= map(select(.!=$head)) |
    .nodes |= map(select(.txid!=$head))) |
  .actionable_quarantined_claims=3 | .blocking_quarantined_claims=3 |
  .quarantined_claim_objects=3 | .raw_quarantined_claims=3 |
  .raw_claim_objects=4'
# shellcheck disable=SC2016 # $head is a jq variable.
mutate_json_in_place "$BENIGN_B_CONFIRMED_AUTHORED/candidate-final-pow.json" \
    --arg head "$CLAIM3" '
  .mining_gate_lineage_head_txid=$head | .mining_gate_family_claims=3 |
  .actionable_quarantined_claims=3 | .blocking_quarantined_claims=3 |
  .quarantined_claims=3 | .raw_quarantined_claims=3 | .unresolved_claims=3'
# shellcheck disable=SC2016 # jq variables are intentionally shell-quoted arguments.
mutate_json_in_place "$BENIGN_B_CONFIRMED_AUTHORED/phase-b-wallet-delta-raw.json" \
    --arg old "$CLAIM1" --arg txid "$CLAIM4" --arg block "$CONFIRMED_CLAIM_BLOCK" \
    --slurpfile final "$BENIGN_B_CONFIRMED_AUTHORED/candidate-final-wallet-transactions.json" '
  ($final[0][]|select(.txid==$txid)) as $row |
  .records |= map(if .class=="authenticated_qq_claim" then
    .txid=$txid | .wallet_rows=[$row] | .recovery_matches=[] |
    .blockhash=$block |
    .getblock_response={hash:$block,confirmations:1,height:104,tx:[$txid]} |
    .getblockhash_response=$block |
    .gettransaction_response=({txid:$txid,hex:"00",decoded:{txid:$txid},
      amount:-10,confirmations:1,blockhash:$block,details:[$row]} +
      ($row|with_entries(select(.key|startswith("qq_")))))
  else . end)'
rebind_phase_b_raw_recovery_matches "$BENIGN_B_CONFIRMED_AUTHORED"
rebuild_phase_b_delta_summary "$BENIGN_B_CONFIRMED_AUTHORED"
reseal_phase_b_fixture "$BENIGN_B_CONFIRMED_AUTHORED"
ok 'resealed Phase-B accepts a confirmed authored claim absent from final recovery' \
    run_fixture_verifier phase-b-final "$BENIGN_B_CONFIRMED_AUTHORED"

BENIGN_B_INTRINSIC_AUTHORED="$TMP/evidence-benign-b-intrinsic-confirmed-authored-claim"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_INTRINSIC_AUTHORED"
INTRINSIC_CLAIM=$(hex64 73)
INTRINSIC_BLOCK=$(hex64 74)
INTRINSIC_ROW=$(make_claim_wallet_row "$INTRINSIC_CLAIM" 0 "$HOTFIX_ZERO_TXID" "$TIP4" | \
  jq --arg txid "$INTRINSIC_CLAIM" --arg block "$INTRINSIC_BLOCK" '
    .qq_shadow_pow_lineage_root=$txid | .confirmations=1 | .blockhash=$block')
# shellcheck disable=SC2016 # $old and $row are jq variables.
mutate_json_in_place \
    "$BENIGN_B_INTRINSIC_AUTHORED/candidate-final-wallet-transactions.json" \
    --arg old "$CLAIM1" --argjson row "$INTRINSIC_ROW" '
  (map(select(.txid!=$old)) + [$row]) | sort_by(.txid)'
# shellcheck disable=SC2016 # $row is a jq variable.
mutate_json_in_place "$BENIGN_B_INTRINSIC_AUTHORED/phase-b-wallet-delta-raw.json" \
    --arg txid "$INTRINSIC_CLAIM" --arg block "$INTRINSIC_BLOCK" \
    --argjson row "$INTRINSIC_ROW" '
  .records |= map(if .class=="authenticated_qq_claim" then
    .txid=$txid | .wallet_rows=[$row] | .recovery_matches=[] |
    .prior_recovery_authority=[] | .blockhash=$block |
    .getblock_response={hash:$block,confirmations:1,height:104,tx:[$txid]} |
    .getblockhash_response=$block |
    .gettransaction_response=({txid:$txid,hex:"00",decoded:{txid:$txid},
      amount:-10,confirmations:1,blockhash:$block,details:[$row]} +
      ($row|with_entries(select(.key|startswith("qq_")))))
  else . end)'
rebind_phase_b_raw_recovery_matches "$BENIGN_B_INTRINSIC_AUTHORED"
rebuild_phase_b_delta_summary "$BENIGN_B_INTRINSIC_AUTHORED"
reseal_phase_b_fixture "$BENIGN_B_INTRINSIC_AUTHORED"
ok 'resealed Phase-B accepts an intrinsically authored active-chain claim with no recovery row' \
    run_fixture_verifier phase-b-final "$BENIGN_B_INTRINSIC_AUTHORED"

for intrinsic_spec in \
    "qq_shadow_pow_lineage_parent|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "qq_shadow_pow_lineage_ordinal|2" \
    "qq_shadow_pow_lineage_family|0000000000000000000000000000000000000000000000000000000000000000" \
    "qq_shadow_pow_legacy_cleanup_quarantine|1" \
    "qq_auto_shadow_stale|1" \
    "qq_manual_shadow_abandon|1" \
    "qq_reorg_shadow_resubmit|1"; do
    intrinsic_field=${intrinsic_spec%%|*}
    intrinsic_value=${intrinsic_spec#*|}
    HOSTILE_B_INTRINSIC="$TMP/evidence-hostile-b-intrinsic-${intrinsic_field}"
    clone_fixture_tree "$BENIGN_B_INTRINSIC_AUTHORED" "$HOSTILE_B_INTRINSIC"
    # shellcheck disable=SC2016 # $field and $value are jq variables.
    mutate_json_in_place "$HOSTILE_B_INTRINSIC/candidate-final-wallet-transactions.json" \
        --arg txid "$INTRINSIC_CLAIM" --arg field "$intrinsic_field" \
        --arg value "$intrinsic_value" '
      map(if .txid==$txid then .[$field]=$value else . end)'
    # shellcheck disable=SC2016 # $field and $value are jq variables.
    mutate_json_in_place "$HOSTILE_B_INTRINSIC/phase-b-wallet-delta-raw.json" \
        --arg field "$intrinsic_field" --arg value "$intrinsic_value" '
      .records |= map(if .class=="authenticated_qq_claim" then
        .gettransaction_response[$field]=$value |
        .wallet_rows |= map(.[$field]=$value)
      else . end)'
    rebuild_phase_b_delta_summary "$HOSTILE_B_INTRINSIC"
    reseal_phase_b_fixture "$HOSTILE_B_INTRINSIC"
    reject "intrinsic confirmed claim rejects descriptor forgery ${intrinsic_field}" \
        run_fixture_verifier phase-b-final "$HOSTILE_B_INTRINSIC"
done

for version in 2 3; do
    BENIGN_B_CONFIRMED_VERSION="$TMP/evidence-benign-b-confirmed-qqp${version}-claim"
    clone_fixture_tree "$BENIGN_B_CONFIRMED_AUTHORED" "$BENIGN_B_CONFIRMED_VERSION"
    if [[ "$version" == 2 ]]; then
        mutate_json_in_place "$BENIGN_B_CONFIRMED_VERSION/phase-b-progress.json" '
          .samples[].recovery.component_details[0].nodes |= map(
            .proof_version=2 | .proof_origin_bound=false | .proof_input_bound=false |
            .disposition="eligible" | .proof_may_revalidate_on_descendant=false)'
    else
        mutate_json_in_place "$BENIGN_B_CONFIRMED_VERSION/phase-b-progress.json" '
          .samples[].recovery.component_details[0].nodes |= map(
            .proof_version=3 | .proof_origin_bound=true | .proof_input_bound=false |
            .disposition="origin_expired" | .proof_may_revalidate_on_descendant=false)'
    fi
    rebind_phase_b_raw_recovery_matches "$BENIGN_B_CONFIRMED_VERSION"
    rebuild_phase_b_delta_summary "$BENIGN_B_CONFIRMED_VERSION"
    reseal_phase_b_fixture "$BENIGN_B_CONFIRMED_VERSION"
    ok "resealed Phase-B confirms a disappeared exact QQP${version} authored claim" \
        run_fixture_verifier phase-b-final "$BENIGN_B_CONFIRMED_VERSION"
done

BENIGN_B_COUNTER_DRIFT="$TMP/evidence-benign-b-candidate-counter-drift"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_COUNTER_DRIFT"
mutate_json_in_place "$BENIGN_B_COUNTER_DRIFT/candidate-final-recovery.json" '
  .confirmed_manual_resolutions=1 | .automatic_actions_in_window=2 |
  .automatic_fee_exposure_in_window=0.25 | .reconciled_descendant_claims=3 |
  .retired_claim_objects=4 | .retired_components=1 | .resolved_components=1'
reseal_phase_b_fixture "$BENIGN_B_COUNTER_DRIFT"
ok 'resealed Phase-B accepts benign candidate-native counter and retained-history drift' \
    run_fixture_verifier phase-b-final "$BENIGN_B_COUNTER_DRIFT"

HOSTILE_B_NEW_RESOLUTION="$TMP/evidence-hostile-b-new-resolution-identity"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_NEW_RESOLUTION"
NEW_PHASE_B_RESOLUTION_TXID=$(hex64 63)
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$HOSTILE_B_NEW_RESOLUTION/candidate-final-recovery.json" \
    --arg txid "$NEW_PHASE_B_RESOLUTION_TXID" '
  .component_details[0] |= (
    .nodes[0] as $template |
    .resolution_txids=[$txid] |
    .nodes += [($template | .txid=$txid | .kind="managed_resolution" |
      .quarantined=false | .resolution_metadata_valid=true)])'
reseal_phase_b_fixture "$HOSTILE_B_NEW_RESOLUTION"
reject 'resealed Phase-B rejects a new candidate-native resolution identity' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_NEW_RESOLUTION"

HOSTILE_B_NEW_FEE_WALLET="$TMP/evidence-hostile-b-new-fee-recovery-wallet-record"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_NEW_FEE_WALLET"
NEW_PHASE_B_FEE_TXID=$(hex64 64)
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place \
    "$HOSTILE_B_NEW_FEE_WALLET/candidate-final-wallet-transactions.json" \
    --arg txid "$NEW_PHASE_B_FEE_TXID" '. + [{txid:$txid,category:"send",amount:-1,
      fee:-0.01,confirmations:0,abandoned:false,qq_shadow_pow_cleanup_for:"fixture"}]'
reseal_phase_b_fixture "$HOSTILE_B_NEW_FEE_WALLET"
reject 'resealed Phase-B rejects a new fee-bearing cleanup wallet record' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_NEW_FEE_WALLET"

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

BENIGN_A_FINAL_METRICS="$TMP/evidence-benign-a-final-recovery-metrics"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_FINAL_METRICS"
mutate_json_in_place "$BENIGN_A_FINAL_METRICS/candidate-final-recovery-inventory.json" \
    '.confirmed_manual_resolutions=1'
cp "$BENIGN_A_FINAL_METRICS/candidate-final-recovery-inventory.json" \
    "$BENIGN_A_FINAL_METRICS/candidate-final-recovery-after.json"
reseal_phase_a_pre_fixture "$BENIGN_A_FINAL_METRICS"
ok 'resealed Phase-A accepts benign candidate-native recovery counter drift' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_FINAL_METRICS"

BENIGN_A_TERMINAL_RECOVERY_DRIFT="$TMP/evidence-benign-a-terminal-recovery-drift"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_TERMINAL_RECOVERY_DRIFT"
mutate_json_in_place \
    "$BENIGN_A_TERMINAL_RECOVERY_DRIFT/candidate-final-recovery-after.json" \
    '.component_details[0].nodes[0].disposition="eligible"'
reseal_phase_a_pre_fixture "$BENIGN_A_TERMINAL_RECOVERY_DRIFT"
ok 'same-cut audit component-detail drift does not redefine mining authority' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_TERMINAL_RECOVERY_DRIFT"

BENIGN_A_TERMINAL_FINGERPRINT_DRIFT="$TMP/evidence-benign-a-terminal-fingerprint-drift"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_TERMINAL_FINGERPRINT_DRIFT"
mutate_json_in_place "$BENIGN_A_TERMINAL_FINGERPRINT_DRIFT/candidate-final-pow-after.json" \
    '.mining_gate_candidate_state_fingerprint=("d"*64)'
reseal_phase_a_pre_fixture "$BENIGN_A_TERMINAL_FINGERPRINT_DRIFT"
ok 'same-cut candidate fingerprint drift does not redefine operational authority' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_TERMINAL_FINGERPRINT_DRIFT"

HOSTILE_A_TERMINAL_OPERATIONAL_DRIFT="$TMP/evidence-hostile-a-terminal-operational-drift"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_TERMINAL_OPERATIONAL_DRIFT"
mutate_json_in_place "$HOSTILE_A_TERMINAL_OPERATIONAL_DRIFT/candidate-final-pow-after.json" \
    '.mining_gate_eligible_claims=2'
reseal_phase_a_pre_fixture "$HOSTILE_A_TERMINAL_OPERATIONAL_DRIFT"
reject 'same-cut selected operational gate drift is rejected' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_TERMINAL_OPERATIONAL_DRIFT"

HOSTILE_A_QQP4_TERMINAL_SCHEDULE="$TMP/evidence-hostile-a-qqp4-terminal-schedule"
clone_fixture_tree "$EVIDENCE_A_PRE" "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE"
goldrush_state_json "$TIP4" 104 false 105 \
    >"$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-goldrush-state.json"
cp "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-goldrush-state.json" \
    "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-goldrush-state-after.json"
# shellcheck disable=SC2016 # $first and $second are jq variables.
mutate_json_in_place \
    "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-stable-cut.json" \
    --arg first "$(sha_file \
      "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-goldrush-state.json")" \
    --arg second "$(sha_file \
      "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-goldrush-state-after.json")" '
  .first_goldrush_state_sha256=$first |
  .second_goldrush_state_sha256=$second |
  .qqp4_schedule={qqp4_activation_disabled:false,qqp4_activation_height:105}
'
# shellcheck disable=SC2016 # $stable is a jq variable.
mutate_json_in_place "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/phase-a-claim-proof.json" \
    --arg stable "$(sha_file \
      "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE/candidate-final-stable-cut.json")" \
    '.final_stable_cut_sha256=$stable'
reseal_phase_a_pre_fixture "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE"
reject 'Phase-A full verifier rejects terminal QQP4 schedule drift from progress cuts' \
    run_fixture_verifier phase-a-pre-rewind "$HOSTILE_A_QQP4_TERMINAL_SCHEDULE"

BENIGN_A_RETAINED="$TMP/evidence-benign-a-retained-lineage"
clone_fixture_tree "$EVIDENCE_A_PRE" "$BENIGN_A_RETAINED"
mutate_json_in_place "$BENIGN_A_RETAINED/phase-a-claim-proof.json" '
  .retired_claim_objects=4 | .retired_components=1 |
  .candidate_retired_member_txids=.candidate_created_qqsproof_txids |
  .authored_components[].all_claims_zero_payment_retirable=true |
  .authored_components[].all_claims_expired_locally_retired=true |
  .authored_components[].newly_authored_members[].expired_locally_retired=true |
  .authored_components[0].newly_authored_members[0].abandoned=true |
  .abandoned_wallet_txids=[.authored_components[0].newly_authored_members[0].txid]
'
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$BENIGN_A_RETAINED/candidate-final-wallet-transactions.json" \
  --arg txid "$CLAIM1" 'map(if .txid==$txid then .abandoned=true else . end)'
mutate_json_in_place "$BENIGN_A_RETAINED/candidate-final-recovery-inventory.json" '
  .retired_claim_objects=4 | .retired_components=1 |
  .component_details[0].all_claims_zero_payment_retirable=true |
  .component_details[0].all_claims_expired_locally_retired=true |
  .component_details[0].nodes |= map(.expired_locally_retired=true) |
  .component_details[0].nodes[0].abandoned=true
'
cp "$BENIGN_A_RETAINED/candidate-final-recovery-inventory.json" \
    "$BENIGN_A_RETAINED/candidate-final-recovery-after.json"
jq -S '.authored_components' "$BENIGN_A_RETAINED/phase-a-claim-proof.json" \
    >"$BENIGN_A_RETAINED/candidate-authored-components.json"
reseal_phase_a_pre_fixture "$BENIGN_A_RETAINED"
ok 'resealed coherent retired and abandoned history remains non-authoritative telemetry' \
    run_fixture_verifier phase-a-pre-rewind "$BENIGN_A_RETAINED"

HOSTILE_A_FINAL="$TMP/evidence-hostile-a-final-catchup-cut"
clone_fixture_tree "$EVIDENCE_A_FINAL" "$HOSTILE_A_FINAL"
mutate_json_in_place "$HOSTILE_A_FINAL/base-catchup-chain-after.json" \
    '.bestblockhash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
reseal_phase_a_final_fixture "$HOSTILE_A_FINAL"
reject 'resealed Phase-A catch-up sample cannot forge the stable cut' \
    run_fixture_verifier phase-a-final "$HOSTILE_A_FINAL"

HOSTILE_B_COIN_RECOVERY="$TMP/evidence-hostile-b-coinstake-recovery"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_COIN_RECOVERY"
# shellcheck disable=SC2016 # $records and $matches are jq variables.
mutate_json_in_place "$HOSTILE_B_COIN_RECOVERY/phase-b-wallet-delta-raw.json" \
    '.records as $records |
     ($records[]|select(.class=="authenticated_qq_claim")|.recovery_matches) as $matches |
     .records |= map(if .class=="confirmed_coinstake" then .recovery_matches=$matches else . end)'
reseal_phase_b_fixture "$HOSTILE_B_COIN_RECOVERY"
reject 'resealed Phase-B coinstake cannot carry claim recovery matches' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_COIN_RECOVERY"

HOSTILE_B_COIN_CASE="$TMP/evidence-hostile-b-coinstake-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_COIN_CASE"
mutate_json_in_place "$HOSTILE_B_COIN_CASE/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="confirmed_coinstake" then
      .blockhash|=ascii_upcase | .getblock_response.hash|=ascii_upcase |
      .wallet_rows[].blockhash|=ascii_upcase else . end)'
reseal_phase_b_fixture "$HOSTILE_B_COIN_CASE"
reject 'resealed Phase-B coinstake uppercase blockhash is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_COIN_CASE"

HOSTILE_B_PAYOUT_CASE="$TMP/evidence-hostile-b-payout-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_PAYOUT_CASE"
mutate_json_in_place "$HOSTILE_B_PAYOUT_CASE/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim_payout" then
      .blockhash|=ascii_upcase | .wallet_rows[].blockhash|=ascii_upcase |
      .getshadowtransaction_response.base_anchor.blockhash|=ascii_upcase else . end)'
reseal_phase_b_fixture "$HOSTILE_B_PAYOUT_CASE"
reject 'resealed Phase-B payout uppercase blockhash is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_PAYOUT_CASE"

HOSTILE_B_SOURCE_CASE="$TMP/evidence-hostile-b-source-uppercase"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_SOURCE_CASE"
mutate_json_in_place "$HOSTILE_B_SOURCE_CASE/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim_payout" then
      .source_claim_txid|=ascii_upcase |
      .getshadowtransaction_response.pow_claim_source.txid|=ascii_upcase else . end)'
reseal_phase_b_fixture "$HOSTILE_B_SOURCE_CASE"
reject 'resealed Phase-B payout uppercase source claim txid is rejected' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_SOURCE_CASE"

HOSTILE_B_FAMILY="$TMP/evidence-hostile-b-claim-family"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_FAMILY"
mutate_json_in_place "$HOSTILE_B_FAMILY/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim" then
      .wallet_rows[0].qq_shadow_pow_lineage_family=
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      else . end)'
reseal_phase_b_fixture "$HOSTILE_B_FAMILY"
reject 'resealed Phase-B claim family must recompute from recovery evidence' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_FAMILY"

HOSTILE_B_PAYOUT_SOURCE="$TMP/evidence-hostile-b-payout-source"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_PAYOUT_SOURCE"
mutate_json_in_place "$HOSTILE_B_PAYOUT_SOURCE/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim_payout" then
      .source_claim_txid="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      else . end)'
reseal_phase_b_fixture "$HOSTILE_B_PAYOUT_SOURCE"
reject 'resealed Phase-B payout source identity must match getshadowtransaction' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_PAYOUT_SOURCE"

HOSTILE_B_ORIGIN="$TMP/evidence-hostile-b-origin-unbound"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_ORIGIN"
mutate_json_in_place "$HOSTILE_B_ORIGIN/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim" then
      .recovery_matches[0].node.proof_origin_bound=false else . end)'
reseal_phase_b_fixture "$HOSTILE_B_ORIGIN"
reject 'resealed Phase-B QQP4 claim must retain its exact origin-bound tuple' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_ORIGIN"

HOSTILE_B_INPUT="$TMP/evidence-hostile-b-input-unbound"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$HOSTILE_B_INPUT"
mutate_json_in_place "$HOSTILE_B_INPUT/phase-b-wallet-delta-raw.json" \
    '.records |= map(if .class=="authenticated_qq_claim" then
      .recovery_matches[0].node.proof_input_bound=false else . end)'
reseal_phase_b_fixture "$HOSTILE_B_INPUT"
reject 'resealed Phase-B claim must remain input-bound in raw recovery evidence' \
    run_fixture_verifier phase-b-final "$HOSTILE_B_INPUT"

BENIGN_B_RETAINED_STATUS="$TMP/evidence-benign-b-retained-status"
clone_fixture_tree "$EVIDENCE_B_FINAL" "$BENIGN_B_RETAINED_STATUS"
# shellcheck disable=SC2016 # $txid is a jq variable.
mutate_json_in_place "$BENIGN_B_RETAINED_STATUS/candidate-final-recovery.json" \
    --arg txid "$CLAIM1" '
      .retired_claim_objects=1 | .retired_components=1 |
      .component_details[0].all_claims_zero_payment_retirable=true |
      .component_details[0].all_claims_expired_locally_retired=true |
      .component_details[0].nodes |= map(
        if .txid==$txid then .expired_locally_retired=true | .abandoned=true else . end)'
rebind_phase_b_raw_recovery_matches "$BENIGN_B_RETAINED_STATUS"
reseal_phase_b_fixture "$BENIGN_B_RETAINED_STATUS"
ok 'resealed Phase-B retained retirement and abandonment status is non-authoritative telemetry' \
    run_fixture_verifier phase-b-final "$BENIGN_B_RETAINED_STATUS"

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
