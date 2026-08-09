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
v3015_require_commands docker jq sha256sum awk grep date find realpath stat sed wc tr sort
v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
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

service="node${node}"
container="blackcoin-v4-gui-${node}"
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
      --arg image_id "$CANDIDATE_IMAGE_ID" '
      .[0].Config.Entrypoint[0] == "/bin/bash" and
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
    local chain network wallet staking pow recovery now
    chain=$(rpc getblockchaininfo)
    network=$(rpc getnetworkinfo)
    wallet=$(rpc getwalletinfo)
    staking=$(rpc getstakinginfo)
    pow=$(rpc getpowmininginfo)
    recovery=$(rpc getpowclaimrecoveryinfo)
    now=$(date +%s)
    jq -cn --argjson chain "$chain" --argjson network "$network" \
      --argjson wallet "$wallet" --argjson staking "$staking" --argjson pow "$pow" \
      --argjson recovery "$recovery" \
      --argjson now "$now" '{
        tip:$chain.bestblockhash,height:$chain.blocks,blocks:$chain.blocks,
        headers:$chain.headers,ibd:$chain.initialblockdownload,
        peers_out:$network.connections_out,
        wallet_normal_unlocked:(($wallet.unlocked_until // 0) > $now and
          ($wallet.unlocked_staking_only // false) == false),
        wallet_generation:$recovery.wallet_generation,
        wallet_processed_tip:$recovery.wallet_processed_tip,
        wallet_tip_matches:$recovery.wallet_tip_matches,
        staking:$staking,pow:$pow
      }'
}

capture_wallet_state()
{
    local wallet wallets recovery transactions quantum pow chain
    wallet=$(rpc getwalletinfo)
    wallets=$(rpc listwallets)
    recovery=$(rpc getpowclaimrecoveryinfo)
    transactions=$(rpc listtransactions '*' 2147483647 0 true)
    quantum=$(rpc getquantumkeyinventory)
    pow=$(rpc getpowmininginfo)
    chain=$(rpc getblockchaininfo)
    jq -cn --argjson wallet "$wallet" --argjson wallets "$wallets" --argjson recovery "$recovery" \
      --argjson transactions "$transactions" --argjson quantum "$quantum" \
      --argjson pow "$pow" --argjson chain "$chain" \
      '{wallet:$wallet,loaded_wallets:$wallets,recovery:$recovery,transactions:$transactions,
        quantum_inventory:$quantum,payout:$pow.payout_address,chain:$chain}'
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

baseline=$(capture_wallet_state)
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
locked_wallet=$(rpc getwalletinfo)
locked_staking=$(rpc getstakinginfo)
locked_pow=$(rpc getpowmininginfo)
locked=$(jq -cn --argjson wallet "$locked_wallet" --argjson staking "$locked_staking" \
  --argjson pow "$locked_pow" '{
    wallet_locked:(($wallet.unlocked_until // 0) == 0),normal_unlock_called:false,
    pos_intent_retained:($staking.autostart_staking == true),
    pow_intent_retained:($pow.enabled == true and $pow.autostart == true),
    staking:$staking,pow:$pow
  }')
v3015_locked_restart_json_is_valid "$locked" ||
    v3015_die 'locked restart did not retain Core-native PoS/PoW intent'

/bin/bash "$NORMAL_UNLOCK_HELPER" "$node" >/dev/null
samples='[]'
last_tip=''
deadline=$((SECONDS + 1800))
while [[ "$(jq 'length' <<<"$samples")" -lt 4 ]]; do
    sample=$(capture_sample) || true
    tip=$(jq -r '.tip // empty' <<<"$sample")
    if [[ "$tip" =~ ^[0-9a-f]{64}$ && "$tip" != "$last_tip" ]] &&
       v3015_pow_json_is_typed_safe "$(jq -c '.pow' <<<"$sample")" &&
       v3015_pos_json_is_active "$(jq -c '.staking' <<<"$sample")" &&
       jq -e '.ibd == false and .blocks == .headers and .peers_out >= 1 and
         .wallet_normal_unlocked == true and .pow.current_height == .height and
         .pow.claim_inventory_tip == .tip and .staking.blocks == .height and
         .wallet_processed_tip == .tip and .wallet_tip_matches == true' \
         <<<"$sample" >/dev/null; then
        samples=$(jq -cn --argjson old "$samples" --argjson sample "$sample" '$old + [$sample]')
        last_tip=$tip
    fi
    ((SECONDS < deadline)) || v3015_die 'fewer than three advancing tip changes observed'
    [[ "$(jq 'length' <<<"$samples")" -ge 4 ]] || sleep 5
done
v3015_pow_series_is_live "$samples" || v3015_die 'action-aware PoW/PoS liveness failed'

final=$(capture_wallet_state)
wallet_audit=$(v3015_make_wallet_audit "$baseline" "$final")
v3015_wallet_delta_is_safe "$wallet_audit" ||
    v3015_die 'wallet delta is unclassified or contains recovery/key/payout mutation'

result=$(jq -cn --argjson node "$node" --arg source "$SOURCE_SHA" \
  --arg before "$before_id" --arg after "$after_id" --argjson locked "$locked" \
  --arg argv "$invocation_argv_sha" --arg body "$RUNTIME_ENTRYPOINT_BODY_SHA256" \
  --arg image "$CANDIDATE_IMAGE_REF" --arg image_id "$CANDIDATE_IMAGE_ID" \
  --argjson samples "$samples" --argjson audit "$wallet_audit" '{
    schema:1,node:$node,source_sha:$source,network_version:300105,
    subversion:"/Blackcoin:30.1.5/",container_id_before:$before,
    container_id_after_recreate:$after,restart_performed:true,
    container_recreated:true,normal_unlock_only:true,repair_rpcs:[],
    data_rewind_used:false,containment_only_on_failure:true,
    invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
      entrypoint_body_sha256:$body,runtime_argv_sha256:$argv,
      config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=1",
        "-powminingthreads=1","-powminingcpu=1"]},
    locked_restart:$locked,samples:$samples,wallet_audit:$audit
  }')
v3015_node_result_is_valid <(printf '%s\n' "$result") "$node" ||
    v3015_die 'self-verification failed'
printf '%s\n' "$result" | v3015_atomic_write "$output"
candidate_started=0
trap - EXIT
printf 'node %s native restart durability PASS\n' "$node"
