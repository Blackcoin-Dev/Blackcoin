#!/usr/bin/env bash
export LC_ALL=C
export TZ=UTC
set -Eeuo pipefail
umask 077

# This tool is intentionally single-subject.  It is not a fleet loop and it is
# not a generic transaction wrapper.  The only wallet mutations it can invoke
# are one exact-plan sign_only recovery and, in a later invocation, the exact
# targeted commitshadowpowclaimresolution RPC for the persisted txid.

readonly CONTRACT='node27-installed-v30.1.4-fee-recovery-canary/v1'
readonly NODE_ID=27
readonly SERVICE='node27'
readonly CONTAINER='blackcoin-v4-gui-27'
readonly COMPOSE_PROJECT='blackcoin30'
readonly CLI='/usr/local/bin/blackcoin-cli'
readonly DATADIR='/home/blackcoin/.blackcoin'
readonly WALLET=''
readonly SOURCE_COMMIT='13262151077cce3f72d07d17dc7725b2b6a8e1ab'
readonly NETWORK_VERSION=300104
readonly SUBVERSION='/Blackcoin:30.1.4/'
readonly IMAGE_REF='qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly IMAGE_ID='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'

readonly CLAIM_TXID='2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d'
readonly ANCHOR_TXID='3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87'
readonly ANCHOR_VOUT=0
readonly ANCHOR_AMOUNT='9.83326930'
readonly CLAIM_RETURN_AMOUNT='9.83298230'
readonly RECOVERY_OUTPUT_AMOUNT='9.83307830'
readonly ANCHOR_SCRIPT='76a914085f283018f571e673c38efe7a648493ce3b499088ac'
readonly ANCHOR_ADDRESS='B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct'
readonly GENERATION_FINGERPRINT='0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860'
readonly PAYOUT_ADDRESS='blk1s0hl7dsh5huajtwtx5ve65qjfwearvctxtm7c88t6vcc9m8qeam4s43es72'
readonly PAYOUT_SCRIPT='60207dffe6c2f4bf3b25b966a333aa0249767a3661665efd839d7a66305d9c19eeeb'

readonly FEE_RATE_ATOMS_PER_K=100000
readonly RECOVERY_FEE='0.00019100'
readonly CLAIM_FEE='0.00028700'
readonly RECOVERY_VSIZE=191
readonly CLAIM_VSIZE=287
readonly BASELINE_CLAIMS_SUBMITTED=4
readonly REQUIRED_CONFIRMATIONS=6

PHASE='audit'
OUTPUT=''
AUDIT_RECEIPT=''
AUDIT_SHA256=''
SIGN_RECEIPT=''
SIGN_SHA256=''
RELAY_RECEIPT=''
RELAY_SHA256=''
AUTHORITY_RECEIPT=''
AUTHORITY_SHA256=''
DOCKER_PATH=''
DOCKER_SHA256=''
SELF_PATH=''
TOOL_SHA256=''

die()
{
    printf 'FATAL: %s\n' "$*" >&2
    exit 1
}

usage()
{
    cat <<'EOF'
Usage:
  node27_recovery_canary.sh [audit] [--output ABSOLUTE_PATH]
  node27_recovery_canary.sh sign-only --output ABSOLUTE_PATH \
      --audit-receipt ABSOLUTE_PATH --audit-sha256 HEX \
      --authority-receipt ABSOLUTE_PATH --authority-sha256 HEX
  node27_recovery_canary.sh relay --output ABSOLUTE_PATH \
      --sign-receipt ABSOLUTE_PATH --sign-sha256 HEX \
      --authority-receipt ABSOLUTE_PATH --authority-sha256 HEX
  node27_recovery_canary.sh verify-final --output ABSOLUTE_PATH \
      --sign-receipt ABSOLUTE_PATH --sign-sha256 HEX \
      --relay-receipt ABSOLUTE_PATH --relay-sha256 HEX

No arguments means audit.  audit and verify-final are read-only.  sign-only and
relay are separate authorities and separate process invocations.
EOF
}

hash_file()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | awk '{print $1}'
    else
        shasum -a 256 -- "$1" | awk '{print $1}'
    fi
}

hash_stdin()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

file_mode()
{
    if stat -f '%Lp' "$1" >/dev/null 2>&1; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

file_uid()
{
    if stat -f '%u' "$1" >/dev/null 2>&1; then
        stat -f '%u' "$1"
    else
        stat -c '%u' "$1"
    fi
}

require_hex64()
{
    [[ "$1" =~ ^[0-9a-f]{64}$ ]] || die "$2 must be lowercase 64-hex"
}

require_receipt_file()
{
    local path=$1 expected=$2 label=$3
    [[ "$path" == /* && -f "$path" && ! -L "$path" ]] ||
        die "$label must be an absolute regular non-symlink file"
    [[ "$(realpath "$path")" == "$path" ]] || die "$label must be canonical"
    [[ "$(file_mode "$path")" == 600 ]] || die "$label must be mode 0600"
    [[ "$(file_uid "$path")" == "$(id -u)" ]] || die "$label owner changed"
    require_hex64 "$expected" "$label sha256"
    [[ "$(hash_file "$path")" == "$expected" ]] || die "$label sha256 mismatch"
    jq -e 'type == "object"' "$path" >/dev/null || die "$label is not a JSON object"
}

write_receipt()
{
    local json=$1 parent tmp
    if [[ -z "$OUTPUT" ]]; then
        jq -S . <<< "$json"
        return
    fi
    [[ "$OUTPUT" == /* && ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] ||
        die 'output must be a new absolute path'
    parent=${OUTPUT%/*}
    [[ -d "$parent" && ! -L "$parent" && "$(realpath "$parent")" == "$parent" ]] ||
        die 'output parent must be a canonical non-symlink directory'
    tmp=$(mktemp "${parent}/.node27-recovery-receipt.XXXXXX") ||
        die 'could not allocate receipt temporary file'
    jq -S . <<< "$json" > "$tmp" || { rm -f "$tmp"; die 'could not render receipt'; }
    chmod 600 "$tmp" || { rm -f "$tmp"; die 'could not protect receipt'; }
    if ! ln "$tmp" "$OUTPUT"; then
        rm -f "$tmp"
        die 'could not publish receipt without replacement'
    fi
    rm -f "$tmp"
    printf 'RECEIPT %s SHA256 %s\n' "$OUTPUT" "$(hash_file "$OUTPUT")" >&2
}

resolve_self_and_transport()
{
    SELF_PATH=$(realpath "$0") || die 'tool path is unavailable'
    [[ -f "$SELF_PATH" && ! -L "$SELF_PATH" ]] || die 'tool must be a regular file'
    TOOL_SHA256=$(hash_file "$SELF_PATH") || die 'tool sha256 is unavailable'
    DOCKER_PATH=$(command -v docker) || die 'docker executable is unavailable'
    DOCKER_PATH=$(realpath "$DOCKER_PATH") || die 'docker path is unavailable'
    [[ "$DOCKER_PATH" == /* && -f "$DOCKER_PATH" && -x "$DOCKER_PATH" && ! -L "$DOCKER_PATH" ]] ||
        die 'docker must resolve to an executable regular file'
    DOCKER_SHA256=$(hash_file "$DOCKER_PATH") || die 'docker sha256 is unavailable'
}

docker_call()
{
    "$DOCKER_PATH" "$@"
}

rpc()
{
    local method=$1
    shift
    case "$method" in
        listwallets|getblockchaininfo|getnetworkinfo|getwalletinfo|getstakinginfo|getpowmininginfo|getpowclaimrecoveryinfo|gettransaction|gettxout|getrawmempool|getaddressinfo|getquantumkeyinventory|decoderawtransaction)
            ;;
        resolveallshadowpowclaims)
            [[ "$PHASE" == audit || "$PHASE" == sign-only || "$PHASE" == relay ]] ||
                die "resolveallshadowpowclaims is forbidden in phase $PHASE"
            ;;
        commitshadowpowclaimresolution)
            [[ "$PHASE" == relay ]] ||
                die 'commitshadowpowclaimresolution is permitted only in relay phase'
            ;;
        *)
            die "RPC method is not allowlisted: $method"
            ;;
    esac
    docker_call exec "$CONTAINER" "$CLI" -datadir="$DATADIR" \
        -rpcwallet="$WALLET" "$method" "$@"
}

runtime_snapshot()
{
    local inspect
    inspect=$(docker_call inspect "$CONTAINER") || die 'container inspect failed'
    jq -e --arg name "/$CONTAINER" --arg service "$SERVICE" \
        --arg project "$COMPOSE_PROJECT" --arg ref "$IMAGE_REF" --arg image "$IMAGE_ID" '
        length == 1 and .[0].Name == $name and
        .[0].Config.Image == $ref and .[0].Image == $image and
        .[0].Config.Labels["com.docker.compose.service"] == $service and
        .[0].Config.Labels["com.docker.compose.project"] == $project and
        .[0].State.Running == true and .[0].State.Paused == false and
        .[0].State.Restarting == false and .[0].State.Health.Status == "healthy" and
        (.[0].Id | test("^[0-9a-f]{64}$")) and
        (.[0].State.StartedAt | type == "string" and length > 0)
    ' >/dev/null <<< "$inspect" || die 'node27 runtime identity is not exact and healthy'
    jq -c --argjson node "$NODE_ID" --arg service "$SERVICE" --arg container "$CONTAINER" \
        --arg project "$COMPOSE_PROJECT" --arg ref "$IMAGE_REF" --arg image "$IMAGE_ID" '
        {node:$node,service:$service,container:$container,compose_project:$project,
         image_ref:$ref,image_id:$image,container_id:.[0].Id,
         started_at:.[0].State.StartedAt,healthy:true}
    ' <<< "$inspect"
}

assert_runtime_unchanged()
{
    local expected=$1 current
    current=$(runtime_snapshot)
    jq -e -n --argjson a "$expected" --argjson b "$current" '$a == $b' >/dev/null ||
        die 'node27 runtime identity changed during the phase'
}

preview_options()
{
    printf '%s\n' '{"action":"preview","fee_rate":100,"max_fee_per_resolution":0.00019100,"max_total_fee":0.00019100}'
}

signed_preview_options()
{
    # Explicit fee_rate is forbidden by Core for already-signed bytes.  The
    # immutable 0.00019100 fee and both absolute caps remain exact.
    printf '%s\n' '{"action":"preview","max_fee_per_resolution":0.00019100,"max_total_fee":0.00019100}'
}

validate_chain_network()
{
    jq -e '
        .chain == "main" and .blocks == .headers and
        .initialblockdownload == false and .pruned == false and
        (.warnings // "") == "" and
        (.bestblockhash | test("^[0-9a-f]{64}$")) and
        (.blocks | type == "number" and floor == . and . > 0)
    ' >/dev/null <<< "$CHAIN" || die 'chain is not an exact synchronized unpruned mainnet view'
    jq -e --argjson version "$NETWORK_VERSION" --arg subversion "$SUBVERSION" '
        .version == $version and .subversion == $subversion and
        .networkactive == true and (.connections // 0) > 0 and
        (.connections_out // 0) > 0 and (.warnings // "") == ""
    ' >/dev/null <<< "$NETWORK" || die 'installed v30.1.4 network identity is not exact and connected'
}

validate_wallet_and_roles()
{
    jq -e '. == [""]' >/dev/null <<< "$WALLETS" ||
        die 'loaded-wallet inventory is not exactly the unnamed node27 wallet'
    jq -e '
        .walletname == "" and .format == "sqlite" and
        .private_keys_enabled == true and (.external_signer // false) == false and
        (.scanning // false) == false and .unlocked_staking_only == false and
        (.unlocked_until // 0) > 0 and (.txcount | type == "number" and floor == .)
    ' >/dev/null <<< "$WALLET_INFO" || die 'node27 wallet identity or normal unlock is unavailable'
    jq -e '.enabled == true and .staking == true and (.weight // 0) > 0' \
        >/dev/null <<< "$STAKING" || die 'node27 PoS is not actively searching with positive weight'
    jq -e --arg payout "$PAYOUT_ADDRESS" '
        .enabled == true and .threads == 1 and .cpu_percent == 1 and
        .state == "claim_quarantined" and .hashrate == 0 and
        .claims_submitted == 4 and .blocking_quarantined_claims == 1 and
        .actionable_quarantined_claims == 1 and
        .indeterminate_quarantined_claims == 0 and .live_claims == 0 and
        .pending_manual_resolutions == 0 and
        .pending_automatic_resolutions == 0 and
        .claim_recovery_database_outcome_ambiguous == false and
        .payout_address == $payout and
        .allow_automatic_quantum_key_creation == false and
        .configured_stake_reserve_coins == 1 and
        (.claim_coins_after_stake_reserve // 0) > 0
    ' >/dev/null <<< "$MINING" || die 'node27 installed PoS/PoW role baseline changed'
    jq -e --arg address "$ANCHOR_ADDRESS" --arg script "$ANCHOR_SCRIPT" '
        .address == $address and .scriptPubKey == $script and .ismine == true and
        .solvable == true and .iswatchonly == false and .ischange == false
    ' >/dev/null <<< "$ANCHOR_ADDRESS_INFO" || die 'anchor address ownership changed'
    jq -e --arg address "$PAYOUT_ADDRESS" --arg script "$PAYOUT_SCRIPT" '
        .address == $address and .scriptPubKey == $script and .ismine == true and
        .solvable == true and .iswatchonly == false and .ischange == false and
        (.labels | index("PoW - Quantum Claim Address") != null)
    ' >/dev/null <<< "$PAYOUT_ADDRESS_INFO" || die 'pinned quantum payout ownership or label changed'
}

validate_anchor_claim_component()
{
    jq -e --arg txid "$ANCHOR_TXID" --argjson vout "$ANCHOR_VOUT" \
        --argjson amount "$ANCHOR_AMOUNT" --arg script "$ANCHOR_SCRIPT" '
        .confirmations >= 1 and .value == $amount and
        .scriptPubKey.hex == $script and .scriptPubKey.address == "B5DM1sc2SDmwyisnMyARttVXcHZdtcAsct" and
        .coinbase == false and .coinstake == false
    ' >/dev/null <<< "$ANCHOR_UTXO" || die 'exact confirmed recovery anchor is absent or changed'

    jq -e --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson vout "$ANCHOR_VOUT" --arg script "$ANCHOR_SCRIPT" \
        --argjson value "$CLAIM_RETURN_AMOUNT" --argjson fee "-$CLAIM_FEE" \
        --argjson vsize "$CLAIM_VSIZE" '
        .txid == $claim and .confirmations == 0 and .trusted == false and
        (.details | length) == 1 and .details[0].category == "send" and
        .details[0].fee == $fee and .details[0].abandoned == false and
        .decoded.txid == $claim and .decoded.version == 2 and
        .decoded.vsize == $vsize and (.decoded.vin | length) == 1 and
        .decoded.vin[0].txid == $anchor and .decoded.vin[0].vout == $vout and
        (.decoded.vout | length) == 2 and .decoded.vout[0].n == 0 and
        .decoded.vout[0].value == $value and
        .decoded.vout[0].scriptPubKey.hex == $script and
        .decoded.vout[1].n == 1 and .decoded.vout[1].value == 0 and
        .decoded.vout[1].scriptPubKey.type == "nulldata"
    ' >/dev/null <<< "$CLAIM_TX" || die 'exact retained QQP2 claim shape changed'
    jq -e --arg claim "$CLAIM_TXID" 'type == "array" and index($claim) == null' \
        >/dev/null <<< "$MEMPOOL" || die 'retained claim unexpectedly entered the local mempool'

    jq -e --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson vout "$ANCHOR_VOUT" --argjson amount "$ANCHOR_AMOUNT" \
        --arg script "$ANCHOR_SCRIPT" --arg generation "$GENERATION_FINGERPRINT" '
        .policy_authoritative == true and .policy.mode == "unset" and
        .chain_ready == true and .database_outcome_ambiguous == false and
        .wallet_tip_matches == true and .active_tip == .wallet_processed_tip and
        .active_height == .wallet_processed_height and
        .blocking_components == 1 and .blocking_quarantined_claims == 1 and
        .actionable_quarantined_claims == 1 and
        .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0 and
        (.unanchored_claim_txids | length) == 0 and
        ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == $vout)] | length) == 1 and
        ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == $vout)][0] |
          .anchor == {txid:$anchor,vout:$vout,amount:$amount,scriptPubKey:$script} and
          .generation_fingerprint == $generation and
          (.component_fingerprint | test("^[0-9a-f]{64}$")) and
          .classification == "current_branch_ineligible" and
          .claim_txids == [$claim] and .root_claim_txids == [$claim] and
          .resolution_txids == [] and .ordinary_or_mixed_txids == [] and
          .descendant_claims == 0 and .minimum_stale_depth >= 9000 and
          .stale_depth_known == true and .anchor_authenticated == true and
          .anchor_unspent == true and .all_claims_quarantined == true and
          .all_claims_explicitly_provenanced == true and
          .all_claims_zero_payment_retirable == false and
          .all_claims_expired_locally_retired == false and
          .has_revalidating_unbound_proof == true and
          (.nodes | length) == 1 and .nodes[0].txid == $claim and
          .nodes[0].kind == "claim" and .nodes[0].provenance == "explicit_authored" and
          .nodes[0].disposition == "unbound_proof_may_revalidate" and
          .nodes[0].proof_may_revalidate_on_descendant == true and
          .nodes[0].active_chain_confirmed == false and .nodes[0].in_mempool == false and
          .nodes[0].quarantined == true and .nodes[0].expected_shape == true and
          .nodes[0].wallet_authored == true and .nodes[0].abandoned == false and
          .nodes[0].expired_locally_retired == false and
          .nodes[0].stale_depth_known == true and .nodes[0].stale_depth >= 9000 and
          .nodes[0].resolution_metadata_valid == false and
          .nodes[0].resolution_relay_authorized == false)
    ' >/dev/null <<< "$RECOVERY" || die 'exact node27 blocking component changed or became unsafe'
}

validate_unsigned_preview()
{
    jq -e --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson vout "$ANCHOR_VOUT" --arg generation "$GENERATION_FINGERPRINT" \
        --argjson fee "$RECOVERY_FEE" --argjson input "$ANCHOR_AMOUNT" \
        --argjson output "$RECOVERY_OUTPUT_AMOUNT" --argjson vsize "$RECOVERY_VSIZE" \
        --argjson rate "$FEE_RATE_ATOMS_PER_K" '
        .action == "preview" and .plan_reusable == true and .complete == true and
        .wallet_tip_matches == true and .one_call_finality == false and
        .frontier_may_advance == true and .contains_revalidating_unbound_proof == true and
        .max_fee_per_resolution == $fee and .aggregate_batch_fee_cap == $fee and
        .fee_rate_atoms_per_k == $rate and .total_fee == $fee and
        .actionable_components == 1 and (.actions | length) == 1 and
        .success == true and .stale_plan == false and
        .durable_state_changed == false and .durable_state_ambiguous == false and
        .signed_and_persisted == 0 and .relay_authority_granted == 0 and
        .broadcast == 0 and .already_in_mempool == 0 and .relay_deferred == 0 and
        (.plan_id | test("^[0-9a-f]{64}$")) and
        (.active_tip | test("^[0-9a-f]{64}$")) and
        (.active_height | type == "number" and floor == . and . > 0) and
        (.wallet_generation | type == "number" and floor == . and . >= 0) and
        (.actions[0] |
          .anchor == {txid:$anchor,vout:$vout} and
          .generation_fingerprint == $generation and
          (.component_fingerprint | test("^[0-9a-f]{64}$")) and
          .classification == "current_branch_ineligible" and .status == "ready" and
          .claim_txids == [$claim] and .descendant_claims == 0 and .fee == $fee and
          .persisted == false and .relay_authorized == false and .in_mempool == false and
          .frontier_may_advance == true and
          .conflicts_with_revalidating_unbound_proof == true and
          .reason_code == "unbound-proof-may-revalidate" and
          (.unsigned_template_hash | test("^[0-9a-f]{64}$")) and
          .vsize == $vsize and .input_amount == $input and .output_amount == $output) and
        all(.refused[]?; .reason_code == "anchor-spent")
    ' >/dev/null <<< "$PREVIEW" || die 'exact one-transaction preview exceeded authority'
    jq -e -n --argjson p "$PREVIEW" --argjson r "$RECOVERY" --argjson c "$CHAIN" '
        $p.active_tip == $r.active_tip and $p.active_height == $r.active_height and
        $p.active_tip == $c.bestblockhash and $p.active_height == $c.blocks and
        $p.wallet_generation == $r.wallet_generation and
        $p.actions[0].component_fingerprint ==
          ([$r.component_details[] | select(.anchor.txid == "3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87" and .anchor.vout == 0)][0].component_fingerprint)
    ' >/dev/null || die 'preview is not bound to the exact verbose component cut'
}

collect_unsigned_audit()
{
    local before after runtime_before runtime_after
    for _ in 1 2 3; do
        runtime_before=$(runtime_snapshot)
        before=$(rpc getblockchaininfo) || die 'initial chain bracket failed'
        NETWORK=$(rpc getnetworkinfo) || die 'network RPC failed'
        WALLETS=$(rpc listwallets) || die 'loaded-wallet RPC failed'
        WALLET_INFO=$(rpc getwalletinfo) || die 'wallet RPC failed'
        STAKING=$(rpc getstakinginfo) || die 'staking RPC failed'
        MINING=$(rpc getpowmininginfo) || die 'PoW RPC failed'
        RECOVERY=$(rpc getpowclaimrecoveryinfo true) || die 'verbose recovery RPC failed'
        ANCHOR_UTXO=$(rpc gettxout "$ANCHOR_TXID" "$ANCHOR_VOUT" true) ||
            die 'anchor UTXO RPC failed'
        CLAIM_TX=$(rpc gettransaction "$CLAIM_TXID" false true) ||
            die 'claim transaction RPC failed'
        MEMPOOL=$(rpc getrawmempool) || die 'mempool RPC failed'
        ANCHOR_ADDRESS_INFO=$(rpc getaddressinfo "$ANCHOR_ADDRESS") ||
            die 'anchor address RPC failed'
        PAYOUT_ADDRESS_INFO=$(rpc getaddressinfo "$PAYOUT_ADDRESS") ||
            die 'payout address RPC failed'
        QUANTUM_KEYS=$(rpc getquantumkeyinventory) || die 'quantum inventory RPC failed'
        PREVIEW=$(rpc resolveallshadowpowclaims "$(preview_options)") ||
            die 'read-only recovery preview failed'
        after=$(rpc getblockchaininfo) || die 'final chain bracket failed'
        runtime_after=$(runtime_snapshot)
        if jq -e -n --argjson a "$before" --argjson b "$after" \
                '$a.bestblockhash == $b.bestblockhash and $a.blocks == $b.blocks' >/dev/null &&
           jq -e -n --argjson a "$runtime_before" --argjson b "$runtime_after" '$a == $b' >/dev/null; then
            CHAIN=$after
            RUNTIME=$runtime_after
            validate_chain_network
            validate_wallet_and_roles
            validate_anchor_claim_component
            validate_unsigned_preview
            return
        fi
    done
    die 'node27 could not produce one stable read-only audit cut in three attempts'
}

key_fingerprint()
{
    jq -S -c '{walletname,walletversion,format,private_keys_enabled,
      keypoololdest,keypoolsize,keypoolsize_hd_internal,unlocked_staking_only}' <<< "$1" |
        hash_stdin
}

audit_receipt_json()
{
    local key_sha quantum_sha component
    key_sha=$(key_fingerprint "$WALLET_INFO")
    quantum_sha=$(jq -S -c . <<< "$QUANTUM_KEYS" | hash_stdin)
    component=$(jq -c --arg anchor "$ANCHOR_TXID" \
        '[.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)][0]' \
        <<< "$RECOVERY")
    jq -n -c \
        --arg contract "$CONTRACT" --arg phase audit --arg tool "$TOOL_SHA256" \
        --arg docker_path "$DOCKER_PATH" --arg docker_sha "$DOCKER_SHA256" \
        --arg source "$SOURCE_COMMIT" --arg wallet "$WALLET" \
        --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg amount "$ANCHOR_AMOUNT" --arg script "$ANCHOR_SCRIPT" \
        --arg generation "$GENERATION_FINGERPRINT" --arg payout "$PAYOUT_ADDRESS" \
        --arg fee "$RECOVERY_FEE" --argjson node "$NODE_ID" \
        --argjson runtime "$RUNTIME" --argjson chain "$CHAIN" \
        --argjson wallet_info "$WALLET_INFO" --arg key_sha "$key_sha" \
        --arg quantum_sha "$quantum_sha" --argjson staking "$STAKING" \
        --argjson mining "$MINING" --argjson recovery "$RECOVERY" \
        --argjson preview "$PREVIEW" --argjson component "$component" '
        {schema:1,contract:$contract,phase:$phase,result:"approved_for_external_financial_review",
         mutation_performed:false,tool_sha256:$tool,
         transport:{docker_path:$docker_path,docker_sha256:$docker_sha},
         installed_source:{commit:$source,network_version:300104,subversion:"/Blackcoin:30.1.4/"},
         runtime:$runtime,
         wallet:{name:$wallet,format:$wallet_info.format,walletversion:$wallet_info.walletversion,
           txcount:$wallet_info.txcount,key_fingerprint_sha256:$key_sha,
           quantum_inventory_sha256:$quantum_sha,payout_address:$payout,
           payout_address_unchanged_required:true,key_creation_authorized:false},
         chain:{height:$chain.blocks,tip:$chain.bestblockhash},
         subject:{claim_txid:$claim,anchor:{txid:$anchor,vout:0,amount_blk:$amount,
           script_pub_key:$script},generation_fingerprint:$generation,
           component_fingerprint:$component.component_fingerprint,
           classification:$component.classification,
           conflict:"unbound_proof_may_revalidate"},
         plan:{plan_id:$preview.plan_id,active_tip:$preview.active_tip,
           active_height:$preview.active_height,wallet_generation:$preview.wallet_generation,
           component_fingerprint:$preview.actions[0].component_fingerprint,
           unsigned_template_hash:$preview.actions[0].unsigned_template_hash,
           transaction_count:1,fee_rate_sat_vb:100,fee_rate_atoms_per_k:100000,
           vsize:191,input_amount_blk:"9.83326930",output_amount_blk:"9.83307830",
           fee_blk:$fee,max_fee_per_resolution_blk:$fee,max_total_fee_blk:$fee,
           other_inputs_allowed:false,change_output:false,new_key_or_address:false},
         baseline:{claims_submitted:$mining.claims_submitted,
           confirmed_manual_resolutions:$recovery.confirmed_manual_resolutions,
           confirmed_resolution_fees:$recovery.confirmed_resolution_fees,
           pos_enabled:$staking.enabled,pos_staking:$staking.staking,pos_weight:$staking.weight,
           pow_enabled:$mining.enabled,pow_threads:$mining.threads,pow_cpu_percent:$mining.cpu_percent,
           pow_state:$mining.state,pow_hashrate:$mining.hashrate},
         required_next_authority:{schema:1,
           authority:"node27-v30.1.4-recovery-sign-only",decision:"authorize",
           audit_receipt_sha256:"REPLACE_WITH_AUDIT_RECEIPT_SHA256",
           tool_sha256:$tool,transport_sha256:$docker_sha,node:27,service:"node27",
           container:"blackcoin-v4-gui-27",image_ref:$runtime.image_ref,image_id:$runtime.image_id,
           wallet:$wallet,claim_txid:$claim,anchor_txid:$anchor,anchor_vout:0,
           generation_fingerprint:$generation,plan_id:$preview.plan_id,
           active_tip:$preview.active_tip,active_height:$preview.active_height,
           wallet_generation:$preview.wallet_generation,
           component_fingerprint:$preview.actions[0].component_fingerprint,
           unsigned_template_hash:$preview.actions[0].unsigned_template_hash,
           transaction_count:1,fee_rate_sat_vb:100,fee_blk:$fee,
           max_fee_per_resolution_blk:$fee,max_total_fee_blk:$fee,
           acknowledgements:{fee_and_conflict_risk:true,
             unbound_qqp2_may_revalidate:true,potential_quantum_payout_forfeiture:true,
             durable_draft_has_no_public_delete:true,no_relay_authority_in_this_phase:true,
             future_pow_claim_fees_not_capped_by_this_receipt:true,
             no_generic_transaction_rpc:true,no_fleet_expansion:true}}}
    '
}

validate_audit_receipt()
{
    require_receipt_file "$AUDIT_RECEIPT" "$AUDIT_SHA256" 'audit receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg docker_path "$DOCKER_PATH" --arg docker_sha "$DOCKER_SHA256" \
        --arg source "$SOURCE_COMMIT" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --arg fee "$RECOVERY_FEE" '
        .schema == 1 and .contract == $contract and .phase == "audit" and
        .result == "approved_for_external_financial_review" and
        .mutation_performed == false and .tool_sha256 == $tool and
        .transport == {docker_path:$docker_path,docker_sha256:$docker_sha} and
        .installed_source.commit == $source and
        .runtime == {node:27,service:"node27",container:"blackcoin-v4-gui-27",
          compose_project:"blackcoin30",image_ref:"qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2",
          image_id:"sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909",
          container_id:.runtime.container_id,started_at:.runtime.started_at,healthy:true} and
        .wallet.name == "" and .wallet.payout_address == "blk1s0hl7dsh5huajtwtx5ve65qjfwearvctxtm7c88t6vcc9m8qeam4s43es72" and
        .wallet.payout_address_unchanged_required == true and
        .wallet.key_creation_authorized == false and
        .subject.claim_txid == $claim and .subject.anchor.txid == $anchor and
        .subject.anchor.vout == 0 and .subject.generation_fingerprint == $generation and
        .subject.classification == "current_branch_ineligible" and
        .subject.conflict == "unbound_proof_may_revalidate" and
        .plan.transaction_count == 1 and .plan.fee_rate_sat_vb == 100 and
        .plan.vsize == 191 and .plan.fee_blk == $fee and
        .plan.max_fee_per_resolution_blk == $fee and .plan.max_total_fee_blk == $fee and
        .plan.other_inputs_allowed == false and .plan.change_output == false and
        .plan.new_key_or_address == false and .baseline.claims_submitted == 4 and
        (.plan.plan_id | test("^[0-9a-f]{64}$")) and
        (.plan.active_tip | test("^[0-9a-f]{64}$")) and
        (.plan.component_fingerprint | test("^[0-9a-f]{64}$")) and
        (.plan.unsigned_template_hash | test("^[0-9a-f]{64}$"))
    ' "$AUDIT_RECEIPT" >/dev/null || die 'audit receipt does not bind the exact node27 subject'
}

validate_sign_authority()
{
    require_receipt_file "$AUTHORITY_RECEIPT" "$AUTHORITY_SHA256" 'sign authority receipt'
    jq -e --arg audit_sha "$AUDIT_SHA256" --arg tool "$TOOL_SHA256" \
        --arg transport "$DOCKER_SHA256" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --arg fee "$RECOVERY_FEE" \
        --slurpfile audit "$AUDIT_RECEIPT" '
        keys == ["acknowledgements","active_height","active_tip","anchor_txid","anchor_vout",
          "audit_receipt_sha256","authority","claim_txid","component_fingerprint","container",
          "decision","fee_blk","fee_rate_sat_vb","generation_fingerprint","image_id","image_ref",
          "max_fee_per_resolution_blk","max_total_fee_blk","node","plan_id","schema","service",
          "tool_sha256","transaction_count","transport_sha256","unsigned_template_hash","wallet",
          "wallet_generation"] and
        .schema == 1 and .authority == "node27-v30.1.4-recovery-sign-only" and
        .decision == "authorize" and .audit_receipt_sha256 == $audit_sha and
        .tool_sha256 == $tool and .transport_sha256 == $transport and
        .node == 27 and .service == "node27" and .container == "blackcoin-v4-gui-27" and
        .image_ref == $audit[0].runtime.image_ref and .image_id == $audit[0].runtime.image_id and
        .wallet == "" and .claim_txid == $claim and .anchor_txid == $anchor and
        .anchor_vout == 0 and .generation_fingerprint == $generation and
        .plan_id == $audit[0].plan.plan_id and .active_tip == $audit[0].plan.active_tip and
        .active_height == $audit[0].plan.active_height and
        .wallet_generation == $audit[0].plan.wallet_generation and
        .component_fingerprint == $audit[0].plan.component_fingerprint and
        .unsigned_template_hash == $audit[0].plan.unsigned_template_hash and
        .transaction_count == 1 and .fee_rate_sat_vb == 100 and .fee_blk == $fee and
        .max_fee_per_resolution_blk == $fee and .max_total_fee_blk == $fee and
        .acknowledgements == {fee_and_conflict_risk:true,
          unbound_qqp2_may_revalidate:true,potential_quantum_payout_forfeiture:true,
          durable_draft_has_no_public_delete:true,no_relay_authority_in_this_phase:true,
          future_pow_claim_fees_not_capped_by_this_receipt:true,
          no_generic_transaction_rpc:true,no_fleet_expansion:true}
    ' "$AUTHORITY_RECEIPT" >/dev/null || die 'sign authority receipt is not exact'
}

assert_current_audit_matches_receipt()
{
    local current
    current=$(audit_receipt_json)
    jq -e -n --argjson old "$(cat "$AUDIT_RECEIPT")" --argjson new "$current" '
        $old.tool_sha256 == $new.tool_sha256 and
        $old.transport == $new.transport and $old.runtime == $new.runtime and
        $old.wallet == $new.wallet and $old.chain == $new.chain and
        $old.subject == $new.subject and $old.plan == $new.plan and
        $old.baseline == $new.baseline
    ' >/dev/null || die 'audit plan, tip, wallet generation, or subject changed before signing'
}

validate_signed_transaction()
{
    local decoded=$1 txid=$2
    jq -e --arg txid "$txid" --arg anchor "$ANCHOR_TXID" --arg script "$ANCHOR_SCRIPT" \
        --argjson vout "$ANCHOR_VOUT" --argjson value "$RECOVERY_OUTPUT_AMOUNT" \
        --argjson vsize "$RECOVERY_VSIZE" '
        .txid == $txid and .version == 2 and .vsize == $vsize and .locktime == 0 and
        (.vin | length) == 1 and .vin[0].txid == $anchor and .vin[0].vout == $vout and
        .vin[0].sequence == 4294967295 and
        (.vin[0].scriptSig.hex | type == "string" and length > 0) and
        (.vout | length) == 1 and .vout[0].n == 0 and .vout[0].value == $value and
        .vout[0].scriptPubKey.hex == $script and .vout[0].scriptPubKey.type == "pubkeyhash"
    ' >/dev/null <<< "$decoded" || die 'signed recovery bytes violate exact one-input/one-output shape'
}

validate_sign_result()
{
    local result=$1 plan=$2
    jq -e --arg plan "$plan" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --argjson fee "$RECOVERY_FEE" '
        .action == "sign_only" and .success == true and .stale_plan == false and
        .durable_state_changed == true and .durable_state_ambiguous == false and
        .plan_consumed == true and .acknowledged_plan_id == $plan and
        .acknowledged_total_fee == $fee and .signed_and_persisted == 1 and
        .relay_authority_granted == 0 and .broadcast == 0 and
        .already_in_mempool == 0 and .relay_deferred == 0 and
        (.actions | length) == 1 and (.actions[0] |
          .anchor == {txid:$anchor,vout:0} and .claim_txids == [$claim] and
          .generation_fingerprint == $generation and .fee == $fee and
          .status == "signed_and_persisted" and .persisted == true and
          .relay_authorized == false and .in_mempool == false and
          (.resolution_txid | test("^[0-9a-f]{64}$")) and
          (.hex | test("^[0-9a-f]+$") and (length % 2 == 0)))
    ' >/dev/null <<< "$result" || die 'sign-only RPC result exceeded exact authority'
}

validate_signed_preview()
{
    local preview=$1 txid=$2 recovery=$3 chain=$4
    jq -e --arg txid "$txid" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --argjson fee "$RECOVERY_FEE" '
        .action == "preview" and .complete == true and .wallet_tip_matches == true and
        .plan_reusable == true and .success == true and .durable_state_changed == false and
        .durable_state_ambiguous == false and .max_fee_per_resolution == $fee and
        .aggregate_batch_fee_cap == $fee and .total_fee == $fee and
        .actionable_components == 1 and (.actions | length) == 1 and
        (.plan_id | test("^[0-9a-f]{64}$")) and
        (.active_tip | test("^[0-9a-f]{64}$")) and
        (.active_height | type == "number" and floor == . and . > 0) and
        (.wallet_generation | type == "number" and floor == . and . >= 0) and
        (.actions[0] | .anchor == {txid:$anchor,vout:0} and
          .generation_fingerprint == $generation and
          (.component_fingerprint | test("^[0-9a-f]{64}$")) and
          .claim_txids == [$claim] and .descendant_claims == 0 and
          .status == "reuse_managed" and .resolution_txid == $txid and .fee == $fee and
          .vsize == 191 and .input_amount == 9.83326930 and .output_amount == 9.83307830 and
          .persisted == true and .relay_authorized == false and .in_mempool == false)
    ' >/dev/null <<< "$preview" || die 'signed-byte preview is not the exact nonauthorized plan'
    jq -e -n --argjson p "$preview" --argjson r "$recovery" --argjson c "$chain" \
        --arg anchor "$ANCHOR_TXID" '
        $p.active_tip == $r.active_tip and $p.active_height == $r.active_height and
        $p.active_tip == $c.bestblockhash and $p.active_height == $c.blocks and
        $p.wallet_generation == $r.wallet_generation and
        $p.actions[0].component_fingerprint ==
          ([$r.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)][0].component_fingerprint)
    ' >/dev/null || die 'signed-byte plan is not bound to the exact chain/component cut'
}

validate_post_sign_state()
{
    local txid=$1 baseline_txcount=$2 baseline_key=$3 baseline_quantum=$4
    local wallet mining staking recovery mempool quantum persisted key_after quantum_after preview chain_after
    wallet=$(rpc getwalletinfo) || die 'post-sign wallet RPC failed'
    mining=$(rpc getpowmininginfo) || die 'post-sign PoW RPC failed'
    staking=$(rpc getstakinginfo) || die 'post-sign PoS RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'post-sign recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'post-sign mempool RPC failed'
    quantum=$(rpc getquantumkeyinventory) || die 'post-sign quantum inventory failed'
    preview=$(rpc resolveallshadowpowclaims "$(signed_preview_options)") ||
        die 'post-sign exact managed-byte preview failed'
    chain_after=$(rpc getblockchaininfo) || die 'post-sign chain bracket failed'
    persisted=$(rpc gettransaction "$txid" false true) || die 'persisted resolution is unavailable'
    key_after=$(key_fingerprint "$wallet")
    quantum_after=$(jq -S -c . <<< "$quantum" | hash_stdin)
    jq -e --argjson before "$baseline_txcount" '.txcount == ($before + 1)' \
        >/dev/null <<< "$wallet" || die 'sign-only did not add exactly one wallet transaction'
    [[ "$key_after" == "$baseline_key" && "$quantum_after" == "$baseline_quantum" ]] ||
        die 'sign-only changed legacy or quantum key inventory'
    jq -e --arg payout "$PAYOUT_ADDRESS" '
        .enabled == true and .threads == 1 and .cpu_percent == 1 and
        .payout_address == $payout and .claims_submitted == 4 and
        .state == "claim_quarantined" and .hashrate == 0 and
        .allow_automatic_quantum_key_creation == false
    ' >/dev/null <<< "$mining" || die 'sign-only changed PoW intent, payout, or submission counter'
    jq -e '.enabled == true and .staking == true and (.weight // 0) > 0' \
        >/dev/null <<< "$staking" || die 'PoS changed during sign-only'
    jq -e --arg txid "$txid" 'index($txid) == null' >/dev/null <<< "$mempool" ||
        die 'signed draft unexpectedly has local mempool presence'
    jq -e --arg txid "$txid" '.txid == $txid and .confirmations == 0 and
        (.details | all(.abandoned == false))' >/dev/null <<< "$persisted" ||
        die 'persisted resolution wallet record changed'
    jq -e --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" --arg txid "$txid" \
        --arg generation "$GENERATION_FINGERPRINT" '
        .database_outcome_ambiguous == false and .wallet_tip_matches == true and
        .blocking_components == 1 and .pending_manual_resolutions == 1 and
        .pending_automatic_resolutions == 0 and
        ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)] | length) == 1 and
        ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)][0] |
          .generation_fingerprint == $generation and .classification == "resolution_pending" and
          .claim_txids == [$claim] and .root_claim_txids == [$claim] and
          .resolution_txids == [$txid] and .ordinary_or_mixed_txids == [] and
          .anchor_authenticated == true and .anchor_unspent == true and
          ([.nodes[] | select(.txid == $txid and .kind == "managed_resolution" and
            .active_chain_confirmed == false and .in_mempool == false and
            .abandoned == false and .resolution_metadata_valid == true and
            .resolution_relay_authorized == false)] | length) == 1)
    ' >/dev/null <<< "$recovery" || die 'post-sign managed draft inventory is not exact'
    jq -e -n --argjson a "$CHAIN" --argjson b "$chain_after" \
        '$a.bestblockhash == $b.bestblockhash and $a.blocks == $b.blocks' >/dev/null ||
        die 'tip changed across sign-only evidence cut'
    validate_signed_preview "$preview" "$txid" "$recovery" "$chain_after"
    POST_WALLET=$wallet
    POST_MINING=$mining
    POST_STAKING=$staking
    POST_RECOVERY=$recovery
    POST_KEY_SHA=$key_after
    POST_QUANTUM_SHA=$quantum_after
}

run_sign_only()
{
    local plan options result txid hex decoded hex_sha baseline_txcount baseline_key baseline_quantum receipt
    [[ -n "$OUTPUT" ]] || die 'sign-only requires --output'
    validate_audit_receipt
    validate_sign_authority
    collect_unsigned_audit
    assert_current_audit_matches_receipt
    plan=$(jq -r '.plan.plan_id' "$AUDIT_RECEIPT")
    baseline_txcount=$(jq -r '.wallet.txcount' "$AUDIT_RECEIPT")
    baseline_key=$(jq -r '.wallet.key_fingerprint_sha256' "$AUDIT_RECEIPT")
    baseline_quantum=$(jq -r '.wallet.quantum_inventory_sha256' "$AUDIT_RECEIPT")
    options=$(jq -cn --arg plan "$plan" \
        '{action:"sign_only",expected_plan_id:$plan,
          acknowledge_fee_and_conflict_risk:true,fee_rate:100,
          max_fee_per_resolution:0.00019100,max_total_fee:0.00019100}')
    result=$(rpc resolveallshadowpowclaims "$options") || die 'sign-only RPC failed closed'
    validate_sign_result "$result" "$plan"
    txid=$(jq -r '.actions[0].resolution_txid' <<< "$result")
    hex=$(jq -r '.actions[0].hex' <<< "$result")
    decoded=$(rpc decoderawtransaction "$hex") || die 'signed bytes could not be decoded'
    validate_signed_transaction "$decoded" "$txid"
    hex_sha=$(printf '%s' "$hex" | hash_stdin)
    assert_runtime_unchanged "$RUNTIME"
    validate_post_sign_state "$txid" "$baseline_txcount" "$baseline_key" "$baseline_quantum"
    assert_runtime_unchanged "$RUNTIME"
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg audit_sha "$AUDIT_SHA256" --arg authority_sha "$AUTHORITY_SHA256" \
        --arg txid "$txid" --arg hex_sha "$hex_sha" --arg fee "$RECOVERY_FEE" \
        --argjson runtime "$RUNTIME" --argjson decoded "$decoded" \
        --argjson execution "$result" --argjson wallet "$POST_WALLET" \
        --argjson mining "$POST_MINING" --argjson staking "$POST_STAKING" \
        --argjson recovery "$POST_RECOVERY" --arg key_sha "$POST_KEY_SHA" \
        --arg quantum_sha "$POST_QUANTUM_SHA" '
        {schema:1,contract:$contract,phase:"sign-only",result:"signed_nonrelayable_draft",
         mutation_performed:true,tool_sha256:$tool,audit_receipt_sha256:$audit_sha,
         financial_authority_receipt_sha256:$authority_sha,runtime:$runtime,
         subject:{claim_txid:"2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d",
           anchor_txid:"3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87",
           anchor_vout:0,generation_fingerprint:"0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860"},
         signed_transaction:{txid:$txid,hex_sha256:$hex_sha,decoded:$decoded,
           fee_blk:$fee,persisted:true,relay_authorized:false,in_mempool:false},
         execution:$execution,
         post_state:{wallet_txcount:$wallet.txcount,key_fingerprint_sha256:$key_sha,
           quantum_inventory_sha256:$quantum_sha,payout_address:$mining.payout_address,
           claims_submitted:$mining.claims_submitted,pow_enabled:$mining.enabled,
           pow_state:$mining.state,pow_hashrate:$mining.hashrate,
           pos_enabled:$staking.enabled,pos_staking:$staking.staking,pos_weight:$staking.weight,
           pending_manual_resolutions:$recovery.pending_manual_resolutions,
           database_outcome_ambiguous:$recovery.database_outcome_ambiguous},
         next_authority:{required:true,authority:"node27-v30.1.4-targeted-recovery-relay",
           exact_resolution_txid:$txid,sign_receipt_sha256:"REPLACE_WITH_SIGN_RECEIPT_SHA256",
           durable_relay_across_restart:true,recall_available:false,
           generic_sendrawtransaction_authorized:false,fleet_expansion_authorized:false}}
    ')
    write_receipt "$receipt"
}

validate_sign_receipt()
{
    require_receipt_file "$SIGN_RECEIPT" "$SIGN_SHA256" 'sign receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" --arg claim "$CLAIM_TXID" \
        --arg anchor "$ANCHOR_TXID" --arg generation "$GENERATION_FINGERPRINT" \
        --arg fee "$RECOVERY_FEE" '
        .schema == 1 and .contract == $contract and .phase == "sign-only" and
        .result == "signed_nonrelayable_draft" and .mutation_performed == true and
        .tool_sha256 == $tool and .subject.claim_txid == $claim and
        .subject.anchor_txid == $anchor and .subject.anchor_vout == 0 and
        .subject.generation_fingerprint == $generation and
        (.signed_transaction.txid | test("^[0-9a-f]{64}$")) and
        (.signed_transaction.hex_sha256 | test("^[0-9a-f]{64}$")) and
        .signed_transaction.fee_blk == $fee and .signed_transaction.persisted == true and
        .signed_transaction.relay_authorized == false and .signed_transaction.in_mempool == false and
        .post_state.claims_submitted == 4 and .post_state.pow_enabled == true and
        .post_state.pos_enabled == true and .post_state.pos_staking == true and
        .post_state.database_outcome_ambiguous == false
    ' "$SIGN_RECEIPT" >/dev/null || die 'sign receipt is not exact'
}

validate_relay_authority()
{
    require_receipt_file "$AUTHORITY_RECEIPT" "$AUTHORITY_SHA256" 'relay authority receipt'
    jq -e --arg sign_sha "$SIGN_SHA256" --arg tool "$TOOL_SHA256" \
        --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" --arg fee "$RECOVERY_FEE" \
        --slurpfile sign "$SIGN_RECEIPT" '
        keys == ["acknowledgements","anchor_txid","anchor_vout","authority","claim_txid",
          "decision","fee_blk","image_id","image_ref","node","resolution_txid","schema",
          "service","sign_receipt_sha256","tool_sha256","transaction_count","wallet"] and
        .schema == 1 and .authority == "node27-v30.1.4-targeted-recovery-relay" and
        .decision == "authorize" and .sign_receipt_sha256 == $sign_sha and
        .tool_sha256 == $tool and .node == 27 and .service == "node27" and
        .image_ref == $sign[0].runtime.image_ref and .image_id == $sign[0].runtime.image_id and
        .wallet == "" and .claim_txid == $claim and .anchor_txid == $anchor and
        .anchor_vout == 0 and .resolution_txid == $sign[0].signed_transaction.txid and
        .transaction_count == 1 and .fee_blk == $fee and
        .acknowledgements == {exact_signed_bytes_reviewed:true,
          fee_and_conflict_risk:true,unbound_qqp2_may_revalidate:true,
          potential_quantum_payout_forfeiture:true,durable_relay_across_restart:true,
          propagated_transaction_cannot_be_recalled:true,
          original_claim_or_resolution_may_confirm:true,
          future_pow_claim_fees_not_capped_by_this_receipt:true,
          no_generic_transaction_rpc:true,no_fee_bump_or_replacement:true,
          no_fleet_expansion:true}
    ' "$AUTHORITY_RECEIPT" >/dev/null || die 'relay authority receipt is not exact'
}

validate_persisted_pre_relay()
{
    local txid=$1 expected_runtime=$2 expected_key=$3 expected_quantum=$4
    local wallet mining staking recovery mempool persisted preview key_sha quantum quantum_sha decoded
    assert_runtime_unchanged "$expected_runtime"
    wallet=$(rpc getwalletinfo) || die 'pre-relay wallet RPC failed'
    mining=$(rpc getpowmininginfo) || die 'pre-relay PoW RPC failed'
    staking=$(rpc getstakinginfo) || die 'pre-relay PoS RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'pre-relay recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'pre-relay mempool RPC failed'
    persisted=$(rpc gettransaction "$txid" false true) || die 'pre-relay signed tx is unavailable'
    quantum=$(rpc getquantumkeyinventory) || die 'pre-relay quantum inventory failed'
    key_sha=$(key_fingerprint "$wallet")
    quantum_sha=$(jq -S -c . <<< "$quantum" | hash_stdin)
    [[ "$key_sha" == "$expected_key" && "$quantum_sha" == "$expected_quantum" ]] ||
        die 'key inventory changed before relay'
    jq -e --arg payout "$PAYOUT_ADDRESS" '.enabled == true and .threads == 1 and
        .cpu_percent == 1 and .payout_address == $payout and .claims_submitted == 4 and
        .state == "claim_quarantined" and .hashrate == 0' >/dev/null <<< "$mining" ||
        die 'PoW role changed before relay'
    jq -e '.enabled == true and .staking == true and (.weight // 0) > 0' \
        >/dev/null <<< "$staking" || die 'PoS changed before relay'
    jq -e --arg txid "$txid" 'index($txid) == null' >/dev/null <<< "$mempool" ||
        die 'signed resolution already reached mempool without targeted relay authority'
    decoded=$(jq -c '.decoded' <<< "$persisted")
    validate_signed_transaction "$decoded" "$txid"
    preview=$(rpc resolveallshadowpowclaims "$(signed_preview_options)") ||
        die 'pre-relay exact managed-byte preview failed'
    jq -e --arg txid "$txid" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson fee "$RECOVERY_FEE" '
        .action == "preview" and .complete == true and .wallet_tip_matches == true and
        .plan_reusable == true and .success == true and .durable_state_ambiguous == false and
        .max_fee_per_resolution == $fee and .aggregate_batch_fee_cap == $fee and
        .total_fee == $fee and .actionable_components == 1 and (.actions | length) == 1 and
        (.actions[0] | .anchor == {txid:$anchor,vout:0} and .claim_txids == [$claim] and
          .status == "reuse_managed" and .resolution_txid == $txid and .fee == $fee and
          .vsize == 191 and .input_amount == 9.83326930 and .output_amount == 9.83307830 and
          .persisted == true and .relay_authorized == false and .in_mempool == false)
    ' >/dev/null <<< "$preview" || die 'pre-relay plan is not the exact nonauthorized signed transaction'
    PRE_RELAY_PREVIEW=$preview
}

validate_relay_result()
{
    local result=$1 txid=$2
    jq -e --arg txid "$txid" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson fee "$RECOVERY_FEE" '
        .action == "commit_and_broadcast" and .success == true and
        .stale_plan == false and .durable_state_changed == true and
        .durable_state_ambiguous == false and .plan_consumed == true and
        .acknowledged_total_fee == $fee and .signed_and_persisted == 0 and
        .relay_authority_granted == 1 and (.actions | length) == 1 and
        (.broadcast + .already_in_mempool + .relay_deferred) == 1 and
        (.actions[0] | .anchor == {txid:$anchor,vout:0} and .claim_txids == [$claim] and
          .resolution_txid == $txid and .fee == $fee and .persisted == true and
          .relay_authorized == true and
          (.status == "broadcast" or .status == "already_in_mempool" or .status == "relay_deferred"))
    ' >/dev/null <<< "$result" || die 'targeted relay RPC result exceeded exact authority'
}

run_relay()
{
    local txid expected_runtime expected_key expected_quantum result recovery mempool resolution claim
    local network_state receipt
    [[ -n "$OUTPUT" ]] || die 'relay requires --output'
    validate_sign_receipt
    validate_relay_authority
    txid=$(jq -r '.signed_transaction.txid' "$SIGN_RECEIPT")
    expected_runtime=$(jq -c '.runtime' "$SIGN_RECEIPT")
    expected_key=$(jq -r '.post_state.key_fingerprint_sha256' "$SIGN_RECEIPT")
    expected_quantum=$(jq -r '.post_state.quantum_inventory_sha256' "$SIGN_RECEIPT")
    validate_persisted_pre_relay "$txid" "$expected_runtime" "$expected_key" "$expected_quantum"
    result=$(rpc commitshadowpowclaimresolution "$txid" true) ||
        die 'targeted commit RPC failed; exact persisted bytes may require read-only reconciliation'
    validate_relay_result "$result" "$txid"
    assert_runtime_unchanged "$expected_runtime"
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'post-relay recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'post-relay mempool RPC failed'
    resolution=$(rpc gettransaction "$txid" false true) || die 'post-relay resolution RPC failed'
    claim=$(rpc gettransaction "$CLAIM_TXID" false true) || die 'post-relay claim RPC failed'
    jq -e --arg txid "$txid" --arg anchor "$ANCHOR_TXID" '
        .database_outcome_ambiguous == false and .pending_automatic_resolutions == 0 and
        ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0) |
          .nodes[] | select(.txid == $txid and .kind == "managed_resolution" and
            .resolution_metadata_valid == true and .resolution_relay_authorized == true)] | length) == 1
    ' >/dev/null <<< "$recovery" || die 'durable exact-byte relay authority is not visible'
    network_state=$(jq -n -r --arg txid "$txid" --argjson mempool "$mempool" \
        --argjson resolution "$resolution" --argjson claim "$claim" '
        if ($resolution.confirmations // 0) > 0 then "resolution_confirmed"
        elif ($claim.confirmations // 0) > 0 then "original_claim_confirmed"
        elif ($mempool | index($txid)) != null then "resolution_in_mempool"
        else "authorized_relay_not_observed" end')
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg sign_sha "$SIGN_SHA256" --arg authority_sha "$AUTHORITY_SHA256" \
        --arg txid "$txid" --arg network "$network_state" \
        --argjson runtime "$expected_runtime" --argjson preview "$PRE_RELAY_PREVIEW" \
        --argjson execution "$result" --argjson recovery "$recovery" \
        --argjson resolution "$resolution" --argjson claim "$claim" '
        {schema:1,contract:$contract,phase:"relay",result:$network,
         mutation_performed:true,tool_sha256:$tool,sign_receipt_sha256:$sign_sha,
         financial_authority_receipt_sha256:$authority_sha,runtime:$runtime,
         resolution_txid:$txid,pre_relay_plan:$preview,execution:$execution,
         post_relay:{recovery:$recovery,resolution:$resolution,original_claim:$claim},
         containment:{exact_bytes_only:true,fee_bump_or_replacement:false,
           generic_sendrawtransaction:false,abandonment:false,fleet_expansion:false,
           propagated_bytes_recallable:false},
         final_acceptance:{required_confirmations:6,pos_active_required:true,
           positive_hashrate_required:true,claims_submitted_must_exceed:4}}
    ')
    write_receipt "$receipt"
    [[ "$network_state" != authorized_relay_not_observed ]] ||
        die 'relay authority is durable but mempool/confirmation observation is absent; monitor exact tx only'
}

validate_relay_receipt()
{
    require_receipt_file "$RELAY_RECEIPT" "$RELAY_SHA256" 'relay receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" --arg sign_sha "$SIGN_SHA256" \
        --slurpfile sign "$SIGN_RECEIPT" '
        .schema == 1 and .contract == $contract and .phase == "relay" and
        .mutation_performed == true and .tool_sha256 == $tool and
        .sign_receipt_sha256 == $sign_sha and
        .resolution_txid == $sign[0].signed_transaction.txid and
        (.result == "resolution_in_mempool" or .result == "resolution_confirmed" or
         .result == "original_claim_confirmed") and
        .containment == {exact_bytes_only:true,fee_bump_or_replacement:false,
          generic_sendrawtransaction:false,abandonment:false,fleet_expansion:false,
          propagated_bytes_recallable:false} and
        .final_acceptance.required_confirmations == 6 and
        .final_acceptance.pos_active_required == true and
        .final_acceptance.positive_hashrate_required == true and
        .final_acceptance.claims_submitted_must_exceed == 4
    ' "$RELAY_RECEIPT" >/dev/null || die 'relay receipt is not exact'
}

run_verify_final()
{
    local txid expected_runtime expected_key expected_quantum runtime chain_before chain_after
    local resolution claim recovery mining staking wallet quantum anchor winner confirmations receipt
    [[ -n "$OUTPUT" ]] || die 'verify-final requires --output'
    validate_sign_receipt
    validate_relay_receipt
    txid=$(jq -r '.signed_transaction.txid' "$SIGN_RECEIPT")
    expected_runtime=$(jq -c '.runtime' "$SIGN_RECEIPT")
    expected_key=$(jq -r '.post_state.key_fingerprint_sha256' "$SIGN_RECEIPT")
    expected_quantum=$(jq -r '.post_state.quantum_inventory_sha256' "$SIGN_RECEIPT")
    runtime=$(runtime_snapshot)
    jq -e -n --argjson a "$expected_runtime" --argjson b "$runtime" '$a == $b' >/dev/null ||
        die 'runtime identity changed before final verification'
    chain_before=$(rpc getblockchaininfo) || die 'final initial chain bracket failed'
    resolution=$(rpc gettransaction "$txid" false true) || die 'final resolution RPC failed'
    claim=$(rpc gettransaction "$CLAIM_TXID" false true) || die 'final claim RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'final recovery RPC failed'
    mining=$(rpc getpowmininginfo) || die 'final PoW RPC failed'
    staking=$(rpc getstakinginfo) || die 'final PoS RPC failed'
    wallet=$(rpc getwalletinfo) || die 'final wallet RPC failed'
    quantum=$(rpc getquantumkeyinventory) || die 'final quantum inventory failed'
    anchor=$(rpc gettxout "$ANCHOR_TXID" "$ANCHOR_VOUT" true || true)
    chain_after=$(rpc getblockchaininfo) || die 'final ending chain bracket failed'
    jq -e -n --argjson a "$chain_before" --argjson b "$chain_after" '
        $a.bestblockhash == $b.bestblockhash and $a.blocks == $b.blocks
    ' >/dev/null || die 'tip changed during final evidence cut'
    [[ -z "$anchor" || "$anchor" == null ]] || die 'confirmed anchor remains unspent'
    if jq -e --argjson n "$REQUIRED_CONFIRMATIONS" '.confirmations >= $n' >/dev/null <<< "$resolution"; then
        winner=resolution
        confirmations=$(jq -r '.confirmations' <<< "$resolution")
    elif jq -e --argjson n "$REQUIRED_CONFIRMATIONS" '.confirmations >= $n' >/dev/null <<< "$claim"; then
        winner=original_claim
        confirmations=$(jq -r '.confirmations' <<< "$claim")
    else
        die 'neither exact conflicting transaction has six active-chain confirmations'
    fi
    jq -e '.database_outcome_ambiguous == false and .wallet_tip_matches == true and
        .blocking_components == 0 and .blocking_quarantined_claims == 0 and
        .actionable_quarantined_claims == 0 and .indeterminate_quarantined_claims == 0 and
        .pending_manual_resolutions == 0 and .pending_automatic_resolutions == 0' \
        >/dev/null <<< "$recovery" || die 'active-chain outcome did not clear the recovery gate'
    jq -e --arg payout "$PAYOUT_ADDRESS" --argjson baseline "$BASELINE_CLAIMS_SUBMITTED" '
        .enabled == true and .threads == 1 and .cpu_percent == 1 and
        (.state == "ready" or .state == "hashing") and .hashrate > 0 and
        .claims_submitted > $baseline and .blocking_quarantined_claims == 0 and
        .payout_address == $payout and .allow_automatic_quantum_key_creation == false
    ' >/dev/null <<< "$mining" ||
        die 'final evidence lacks positive hashing and a strict claims_submitted increase'
    jq -e '.enabled == true and .staking == true and (.weight // 0) > 0' \
        >/dev/null <<< "$staking" || die 'final PoS evidence is not active'
    [[ "$(key_fingerprint "$wallet")" == "$expected_key" ]] ||
        die 'legacy key identity changed by the canary'
    [[ "$(jq -S -c . <<< "$quantum" | hash_stdin)" == "$expected_quantum" ]] ||
        die 'quantum key identity changed by the canary'
    assert_runtime_unchanged "$expected_runtime"
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg sign_sha "$SIGN_SHA256" --arg relay_sha "$RELAY_SHA256" \
        --arg txid "$txid" --arg winner "$winner" --argjson confirmations "$confirmations" \
        --argjson runtime "$runtime" --argjson chain "$chain_after" \
        --argjson resolution "$resolution" --argjson claim "$claim" \
        --argjson recovery "$recovery" --argjson mining "$mining" --argjson staking "$staking" '
        {schema:1,contract:$contract,phase:"verify-final",result:"canary_accepted",
         mutation_performed:false,tool_sha256:$tool,sign_receipt_sha256:$sign_sha,
         relay_receipt_sha256:$relay_sha,runtime:$runtime,
         active_chain:{height:$chain.blocks,tip:$chain.bestblockhash,winner:$winner,
           winner_txid:(if $winner == "resolution" then $txid else
             "2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d" end),
           confirmations:$confirmations,anchor_spent:true},
         conflicting_transactions:{resolution:$resolution,original_claim:$claim},
         recovery_gate:{blocking_components:$recovery.blocking_components,
           blocking_claims:$recovery.blocking_quarantined_claims,
           database_outcome_ambiguous:$recovery.database_outcome_ambiguous},
         service_evidence:{pos_enabled:$staking.enabled,pos_staking:$staking.staking,
           pos_weight:$staking.weight,pow_enabled:$mining.enabled,pow_state:$mining.state,
           pow_hashrate:$mining.hashrate,claims_submitted_baseline:4,
           claims_submitted_after:$mining.claims_submitted,
           payout_address:$mining.payout_address,key_inventory_unchanged:true},
         scope:{node27_only:true,node30_untouched:true,fleet_expansion:false,
           candidate_bytes_deployed:false}}
    ')
    write_receipt "$receipt"
}

parse_args()
{
    if (($# > 0)); then
        case "$1" in
            audit|sign-only|relay|verify-final) PHASE=$1; shift ;;
            -h|--help) usage; exit 0 ;;
            --*) ;;
            *) usage >&2; die 'unknown phase' ;;
        esac
    fi
    while (($# > 0)); do
        case "$1" in
            --output) [[ $# -ge 2 ]] || die '--output requires a value'; OUTPUT=$2; shift 2 ;;
            --audit-receipt) [[ $# -ge 2 ]] || die '--audit-receipt requires a value'; AUDIT_RECEIPT=$2; shift 2 ;;
            --audit-sha256) [[ $# -ge 2 ]] || die '--audit-sha256 requires a value'; AUDIT_SHA256=$2; shift 2 ;;
            --sign-receipt) [[ $# -ge 2 ]] || die '--sign-receipt requires a value'; SIGN_RECEIPT=$2; shift 2 ;;
            --sign-sha256) [[ $# -ge 2 ]] || die '--sign-sha256 requires a value'; SIGN_SHA256=$2; shift 2 ;;
            --relay-receipt) [[ $# -ge 2 ]] || die '--relay-receipt requires a value'; RELAY_RECEIPT=$2; shift 2 ;;
            --relay-sha256) [[ $# -ge 2 ]] || die '--relay-sha256 requires a value'; RELAY_SHA256=$2; shift 2 ;;
            --authority-receipt) [[ $# -ge 2 ]] || die '--authority-receipt requires a value'; AUTHORITY_RECEIPT=$2; shift 2 ;;
            --authority-sha256) [[ $# -ge 2 ]] || die '--authority-sha256 requires a value'; AUTHORITY_SHA256=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
}

main()
{
    parse_args "$@"
    resolve_self_and_transport
    case "$PHASE" in
        audit)
            [[ -z "$AUDIT_RECEIPT$AUDIT_SHA256$SIGN_RECEIPT$SIGN_SHA256$RELAY_RECEIPT$RELAY_SHA256$AUTHORITY_RECEIPT$AUTHORITY_SHA256" ]] ||
                die 'audit accepts no authority or prior receipt'
            collect_unsigned_audit
            write_receipt "$(audit_receipt_json)"
            ;;
        sign-only)
            [[ -n "$AUDIT_RECEIPT" && -n "$AUDIT_SHA256" &&
               -n "$AUTHORITY_RECEIPT" && -n "$AUTHORITY_SHA256" ]] ||
                die 'sign-only requires exact audit and financial-authority receipts'
            [[ -z "$SIGN_RECEIPT$SIGN_SHA256$RELAY_RECEIPT$RELAY_SHA256" ]] ||
                die 'sign-only rejects relay or prior sign receipts'
            run_sign_only
            ;;
        relay)
            [[ -n "$SIGN_RECEIPT" && -n "$SIGN_SHA256" &&
               -n "$AUTHORITY_RECEIPT" && -n "$AUTHORITY_SHA256" ]] ||
                die 'relay requires exact sign and financial-authority receipts'
            [[ -z "$AUDIT_RECEIPT$AUDIT_SHA256$RELAY_RECEIPT$RELAY_SHA256" ]] ||
                die 'relay rejects audit and prior relay receipt arguments'
            run_relay
            ;;
        verify-final)
            [[ -n "$SIGN_RECEIPT" && -n "$SIGN_SHA256" &&
               -n "$RELAY_RECEIPT" && -n "$RELAY_SHA256" ]] ||
                die 'verify-final requires exact sign and relay receipts'
            [[ -z "$AUDIT_RECEIPT$AUDIT_SHA256$AUTHORITY_RECEIPT$AUTHORITY_SHA256" ]] ||
                die 'verify-final rejects mutation authority arguments'
            run_verify_final
            ;;
    esac
}

main "$@"
