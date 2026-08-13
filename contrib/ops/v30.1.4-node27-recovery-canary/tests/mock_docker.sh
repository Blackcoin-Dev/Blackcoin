#!/usr/bin/env bash
set -Eeuo pipefail

: "${MOCK_STATE_DIR:?}"
: "${MOCK_LOG:?}"

readonly CONTAINER='blackcoin-v4-gui-27'
readonly IMAGE_REF='qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly IMAGE_ID='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'
readonly CLAIM='2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d'
readonly ANCHOR='3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87'
readonly GENERATION='0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860'
readonly COMPONENT='b2264221895cea65509aa59e4de27a9b50958f1caee05b5302193544f3f8eb30'
readonly POST_COMPONENT='c2264221895cea65509aa59e4de27a9b50958f1caee05b5302193544f3f8eb30'
readonly PLAN='890067c186ce29d5752520cf2f61cb09a1d186f27cc784f10dbe94fc62c901d7'
readonly SIGNED_PLAN='990067c186ce29d5752520cf2f61cb09a1d186f27cc784f10dbe94fc62c901d7'
readonly TEMPLATE='38179653a85ee5f97470a59caba6ab2fd90214de164d1b4c59a45823af6abf23'
readonly RESOLUTION='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly TIP='3691d1d00b792e5950b285ed2ae3ae5b7058bbf5ede84ace99a89bf63c8e6375'
readonly PAYOUT='blk1s0hl7dsh5huajtwtx5ve65qjfwearvctxtm7c88t6vcc9m8qeam4s43es72'
readonly ANCHOR_SCRIPT='76a914085f283018f571e673c38efe7a648493ce3b499088ac'
readonly PAYOUT_SCRIPT='60207dffe6c2f4bf3b25b966a333aa0249767a3661665efd839d7a66305d9c19eeeb'
readonly SIGNED_HEX='0200000001000000000000000000000000000000000000000000000000000000000000000000000000015101ffffffff01b6b99c3a000000001976a914085f283018f571e673c38efe7a648493ce3b499088ac00000000'

scenario=${MOCK_SCENARIO:-success}
state=$(cat "$MOCK_STATE_DIR/state" 2>/dev/null || printf unsigned)

log()
{
    printf '%s\n' "$*" >> "$MOCK_LOG"
}

runtime_json()
{
    local ref=$IMAGE_REF service=node27 project=blackcoin30
    [[ "$scenario" != wrong-image ]] || ref='qqblackcoin/blackcoin-v4-gui@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    [[ "$scenario" != wrong-service ]] || service=node28
    [[ "$scenario" != wrong-project ]] || project=other
    jq -n --arg ref "$ref" --arg service "$service" --arg project "$project" --arg image "$IMAGE_ID" '
      [{Id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        Name:"/blackcoin-v4-gui-27",Image:$image,
        Config:{Image:$ref,Labels:{"com.docker.compose.service":$service,
          "com.docker.compose.project":$project}},
        State:{Running:true,Paused:false,Restarting:false,
          StartedAt:"2026-08-13T17:00:00.000000000Z",Health:{Status:"healthy"}}}]
    '
}

chain_json()
{
    jq -n --arg tip "$TIP" '{chain:"main",blocks:5991315,headers:5991315,
      bestblockhash:$tip,initialblockdownload:false,pruned:false,warnings:""}'
}

wallet_json()
{
    local txcount=1044
    [[ "$state" == unsigned ]] || txcount=1045
    jq -n --argjson txcount "$txcount" '{walletname:"",walletversion:169900,format:"sqlite",
      txcount:$txcount,private_keys_enabled:true,external_signer:false,scanning:false,
      unlocked_until:2000000000,unlocked_staking_only:false,keypoololdest:1783470558,
      keypoolsize:1000,keypoolsize_hd_internal:1000}'
}

mining_json()
{
    local enabled=true state_name=claim_quarantined hashrate=0 claims=4 blocking=1 actionable=1
    if [[ "$state" == final ]]; then
        state_name=hashing
        hashrate=42.5
        claims=5
        blocking=0
        actionable=0
    fi
    [[ "$scenario" != final-no-hash ]] || hashrate=0
    [[ "$scenario" != final-no-claim ]] || claims=4
    [[ "$scenario" != final-pow-disabled ]] || enabled=false
    jq -n --arg payout "$PAYOUT" --arg state "$state_name" --argjson enabled "$enabled" \
      --argjson hash "$hashrate" --argjson claims "$claims" --argjson blocking "$blocking" \
      --argjson actionable "$actionable" '
      {enabled:$enabled,autostart:false,allow_automatic_quantum_key_creation:false,
       state:$state,threads:1,cpu_percent:1,hashrate:$hash,claims_submitted:$claims,
       unresolved_claims:$blocking,live_claims:0,quarantined_claims:$blocking,
       raw_quarantined_claims:51,blocking_quarantined_claims:$blocking,
       actionable_quarantined_claims:$actionable,resolved_on_active_chain_claims:50,
       indeterminate_quarantined_claims:0,claim_components:44,
       pending_manual_resolutions:(if $blocking == 1 then (if $state == "claim_quarantined" then 0 else 1 end) else 0 end),
       pending_automatic_resolutions:0,claim_recovery_database_outcome_ambiguous:false,
       configured_stake_reserve_coins:1,claim_coins_after_stake_reserve:97,
       payout_address:$payout}
    '
}

claim_transaction_json()
{
    local confirmations=0 trusted=false
    if [[ "$state" == final && "$scenario" == final-claim-wins ]]; then
        confirmations=7
        trusted=true
    elif [[ "$state" == final ]]; then
        confirmations=-7
    fi
    jq -n --arg claim "$CLAIM" --arg anchor "$ANCHOR" --arg script "$ANCHOR_SCRIPT" \
      --argjson conf "$confirmations" --argjson trusted "$trusted" '
      {txid:$claim,confirmations:$conf,trusted:$trusted,
       details:[{category:"send",amount:0,label:"PoW Claim",vout:0,fee:-0.00028700,abandoned:false}],
       decoded:{txid:$claim,hash:$claim,version:2,size:287,vsize:287,weight:1148,locktime:0,
         vin:[{txid:$anchor,vout:0,scriptSig:{asm:"sig pubkey",hex:"abcd"},sequence:4294967293}],
         vout:[{value:9.83298230,n:0,scriptPubKey:{hex:$script,address:"B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct",type:"pubkeyhash"}},
           {value:0,n:1,scriptPubKey:{hex:"6a01ff",type:"nulldata"}}]}}
    '
}

resolution_decoded_json()
{
    local extra='false'
    [[ "$scenario" != extra-input ]] || extra=true
    jq -n --arg txid "$RESOLUTION" --arg anchor "$ANCHOR" --arg script "$ANCHOR_SCRIPT" \
      --argjson extra "$extra" '
      {txid:$txid,hash:$txid,version:2,size:191,vsize:191,weight:764,locktime:0,
       vin:([{txid:$anchor,vout:0,scriptSig:{asm:"sig pubkey",hex:"abcd"},sequence:4294967295}] +
         (if $extra then [{txid:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",vout:1,
           scriptSig:{asm:"sig",hex:"ab"},sequence:4294967295}] else [] end)),
       vout:[{value:9.83307830,n:0,scriptPubKey:{hex:$script,
         address:"B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct",type:"pubkeyhash"}}]}
    '
}

resolution_transaction_json()
{
    local confirmations=0 trusted=false
    if [[ "$state" == final && "$scenario" != final-claim-wins ]]; then
        confirmations=7
        [[ "$scenario" != final-five-conf ]] || confirmations=5
        trusted=true
    elif [[ "$state" == final ]]; then
        confirmations=-7
    fi
    jq -n --arg txid "$RESOLUTION" --argjson conf "$confirmations" --argjson trusted "$trusted" \
      --argjson decoded "$(resolution_decoded_json)" '
      {txid:$txid,confirmations:$conf,trusted:$trusted,
       details:[{category:"send",amount:-9.83307830,fee:-0.00019100,abandoned:false},
         {category:"receive",amount:9.83307830,abandoned:false}],decoded:$decoded}
    '
}

claim_node()
{
    jq -n --arg txid "$CLAIM" '{txid:$txid,kind:"claim",provenance:"explicit_authored",
      disposition:"unbound_proof_may_revalidate",proof_may_revalidate_on_descendant:true,
      active_chain_confirmed:false,in_mempool:false,quarantined:true,expected_shape:true,
      wallet_authored:true,abandoned:false,expired_locally_retired:false,stale_depth:9064,
      stale_depth_known:true,resolution_metadata_valid:false,resolution_relay_authorized:false}'
}

resolution_node()
{
    local relay=false in_mempool=false confirmed=false
    [[ "$state" != relayed && "$state" != final ]] || relay=true
    [[ "$state" != relayed ]] || in_mempool=true
    if [[ "$state" == final && "$scenario" != final-claim-wins ]]; then confirmed=true; fi
    jq -n --arg txid "$RESOLUTION" --argjson relay "$relay" --argjson mempool "$in_mempool" \
      --argjson confirmed "$confirmed" '
      {txid:$txid,kind:"managed_resolution",provenance:"explicit_authored",disposition:"unknown",
       proof_may_revalidate_on_descendant:false,active_chain_confirmed:$confirmed,
       in_mempool:$mempool,quarantined:false,expected_shape:true,wallet_authored:true,
       abandoned:false,expired_locally_retired:false,stale_depth:0,stale_depth_known:false,
       resolution_metadata_valid:true,resolution_relay_authorized:$relay}
    '
}

recovery_json()
{
    local classification=current_branch_ineligible pending=0 blocking=1 actionable=1
    local component=$COMPONENT tip=$TIP wallet_generation=114 resolution_txids='[]' nodes
    nodes=$(jq -n --argjson claim "$(claim_node)" '[$claim]')
    if [[ "$state" != unsigned ]]; then
        classification=resolution_pending
        pending=1
        component=$POST_COMPONENT
        wallet_generation=115
        resolution_txids=$(jq -n --arg txid "$RESOLUTION" '[$txid]')
        nodes=$(jq -n --argjson claim "$(claim_node)" --argjson resolution "$(resolution_node)" '[$claim,$resolution]')
    fi
    if [[ "$state" == final ]]; then
        classification=resolved_on_active_chain
        pending=0
        blocking=0
        actionable=0
    fi
    [[ "$scenario" != bad-component ]] || classification=indeterminate
    [[ "$scenario" != recovery-wrong-tip ]] || tip='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
    jq -n --arg tip "$tip" --arg anchor "$ANCHOR" --arg claim "$CLAIM" --arg script "$ANCHOR_SCRIPT" \
      --arg generation "$GENERATION" --arg component "$component" --arg classification "$classification" \
      --argjson wallet_generation "$wallet_generation" \
      --argjson pending "$pending" --argjson blocking "$blocking" --argjson actionable "$actionable" \
      --argjson resolution_txids "$resolution_txids" --argjson nodes "$nodes" '
      {policy:{mode:"unset"},policy_authoritative:true,chain_ready:true,
       database_outcome_ambiguous:false,active_tip:$tip,active_height:5991315,
       wallet_processed_tip:$tip,wallet_processed_height:5991315,wallet_generation:$wallet_generation,
       wallet_tip_matches:true,raw_quarantined_claims:51,
       blocking_quarantined_claims:$blocking,actionable_quarantined_claims:$actionable,
       resolved_on_active_chain_claims:50,indeterminate_quarantined_claims:0,
       components:44,raw_claim_objects:51,live_claim_objects:0,quarantined_claim_objects:51,
       blocking_components:$blocking,retired_claim_objects:0,retired_components:0,
       resolved_components:43,pending_manual_resolutions:$pending,pending_automatic_resolutions:0,
       confirmed_manual_resolutions:1,confirmed_automatic_resolutions:0,
       confirmed_resolution_fees:0.00019100,automatic_actions_in_window:0,
       automatic_fee_exposure_in_window:0,reconciled_descendant_claims:0,claims_recycled:1,
       component_details:[{anchor:{txid:$anchor,vout:0,amount:9.83326930,scriptPubKey:$script},
         generation_fingerprint:$generation,component_fingerprint:$component,
         classification:$classification,claim_txids:[$claim],root_claim_txids:[$claim],
         resolution_txids:$resolution_txids,ordinary_or_mixed_txids:[],descendant_claims:0,
         minimum_stale_depth:9064,stale_depth_known:true,anchor_authenticated:true,
         anchor_unspent:($classification != "resolved_on_active_chain"),all_claims_quarantined:true,
         all_claims_explicitly_provenanced:true,all_claims_zero_payment_retirable:false,
         all_claims_expired_locally_retired:false,has_revalidating_unbound_proof:true,nodes:$nodes}],
       unanchored_claim_txids:[]}
    '
}

unsigned_preview()
{
    local fee=0.00019100 component=$COMPONENT
    [[ "$scenario" != bad-fee ]] || fee=0.00019200
    jq -n --arg plan "$PLAN" --arg tip "$TIP" --arg anchor "$ANCHOR" --arg claim "$CLAIM" \
      --arg generation "$GENERATION" --arg component "$component" --arg template "$TEMPLATE" \
      --argjson fee "$fee" '
      {action:"preview",plan_id:$plan,plan_reusable:true,active_tip:$tip,active_height:5991315,
       wallet_generation:114,wallet_tip_matches:true,complete:true,one_call_finality:false,
       frontier_may_advance:true,contains_revalidating_unbound_proof:true,
       max_fee_per_resolution:0.00019100,aggregate_batch_fee_cap:0.00019100,
       fee_rate_atoms_per_k:100000,total_fee:$fee,actionable_components:1,refused_components:43,
       actions:[{anchor:{txid:$anchor,vout:0},generation_fingerprint:$generation,
         component_fingerprint:$component,classification:"current_branch_ineligible",status:"ready",
         claim_txids:[$claim],descendant_claims:0,fee:$fee,persisted:false,relay_authorized:false,
         in_mempool:false,frontier_may_advance:true,conflicts_with_revalidating_unbound_proof:true,
         reason_code:"unbound-proof-may-revalidate",reason:"test",unsigned_template_hash:$template,
         vsize:191,input_amount:9.83326930,output_amount:9.83307830}],
       refused:[],success:true,stale_plan:false,signed_and_persisted:0,durable_state_changed:false,
       durable_state_ambiguous:false,relay_authority_granted:0,broadcast:0,already_in_mempool:0,
       relay_deferred:0,error:"",next_step:"review",warning:"risk"}
    '
}

signed_preview()
{
    jq -n --arg plan "$SIGNED_PLAN" --arg tip "$TIP" --arg anchor "$ANCHOR" --arg claim "$CLAIM" \
      --arg generation "$GENERATION" --arg component "$POST_COMPONENT" --arg txid "$RESOLUTION" '
      {action:"preview",plan_id:$plan,plan_reusable:true,active_tip:$tip,active_height:5991315,
       wallet_generation:115,wallet_tip_matches:true,complete:true,one_call_finality:false,
       frontier_may_advance:true,contains_revalidating_unbound_proof:true,
       max_fee_per_resolution:0.00019100,aggregate_batch_fee_cap:0.00019100,total_fee:0.00019100,
       actionable_components:1,refused_components:43,
       actions:[{anchor:{txid:$anchor,vout:0},generation_fingerprint:$generation,
         component_fingerprint:$component,classification:"resolution_pending",status:"reuse_managed",
         claim_txids:[$claim],descendant_claims:0,fee:0.00019100,persisted:true,
         relay_authorized:false,in_mempool:false,frontier_may_advance:true,
         conflicts_with_revalidating_unbound_proof:true,reason_code:"unbound-proof-may-revalidate",
         reason:"test",resolution_txid:$txid,vsize:191,input_amount:9.83326930,
         output_amount:9.83307830}],refused:[],success:true,stale_plan:false,
       signed_and_persisted:0,durable_state_changed:false,durable_state_ambiguous:false,
       relay_authority_granted:0,broadcast:0,already_in_mempool:0,relay_deferred:0,error:""}
    '
}

sign_result()
{
    jq -n --arg plan "$PLAN" --arg tip "$TIP" --arg anchor "$ANCHOR" --arg claim "$CLAIM" \
      --arg generation "$GENERATION" --arg component "$COMPONENT" --arg txid "$RESOLUTION" \
      --arg hex "$SIGNED_HEX" '
      {action:"sign_only",plan_reusable:false,acknowledged_plan_id:$plan,
       acknowledged_active_tip:$tip,acknowledged_active_height:5991315,
       acknowledged_wallet_generation:114,acknowledged_total_fee:0.00019100,plan_consumed:true,
       actions:[{anchor:{txid:$anchor,vout:0},generation_fingerprint:$generation,
         component_fingerprint:$component,classification:"current_branch_ineligible",
         status:"signed_and_persisted",claim_txids:[$claim],descendant_claims:0,fee:0.00019100,
         persisted:true,relay_authorized:false,in_mempool:false,resolution_txid:$txid,hex:$hex}],
       refused:[],success:true,stale_plan:false,signed_and_persisted:1,
       durable_state_changed:true,durable_state_ambiguous:false,relay_authority_granted:0,
       broadcast:0,already_in_mempool:0,relay_deferred:0,error:""}
    '
}

relay_result()
{
    local status=broadcast broadcast=1 deferred=0
    if [[ "$scenario" == relay-deferred ]]; then status=relay_deferred; broadcast=0; deferred=1; fi
    jq -n --arg plan "$SIGNED_PLAN" --arg tip "$TIP" --arg anchor "$ANCHOR" --arg claim "$CLAIM" \
      --arg generation "$GENERATION" --arg component "$POST_COMPONENT" --arg txid "$RESOLUTION" \
      --arg status "$status" --argjson broadcast "$broadcast" --argjson deferred "$deferred" '
      {action:"commit_and_broadcast",plan_reusable:false,acknowledged_plan_id:$plan,
       acknowledged_active_tip:$tip,acknowledged_active_height:5991315,
       acknowledged_wallet_generation:115,acknowledged_total_fee:0.00019100,plan_consumed:true,
       actions:[{anchor:{txid:$anchor,vout:0},generation_fingerprint:$generation,
         component_fingerprint:$component,classification:"resolution_pending",status:$status,
         claim_txids:[$claim],descendant_claims:0,fee:0.00019100,persisted:true,
         relay_authorized:true,in_mempool:($status == "broadcast"),resolution_txid:$txid}],
       refused:[],success:true,stale_plan:false,signed_and_persisted:0,durable_state_changed:true,
       durable_state_ambiguous:false,relay_authority_granted:1,broadcast:$broadcast,
       already_in_mempool:0,relay_deferred:$deferred,relay_complete:($deferred == 0),error:""}
    '
}

[[ $# -ge 1 ]] || exit 64
command=$1
shift
log "$command $*"

case "$command" in
    inspect)
        [[ "$1" == "$CONTAINER" ]] || exit 65
        runtime_json
        ;;
    exec)
        [[ "$1" == "$CONTAINER" ]] || exit 65
        shift
        [[ "$1" == /usr/local/bin/blackcoin-cli ]] || exit 65
        shift
        [[ "$1" == -datadir=/home/blackcoin/.blackcoin ]] || exit 65
        shift
        [[ "$1" == -rpcwallet= ]] || exit 65
        shift
        method=$1
        shift
        log "rpc $method $*"
        case "$method" in
            getblockchaininfo) chain_json ;;
            getnetworkinfo)
                jq -n '{version:300104,subversion:"/Blackcoin:30.1.4/",networkactive:true,
                  connections:69,connections_in:51,connections_out:18,warnings:""}' ;;
            listwallets)
                [[ "$scenario" != wrong-wallet ]] && printf '[""]\n' || printf '["wrong"]\n' ;;
            getwalletinfo) wallet_json ;;
            getstakinginfo)
                if [[ "$scenario" == final-no-pos ]]; then
                    jq -n '{enabled:true,staking:false,weight:0}'
                else
                    jq -n '{enabled:true,staking:true,weight:99300000000,expectedtime:466709}'
                fi ;;
            getpowmininginfo) mining_json ;;
            getpowclaimrecoveryinfo) recovery_json ;;
            gettxout)
                [[ "$1" == "$ANCHOR" && "$2" == 0 && "$3" == true ]] || exit 66
                if [[ "$state" == final ]]; then
                    printf 'null\n'
                else
                    jq -n --arg tip "$TIP" --arg script "$ANCHOR_SCRIPT" \
                      '{bestblock:$tip,confirmations:9064,value:9.83326930,
                        scriptPubKey:{asm:"OP_DUP OP_HASH160 hash OP_EQUALVERIFY OP_CHECKSIG",
                          desc:"addr(test)",hex:$script,address:"B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct",
                          type:"pubkeyhash"},coinbase:false,coinstake:false}'
                fi ;;
            gettransaction)
                if [[ "$1" == "$CLAIM" ]]; then claim_transaction_json
                elif [[ "$1" == "$RESOLUTION" && "$state" != unsigned ]]; then resolution_transaction_json
                else exit 67; fi ;;
            getrawmempool)
                if [[ "$state" == relayed && "$scenario" != relay-deferred ]]; then
                    jq -n --arg txid "$RESOLUTION" '[$txid]'
                else
                    printf '[]\n'
                fi ;;
            getaddressinfo)
                if [[ "$1" == B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct ]]; then
                    jq -n --arg script "$ANCHOR_SCRIPT" '{address:"B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct",
                      scriptPubKey:$script,ismine:true,solvable:true,iswatchonly:false,ischange:false,labels:[""]}'
                elif [[ "$1" == "$PAYOUT" ]]; then
                    jq -n --arg address "$PAYOUT" --arg script "$PAYOUT_SCRIPT" \
                      '{address:$address,scriptPubKey:$script,ismine:true,solvable:true,
                        iswatchonly:false,ischange:false,labels:["PoW - Quantum Claim Address"]}'
                else exit 68; fi ;;
            getquantumkeyinventory)
                jq -n --arg address "$PAYOUT" '[{address:$address,owned:true,label:"PoW - Quantum Claim Address"}]' ;;
            resolveallshadowpowclaims)
                action=$(jq -r '.action' <<< "$1")
                if [[ "$action" == preview && "$state" == unsigned ]]; then
                    unsigned_preview
                elif [[ "$action" == preview && "$state" == signed ]]; then
                    signed_preview
                elif [[ "$action" == sign_only && "$state" == unsigned ]]; then
                    printf 'signed\n' > "$MOCK_STATE_DIR/state"
                    sign_result
                else
                    exit 69
                fi ;;
            decoderawtransaction)
                [[ "$1" == "$SIGNED_HEX" ]] || exit 70
                resolution_decoded_json ;;
            commitshadowpowclaimresolution)
                [[ "$state" == signed && "$1" == "$RESOLUTION" && "$2" == true ]] || exit 71
                printf 'relayed\n' > "$MOCK_STATE_DIR/state"
                state=relayed
                relay_result ;;
            *) exit 72 ;;
        esac
        ;;
    *) exit 73 ;;
esac
