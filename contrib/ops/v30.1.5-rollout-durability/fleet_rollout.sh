#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/common.sh"
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/typed_contract.sh"

[[ $# == 2 ]] || {
    printf 'usage: %s (preflight|apply) REVIEWED_ENV\n' "$0" >&2
    exit 64
}
mode=$1 env_file=$2
[[ "$mode" == preflight || "$mode" == apply ]] || exit 64
if [[ "$mode" == apply ]]; then
    [[ $EUID == 0 ]] || v3015_die 'fleet apply requires root'
    v3015_load_reviewed_env "$env_file"
else
    # A production preflight uses the same secure file; fixture tests may set
    # V3015_PREFLIGHT_FIXTURE=1 to exercise predicates without root authority.
    if [[ "${V3015_PREFLIGHT_FIXTURE:-0}" == 1 ]]; then
        # shellcheck disable=SC1090
        source "$env_file"
    else
        [[ $EUID == 0 ]] || v3015_die 'production preflight requires root'
        v3015_load_reviewed_env "$env_file"
    fi
fi
v3015_require_commands jq awk sha256sum sort uniq find date install flock docker realpath stat python3 \
    sed wc tr grep sync ln mv mktemp id
v3015_validate_release_env
v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
topology_map="$package_dir/topology.map"
v3015_validate_topology_map "$topology_map" || v3015_die 'sealed node topology map is invalid'
for reviewed_file in "$PHASE_B_RESULT" "$PHASE_B_PROMOTION_MARKER" \
    "$NINE_PATH_CANARY_SHA256SUMS" "$RELEASE_IDENTITY_JSON" \
    "$RUNTIME_POLICY_HANDOFF_RECEIPT" "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT" \
    "$POST_COMPOSE_RECONCILE_IDENTITY_PROOF"; do
    if ! v3015_secure_regular_file "$reviewed_file" 600 ||
       ! v3015_secure_ancestry "$reviewed_file"; then
        v3015_die "reviewed evidence file is unsafe: $reviewed_file"
    fi
done
for guard in "$RUNTIME_GUARD_PATH" "$ENDPOINT_GUARD_PATH"; do
    if ! v3015_secure_regular_file "$guard" 755 ||
       ! v3015_secure_ancestry "$guard"; then
        v3015_die "runtime guard is unsafe: $guard"
    fi
done
if ! v3015_secure_root_executable "$NODE30_FREE_CLAIM_PROBE" ||
   ! v3015_secure_ancestry "$NODE30_FREE_CLAIM_PROBE"; then
    v3015_die 'node30 probe must be canonical root:root 0700, single-linked, and securely parented'
fi
[[ "$(v3015_sha256_file "$RUNTIME_GUARD_PATH")" == "$RENDERED_RUNTIME_GUARD_SHA256" &&
   "$(v3015_sha256_file "$ENDPOINT_GUARD_PATH")" == "$RENDERED_ENDPOINT_GUARD_SHA256" ]] ||
    v3015_die 'installed runtime/endpoint guard pair does not match reviewed v30.1.5 bytes'
v3015_release_identity_is_valid "$RELEASE_IDENTITY_JSON" || v3015_die 'release identity invalid'
[[ "$(v3015_sha256_file "$PHASE_B_RESULT")" == "$PHASE_B_RESULT_SHA256" ]] ||
    v3015_die 'Phase-B RESULT mismatch'
[[ "$(v3015_sha256_file "$PHASE_B_PROMOTION_MARKER")" == "$PHASE_B_PROMOTION_MARKER_SHA256" ]] ||
    v3015_die 'promotion marker mismatch'
[[ "$(v3015_sha256_file "$NINE_PATH_CANARY_SHA256SUMS")" == "$NINE_PATH_CANARY_SEAL_SHA256" ]] ||
    v3015_die 'nine-path canary seal mismatch'
[[ "$(v3015_sha256_file "$PACKAGE_SHA256SUMS")" == "$PACKAGE_SHA256SUMS_SHA256" ]] ||
    v3015_die 'package seal mismatch'
v3015_phase_b_evidence_is_valid "$PHASE_B_RESULT" "$PHASE_B_PROMOTION_MARKER" ||
    v3015_die 'completed Phase-B result/irreversible promotion contract is invalid'

waves="$package_dir/waves.txt"
regular=() free_claim=()
while read -r role nodes; do
    [[ -n "${role:-}" && "$role" != \#* ]] || continue
    [[ "$role" == regular || "$role" == free_claim ]] || v3015_die 'invalid wave role'
    read -r -a wave_nodes <<<"$nodes"
    ((${#wave_nodes[@]} >= 1 && ${#wave_nodes[@]} <= 4)) || v3015_die 'invalid wave width'
    for node in "${wave_nodes[@]}"; do
        [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || v3015_die 'invalid wave node'
        if [[ "$role" == free_claim ]]; then free_claim+=("$node"); else regular+=("$node"); fi
    done
done <"$waves"
[[ "${free_claim[*]}" == 30 ]] || v3015_die 'node30 must be the sole Free Claim wave'
actual_regular=$(printf '%s\n' "${regular[@]}" | sort -n | tr '\n' ' ')
expected_regular=$(printf '%s\n' {1..29} 31 32 | sort -n | tr '\n' ' ')
[[ "$actual_regular" == "$expected_regular" ]] ||
    v3015_die 'regular waves must contain nodes1-29,31-32 exactly once'
[[ "$(printf '%s\n' "${regular[@]}" 30 | sort -n | uniq -d)" == '' ]] ||
    v3015_die 'duplicate node in wave plan'
v3015_require_resolved NODE30_FREE_CLAIM_PROBE "${NODE30_FREE_CLAIM_PROBE:-}"
v3015_is_sha256 "${NODE30_FREE_CLAIM_PROBE_SHA256:-}" ||
    v3015_die 'node30 probe identity unresolved'
if [[ "$mode" == preflight && "${V3015_PREFLIGHT_FIXTURE:-0}" != 1 ]]; then
    [[ "$(v3015_sha256_file "$COMPOSE_FILE")" == "$FINAL_COMPOSE_SHA256" ]] ||
        v3015_die 'Compose does not match the durable handoff receipt'
    preflight_compose_model=$(docker compose -f "$COMPOSE_FILE" config --format json) ||
        v3015_die 'reviewed Compose topology could not be rendered'
    v3015_compose_topology_matches "$topology_map" "$preflight_compose_model" ||
        v3015_die 'reviewed Compose service/container topology is incomplete or ambiguous'
fi

printf 'v30.1.5 preflight PASS: signed source %s, PoS target 32, regular-PoW target 31, node30 Free Claim separate\n' "$SOURCE_SHA"
[[ "$mode" == apply ]] || exit 0

nonce=${LIVE_EXECUTION_CLEARED##*:}
[[ "$nonce" =~ ^[0-9a-f]{32}$ &&
   "$LIVE_EXECUTION_CLEARED" == "v30.1.5:${SOURCE_SHA}:${nonce}" ]] ||
    v3015_die 'nonce-bound live execution authority missing'
[[ "$(v3015_sha256_file "$NODE30_FREE_CLAIM_PROBE")" == "$NODE30_FREE_CLAIM_PROBE_SHA256" ]] ||
    v3015_die 'node30 read-only probe hash mismatch'
[[ "$(v3015_sha256_file "$COMPOSE_FILE")" == "$FINAL_COMPOSE_SHA256" ]] ||
    v3015_die 'Compose does not match the durable handoff receipt'
compose_model=$(docker compose -f "$COMPOSE_FILE" config --format json) ||
    v3015_die 'reviewed Compose topology could not be rendered'
v3015_compose_topology_matches "$topology_map" "$compose_model" ||
    v3015_die 'reviewed Compose service/container topology is incomplete or ambiguous'
[[ "$(v3015_sha256_file "$IMAGE_POLICY_PATH")" == "$FINAL_IMAGE_POLICY_SHA256" ]] ||
    v3015_die 'image policy does not match the durable handoff receipt'
[[ "$(v3015_sha256_file "$POST_COMPOSE_RECONCILE_IDENTITY_PROOF")" == \
   "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" ]] ||
    v3015_die 'post-Compose candidate identity proof does not match its receipt'
v3015_unlock_helper_is_audited "$NORMAL_UNLOCK_HELPER" ||
    v3015_die 'normal-unlock helper identity/content audit failed'
[[ -d "$EVIDENCE_ROOT" && ! -L "$EVIDENCE_ROOT" &&
   "$(realpath -e -- "$EVIDENCE_ROOT")" == "$EVIDENCE_ROOT" ]] ||
    v3015_die 'evidence root is missing, linked, or non-canonical'
[[ -d "$STATE_DIR" && ! -L "$STATE_DIR" &&
   "$(realpath -e -- "$STATE_DIR")" == "$STATE_DIR" ]] ||
    v3015_die 'state directory is missing, linked, or non-canonical'
v3015_secure_ancestry "$EVIDENCE_ROOT" || v3015_die 'evidence root ancestry is untrusted'
v3015_secure_ancestry "$STATE_DIR" || v3015_die 'state directory ancestry is untrusted'

# Serialize against another rollout and both existing fleet supervisors. The
# v30.1.5 maintenance marker then keeps those supervisors fail-closed across
# child processes and crash recovery.
exec 200>/var/run/blackcoin-v3015-rollout.lock
flock -n 200 || v3015_die 'another v30.1.5 rollout owns the transaction lock'
exec 201>/run/blackcoin-endpoint-guard.lock
flock -n 201 || v3015_die 'endpoint guard is active'
exec 202>/var/run/blackcoin-wallet-runtime-guard.lock
flock -n 202 || v3015_die 'wallet runtime guard is active'

stamp=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$EVIDENCE_ROOT/run-${stamp}-${nonce:0:16}"
[[ ! -e "$run_dir" && ! -L "$run_dir" ]] || v3015_die 'run directory exists'
install -d -o root -g root -m 0700 -- "$run_dir"
authority=$(jq -cn --arg source "$SOURCE_SHA" --arg phase_b "$PHASE_B_RESULT_SHA256" \
  --arg package "$PACKAGE_SHA256SUMS_SHA256" --arg nonce "$nonce" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg live "$LIVE_EXECUTION_CLEARED" --arg native "$NATIVE_RESTART_CLEARED" \
  '{schema:1,source_sha:$source,phase_b_result_sha256:$phase_b,
    package_sha256sums_sha256:$package,node30_probe_tool_sha256:$probe_tool,nonce:$nonce,
    live_execution_confirmation:$live,native_restart_confirmation:$native}')
printf '%s\n' "$authority" | v3015_publish_authority_noclobber "$run_dir/AUTHORITY" ||
    v3015_die 'run authority could not be durably published without clobber'
marker="$STATE_DIR/V30_1_5_ROLLOUT_MAINTENANCE.json"
authority_sha=$(v3015_sha256_file "$run_dir/AUTHORITY")
marker_json=$(jq -cn --arg run "$run_dir" --arg nonce "$nonce" --arg source "$SOURCE_SHA" \
  '{schema:1,transaction:"v30.1.5-fleet-rollout",state:"active",run_dir:$run,
    nonce:$nonce,source_sha:$source}')
printf '%s\n' "$marker_json" | v3015_publish_vfat_authority_noclobber "$marker" ||
    v3015_die 'rollout maintenance authority could not be durably published without clobber'
marker_sha=$(v3015_sha256_file "$marker")
[[ "$(jq -cS . "$marker")" == "$(jq -cS . <<<"$marker_json")" ]] ||
    v3015_die 'rollout maintenance authority reread mismatch'

touched=()
success=0
contain_touched()
{
    local status=$? topology_row touched_service touched_container
    if ((status != 0 && success == 0)); then
        containment_failed=0
        for node in "${touched[@]}"; do
            topology_row=$(v3015_topology_lookup "$topology_map" "$node") || {
                containment_failed=1
                continue
            }
            IFS=$'\t' read -r touched_service touched_container <<<"$topology_row"
            [[ -n "$touched_service" && -n "$touched_container" ]] || {
                containment_failed=1
                continue
            }
            v3015_contain_container "$touched_container" || containment_failed=1
        done
        if ((containment_failed == 0)); then
            printf 'fleet rollout contained; live datasets preserved; no image or data rollback attempted\n' >&2
        else
            printf 'URGENT: fleet containment could not be proven; live data was not rewound\n' >&2
            status=125
        fi
    fi
    exit "$status"
}
trap contain_touched EXIT

node30_cli='/usr/local/bin/blackcoin-cli'
node30_datadir='/home/blackcoin/.blackcoin'
node30_argv_sha=''
node30_probe_tool="$run_dir/.node-30-free-claim-probe.tool"
node30_topology=$(v3015_topology_lookup "$topology_map" 30) ||
    v3015_die 'node30 is missing from the sealed topology map'
IFS=$'\t' read -r node30_service node30_container <<<"$node30_topology"
[[ -n "$node30_service" && -n "$node30_container" ]] ||
    v3015_die 'node30 topology lookup is incomplete'
node30_rpc()
{
    docker exec "$node30_container" "$node30_cli" -datadir="$node30_datadir" "$@"
}
wait_node30_rpc()
{
    local deadline=$((SECONDS + 180))
    until node30_rpc getnetworkinfo >/dev/null 2>&1; do
        ((SECONDS < deadline)) || return 1
        sleep 2
    done
}
capture_node30_wallet_state()
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
    chain_before=$(node30_rpc getblockchaininfo)
    wallet=$(node30_rpc getwalletinfo)
    wallets=$(node30_rpc listwallets)
    recovery=$(node30_rpc getpowclaimrecoveryinfo true)
    transactions=$(node30_rpc listtransactions '*' 2147483647 0 true)
    quantum=$(node30_rpc getquantumkeyinventory)
    pow=$(node30_rpc getpowmininginfo)
    labels=$(node30_rpc listlabels)
    while IFS= read -r label_json; do
        label=$(jq -er '.' <<<"$label_json") || return 1
        addresses=$(node30_rpc getaddressesbylabel "$label") || return 1
        labeled_addresses=$(jq -cn --argjson old "$labeled_addresses" \
          --arg label "$label" --argjson addresses "$addresses" '
          ($old + [$addresses | to_entries[] |
            {address:.key,label:$label,purpose:.value.purpose}]) |
          unique_by([.address,.label,.purpose]) | sort_by([.address,.label,.purpose])') || return 1
    done < <(jq -c '.[]' <<<"$labels")
    payout=$(jq -er '.payout_address' <<<"$pow") || return 1
    if [[ -n "$payout" ]]; then
        payout_info=$(node30_rpc getaddressinfo "$payout") || return 1
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
            shadow_transaction=$(node30_rpc getshadowtransaction "$txid") || return 1
            blockhash=$(jq -er '.base_anchor.blockhash' <<<"$shadow_transaction") || return 1
            active_header=$(node30_rpc getblockheader "$blockhash") || return 1
            blockheight=$(jq -er '.height' <<<"$active_header") || return 1
            active_chain_hash=$(node30_rpc getblockhash "$blockheight") || return 1
            active_block=$(node30_rpc getblock "$blockhash" 1) || return 1
            source_transaction='null'
            if [[ "$(jq -r '.mode' <<<"$shadow_transaction")" == pow ]]; then
                source_txid=$(jq -er '.pow_claim_source.txid' <<<"$shadow_transaction") || return 1
                source_transaction=$(node30_rpc getrawtransaction \
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
            transaction=$(node30_rpc gettransaction "$txid" true true) || return 1
            blockhash=$(jq -r '.blockhash // empty' <<<"$transaction") || return 1
            active_header='null'
            active_block='null'
            active_chain_hash=''
            created_tip_header='null'
            created_tip_active_chain_hash=''
            if [[ -n "$blockhash" ]]; then
                active_header=$(node30_rpc getblockheader "$blockhash") || return 1
                blockheight=$(jq -er '.height' <<<"$active_header") || return 1
                active_chain_hash=$(node30_rpc getblockhash "$blockheight") || return 1
                active_block=$(node30_rpc getblock "$blockhash" 1) || return 1
                if jq -e '.qq_shadow_pow_authored == "1"' \
                  <<<"$transaction" >/dev/null; then
                    created_height=$(jq -er \
                      '.qq_shadow_pow_created_height | tonumber |
                       select(floor == . and . > 0)' <<<"$transaction") || return 1
                    created_tip=$(jq -er \
                      '.qq_shadow_pow_created_tip |
                       select(test("^[0-9a-f]{64}$"))' <<<"$transaction") || return 1
                    created_tip_header=$(node30_rpc getblockheader "$created_tip") || return 1
                    created_tip_active_chain_hash=$(node30_rpc getblockhash \
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
    chain_after=$(node30_rpc getblockchaininfo)
    jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
      ($before | {bestblockhash,blocks,headers,chainwork,initialblockdownload}) ==
      ($after | {bestblockhash,blocks,headers,chainwork,initialblockdownload})
    ' >/dev/null || return 1
    jq -cn --argjson wallet "$wallet" --argjson wallets "$wallets" \
      --argjson recovery "$recovery" --argjson transactions "$transactions" \
      --argjson quantum "$quantum" --argjson pow "$pow" --argjson chain "$chain_after" \
      --argjson transaction_evidence "$evidence" \
      --argjson labeled_addresses "$labeled_addresses" --argjson payout_info "$payout_info" \
      '{wallet:$wallet,loaded_wallets:$wallets,recovery:$recovery,transactions:$transactions,
        transaction_evidence:$transaction_evidence,quantum_inventory:$quantum,
        automatic_key_creation_allowed:$pow.allow_automatic_quantum_key_creation,
        payout:$pow.payout_address,payout_address_info:$payout_info,
        labeled_addresses:$labeled_addresses,chain:$chain}'
}
capture_node30_probe_evidence()
{
    local output=$1 observation=$2
    local payload="${output}.payload.tmp" envelope="${output}.tmp"
    local started finished samples payload_json sample_finish rechecks='[]'
    local index tip header rechecked
    [[ "$observation" == initial || "$observation" == terminal ]] || return 1
    v3015_secure_root_executable "$node30_probe_tool" || return 1
    [[ "$(v3015_sha256_file "$node30_probe_tool")" == \
       "$NODE30_FREE_CLAIM_PROBE_SHA256" ]] || return 1
    [[ ! -e "$output" && ! -L "$output" &&
       ! -e "$payload" && ! -L "$payload" && ! -e "$envelope" && ! -L "$envelope" ]] ||
        return 1
    started=$(date +%s%3N)
    "$node30_probe_tool" --node 30 --durability-json \
      --observation "$observation" --rollout-nonce "$nonce" \
      --expected-source-sha "$SOURCE_SHA" \
      --expected-image-ref "$CANDIDATE_IMAGE_REF" \
      --expected-image-id "$CANDIDATE_IMAGE_ID" \
      --expected-tool-sha256 "$NODE30_FREE_CLAIM_PROBE_SHA256" >"$payload" || {
        rm -f -- "$payload"
        return 1
    }
    payload_json=$(jq -cse 'if length == 1 then .[0]
      else error("node30 probe emitted multiple JSON values") end' "$payload") || {
        rm -f -- "$payload"
        return 1
    }
    jq -e 'type == "object" and (keys | sort) ==
      ["free_claim_intent_retained","healthy","locked_restart","node","paused",
       "samples","wallet_normal_unlocked"] and .node == 30 and .healthy == true and
      .paused == true and .wallet_normal_unlocked == true and
      .free_claim_intent_retained == true and
      .locked_restart == {free_claim_intent_retained:true}' \
      <<<"$payload_json" >/dev/null || { rm -f -- "$payload"; return 1; }
    samples=$(jq -ce '.samples' <<<"$payload_json") || { rm -f -- "$payload"; return 1; }
    sample_finish=$(jq -er 'map(.sample_finished_unix_ms) | max' <<<"$samples") || {
        rm -f -- "$payload"
        return 1
    }
    v3015_node30_probe_samples_are_live "$samples" "$observation" \
      "$NODE30_FREE_CLAIM_PROBE_SHA256" "$SOURCE_SHA" "$CANDIDATE_IMAGE_REF" \
      "$CANDIDATE_IMAGE_ID" "$nonce" "$started" "$sample_finish" || {
        rm -f -- "$payload"
        return 1
    }
    while IFS=$'\t' read -r index tip; do
        header=$(node30_rpc getblockheader "$tip" true) || {
            rm -f -- "$payload" "$envelope"
            return 1
        }
        jq -e --arg tip "$tip" '.hash == $tip and
          (.height | type == "number" and floor == . and . >= 0) and
          (.confirmations | type == "number" and floor == . and . > 0)' \
          <<<"$header" >/dev/null || {
            rm -f -- "$payload" "$envelope"
            return 1
        }
        rechecked=$(date +%s%3N)
        rechecks=$(jq -cn --argjson old "$rechecks" --argjson index "$index" \
          --arg tip "$tip" --argjson header "$header" --argjson rechecked "$rechecked" \
          '$old + [{sample_index:$index,blockhash:$header.hash,height:$header.height,
            confirmations:$header.confirmations,rechecked_unix_ms:$rechecked}]') || {
            rm -f -- "$payload" "$envelope"
            return 1
        }
    done < <(jq -r 'to_entries[] | [.key,.value.tip] | @tsv' <<<"$samples")
    finished=$(date +%s%3N)
    jq -cn --arg tool "$NODE30_FREE_CLAIM_PROBE_SHA256" --arg observation "$observation" \
      --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" --arg nonce "$nonce" \
      --argjson started "$started" --argjson finished "$finished" \
      --argjson rechecks "$rechecks" --slurpfile payload "$payload" \
      'if ($payload | length) == 1 then
         {schema:2,observation:$observation,probe_tool_sha256:$tool,source_sha:$source,
          candidate_image_ref:$image,candidate_image_id:$image_id,rollout_nonce:$nonce,
          probe_started_unix_ms:$started,probe_finished_unix_ms:$finished,
          active_chain_rechecks:$rechecks,payload:$payload[0]}
       else error("node30 probe emitted multiple JSON values") end' >"$envelope" || {
        rm -f -- "$payload" "$envelope"
        return 1
    }
    rm -- "$payload" || return 1
    chmod 600 "$envelope" || { rm -f -- "$envelope"; return 1; }
    v3015_node30_probe_output_is_valid "$envelope" "$observation" || {
        rm -f -- "$envelope"
        return 1
    }
    mv -- "$envelope" "$output" || return 1
    sync -f "$output" && sync -f "$run_dir" || return 1
    [[ "$(v3015_sha256_file "$node30_probe_tool")" == \
       "$NODE30_FREE_CLAIM_PROBE_SHA256" ]]
}
verify_node30_invocation()
{
    local inspect body body_sha argv_lines argv_json pid1_sha binary expected network
    inspect=$(docker inspect "$node30_container")
    body=$(jq -er '.[0].Config.Entrypoint[2]' <<<"$inspect") || return 1
    body_sha=$(printf '%s\n' "$body" | sha256sum | awk '{print $1}')
    [[ "$body_sha" == "$RUNTIME_ENTRYPOINT_BODY_SHA256" ]] || return 1
    jq -e '.[0].Name == $container and .[0].Config.Entrypoint[0] == "/bin/bash" and
      .[0].Config.Entrypoint[1] == "-c" and
      .[0].Config.Entrypoint[3] == "node30-v3015-rollout" and
      .[0].Config.Cmd == ["-walletbroadcast=1","-autostartstaking=1","-powmining=0"] and
      .[0].Config.Image == $image and .[0].Image == $image_id' \
      --arg container "/$node30_container" --arg image "$CANDIDATE_IMAGE_REF" \
      --arg image_id "$CANDIDATE_IMAGE_ID" \
      <<<"$inspect" >/dev/null || return 1
    [[ "$(docker image inspect "$CANDIDATE_IMAGE_REF" -f '{{.Id}}')" == \
       "$CANDIDATE_IMAGE_ID" ]] || return 1
    argv_lines=$(docker exec "$node30_container" /bin/bash -c \
      'tr "\000" "\n" < /proc/1/cmdline') || return 1
    argv_json=$(printf '%s\n' "$argv_lines" | jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -e '. == ["/usr/local/bin/blackcoin-qt","-datadir=/home/blackcoin/.blackcoin",
      "-walletbroadcast=1","-autostartstaking=1","-powmining=0"]' \
      <<<"$argv_json" >/dev/null || return 1
    node30_argv_sha=$(docker exec "$node30_container" sha256sum /proc/1/cmdline | awk '{print $1}')
    v3015_is_sha256 "$node30_argv_sha" || return 1
    pid1_sha=$(docker exec "$node30_container" sha256sum /proc/1/exe | awk '{print $1}')
    [[ "$pid1_sha" == "$CANDIDATE_BLACKCOIN_QT_SHA256" ]] || return 1
    while read -r binary expected; do
        [[ "$(docker exec "$node30_container" sha256sum "/usr/local/bin/$binary" | awk '{print $1}')" == \
           "$expected" ]] || return 1
    done <<EOF
blackcoind $CANDIDATE_BLACKCOIND_SHA256
blackcoin-cli $CANDIDATE_BLACKCOIN_CLI_SHA256
blackcoin-qt $CANDIDATE_BLACKCOIN_QT_SHA256
blackcoin-tx $CANDIDATE_BLACKCOIN_TX_SHA256
blackcoin-wallet $CANDIDATE_BLACKCOIN_WALLET_SHA256
blackcoin-util $CANDIDATE_BLACKCOIN_UTIL_SHA256
EOF
    network=$(node30_rpc getnetworkinfo)
    [[ "$(jq -r '.version' <<<"$network")" == 300105 &&
       "$(jq -r '.subversion' <<<"$network")" == '/Blackcoin:30.1.5/' ]]
}

capture_terminal_census_row()
{
    local census_node=$1 census_container census_service census_topology census_rpc
    local chain chain_before chain_after network wallet wallets staking pow
    local role result_file result_sha free_healthy=false free_paused=false probe_sha=null
    local probe_tool_sha=null terminal_probe
    census_topology=$(v3015_topology_lookup "$topology_map" "$census_node") || return 1
    IFS=$'\t' read -r census_service census_container <<<"$census_topology"
    [[ -n "$census_service" && -n "$census_container" ]] || return 1
    census_rpc=(docker exec "$census_container" /usr/local/bin/blackcoin-cli
      -datadir=/home/blackcoin/.blackcoin)
    chain_before=$("${census_rpc[@]}" getblockchaininfo)
    network=$("${census_rpc[@]}" getnetworkinfo)
    wallet=$("${census_rpc[@]}" getwalletinfo)
    wallets=$("${census_rpc[@]}" listwallets)
    staking=$("${census_rpc[@]}" getstakinginfo)
    pow=$("${census_rpc[@]}" getpowmininginfo)
    chain_after=$("${census_rpc[@]}" getblockchaininfo)
    jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
      ($before | {bestblockhash,blocks,headers,chainwork,initialblockdownload}) ==
      ($after | {bestblockhash,blocks,headers,chainwork,initialblockdownload})
    ' >/dev/null || return 1
    chain=$chain_after
    v3015_pos_json_is_active "$staking" || return 1
    if [[ "$census_node" == 30 ]]; then
        role=free_claim
        result_file="$run_dir/node-30-free-claim.json"
        v3015_node30_result_is_valid "$result_file" \
          "$run_dir/node-30-free-claim-probe.raw.json" "$run_dir/AUTHORITY" ||
            return 1
        jq -e '.enabled == false and .autostart == false and .hashrate == 0 and
          .state == "disabled"' <<<"$pow" >/dev/null || return 1
        terminal_probe="$run_dir/node-30-free-claim-terminal-probe.raw.json"
        capture_node30_probe_evidence "$terminal_probe" terminal || return 1
        # The terminal probe spans multiple tips. Resample every Core surface
        # after it returns so an intervening lock, sync, peer, or PoS loss
        # cannot be hidden by the earlier point-in-time snapshot.
        chain_before=$("${census_rpc[@]}" getblockchaininfo)
        network=$("${census_rpc[@]}" getnetworkinfo)
        wallet=$("${census_rpc[@]}" getwalletinfo)
        wallets=$("${census_rpc[@]}" listwallets)
        staking=$("${census_rpc[@]}" getstakinginfo)
        pow=$("${census_rpc[@]}" getpowmininginfo)
        chain_after=$("${census_rpc[@]}" getblockchaininfo)
        jq -e -n --argjson before "$chain_before" --argjson after "$chain_after" '
          ($before | {bestblockhash,blocks,headers,chainwork,initialblockdownload}) ==
          ($after | {bestblockhash,blocks,headers,chainwork,initialblockdownload})
        ' >/dev/null || return 1
        chain=$chain_after
        v3015_pos_json_is_active "$staking" || return 1
        jq -e '.enabled == false and .autostart == false and .hashrate == 0 and
          .state == "disabled"' <<<"$pow" >/dev/null || return 1
        free_healthy=$(jq -r '.payload.healthy' "$terminal_probe")
        free_paused=$(jq -r '.payload.paused' "$terminal_probe")
        probe_sha=$(v3015_sha256_file "$terminal_probe")
        probe_tool_sha=$NODE30_FREE_CLAIM_PROBE_SHA256
    else
        role=regular
        result_file=$(printf '%s/node-%02d.json' "$run_dir" "$census_node")
        v3015_node_result_is_valid "$result_file" "$census_node" "$run_dir/AUTHORITY" || return 1
        v3015_pow_json_is_typed_safe "$pow" || return 1
    fi
    result_sha=$(v3015_sha256_file "$result_file")
    jq -cn --argjson node "$census_node" --arg role "$role" --arg source "$SOURCE_SHA" \
      --arg image "$(docker inspect -f '{{.Config.Image}}' "$census_container")" \
      --arg image_id "$(docker inspect -f '{{.Image}}' "$census_container")" \
      --argjson chain "$chain" --argjson chain_before "$chain_before" \
      --argjson chain_after "$chain_after" --argjson network "$network" \
      --argjson wallet "$wallet" \
      --argjson wallets "$wallets" \
      --argjson staking "$staking" --argjson pow "$pow" --arg result_sha "$result_sha" \
      --argjson healthy "$free_healthy" --argjson paused "$free_paused" \
      --arg probe "$probe_sha" --arg probe_tool "$probe_tool_sha" '{
        node:$node,role:$role,source_sha:$source,network_version:$network.version,
        subversion:$network.subversion,container_image_ref:$image,container_image_id:$image_id,
        chain:$chain,
        core_before:($chain_before | {bestblockhash,blocks,headers,chainwork,
          initialblockdownload}),
        core_after:($chain_after | {bestblockhash,blocks,headers,chainwork,
          initialblockdownload}),
        network:$network,wallet:$wallet,loaded_wallets:$wallets,
        staking:$staking,pow:$pow,
        pos_contract_passed:true,pow_contract_passed:($role == "regular"),
        free_claim_healthy:$healthy,free_claim_paused:$paused,
        free_claim_probe_output_sha256:(if $role == "free_claim" then $probe else null end),
        free_claim_probe_tool_sha256:(if $role == "free_claim" then $probe_tool else null end),
        node_result_sha256:$result_sha}'
}

while read -r role nodes; do
    [[ -n "${role:-}" && "$role" != \#* ]] || continue
    read -r -a wave_nodes <<<"$nodes"
    overlay="$run_dir/overlay-${role}-$(IFS=-; printf '%s' "${wave_nodes[*]}").yml"
    awk -v image_ref="$CANDIDATE_IMAGE_REF" -v role="$role" \
      -v nodes="${wave_nodes[*]}" -v topology_file="$topology_map" \
      -f "$package_dir/render_compose_runtime.awk" /dev/null |
      v3015_atomic_write "$overlay"
    overlay_compose_model=$(docker compose -f "$COMPOSE_FILE" -f "$overlay" \
      config --format json) || v3015_die 'merged Compose topology could not be rendered'
    v3015_compose_topology_matches "$topology_map" "$overlay_compose_model" ||
        v3015_die 'merged Compose service/container topology is incomplete or ambiguous'
    if [[ "$role" == regular ]]; then
        for node in "${wave_nodes[@]}"; do
            # Parent containment ownership must precede child/Compose mutation.
            touched+=("$node")
            "$package_dir/native_restart_durability.sh" "$env_file" "$node" "$overlay" "$run_dir"
        done
    else
        # Node30 is upgraded separately with regular PoW hard-disabled. The
        # separately reviewed probe owns Free Claim service truth; it is read-only.
        node=30
        node30_before_id=$(docker inspect -f '{{.Id}}' "$node30_container")
        node30_baseline=$(capture_node30_wallet_state)
        v3015_wallet_state_has_single_identity "$node30_baseline" ||
            v3015_die 'node30 baseline does not contain exactly one loaded wallet identity'
        node30_baseline_walletname=$(jq -er '.wallet.walletname' <<<"$node30_baseline")
        touched+=(30)
        docker compose -f "$COMPOSE_FILE" -f "$overlay" up -d --no-deps \
          --force-recreate --pull never "$node30_service" >/dev/null
        wait_node30_rpc || v3015_die 'node30 RPC did not return after recreation'
        verify_node30_invocation || v3015_die 'node30 candidate invocation or binary identity mismatch'
        node30_first_argv_sha=$node30_argv_sha
        node30_after_id=$(docker inspect -f '{{.Id}}' "$node30_container")
        [[ "$node30_after_id" != "$node30_before_id" ]] ||
            v3015_die 'node30 candidate container was not recreated'
        node30_candidate_wallet_deadline=$((SECONDS + 180))
        until node30_candidate_wallet=$(capture_node30_wallet_state "$node30_baseline") &&
              v3015_wallet_state_has_single_identity "$node30_candidate_wallet" &&
              [[ "$(jq -r '.wallet.walletname' <<<"$node30_candidate_wallet")" == \
                 "$node30_baseline_walletname" ]] &&
              node30_preunlock_migration=$(v3015_make_preunlock_migration_audit \
                "$node30_baseline" "$node30_candidate_wallet") &&
              v3015_preunlock_migration_is_safe "$node30_preunlock_migration"; do
            ((SECONDS < node30_candidate_wallet_deadline)) ||
                v3015_die 'node30 portable locked pre-unlock migration guard did not converge'
            sleep 2
        done
        /bin/bash "$NORMAL_UNLOCK_HELPER" 30 >/dev/null
        node30_initial_deadline=$((SECONDS + 180))
        until node30_staking=$(node30_rpc getstakinginfo) &&
              v3015_pos_json_is_active "$node30_staking" &&
              node30_pow=$(node30_rpc getpowmininginfo) &&
              jq -e '.enabled == false and .autostart == false and
                .state == "disabled" and .hashrate == 0' <<<"$node30_pow" >/dev/null; do
            ((SECONDS < node30_initial_deadline)) ||
                v3015_die 'node30 PoS/regular-PoW role did not become operational before restart'
            sleep 2
        done
        docker restart --time 30 "$node30_container" >/dev/null
        wait_node30_rpc || v3015_die 'node30 RPC did not return after restart'
        verify_node30_invocation || v3015_die 'node30 restarted invocation identity mismatch'
        [[ "$node30_argv_sha" == "$node30_first_argv_sha" ]] ||
            v3015_die 'node30 runtime argv changed across restart'
        node30_locked_deadline=$((SECONDS + 180))
        while :; do
            if node30_locked_wallet=$(node30_rpc getwalletinfo) &&
               node30_locked_wallets=$(node30_rpc listwallets) &&
               node30_locked_staking=$(node30_rpc getstakinginfo) &&
               node30_locked_pow=$(node30_rpc getpowmininginfo); then
                node30_locked_identity=$(jq -cn --argjson wallet "$node30_locked_wallet" \
                  --argjson wallets "$node30_locked_wallets" \
                  '{wallet:$wallet,loaded_wallets:$wallets}')
                v3015_wallet_state_has_single_identity "$node30_locked_identity" &&
                  [[ "$(jq -r '.wallet.walletname' <<<"$node30_locked_identity")" == \
                     "$node30_baseline_walletname" ]] ||
                    v3015_die 'node30 loaded wallet identity changed across locked restart'
                node30_locked_observation=$(jq -cn --argjson wallet "$node30_locked_wallet" \
                  --argjson staking "$node30_locked_staking" \
                  --argjson pow "$node30_locked_pow" \
                  '{wallet:$wallet,staking:$staking,pow:$pow}')
                jq -e '(.wallet.unlocked_until // 0) == 0 and
                  (.wallet.unlocked_staking_only // false) == false and
                  .staking.enabled == true and .staking.autostart_staking == true and
                  .pow.enabled == false and .pow.autostart == false and
                  .pow.hashrate == 0 and .pow.state == "disabled"' \
                  <<<"$node30_locked_observation" >/dev/null ||
                      v3015_die 'node30 locked restart disabled or contradicted role authority'
                node30_locked_staking_state=$(jq -er '.staking.staking_state' \
                  <<<"$node30_locked_observation")
                node30_locked=$(jq -cn --argjson wallet "$node30_locked_wallet" \
                  --argjson staking "$node30_locked_staking" \
                  --argjson pow "$node30_locked_pow" '{
                    wallet_locked:(($wallet.unlocked_until // 0) == 0),
                    normal_unlock_called:false,
                    pos_intent_retained:($staking.autostart_staking == true),
                    regular_pow_disabled:($pow.enabled == false and $pow.autostart == false),
                    staking:$staking,regular_pow:$pow}')
                if [[ "$node30_locked_staking_state" == locked ]] && jq -e '
                  .wallet_locked == true and .normal_unlock_called == false and
                  .pos_intent_retained == true and .regular_pow_disabled == true and
                  .staking.enabled == true and .staking.autostart_staking == true and
                  .staking.worker_running == true and .staking.staking == false and
                  .staking.eligible == false and .staking.staking_state == "locked" and
                  .regular_pow.enabled == false and .regular_pow.hashrate == 0 and
                  .regular_pow.state == "disabled"' \
                  <<<"$node30_locked" >/dev/null; then break; fi
                [[ "$node30_locked_staking_state" == starting ||
                   "$node30_locked_staking_state" == syncing ]] ||
                    v3015_die 'node30 locked restart PoS worker entered a disabled, stopped, or error state'
            fi
            ((SECONDS < node30_locked_deadline)) ||
                v3015_die 'node30 locked restart worker states did not converge'
            sleep 2
        done
        /bin/bash "$NORMAL_UNLOCK_HELPER" 30 >/dev/null
        node30_raw="$run_dir/node-30-free-claim-probe.raw.json"
        v3015_stage_root_executable_copy "$NODE30_FREE_CLAIM_PROBE" \
          "$NODE30_FREE_CLAIM_PROBE_SHA256" "$node30_probe_tool" ||
            v3015_die 'node30 probe could not be pinned under fleet locks'
        capture_node30_probe_evidence "$node30_raw" initial ||
            v3015_die 'initial node30 Free Claim probe failed closed'
        node30_final=$(capture_node30_wallet_state "$node30_candidate_wallet")
        node30_wallet_audit=$(v3015_make_wallet_audit "$node30_candidate_wallet" "$node30_final")
        v3015_wallet_delta_is_safe "$node30_wallet_audit" ||
            v3015_die 'node30 wallet/recovery/key/payout/policy comparison failed'
        jq -e '.delta.removed_txids == [] and
          all(.delta.transactions[];
            .safe_external_receive == true and
            .authenticated_same_anchor_claim == false and
            .normal_coinstake == false and
            .authenticated_synthetic_payout == false and
            .cleanup == false and .recovery == false and
            .resolution == false and .recovery_fee == 0)' \
          <<<"$node30_wallet_audit" >/dev/null ||
            v3015_die 'node30 wallet delta is not an external receive-only change'
        node30_raw_sha=$(v3015_sha256_file "$node30_raw")
        jq --arg source "$SOURCE_SHA" --arg image "$CANDIDATE_IMAGE_REF" \
          --arg image_id "$CANDIDATE_IMAGE_ID" --arg argv "$node30_argv_sha" \
          --arg raw_sha "$node30_raw_sha" --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
          --arg nonce "$nonce" \
          --argjson locked "$node30_locked" \
          --argjson migration "$node30_preunlock_migration" \
          --argjson audit "$node30_wallet_audit" '
          .payload as $probe | {schema:1,node:30,source_sha:$source,rollout_nonce:$nonce,
            network_version:300105,
            subversion:"/Blackcoin:30.1.5/",role:"free_claim",regular_pow_enabled:false,
            deployment_state:"pause_preserved_pending_separate_release",
            probe_tool_sha256:$probe_tool,raw_probe_sha256:$raw_sha,
            healthy:$probe.healthy,paused:$probe.paused,
            wallet_normal_unlocked:$probe.wallet_normal_unlocked,
            container_recreated:true,restart_performed:true,normal_unlock_only:true,
            repair_rpcs:[],data_rewind_used:false,containment_only_on_failure:true,
            invocation:{candidate_image_ref:$image,candidate_image_id:$image_id,
              entrypoint_body_sha256:
                "753acc9904b48c411f5514abface930f79d72d00c9d73e91435a6511877d47b4",
              runtime_argv_sha256:$argv,
              config_cmd:["-walletbroadcast=1","-autostartstaking=1","-powmining=0"]},
            locked_restart:($locked + {free_claim_intent_retained:
              ($probe.locked_restart.free_claim_intent_retained == true)}),
            free_claim_intent_retained:$probe.free_claim_intent_retained,
            samples:$probe.samples,
            preunlock_migration:$migration,
            wallet_audit:$audit,
            no_recovery_or_resolution_transaction:
              all($audit.delta.transactions[];
                .cleanup == false and .recovery == false and
                .resolution == false and .recovery_fee == 0)}' "$node30_raw" \
          >"$run_dir/node-30-free-claim.json.tmp"
        v3015_node30_result_is_valid "$run_dir/node-30-free-claim.json.tmp" "$node30_raw" \
          "$run_dir/AUTHORITY" ||
          v3015_die 'node30 Free Claim is unhealthy or paused'
        mv -- "$run_dir/node-30-free-claim.json.tmp" "$run_dir/node-30-free-claim.json"
        chmod 600 "$run_dir/node-30-free-claim.json"
    fi
    rm -- "$overlay"
done <"$waves"

# A fresh terminal census is the fleet result authority. Counts and node lists
# are computed from these 32 newly sampled rows; no rollout-loop success count
# is accepted as a substitute for terminal runtime truth.
terminal_nodes='[]'
for node in $(seq 1 32); do
    terminal_row=$(capture_terminal_census_row "$node") ||
        v3015_die "terminal fleet census failed closed at node${node}"
    terminal_nodes=$(jq -cn --argjson rows "$terminal_nodes" --argjson row "$terminal_row" \
      '$rows + [$row]')
done
terminal_probe_sha=$(v3015_sha256_file \
  "$run_dir/node-30-free-claim-terminal-probe.raw.json")
terminal_census=$(jq -cn --arg source "$SOURCE_SHA" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg nonce "$nonce" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$terminal_probe_sha" \
  --argjson nodes "$terminal_nodes" '{schema:1,source_sha:$source,rollout_nonce:$nonce,
    deployment_state:"pause_preserved_pending_separate_release",
    captured_utc:$now,nodes:$nodes,
    pos_active_nodes:[$nodes[] | select(.pos_contract_passed == true) | .node],
    pos_active_count:([$nodes[] | select(.pos_contract_passed == true)] | length),
    regular_pow_nodes:[$nodes[] | select(.role == "regular" and
      .pow_contract_passed == true) | .node],
    regular_pow_operational_count:([$nodes[] | select(.role == "regular" and
      .pow_contract_passed == true)] | length),
    node30_free_claim_healthy:$nodes[29].free_claim_healthy,
    node30_free_claim_paused:$nodes[29].free_claim_paused,
    node30_free_claim_probe_tool_sha256:$probe_tool,
    node30_terminal_probe_sha256:$terminal_probe}')
printf '%s\n' "$terminal_census" | v3015_atomic_write "$run_dir/terminal-fleet-census.json"
v3015_terminal_census_is_valid "$run_dir/terminal-fleet-census.json" "$run_dir" \
  "$run_dir/AUTHORITY" ||
    v3015_die 'terminal 32-node census does not meet v30.1.5 policy'
v3015_remove_owned_root_executable "$node30_probe_tool" \
  "$NODE30_FREE_CLAIM_PROBE_SHA256" ||
    v3015_die 'pinned node30 probe removal ownership/durability proof failed'
terminal_census_sha=$(v3015_sha256_file "$run_dir/terminal-fleet-census.json")

cp -- "$RELEASE_IDENTITY_JSON" "$run_dir/release-identity.json"
cp -- "$run_dir/AUTHORITY" "$run_dir/rollout-authority.json"
cp -- "$RUNTIME_POLICY_HANDOFF_RECEIPT" "$run_dir/runtime-policy-handoff-receipt.json"
cp -- "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT" \
  "$run_dir/persistent-compose-handoff-receipt.json"
cp -- "$POST_COMPOSE_RECONCILE_IDENTITY_PROOF" \
  "$run_dir/post-compose-reconcile-identity.json"
jq -cn --arg source "$SOURCE_SHA" --arg census_sha "$terminal_census_sha" \
  --arg nonce "$nonce" \
  --arg policy_receipt "$RUNTIME_POLICY_HANDOFF_RECEIPT_SHA256" \
  --arg compose_receipt "$PERSISTENT_COMPOSE_HANDOFF_RECEIPT_SHA256" \
  --arg compose_sha "$FINAL_COMPOSE_SHA256" --arg policy_sha "$FINAL_IMAGE_POLICY_SHA256" \
  --arg reconcile "$POST_COMPOSE_RECONCILE_IDENTITY_SHA256" \
  --arg probe_tool "$NODE30_FREE_CLAIM_PROBE_SHA256" \
  --arg terminal_probe "$terminal_probe_sha" \
  --argjson census "$terminal_census" '{schema:1,transaction:"v30.1.5-fleet-rollout",
  source_sha:$source,rollout_nonce:$nonce,
  status:"PAUSE_PRESERVED_PENDING_SEPARATE_RELEASE",
  deployment_state:"pause_preserved_pending_separate_release",
  pos_active:$census.pos_active_count,
  pos_active_nodes:$census.pos_active_nodes,
  regular_pow_operational:$census.regular_pow_operational_count,
  regular_pow_nodes:$census.regular_pow_nodes,node30_role:"free_claim",
  node30_free_claim_healthy:$census.node30_free_claim_healthy,
  node30_free_claim_paused:$census.node30_free_claim_paused,data_rewind_used:false,
  node30_free_claim_probe_tool_sha256:$probe_tool,
  node30_terminal_probe_sha256:$terminal_probe,
  runtime_policy_handoff_receipt_sha256:$policy_receipt,
  persistent_compose_handoff_receipt_sha256:$compose_receipt,
  final_compose_sha256:$compose_sha,final_image_policy_sha256:$policy_sha,
  post_compose_reconcile_identity_sha256:$reconcile,
  containment_only_failure_policy:true}' | v3015_atomic_write "$run_dir/fleet-result.json"

v3015_remove_owned_authority "$run_dir/AUTHORITY" "$authority_sha" ||
    v3015_die 'rollout authority removal ownership/durability proof failed'
(
    cd "$run_dir"
    manifest_tmp=".SHA256SUMS.$$"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -exec basename {} \; | sort |
      while IFS= read -r file; do sha256sum -- "$file"; done >"$manifest_tmp"
    mv -- "$manifest_tmp" SHA256SUMS
    chmod 600 SHA256SUMS
)
"$package_dir/verify-evidence.sh" "$env_file" "$run_dir"
[[ "$(v3015_sha256_file "$marker")" == "$marker_sha" &&
   "$(jq -cS . "$marker")" == "$(jq -cS . <<<"$marker_json")" ]] ||
    v3015_die 'rollout marker ownership changed before removal'
v3015_remove_owned_authority "$marker" "$marker_sha" ||
    v3015_die 'rollout marker removal ownership/durability proof failed'
success=1
trap - EXIT
printf 'v30.1.5 fleet rollout PASS; candidate retained with live data\n'
