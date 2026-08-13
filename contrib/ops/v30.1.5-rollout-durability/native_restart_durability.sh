#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/typed_contract.sh"

[[ $# == 4 ]] || {
    printf 'usage: %s REVIEWED_ENV NODE COMPOSE_OVERLAY EVIDENCE_DIR\n' "$0" >&2
    exit 64
}
env_file=$1 node=$2 overlay=$3 evidence=$4
[[ $EUID == 0 ]] || v3015_die 'native restart proof requires root'
[[ "$node" =~ ^([1-9]|[12][0-9]|3[12])$ && "$node" != 30 ]] ||
    v3015_die 'native restart proof is for regular-PoW nodes, excluding node30'
v3015_load_reviewed_env "$env_file"
v3015_validate_release_env
v3015_require_commands docker jq sha256sum awk grep date find realpath stat sed wc tr sort python3
v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
topology_map="$package_dir/topology.map"
v3015_validate_topology_map "$topology_map" || v3015_die 'sealed node topology map is invalid'
v3015_secure_directory "$evidence" || v3015_die 'evidence directory is not secure'
v3015_secure_ancestry "$evidence" || v3015_die 'evidence ancestry is untrusted'
[[ -f "$overlay" && ! -L "$overlay" ]] || v3015_die 'Compose overlay missing'

[[ "$(v3015_sha256_file "$PHASE_B_RESULT")" == "$PHASE_B_RESULT_SHA256" ]] ||
    v3015_die 'Phase-B RESULT hash mismatch'
[[ "$(v3015_sha256_file "$PHASE_B_PROMOTION_MARKER")" == "$PHASE_B_PROMOTION_MARKER_SHA256" ]] ||
    v3015_die 'Phase-B promotion marker hash mismatch'
[[ "$(v3015_sha256_file "$NINE_PATH_CANARY_SHA256SUMS")" == "$NINE_PATH_CANARY_SEAL_SHA256" ]] ||
    v3015_die 'nine-path canary seal mismatch'
[[ "$(v3015_sha256_file "$PACKAGE_SHA256SUMS")" == "$PACKAGE_SHA256SUMS_SHA256" ]] ||
    v3015_die 'rollout package seal mismatch'
v3015_phase_b_evidence_is_valid "$PHASE_B_RESULT" "$PHASE_B_PROMOTION_MARKER" ||
    v3015_die 'completed Phase-B result/irreversible promotion contract is invalid'
v3015_release_identity_is_valid "$RELEASE_IDENTITY_JSON" || v3015_die 'release identity invalid'
[[ "$(v3015_sha256_file "$COMPOSE_FILE")" == "$FINAL_COMPOSE_SHA256" ]] ||
    v3015_die 'live Compose does not match the durable handoff receipt'
compose_model=$(docker compose -f "$COMPOSE_FILE" -f "$overlay" config --format json) ||
    v3015_die 'merged Compose topology could not be rendered'
v3015_compose_topology_matches "$topology_map" "$compose_model" ||
    v3015_die 'merged Compose service/container topology is incomplete or ambiguous'
v3015_unlock_helper_is_audited "$NORMAL_UNLOCK_HELPER" ||
    v3015_die 'normal-unlock helper identity/content audit failed'

nonce=${LIVE_EXECUTION_CLEARED##*:}
[[ "$nonce" =~ ^[0-9a-f]{32}$ &&
   "$LIVE_EXECUTION_CLEARED" == "v30.1.5:${SOURCE_SHA}:${nonce}" &&
   "$NATIVE_RESTART_CLEARED" == "v30.1.5-native-restart:${SOURCE_SHA}:${nonce}" ]] ||
    v3015_die 'exact nonce-bound live/native-restart authority missing'
marker="$STATE_DIR/V30_1_5_ROLLOUT_MAINTENANCE.json"
[[ -f "$marker" && ! -L "$marker" ]] || v3015_die 'active fleet transaction marker missing'
jq -e --arg run "$evidence" --arg nonce "$nonce" --arg source "$SOURCE_SHA" '
  . == {schema:1,transaction:"v30.1.5-fleet-rollout",state:"active",
    run_dir:$run,nonce:$nonce,source_sha:$source}
' "$marker" >/dev/null || v3015_die 'fleet transaction marker does not bind this proof'
authority_file="$evidence/AUTHORITY"
[[ -f "$authority_file" && ! -L "$authority_file" ]] ||
    v3015_die 'rollout authority file missing'
v3015_rollout_authority_is_valid "$authority_file" ||
    v3015_die 'rollout authority does not bind this execution'
rollout_authority_sha256=$(v3015_sha256_file "$authority_file")

topology_row=$(v3015_topology_lookup "$topology_map" "$node") ||
    v3015_die 'logical node is missing from the sealed topology map'
IFS=$'\t' read -r service container <<<"$topology_row"
[[ -n "$service" && -n "$container" ]] || v3015_die 'topology lookup is incomplete'
cli='/usr/local/bin/blackcoin-cli'
datadir='/home/blackcoin/.blackcoin'
output=$(printf '%s/node-%02d.json' "$evidence" "$node")
[[ ! -e "$output" && ! -L "$output" ]] || v3015_die 'node evidence already exists'

rpc()
{
    docker exec "$container" "$cli" -datadir="$datadir" "$@"
}

wait_rpc()
{
    local deadline=$((SECONDS + 180))
    until rpc getnetworkinfo >/dev/null 2>&1; do
        ((SECONDS < deadline)) || return 1
        sleep 2
    done
}

invocation_argv_sha=''
verify_runtime_invocation()
{
    local inspect body body_sha sentinel argv_lines argv_json pid1_sha argv_sha
    inspect=$(docker inspect "$container")
    body=$(jq -er '.[0].Config.Entrypoint[2]' <<<"$inspect") || return 1
    body_sha=$(printf '%s\n' "$body" | sha256sum | awk '{print $1}')
    sentinel="node${node}-v3015-rollout"
    [[ "$body_sha" == "$RUNTIME_ENTRYPOINT_BODY_SHA256" ]] || return 1
    jq -e --arg sentinel "$sentinel" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg container "/$container" \
      --arg image_id "$CANDIDATE_IMAGE_ID" '
      .[0].Name == $container and .[0].Config.Entrypoint[0] == "/bin/bash" and
      .[0].Config.Entrypoint[1] == "-c" and
      .[0].Config.Entrypoint[3] == $sentinel and
      .[0].Config.Image == $image and .[0].Image == $image_id and
      .[0].Config.Cmd == ["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
        "-powminingthreads=1","-powminingcpu=1"]
    ' <<<"$inspect" >/dev/null || return 1
    argv_lines=$(docker exec "$container" /bin/bash -c \
      'tr "\000" "\n" < /proc/1/cmdline') || return 1
    argv_json=$(printf '%s\n' "$argv_lines" | jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -e '. == ["/usr/local/bin/blackcoin-qt",
      "-datadir=/home/blackcoin/.blackcoin","-walletbroadcast=1","-autostartstaking=1",
      "-powmining=1","-powminingthreads=1","-powminingcpu=1"]' \
      <<<"$argv_json" >/dev/null || return 1
    pid1_sha=$(docker exec "$container" sha256sum /proc/1/exe | awk '{print $1}')
    [[ "$pid1_sha" == "$CANDIDATE_BLACKCOIN_QT_SHA256" ]] || return 1
    argv_sha=$(docker exec "$container" sha256sum /proc/1/cmdline | awk '{print $1}')
    v3015_is_sha256 "$argv_sha" || return 1
    invocation_argv_sha=$argv_sha
}

capture_sample()
{
    local chain_before chain_after network wallet wallets staking pow recovery raw_mempool
    local qqp4_activation
    local now started finished action relay target node familyless_wait=false
    local mempool_entry='null' mempool_present=false freshness='null'
    local live_nodes='[]' live_members='[]' live_node live_entry selected_live_node
    started=$(date +%s%3N)
    chain_before=$(rpc getblockchaininfo)
    network=$(rpc getnetworkinfo)
    wallet=$(rpc getwalletinfo)
    wallets=$(rpc listwallets)
    staking=$(rpc getstakinginfo)
    pow=$(rpc getpowmininginfo)
    recovery=$(rpc getpowclaimrecoveryinfo true)
    qqp4_activation=$(rpc getgoldrushstate | jq -ce '
      {bestblock,height,qqp4_activation_disabled,qqp4_activation_height,
       qqp4_active,qqp4_active_next_block}') || return 1
    raw_mempool=$(rpc getrawmempool true)
    chain_after=$(rpc getblockchaininfo)
    jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
      ($before | {bestblockhash,blocks,headers,chainwork,initialblockdownload}) ==
      ($after | {bestblockhash,blocks,headers,chainwork,initialblockdownload})
    ' >/dev/null || return 1
    now=$(date +%s)
    action=$(jq -er '.mining_gate_action' <<<"$pow")
    relay=$(jq -er '.mining_gate_relay_txid' <<<"$pow")
    if jq -e --arg zero "$zero_txid" '
      .mining_gate_action == "wait_for_next_tip" and
      .mining_gate_can_submit == true and
      .mining_gate_unresolved_components == 0 and
      .mining_gate_live_claims == 0 and .mining_gate_eligible_claims == 0 and
      .mining_gate_family_claims == 0 and
      .mining_gate_lineage_head_txid == $zero and
      .mining_gate_relay_txid == $zero
    ' <<<"$pow" >/dev/null; then
        familyless_wait=true
    fi
    if [[ "$action" != create_new_anchor && "$familyless_wait" != true ]]; then
        if [[ "$action" == relay_existing ]] ||
           [[ "$action" == wait_for_next_tip && "$relay" != "$zero_txid" ]]; then
            target=$relay
        else
            target=$(jq -er '.mining_gate_lineage_head_txid' <<<"$pow")
        fi
        [[ "$target" =~ ^[0-9a-f]{64}$ && "$target" != "$zero_txid" ]] || return 1
        node=$(jq -ce --arg target "$target" '
          [.component_details[]? as $component | $component.nodes[]? |
            select(.txid == $target and .kind == "claim") |
            {component:$component,node:.}] |
          if length == 1 then .[0] else error("gate target is not one recovery node") end
        ' <<<"$recovery") || return 1
        if [[ "$action" == wait_for_live ]]; then
            live_nodes=$(jq -ce '[.component.nodes[] |
              select(.kind == "claim" and .in_mempool == true)] |
              sort_by(.txid)' \
              <<<"$node") || return 1
            [[ "$(jq 'length' <<<"$live_nodes")" -ge 1 ]] || return 1
            selected_live_node=$(jq -ce 'sort_by([.lineage_ordinal,.txid]) | last' \
              <<<"$live_nodes") || return 1
            target=$(jq -er '.txid' <<<"$selected_live_node") || return 1
            node=$(jq -cn --argjson match "$node" --argjson selected "$selected_live_node" \
              '$match | .node=$selected') || return 1
            while IFS= read -r live_node; do
                live_entry=$(jq -ce --arg txid "$(jq -er '.txid' <<<"$live_node")" \
                  '.[$txid] // error("live recovery node absent from raw mempool")' \
                  <<<"$raw_mempool") || return 1
                live_members=$(jq -cn --argjson old "$live_members" \
                  --argjson member "$live_node" --argjson entry "$live_entry" '
                  $old + [{recovery_node:$member,mempool_entry:$entry,
                    mempool_entry_time:$entry.time}]') || return 1
            done < <(jq -c '.[]' <<<"$live_nodes")
        fi
        if mempool_entry=$(jq -ce --arg target "$target" \
          '.[$target] // error("absent")' <<<"$raw_mempool" 2>/dev/null); then
            mempool_present=true
        else
            mempool_entry='null'
        fi
    fi
    finished=$(date +%s%3N)
    if [[ "$action" != create_new_anchor && "$familyless_wait" != true ]]; then
        freshness=$(jq -cn --arg action "$action" \
          --arg tip "$(jq -r '.bestblockhash' <<<"$chain_after")" \
          --arg fingerprint "$(jq -r '.mining_gate_candidate_state_fingerprint' <<<"$pow")" \
          --arg head "$(jq -r '.mining_gate_lineage_head_txid' <<<"$pow")" \
          --arg relay "$relay" --argjson observed "$finished" \
          --argjson node "$node" --argjson present "$mempool_present" \
          --argjson entry "$mempool_entry" --argjson live_members "$live_members" \
          --argjson raw_mempool "$raw_mempool" '{
            action:$action,tip:$tip,observed_unix_ms:$observed,
            candidate_state_fingerprint:$fingerprint,lineage_head_txid:$head,
            relay_txid:$relay,live_members:$live_members,
            raw_mempool:$raw_mempool,
            recovery_node:$node.node,recovery_component:$node.component,
            recovery_component_claims:([$node.component.nodes[] |
              select(.kind == "claim")] | sort_by([.lineage_ordinal,.txid])),
            recovery_component_claim_txids:$node.component.claim_txids,
            recovery_component_root_claim_txids:$node.component.root_claim_txids,
            mempool_entry_present:$present,
            mempool_entry:(if $present then $entry else null end),
            mempool_entry_time:(if $present then $entry.time else null end)}') || return 1
    fi
    jq -cn --argjson chain_before "$chain_before" --argjson chain_after "$chain_after" \
      --argjson network "$network" \
      --argjson wallet "$wallet" --argjson wallets "$wallets" \
      --argjson staking "$staking" --argjson pow "$pow" --argjson recovery "$recovery" \
      --argjson qqp4_activation "$qqp4_activation" \
      --argjson now "$now" --argjson started "$started" --argjson finished "$finished" \
      --argjson freshness "$freshness" '{
        chain_before:($chain_before | {bestblockhash,blocks,headers,chainwork,
          initialblockdownload}),
        chain_after:($chain_after | {bestblockhash,blocks,headers,chainwork,
          initialblockdownload}),
        tip:$chain_after.bestblockhash,height:$chain_after.blocks,blocks:$chain_after.blocks,
        headers:$chain_after.headers,ibd:$chain_after.initialblockdownload,
        peers_out:$network.connections_out,
        sample_started_unix_ms:$started,sample_finished_unix_ms:$finished,
        walletname:$wallet.walletname,loaded_wallets:$wallets,
        wallet_normal_unlocked:(($wallet.unlocked_until // 0) > $now and
          ($wallet.unlocked_staking_only // false) == false),
        wallet_generation:$recovery.wallet_generation,
        wallet_processed_tip:$recovery.wallet_processed_tip,
        wallet_tip_matches:$recovery.wallet_tip_matches,action_freshness:$freshness,
        qqp4_activation:$qqp4_activation,staking:$staking,pow:$pow
      }'
}

capture_wallet_state()
{
    local reference=${1:-null}
    local wallet wallets recovery transactions quantum pow chain_before chain_after
    local labels label_json label addresses labeled_addresses='[]'
    local payout payout_info='null' reference_ids='[]' added_txids txid
    local transaction shadow_transaction source_transaction
    local rows blockhash blockheight active_header active_block active_chain_hash
    local created_height created_tip created_tip_header created_tip_active_chain_hash
    local source_txid evidence='{}'
    jq -e . <<<"$reference" >/dev/null || return 1
    evidence=$(jq -c '.transaction_evidence // {}' <<<"$reference") || return 1
    chain_before=$(rpc getblockchaininfo)
    wallet=$(rpc getwalletinfo)
    wallets=$(rpc listwallets)
    recovery=$(rpc getpowclaimrecoveryinfo true)
    transactions=$(rpc listtransactions '*' 2147483647 0 true)
    quantum=$(rpc getquantumkeyinventory)
    pow=$(rpc getpowmininginfo)
    labels=$(rpc listlabels)
    while IFS= read -r label_json; do
        label=$(jq -er '.' <<<"$label_json") || return 1
        addresses=$(rpc getaddressesbylabel "$label") || return 1
        labeled_addresses=$(jq -cn --argjson old "$labeled_addresses" \
          --arg label "$label" --argjson addresses "$addresses" '
          ($old + [$addresses | to_entries[] |
            {address:.key,label:$label,purpose:.value.purpose}]) |
          unique_by([.address,.label,.purpose]) | sort_by([.address,.label,.purpose])') || return 1
    done < <(jq -c '.[]' <<<"$labels")
    payout=$(jq -er '.payout_address' <<<"$pow") || return 1
    if [[ -n "$payout" ]]; then
        payout_info=$(rpc getaddressinfo "$payout") || return 1
    fi
    if [[ "$reference" != null ]]; then
        reference_ids=$(jq -ce '[.transactions[].txid] | unique | sort' \
          <<<"$reference") || return 1
    fi
    added_txids=$(jq -cn --argjson transactions "$transactions" \
      --argjson reference "$reference_ids" '
      ([$transactions[].txid] | unique | sort) - $reference') || return 1
    while IFS= read -r txid; do
        source_txid=''
        rows=$(jq -ce --arg txid "$txid" '[.[] | select(.txid == $txid)]' \
          <<<"$transactions") || return 1
        if jq -e 'any(.[]; .qq_synthetic_goldrush_payout == "1")' \
          <<<"$rows" >/dev/null; then
            shadow_transaction=$(rpc getshadowtransaction "$txid") || return 1
            blockhash=$(jq -er '.base_anchor.blockhash' <<<"$shadow_transaction") || return 1
            active_header=$(rpc getblockheader "$blockhash") || return 1
            blockheight=$(jq -er '.height' <<<"$active_header") || return 1
            active_chain_hash=$(rpc getblockhash "$blockheight") || return 1
            active_block=$(rpc getblock "$blockhash" 1) || return 1
            source_transaction='null'
            if [[ "$(jq -r '.mode' <<<"$shadow_transaction")" == pow ]]; then
                source_txid=$(jq -er '.pow_claim_source.txid' <<<"$shadow_transaction") || return 1
                source_transaction=$(rpc getrawtransaction \
                  "$source_txid" true "$blockhash") || return 1
            fi
            evidence=$(jq -cn --argjson old "$evidence" --arg txid "$txid" \
              --argjson shadow "$shadow_transaction" --argjson active_header "$active_header" \
              --argjson active_block "$active_block" --arg active_chain_hash "$active_chain_hash" \
              --argjson source_transaction "$source_transaction" '
              $old + {($txid):{kind:"synthetic_payout",shadow_transaction:$shadow,
                active_header:$active_header,active_block:$active_block,
                active_chain_hash:$active_chain_hash,
                source_transaction:$source_transaction}}') || return 1
        else
            transaction=$(rpc gettransaction "$txid" true true) || return 1
            blockhash=$(jq -r '.blockhash // empty' <<<"$transaction") || return 1
            active_header='null'
            active_block='null'
            active_chain_hash=''
            created_tip_header='null'
            created_tip_active_chain_hash=''
            if [[ -n "$blockhash" ]]; then
                active_header=$(rpc getblockheader "$blockhash") || return 1
                blockheight=$(jq -er '.height' <<<"$active_header") || return 1
                active_chain_hash=$(rpc getblockhash "$blockheight") || return 1
                active_block=$(rpc getblock "$blockhash" 1) || return 1
                if jq -e '.qq_shadow_pow_authored == "1"' \
                  <<<"$transaction" >/dev/null; then
                    created_height=$(jq -er \
                      '.qq_shadow_pow_created_height | tonumber |
                       select(floor == . and . > 0)' <<<"$transaction") || return 1
                    created_tip=$(jq -er \
                      '.qq_shadow_pow_created_tip |
                       select(test("^[0-9a-f]{64}$"))' <<<"$transaction") || return 1
                    created_tip_header=$(rpc getblockheader "$created_tip") || return 1
                    created_tip_active_chain_hash=$(rpc getblockhash \
                      "$((created_height - 1))") || return 1
                fi
            fi
            evidence=$(jq -cn --argjson old "$evidence" --arg txid "$txid" \
              --argjson transaction "$transaction" --argjson active_header "$active_header" \
              --argjson active_block "$active_block" --arg active_chain_hash "$active_chain_hash" \
              --argjson created_tip_header "$created_tip_header" \
              --arg created_tip_active_chain_hash "$created_tip_active_chain_hash" '
              $old + {($txid):({kind:"base_transaction",transaction:$transaction,
                active_header:$active_header,active_block:$active_block,
                active_chain_hash:(if $active_chain_hash == "" then null
                  else $active_chain_hash end)} +
                (if $created_tip_header == null then {}
                 else {created_tip_header:$created_tip_header,
                   created_tip_active_chain_hash:$created_tip_active_chain_hash}
                 end))}') || return 1
        fi
    done < <(jq -r '.[]' <<<"$added_txids")
    chain_after=$(rpc getblockchaininfo)
    jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
      ($before | {bestblockhash,blocks,headers,chainwork,initialblockdownload}) ==
      ($after | {bestblockhash,blocks,headers,chainwork,initialblockdownload})
    ' >/dev/null || return 1
    jq -cn --argjson wallet "$wallet" --argjson wallets "$wallets" --argjson recovery "$recovery" \
      --argjson transactions "$transactions" --argjson quantum "$quantum" \
      --argjson pow "$pow" --argjson chain "$chain_after" \
      --argjson transaction_evidence "$evidence" \
      --argjson labeled_addresses "$labeled_addresses" --argjson payout_info "$payout_info" \
      '{wallet:$wallet,loaded_wallets:$wallets,recovery:$recovery,transactions:$transactions,
        transaction_evidence:$transaction_evidence,quantum_inventory:$quantum,
        automatic_key_creation_allowed:$pow.allow_automatic_quantum_key_creation,
        payout:$pow.payout_address,payout_address_info:$payout_info,
        labeled_addresses:$labeled_addresses,chain:$chain}'
}

contained=0
candidate_started=0
contain_on_failure()
{
    local status=$?
    if ((status != 0 && candidate_started == 1 && contained == 0)); then
        contained=1
        if v3015_contain_container "$container"; then
            printf 'node %s contained; live wallet/datadir preserved; no rollback attempted\n' "$node" >&2
        else
            printf 'URGENT: node %s containment could not be proven; live data was not rewound\n' \
                "$node" >&2
            status=125
        fi
    fi
    exit "$status"
}
trap contain_on_failure EXIT

start_candidate_recreate()
{
    # Arm containment before Compose can stop/remove/recreate any portion of
    # the service. A nonzero exit after a partial Compose mutation therefore
    # cannot escape the child transaction.
    candidate_started=1
    docker compose -f "$COMPOSE_FILE" -f "$overlay" up -d --no-deps \
        --force-recreate --pull never "$service" >/dev/null
}

zero_txid=$(printf '0%.0s' {1..64})
baseline=$(capture_wallet_state)
v3015_wallet_state_has_single_identity "$baseline" ||
    v3015_die 'baseline does not contain exactly one loaded wallet identity'
baseline_walletname=$(jq -er '.wallet.walletname' <<<"$baseline")
before_id=$(docker inspect -f '{{.Id}}' "$container")
start_candidate_recreate
wait_rpc || v3015_die 'candidate RPC did not become ready after recreation'
verify_runtime_invocation || v3015_die 'candidate wrapper/PID1/argv identity mismatch'
first_invocation_argv_sha=$invocation_argv_sha
after_id=$(docker inspect -f '{{.Id}}' "$container")
[[ "$after_id" != "$before_id" ]] || v3015_die 'candidate container was not recreated'
[[ "$(docker inspect -f '{{.Config.Image}}' "$container")" == "$CANDIDATE_IMAGE_REF" ]] ||
    v3015_die 'candidate container image reference mismatch'
[[ "$(docker image inspect "$CANDIDATE_IMAGE_REF" -f '{{.Id}}')" == "$CANDIDATE_IMAGE_ID" ]] ||
    v3015_die 'loaded candidate image ID mismatch'
network=$(rpc getnetworkinfo)
[[ "$(jq -r '.version' <<<"$network")" == 300105 &&
   "$(jq -r '.subversion' <<<"$network")" == '/Blackcoin:30.1.5/' ]] ||
    v3015_die 'candidate runtime version identity mismatch'
runtime_blackcoind_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoind | awk '{print $1}')
runtime_cli_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoin-cli | awk '{print $1}')
runtime_qt_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoin-qt | awk '{print $1}')
runtime_tx_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoin-tx | awk '{print $1}')
runtime_wallet_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoin-wallet | awk '{print $1}')
runtime_util_sha=$(docker exec "$container" sha256sum /usr/local/bin/blackcoin-util | awk '{print $1}')
[[ "$runtime_blackcoind_sha" == "$CANDIDATE_BLACKCOIND_SHA256" ]] ||
    v3015_die 'blackcoind bytes mismatch'
[[ "$runtime_cli_sha" == "$CANDIDATE_BLACKCOIN_CLI_SHA256" ]] ||
    v3015_die 'blackcoin-cli bytes mismatch'
[[ "$runtime_qt_sha" == "$CANDIDATE_BLACKCOIN_QT_SHA256" ]] ||
    v3015_die 'blackcoin-qt bytes mismatch'
[[ "$runtime_tx_sha" == "$CANDIDATE_BLACKCOIN_TX_SHA256" ]] ||
    v3015_die 'blackcoin-tx bytes mismatch'
[[ "$runtime_wallet_sha" == "$CANDIDATE_BLACKCOIN_WALLET_SHA256" ]] ||
    v3015_die 'blackcoin-wallet bytes mismatch'
[[ "$runtime_util_sha" == "$CANDIDATE_BLACKCOIN_UTIL_SHA256" ]] ||
    v3015_die 'blackcoin-util bytes mismatch'

candidate_wallet_deadline=$((SECONDS + 180))
until candidate_wallet=$(capture_wallet_state "$baseline") &&
      v3015_wallet_state_has_single_identity "$candidate_wallet" &&
      [[ "$(jq -r '.wallet.walletname' <<<"$candidate_wallet")" == "$baseline_walletname" ]] &&
      preunlock_migration=$(v3015_make_preunlock_migration_audit "$baseline" "$candidate_wallet") &&
      v3015_preunlock_migration_is_safe "$preunlock_migration"; do
    ((SECONDS < candidate_wallet_deadline)) ||
        v3015_die 'portable locked pre-unlock migration guard did not converge'
    sleep 2
done

# First normal unlock establishes candidate operation before the controlled
# restart. The pinned helper performs normal walletpassphrase only; it contains
# no worker-enable or transaction/recovery call.
/bin/bash "$NORMAL_UNLOCK_HELPER" "$node" >/dev/null
initial_deadline=$((SECONDS + 180))
until sample=$(capture_sample) &&
      v3015_pos_json_is_active "$(jq -c '.staking' <<<"$sample")" &&
      v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$sample")"; do
    ((SECONDS < initial_deadline)) || v3015_die 'candidate did not become operational before restart'
    sleep 2
done

docker restart --time 30 "$container" >/dev/null
wait_rpc || v3015_die 'candidate RPC did not return after controlled restart'
verify_runtime_invocation || v3015_die 'restarted wrapper/PID1/argv identity mismatch'
[[ "$invocation_argv_sha" == "$first_invocation_argv_sha" ]] ||
    v3015_die 'runtime argv changed across controlled restart'
locked_deadline=$((SECONDS + 180))
while :; do
    if locked_wallet=$(rpc getwalletinfo) && locked_wallets=$(rpc listwallets) &&
       locked_staking=$(rpc getstakinginfo) && locked_pow=$(rpc getpowmininginfo); then
        locked_identity=$(jq -cn --argjson wallet "$locked_wallet" \
          --argjson wallets "$locked_wallets" '{wallet:$wallet,loaded_wallets:$wallets}')
        v3015_wallet_state_has_single_identity "$locked_identity" &&
          [[ "$(jq -r '.wallet.walletname' <<<"$locked_identity")" == \
             "$baseline_walletname" ]] ||
            v3015_die 'loaded wallet identity changed across locked restart'
        locked_observation=$(jq -cn --argjson wallet "$locked_wallet" \
          --argjson staking "$locked_staking" --argjson pow "$locked_pow" \
          '{wallet:$wallet,staking:$staking,pow:$pow}')
        jq -e '(.wallet.unlocked_until // 0) == 0 and
          (.wallet.unlocked_staking_only // false) == false and
          .staking.enabled == true and .staking.autostart_staking == true and
          .pow.enabled == true and .pow.autostart == true and .pow.threads >= 1 and
          .pow.cpu_percent > 0 and .pow.hashrate == 0' \
          <<<"$locked_observation" >/dev/null ||
              v3015_die 'locked restart disabled or contradicted Core-native PoS/PoW authority'
        locked_staking_state=$(jq -er '.staking.staking_state' <<<"$locked_observation")
        locked_pow_state=$(jq -er '.pow.state' <<<"$locked_observation")
        locked=$(jq -cn --argjson wallet "$locked_wallet" --argjson staking "$locked_staking" \
          --argjson pow "$locked_pow" '{
          wallet_locked:(($wallet.unlocked_until // 0) == 0),normal_unlock_called:false,
          pos_intent_retained:($staking.autostart_staking == true),
          pow_intent_retained:($pow.enabled == true and $pow.autostart == true),
          staking:$staking,pow:$pow}')
        if [[ "$locked_staking_state" == locked &&
              "$locked_pow_state" == wallet_locked_or_staking_only ]]; then
            v3015_locked_restart_json_is_valid "$locked" ||
                v3015_die 'locked restart returned a contradictory final worker tuple'
            break
        fi
        [[ "$locked_staking_state" == starting || "$locked_staking_state" == syncing ||
           "$locked_staking_state" == locked ]] ||
            v3015_die 'locked restart PoS worker entered a disabled, stopped, or error state'
        [[ "$locked_pow_state" == starting ||
           "$locked_pow_state" == wallet_locked_or_staking_only ]] ||
            v3015_die 'locked restart PoW worker entered a disabled, stopped, or error state'
    fi
    ((SECONDS < locked_deadline)) ||
        v3015_die 'locked restart PoS/PoW worker states did not converge'
    sleep 2
done

/bin/bash "$NORMAL_UNLOCK_HELPER" "$node" >/dev/null
samples='[]'
deadline=$((SECONDS + 600))
while [[ "$(jq 'length' <<<"$samples")" -lt 4 ]] ||
      ! v3015_pow_series_is_complete "$samples"; do
    sample=$(capture_sample) || true
    if v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$sample")" &&
       v3015_pos_json_is_active "$(jq -c '.staking' <<<"$sample")" &&
       jq -e '.ibd == false and .blocks == .headers and .peers_out >= 1 and
         .wallet_normal_unlocked == true and .pow.current_height == .height and
         .pow.claim_inventory_tip == .tip and .staking.blocks == .height and
         .wallet_processed_tip == .tip and .wallet_tip_matches == true' \
         <<<"$sample" >/dev/null; then
        samples=$(jq -cn --argjson old "$samples" --argjson sample "$sample" '$old + [$sample]')
    fi
    ((SECONDS < deadline)) ||
        v3015_die 'no authenticated PoW liveness witness arrived within ten minutes'
    if [[ "$(jq 'length' <<<"$samples")" -lt 4 ]] ||
       ! v3015_pow_series_is_complete "$samples"; then
        sleep 5
    fi
done
v3015_pow_series_is_complete "$samples" ||
    v3015_die 'action-aware PoW/PoS liveness witness failed'

final=$(capture_wallet_state "$candidate_wallet")
wallet_audit=$(v3015_make_wallet_audit "$candidate_wallet" "$final")
v3015_wallet_delta_is_safe "$wallet_audit" ||
    v3015_die 'candidate-native wallet delta is unclassified or contains recovery/key/payout mutation'

result=$(jq -cn --argjson node "$node" --arg source "$SOURCE_SHA" \
  --arg before "$before_id" --arg after "$after_id" --argjson locked "$locked" \
  --arg argv "$invocation_argv_sha" --arg body "$RUNTIME_ENTRYPOINT_BODY_SHA256" \
  --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
  --arg nonce "$nonce" --arg authority "$rollout_authority_sha256" \
  --argjson samples "$samples" --argjson migration "$preunlock_migration" \
  --argjson audit "$wallet_audit" '{
    schema:1,node:$node,source_sha:$source,rollout_nonce:$nonce,
    rollout_authority_sha256:$authority,network_version:300105,
    subversion:"/Blackcoin:30.1.5/",container_id_before:$before,
    container_id_after_recreate:$after,restart_performed:true,
    container_recreated:true,normal_unlock_only:true,repair_rpcs:[],
    data_rewind_used:false,containment_only_on_failure:true,
    invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
      entrypoint_body_sha256:$body,runtime_argv_sha256:$argv,
      config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
        "-powminingthreads=1","-powminingcpu=1"]},
    locked_restart:$locked,preunlock_migration:$migration,
    samples:$samples,wallet_audit:$audit
  }')
v3015_node_result_is_valid <(printf '%s\n' "$result") "$node" "$authority_file" ||
    v3015_die 'self-verification failed'
printf '%s\n' "$result" | v3015_atomic_write "$output"
candidate_started=0
trap - EXIT
printf 'node %s native restart durability PASS\n' "$node"
