#!/usr/bin/env bash

# One-time recovery for explicitly pinned v30.1.3 QQP2 claims that cannot use
# v30.1.4 zero-payment retirement because their wallets lack authenticated
# origin metadata. Every recovery returns the anchor to its existing script,
# uses the exact previewed bytes, and is capped at 0.000191 BLK per wallet.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

if ((BASH_VERSINFO[0] < 4)); then
    printf '%s FATAL: Bash 4 or newer is required\n' "$(date -u +%FT%TZ)" >&2
    exit 64
fi

readonly CLI=/usr/local/bin/blackcoin-cli
readonly DATADIR=/home/blackcoin/.blackcoin
readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly CANDIDATE_REF=qqblackcoin/blackcoin-v4-gui@sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2
readonly CANDIDATE_ID=sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909
readonly PER_NODE_FEE=0.000191
readonly CONFIRM_VALUE=v30.1.4-resolve-pinned-legacy-pow-blockers
case "${LEGACY_POW_RECOVERY_SCOPE:-all}" in
    all) NODES=({1..29} 31 32) ;;
    surfaced-19-28) NODES=(19 28) ;;
    *)
        printf '%s FATAL: unsupported recovery scope\n' "$(date -u +%FT%TZ)" >&2
        exit 64
        ;;
esac
readonly -a NODES
readonly -A EXPECTED_ANCHOR_TXID=(
    [1]=0f278cbdbb1708db349f7d31f348197a564fa2e647ca1e4ea1432b1041853cfb
    [4]=3c7ee1c60e54eb705a7f2366386c3814eff942f4053c5d5050b13cf3cf43cbc0
    [5]=885e1e7bb79b541a5c93ab048de3ad246ae888ea9313cbe4f7feb2b35489bd11
    [7]=178e043c7e6cba9cee5e56a3736c678f405ec3db6366bde53856355ece419c29
    [8]=9f0530d5f4bf6e756aa60032613a5da9389681881efdb5a0cea6ef21a3de106a
    [9]=d2e5917b27722d13ea4cd0fe9d1d87d6aa0188a186270a161d810b86807da22b
    [10]=536f494f630f63973be6bb1b170dca8ef5f94a86bf79b52cb035a85cf4ceb98f
    [11]=af580bbb7cc23bd4562655565dcd1cbe8a5dfbd3e274811d6cb9437cc0a80b1a
    [13]=4cb20cd959abf8bfbdc54aa7480608f7bf94ec25157e683c9b596bb3fe4f95bb
    [14]=12cdab962608f2a1836027b0018cdc1fa2daa95f2d324d43f64b8c22068dd197
    [15]=1d768e750cf7670010c98f19f72e860852382ecf304af4117c57114a63c778b0
    [16]=d80ed2645adf66a9f62ce782ff9438881fe108c86e0911cc387bf15279fcdca2
    [18]=4db5a37b7149f1e45fd2b2cbd00771b396aefc5c0fa65d65002e29ed77573c73
    [19]=f5d205f1e9724ad0aa7467aec8934624c9ff9347587e946b29d7f3f8c99cad99
    [20]=700c01dd7bcc58513953e018e422a2cc34800546313a59684645a01561d6ce19
    [21]=3695214589376c1b2a543c967b9c04c696944a8861059b156f5a5ea06db49097
    [23]=def4b346def14dc6eb2db2a0d5c311ac011b1a5ad319058a661664efd7ff730d
    [25]=45e31c338a1e18f77286da28e9e8584ad92c8683256806d5546046019d9b1a1d
    [26]=d6a692fff726d9c60416f8bd3f41abb7757da51863eb00fdd6ca66c9fecc8211
    [27]=0e495a762e546dd3eecbfc4709f750c5a94fbe5f813163de8a2ad33b6a394956
    [28]=d68b3295a5dcd3d580f1618ebac3753054b1a90e3ae998382b00d9f18c15c05a
    [29]=3038c2cbd16046d7e9b3fe2c285bf3352c18e7d229f316f1e343665d056325a0
    [31]=6ba506f3369954d3a6cff090049ce9d3fc968c1247915bb5b10f48d1e1605e19
)
readonly -A EXPECTED_CLAIM_TXID=(
    [1]=e371a726aa4a7318934570100f17000138ae132d13a97d3e6f4ed80416b451b8
    [4]=c6ba534cff35d622e1557ac8b1b3c9afaef61c0ca53f77b06d9576b705314611
    [5]=789b4ff4ef5f42d773688aa6a5f8a8f5e4dc118dcd176a23d2cdfb865cf40759
    [7]=e1b385dd02e8b27a1cca7f1f893bdb1c4ad8105f630faa13059c963f5a5b9dcd
    [8]=6728ad15e263b1f4685388163a9e11a2a7bad21eb5a9e95c4625ea556b316ff7
    [9]=527901735c046e365a83ba15e14e0a3d595df08e48b10b7cc30ad3b1f1b01933
    [10]=0a0e223066b13696eefeaf9cd2907f5ccf53a9a3f5e0b030fe6cabe982883e09
    [11]=d03dda63adfb02544b6079f6349113851313e6919b6b1f59998be6ad7d1ec205
    [13]=130310c7a6fe849828210e81ab13fe3959534ad9616f6a14085e693830d1f48c
    [14]=9ed93e7dcc2c183917af1cea8fd698388d31eaf0e1db369afbd902a876e463ea
    [15]=24a121b99c5a336855fb68311453aac3b9effb68484ce4abb52ae28f542a4934
    [16]=91d8620a4ec98353ccb35e788098b978ed6a0ae6adc6bf2e0dfdc626c671f284
    [18]=da48afdfe881ba73f48b6cddf55f8f3658d13c9a7ff80268345158763c7a35c7
    [19]=93752b425ee0f4e2bdbb2e2c1306aa8df4845459efdd19a4d61e60d8294ea617
    [20]=50d667584aea6b965480dbed7886b0af99556288a3aedaa231909935060aa250
    [21]=70f147c37c61a37e82d1404c2a4eb96ee6f19812be09a47b5f6196d4cb626209
    [23]=f1d671d0b259395fb9aa1b19659a5b7bd442682260bb3c6893a5a377428128b8
    [25]=3ea1b63a2a24d3d999f16063d9738167f34bfcfa197efe37636f70e3e29dfead
    [26]=1962c4becab246db8236a0f61956919834c890bb311655898f7febe945433f41
    [27]=943d1850ed4b736104cb5825161e59eead49d26e1aee3b8852d9cae5690aa2dd
    [28]=f430be2b00906aaa06d98df39114a3ef18fc63c226d6d14fef3575100bdcc687
    [29]=97be7f5fc150486270b0af5bcd676e46f491e1741b5c5c003a1aa1c5f8a690c5
    [31]=ce18410d10e92ca027a54de6ed166b28d044bf35405148ee05771f26aa24cb09
)
readonly -A EXPECTED_GENERATION=(
    [1]=d6061b5c34726b81fbe40f3029094bca7a2f73b58dae2ac3ec6654458513cb48
    [4]=426b7cc4261729b36deac94119b6b51b56dce90c4dacd530ae02e8f7f5730556
    [5]=b4a3af7baab78f6d6536e5900890a866b87ee280010d63dae1094c33d3e25395
    [7]=10a15d300fd2bc1c420c2f560b5ca658accd3ce2448689d66baada486ec17583
    [8]=ad8b52aa42b9b8683681f17d2da3e839307010adab9fe102bc60be0544b63a8f
    [9]=dd4bc7ae2d1afb407a6d014a616fde03ebf7222b43bc7307e30b80d1504f4621
    [10]=d930b597b30a94d3cc524dacf3b37ca816eda320d4b3a9e77deb4250b88d6590
    [11]=9b5a9eead3a266cb165abd51d2d81d974b79672fee023f8b4fcbef3e6b252cb3
    [13]=28ed7ef2731b825102495af7a9a7e160e6ed4e40bb2fbb5c224a7c121b7e9a38
    [14]=d273fe2ff6aacfddb9ecb19404d0f85cad96f8390b0fa26d1828fd4a64461e87
    [15]=7273c6acd79eb6a4e8b14ef95f1666b8e1bdc75d5aeefb1245bdfbf80ed4dd5b
    [16]=cb531a7932eb90ae7079da9db7d6c079a7f097e93031bc0a17d1ff6857b0c767
    [18]=6bfe1eedb6ec10889782f7468c3ae4e1627f335a3fe38c8bb849a8582f169933
    [19]=11ea75f6c6ca652fd01d33e98050edd9f43426af5ddb990dc04f0ebda463afc1
    [20]=8d925c1ea3f1a703bd8d4851a8257f8da52317336d8d8b914b7401c34bfd8e9c
    [21]=db9a215805c6f55c33ab66e29c64def2ce54bde6319c41ef9c1c081a9904f867
    [23]=ad0b66e4dabca02ebe23eadf00c552d137db1e68af3f0b4e327cb6ce009f1439
    [25]=31c850ff3b8e3fbde4d0cf5d3d0823c38100e25ed3fe7f3bc97f3b9a78c461df
    [26]=9f9c65f75f1650e1b2a1eca0fa3d730dcafdcdec5de81b37219fd72c7e043b4c
    [27]=641b646807170dbc980f70d2b2c028b7855b99f5e71c4ea7a747eb3fc2e9e9ef
    [28]=50dafc08f708dfbd42438ea10adfdfacef7a79f18cd0566f1b0cd582c28219d0
    [29]=cee93bbb8ea41533df09734f200c3b49a3d348df2f381191547f8cf002535006
    [31]=a81378834d92a232f460c8a07456b295cec24942a900a98897f736f856f54626
)

current_container=
current_wallet=
container_id=
container_started=
rpc_context_ready=false
exit_pow_action=none

die()
{
    printf '%s FATAL: %s\n' "$(date -u +%FT%TZ)" "$*" >&2
    exit 1
}

wallet_fingerprint()
{
    jq -S -c '{private_keys_enabled,keypoolsize,keypoolsize_hd_internal,keypoololdest}' |
        sha256sum | awk '{print $1}'
}

rpc()
{
    timeout -k 2 45 docker exec "$current_container" "$CLI" -datadir="$DATADIR" \
        -rpcwallet="$current_wallet" "$@"
}

runtime_identity_matches()
{
    local inspect
    [[ -n "$container_id" && -n "$container_started" ]] || return 1
    inspect=$(docker inspect "$current_container") || return 1
    jq -e --arg ref "$CANDIDATE_REF" --arg id "$CANDIDATE_ID" \
        --arg cid "$container_id" --arg started "$container_started" '
        length == 1 and .[0].Id == $cid and .[0].State.StartedAt == $started and
        .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].State.Running == true and .[0].State.Paused == false and
        .[0].State.Health.Status == "healthy"
    ' >/dev/null <<< "$inspect"
}

restore_pow_on_exit()
{
    local rc=$?
    if [[ "$rpc_context_ready" == true ]] && runtime_identity_matches; then
        case "$exit_pow_action" in
            enable)
                timeout -k 2 45 docker exec "$current_container" "$CLI" -datadir="$DATADIR" \
                    -rpcwallet="$current_wallet" setpowmining true 1 1 false \
                    >/dev/null 2>&1 || true
                ;;
            disable)
                timeout -k 2 45 docker exec "$current_container" "$CLI" -datadir="$DATADIR" \
                    -rpcwallet="$current_wallet" setpowmining false 1 1 \
                    >/dev/null 2>&1 || true
                ;;
        esac
    fi
    exit "$rc"
}

trap restore_pow_on_exit EXIT

[[ "$(id -u)" -eq 0 ]] || die 'root required'
[[ "${CONFIRM_RESOLVE_LEGACY_POW_BLOCKERS:-}" == "$CONFIRM_VALUE" ]] ||
    die "confirmation requires CONFIRM_RESOLVE_LEGACY_POW_BLOCKERS=$CONFIRM_VALUE"

for node in "${NODES[@]}"; do
    rpc_context_ready=false
    exit_pow_action=none
    container_id=
    container_started=
    printf -v padded '%02d' "$node"
    if [[ "$node" -eq 1 ]]; then
        current_container=blackcoin-v4-gui
    else
        current_container="blackcoin-v4-gui-$node"
    fi
    wallet_manifest="$STATE_DIR/runtime-wallet-manifests/node-$padded.json"
    identity_manifest="$STATE_DIR/runtime-identity-manifests/node-$padded.json"
    pow_manifest="$STATE_DIR/pow-wallet-manifests/node-$padded.json"
    for protected in "$wallet_manifest" "$identity_manifest" "$pow_manifest"; do
        [[ -f "$protected" && ! -L "$protected" &&
           "$(realpath -e -- "$protected")" == "$protected" &&
           "$(stat -c '%u:%g:%a' "$protected")" == 0:0:600 ]] ||
            die "node $padded protected manifest is invalid: $protected"
    done
    current_wallet=$(jq -er \
        'if type == "array" and length == 1 then .[0] else error("invalid") end' \
        "$wallet_manifest") || die "node $padded wallet manifest shape changed"
    rpc_context_ready=true
    jq -e --arg wallet "$current_wallet" '. == [$wallet]' "$wallet_manifest" >/dev/null ||
        die "node $padded wallet manifest changed"
    jq -e --arg node "$padded" --arg wallet "$current_wallet" '
        .schema == 2 and .node_id == $node and .wallet == $wallet and
        (.legacy_descriptors_sha256 | test("^[0-9a-f]{64}$")) and
        (.quantum_identity_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_policy_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_legacy_descriptor_set_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_quantum_address_set_sha256 | test("^[0-9a-f]{64}$")) and
        (.trusted_quantum_address_count | type) == "number" and
        .trusted_quantum_address_count >= 1
    ' "$identity_manifest" >/dev/null || die "node $padded identity manifest changed"
    jq -e --arg node "$padded" --arg wallet "$current_wallet" '
        .schema == 1 and .node_id == $node and .wallet == $wallet and
        .enabled == true and (.payout_address | test("^blk1s[0-9a-z]+$")) and
        .label == "PoW - Quantum Claim Address" and
        (.backup_path | type) == "string" and
        (.backup_sha256 | test("^[0-9a-f]{64}$")) and
        (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
        (.wallet_fingerprint | test("^[0-9a-f]{64}$"))
    ' "$pow_manifest" >/dev/null || die "node $padded PoW manifest changed"
    payout=$(jq -er '.payout_address | select(type == "string")' "$pow_manifest") ||
        die "node $padded payout address is unavailable"
    backup=$(jq -er '.backup_path' "$pow_manifest") || die "node $padded backup is unavailable"
    backup_sha=$(jq -er '.backup_sha256' "$pow_manifest") ||
        die "node $padded backup hash is unavailable"
    [[ -f "$backup" && ! -L "$backup" && "$(realpath -e -- "$backup")" == "$backup" &&
       "$(stat -c '%u:%g:%a' "$backup")" == 0:0:600 &&
       "$(sha256sum "$backup" | awk '{print $1}')" == "$backup_sha" ]] ||
        die "node $padded backup validation failed"

    exec 9>"/run/blackcoin-node-$padded-runtime.lock"
    flock -n 9 || die "node $padded runtime lock is busy"
    inspect=$(docker inspect "$current_container") || die "node $padded container is absent"
    jq -e --arg ref "$CANDIDATE_REF" --arg id "$CANDIDATE_ID" '
        length == 1 and .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].State.Running == true and .[0].State.Paused == false and
        .[0].State.Health.Status == "healthy" and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3
    ' >/dev/null <<< "$inspect" || die "node $padded runtime is not ready"
    container_id=$(jq -er '.[0].Id' <<< "$inspect") || die "node $padded ID is unavailable"
    container_started=$(jq -er '.[0].State.StartedAt' <<< "$inspect") ||
        die "node $padded start identity is unavailable"
    [[ "$(rpc listwallets | jq -c 'sort')" == "$(jq -c 'sort' "$wallet_manifest")" ]] ||
        die "node $padded loaded-wallet inventory changed"
    wallet_info=$(rpc getwalletinfo) || die "node $padded wallet info is unavailable"
    jq -e '.private_keys_enabled == true and (.scanning // false) == false and
        .unlocked_staking_only == false and (.unlocked_until // 0) > now' \
        >/dev/null <<< "$wallet_info" || die "node $padded wallet is not normally unlocked"
    keypool_before=$(wallet_fingerprint <<< "$wallet_info")
    quantum_before=$(rpc getquantumkeyinventory | jq -S -c . | sha256sum | awk '{print $1}')
    staking=$(rpc getstakinginfo) || die "node $padded staking info is unavailable"
    jq -e '.enabled == true and .staking == true and (.weight // 0) > 0' \
        >/dev/null <<< "$staking" || die "node $padded PoS is not active"

    exit_pow_action=enable
    rpc setpowmining false 1 1 >/dev/null || die "node $padded PoW could not be paused"
    info=$(rpc getpowclaimrecoveryinfo) || die "node $padded recovery info is unavailable"
    jq -e '.chain_ready == true and .wallet_tip_matches == true and
        .database_outcome_ambiguous == false and .policy_authoritative == true and
        .policy.mode == "unset" and (.blocking_quarantined_claims == 0 or
        (.blocking_quarantined_claims == 1 and .blocking_components == 1))' \
        >/dev/null <<< "$info" || die "node $padded recovery authority is unsafe"

    action=already-clear
    fee=0
    expected_anchor=
    expected_claim=
    expected_generation=
    receipt_plan=
    receipt_tip=
    receipt_height=
    receipt_wallet_generation=
    resolution_txid=
    if [[ "$(jq -r '.blocking_quarantined_claims' <<< "$info")" == 1 ]]; then
        expected_anchor=${EXPECTED_ANCHOR_TXID[$node]:-}
        expected_claim=${EXPECTED_CLAIM_TXID[$node]:-}
        expected_generation=${EXPECTED_GENERATION[$node]:-}
        [[ -n "$expected_anchor" && -n "$expected_claim" &&
           -n "$expected_generation" ]] ||
            die "node $padded has an unapproved blocking claim"
        confirmed_before=$(jq -er '.confirmed_manual_resolutions' <<< "$info") ||
            die "node $padded confirmed-resolution baseline is unavailable"
        fees_before=$(jq -er '.confirmed_resolution_fees' <<< "$info") ||
            die "node $padded resolution-fee baseline is unavailable"
        preview_options=$(jq -cn --argjson cap "$PER_NODE_FEE" \
            '{action:"preview",max_fee_per_resolution:$cap,max_total_fee:$cap}')
        result=
        rc=1
        for _ in 1 2 3; do
            preview=$(rpc resolveallshadowpowclaims "$preview_options") ||
                die "node $padded recovery preview failed"
            jq -e --argjson cap "$PER_NODE_FEE" \
                --arg anchor "$expected_anchor" --arg claim "$expected_claim" \
                --arg generation "$expected_generation" '
                .complete == true and .wallet_tip_matches == true and
                .actionable_components == 1 and (.actions | length) == 1 and
                (.actions[0].status == "ready" or
                 .actions[0].status == "reuse_managed") and
                .actions[0].anchor == {txid:$anchor,vout:0} and
                .actions[0].claim_txids == [$claim] and
                .actions[0].generation_fingerprint == $generation and
                .actions[0].reason_code == "unbound-proof-may-revalidate" and
                .actions[0].conflicts_with_revalidating_unbound_proof == true and
                .actions[0].fee > 0 and .actions[0].fee <= $cap and
                .total_fee == .actions[0].fee and
                all(.refused[]?; .reason_code == "anchor-spent")
            ' >/dev/null <<< "$preview" || die "node $padded preview exceeded authority"
            plan=$(jq -er '.plan_id | select(test("^[0-9a-f]{64}$"))' <<< "$preview") ||
                die "node $padded preview lacks an exact plan"
            plan_tip=$(jq -er '.active_tip | select(test("^[0-9a-f]{64}$"))' <<< "$preview") ||
                die "node $padded preview lacks an active tip"
            plan_height=$(jq -er '.active_height | select(type == "number")' <<< "$preview") ||
                die "node $padded preview lacks an active height"
            plan_generation=$(jq -er '.wallet_generation | select(type == "number")' <<< "$preview") ||
                die "node $padded preview lacks a wallet generation"
            receipt_plan=$plan
            receipt_tip=$plan_tip
            receipt_height=$plan_height
            receipt_wallet_generation=$plan_generation
            runtime_identity_matches ||
                die "node $padded runtime identity changed before recovery"
            options=$(jq -cn --arg plan "$plan" --argjson cap "$PER_NODE_FEE" '
                {action:"commit_and_broadcast",expected_plan_id:$plan,
                 acknowledge_fee_and_conflict_risk:true,
                 max_fee_per_resolution:$cap,max_total_fee:$cap}')
            set +e
            result=$(rpc resolveallshadowpowclaims "$options" 2>&1)
            rc=$?
            set -e
            if ((rc == 0)) && jq -e --argjson cap "$PER_NODE_FEE" \
                    --arg anchor "$expected_anchor" --arg claim "$expected_claim" \
                    --arg generation "$expected_generation" --arg plan "$plan" \
                    --arg tip "$plan_tip" --argjson height "$plan_height" \
                    --argjson wallet_generation "$plan_generation" '
                    .success == true and .stale_plan == false and
                    .durable_state_ambiguous == false and .plan_consumed == true and
                    .acknowledged_plan_id == $plan and
                    .acknowledged_active_tip == $tip and
                    .acknowledged_active_height == $height and
                    .acknowledged_wallet_generation == $wallet_generation and
                    .acknowledged_total_fee > 0 and .acknowledged_total_fee <= $cap and
                    (.actions | length) == 1 and
                    .actions[0].anchor == {txid:$anchor,vout:0} and
                    .actions[0].claim_txids == [$claim] and
                    .actions[0].generation_fingerprint == $generation and
                    (.actions[0].status == "broadcast" or
                     .actions[0].status == "already_in_mempool" or
                     .actions[0].status == "relay_deferred") and
                    .actions[0].persisted == true and
                    .actions[0].relay_authorized == true and
                    (.actions[0].resolution_txid | test("^[0-9a-f]{64}$")) and
                    .actions[0].fee == .acknowledged_total_fee and
                    (.broadcast + .already_in_mempool + .relay_deferred) >= 1
                ' >/dev/null <<< "$result"; then
                action=$(jq -r '.actions[0].status' <<< "$result")
                fee=$(jq -r '.acknowledged_total_fee' <<< "$result")
                resolution_txid=$(jq -r '.actions[0].resolution_txid' <<< "$result")
                break
            fi
            if jq -e '.durable_state_ambiguous == true' >/dev/null 2>&1 <<< "$result"; then
                exit_pow_action=none
                die "node $padded recovery result is durably ambiguous; PoW remains paused"
            fi
            reconcile=$(rpc getpowclaimrecoveryinfo 2>/dev/null || true)
            if jq -e '.database_outcome_ambiguous == true' >/dev/null 2>&1 <<< "$reconcile"; then
                exit_pow_action=none
                die "node $padded recovery database is ambiguous; PoW remains paused"
            fi
            if jq -e --argjson count "$confirmed_before" --argjson before "$fees_before" \
                --argjson cap "$PER_NODE_FEE" '
                .database_outcome_ambiguous == false and
                .blocking_quarantined_claims == 0 and
                .confirmed_manual_resolutions == ($count + 1) and
                .confirmed_resolution_fees > $before and
                (.confirmed_resolution_fees - $before) <= $cap
            ' >/dev/null 2>&1 <<< "$reconcile"; then
                action=reconciled-confirmed
                fee=$(jq -nr --argjson after "$(jq '.confirmed_resolution_fees' <<< "$reconcile")" \
                    --argjson before "$fees_before" '$after - $before')
                rc=0
                break
            fi
            repre=$(rpc resolveallshadowpowclaims "$preview_options" 2>/dev/null || true)
            if jq -e --argjson cap "$PER_NODE_FEE" \
                --arg anchor "$expected_anchor" --arg claim "$expected_claim" \
                --arg generation "$expected_generation" '
                .complete == true and .wallet_tip_matches == true and
                .actionable_components == 1 and (.actions | length) == 1 and
                .actions[0].status == "reuse_managed" and
                .actions[0].anchor == {txid:$anchor,vout:0} and
                .actions[0].claim_txids == [$claim] and
                .actions[0].generation_fingerprint == $generation and
                .actions[0].persisted == true and
                .actions[0].relay_authorized == true and
                .actions[0].fee > 0 and .actions[0].fee <= $cap
            ' >/dev/null 2>&1 <<< "$repre"; then
                action=reconciled-managed
                fee=$(jq -r '.actions[0].fee' <<< "$repre")
                resolution_txid=$(jq -r '.actions[0].resolution_txid // empty' <<< "$repre")
                rc=0
                break
            fi
            if ! jq -e --arg anchor "$expected_anchor" --arg claim "$expected_claim" '
                .complete == true and (.actions | length) == 1 and
                .actions[0].status == "ready" and
                .actions[0].anchor == {txid:$anchor,vout:0} and
                .actions[0].claim_txids == [$claim]
            ' >/dev/null 2>&1 <<< "$repre"; then
                printf '%s\n' "$result" >&2
                die "node $padded recovery execution could not be reconciled"
            fi
            rc=1
        done
        ((rc == 0)) || die "node $padded recovery plan stayed stale"
    fi

    runtime_identity_matches || die "node $padded runtime identity changed before PoW enable"
    exit_pow_action=disable
    start=$(rpc setpowmining true 1 1 false) || die "node $padded PoW enable failed"
    jq -e --arg payout "$payout" '
        .enabled == true and .threads == 1 and .cpu_percent == 1 and
        .payout_address == $payout and .created_payout_key == false
    ' >/dev/null <<< "$start" || die "node $padded PoW did not retain its pinned payout"
    runtime_identity_matches || die "node $padded runtime changed after PoW enable"
    keypool_after=$(rpc getwalletinfo | wallet_fingerprint)
    quantum_after=$(rpc getquantumkeyinventory | jq -S -c . | sha256sum | awk '{print $1}')
    [[ "$keypool_after" == "$keypool_before" &&
       "$quantum_after" == "$quantum_before" ]] ||
        die "node $padded key inventory changed"
    final_ok=false
    for _ in $(seq 1 60); do
        after=$(rpc getpowclaimrecoveryinfo) || die "node $padded final recovery info failed"
        mining=$(rpc getpowmininginfo) || die "node $padded final mining info failed"
        if jq -e --argjson recovery "$after" '
            .enabled == true and .threads == 1 and .cpu_percent == 1 and
            (.hashrate | type) == "number" and
            $recovery.database_outcome_ambiguous == false and
            (($recovery.blocking_quarantined_claims == 0 and
              .blocking_quarantined_claims == 0 and
              (.state == "ready" or .state == "hashing" or .state == "claim_in_flight") and
              .hashrate > 0) or
             ($recovery.blocking_quarantined_claims == 1 and
              $recovery.pending_manual_resolutions == 1 and
              .blocking_quarantined_claims == 1 and .state == "claim_quarantined" and
              .hashrate == 0))
        ' >/dev/null <<< "$mining"; then
            final_ok=true
            break
        fi
        sleep 1
    done
    [[ "$final_ok" == true ]] || die "node $padded PoW state is neither running nor pending"
    runtime_identity_matches || die "node $padded runtime changed before final receipt"
    exit_pow_action=none
    operational=$(jq -r '.blocking_quarantined_claims == 0' <<< "$after")
    jq -cn --argjson node "$node" --arg action "$action" --argjson fee "$fee" \
        --argjson operational "$operational" \
        --arg container_id "$container_id" --arg container_started "$container_started" \
        --arg anchor "$expected_anchor" --arg claim "$expected_claim" \
        --arg generation "$expected_generation" --arg plan_id "$receipt_plan" \
        --arg active_tip "$receipt_tip" --arg active_height "$receipt_height" \
        --arg wallet_generation "$receipt_wallet_generation" \
        --arg resolution_txid "$resolution_txid" \
        --argjson recovery "$after" --argjson mining "$mining" \
        '{node:$node,recovery_action:$action,authorized_fee:$fee,
          operational:$operational,
          runtime:{container_id:$container_id,started_at:$container_started},
          authority:{anchor_txid:($anchor | if length > 0 then . else null end),
            claim_txid:($claim | if length > 0 then . else null end),
            generation_fingerprint:($generation | if length > 0 then . else null end),
            plan_id:($plan_id | if length > 0 then . else null end),
            active_tip:($active_tip | if length > 0 then . else null end),
            active_height:($active_height | if length > 0 then tonumber else null end),
            wallet_generation:($wallet_generation | if length > 0 then tonumber else null end),
            resolution_txid:($resolution_txid | if length > 0 then . else null end)},
          blocking_claims:$recovery.blocking_quarantined_claims,
          pending_manual:$recovery.pending_manual_resolutions,
          confirmed_manual:$recovery.confirmed_manual_resolutions,
          confirmed_resolution_fees:$recovery.confirmed_resolution_fees,
          pow_enabled:$mining.enabled,hashrate:$mining.hashrate,
          worker_state:$mining.state}'
    flock -u 9
    exec 9>&-
done
