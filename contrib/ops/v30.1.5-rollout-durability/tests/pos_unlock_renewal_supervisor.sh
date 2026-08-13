#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
supervisor="$package_dir/pos_unlock_renewal_supervisor.sh"
# shellcheck disable=SC1090 # The exact package-local supervisor is the unit under test.
source "$supervisor"

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
skip()
{
    tests=$((tests + 1))
    printf 'ok %03d - %s # SKIP %s\n' "$tests" "$1" "$2"
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

tmp=$(realpath -- "$(mktemp -d "${TMPDIR:-/tmp}/pos-renewal-tests.XXXXXX")")
trap 'renewal_cleanup; rm -rf -- "$tmp"' EXIT
uid=$(id -u)
test_now=$(date +%s)
hex_a=$(printf 'a%.0s' {1..64})
hex_b=$(printf 'b%.0s' {1..64})
hex_c=$(printf 'c%.0s' {1..64})
hex_d=$(printf 'd%.0s' {1..64})
hex_e=$(printf 'e%.0s' {1..64})

make_state_manifests()
{
    local root=$1 node padded wallet
    mkdir -p "$root/runtime-wallet-manifests" "$root/runtime-identity-manifests"
    chmod 700 "$root" "$root/runtime-wallet-manifests" \
      "$root/runtime-identity-manifests"
    for node in $(seq 1 32); do
        printf -v padded '%02d' "$node"
        wallet="wallet-$padded"
        jq -cn --arg wallet "$wallet" '[$wallet]' \
          >"$root/runtime-wallet-manifests/node-$padded.json"
        jq -cn --arg node "$padded" --arg wallet "$wallet" --arg h "$hex_a" '{
          schema:2,node_id:$node,wallet:$wallet,legacy_descriptors_sha256:$h,
          quantum_identity_sha256:$h,trusted_policy_sha256:$h,
          trusted_legacy_descriptor_set_sha256:$h,
          trusted_quantum_address_set_sha256:$h,trusted_quantum_address_count:1
        }' >"$root/runtime-identity-manifests/node-$padded.json"
    done
    find "$root" -type f -exec chmod 600 {} +
}

make_manifest_map()
{
    local root=$1 output=$2 node padded relative sha map='{}'
    for node in $(seq 1 32); do
        printf -v padded '%02d' "$node"
        for relative in "runtime-wallet-manifests/node-$padded.json" \
          "runtime-identity-manifests/node-$padded.json"; do
            sha=$(sha256sum "$root/$relative" | awk '{print $1}')
            map=$(jq -cn --argjson map "$map" --arg relative "$relative" --arg sha "$sha" \
              '$map + {($relative):$sha}')
        done
    done
    printf '%s\n' "$map" >"$output"
}

make_authority()
{
    local output=$1 manifest_map=$2 supervisor_sha=${3:-$hex_a}
    local package_sha=${4:-$hex_b} topology_sha=${5:-$hex_c} job10_sha=${6:-$hex_d}
    local issued=$((test_now - 10)) valid_from=$((test_now - 5)) valid_until=$((test_now + 86390))
    # shellcheck disable=SC2153 # Constants are assigned by the sourced supervisor.
    jq -n --argjson manifests "$(<"$manifest_map")" \
      --arg nonce '0123456789abcdef0123456789abcdef' \
      --argjson issued "$issued" --argjson valid_from "$valid_from" \
      --argjson valid_until "$valid_until" --arg parent "$TOOLING_PARENT_COMMIT" \
      --arg supervisor_sha "$supervisor_sha" --arg package_sha "$package_sha" \
      --arg topology_sha "$topology_sha" --arg job10_sha "$job10_sha" \
      --arg cron_sha "$(renewal_cron_sha256)" --arg helper "$EXPECTED_HELPER_SHA256" \
      --arg marker "$EXPECTED_MARKER_SHA256" --arg image_id "$EXPECTED_IMAGE_ID" \
      --arg image_ref "$EXPECTED_IMAGE_REF" --arg subversion "$EXPECTED_SUBVERSION" \
      --arg global "$GLOBAL_LOCK" --arg per_node "$PER_NODE_LOCK_PATTERN" \
      --arg install_root "$INSTALL_ROOT" --arg installed_supervisor "$INSTALLED_SUPERVISOR" \
      --arg installed_authority "$INSTALLED_AUTHORITY" --arg installed_job10 "$INSTALLED_JOB10_CONTRACT" \
      --arg installed_topology "$INSTALLED_TOPOLOGY_MAP" \
      --arg installed_manifest "$INSTALLED_PACKAGE_MANIFEST" --arg cron_path "$CRON_PATH" \
      --arg receipt_root "$RUNTIME_RECEIPT_ROOT" --arg historical "$HISTORICAL_JOB10_RECEIPT" \
      --arg cron_expression "$CRON_EXPRESSION" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-authority",state:"authorized",
        authority_nonce:$nonce,issued_at_epoch:$issued,valid_from_epoch:$valid_from,
        valid_until_epoch:$valid_until,tooling_parent_commit:$parent,
        supervisor_sha256:$supervisor_sha,package_manifest_sha256:$package_sha,
        topology_map_sha256:$topology_sha,job10_contract_sha256:$job10_sha,
        cron_sha256:$cron_sha,normal_unlock_helper_sha256:$helper,
        maintenance_marker_sha256:$marker,image_id:$image_id,image_ref:$image_ref,
        network_version:300104,subversion:$subversion,minimum_peers:1,
        minimum_post_unlock_seconds:43200,post_helper_wait_seconds:60,
        renewal_cadence_minutes:360,cron_expression:$cron_expression,
        global_lock:$global,per_node_lock_pattern:$per_node,install_root:$install_root,
        installed_supervisor:$installed_supervisor,installed_authority:$installed_authority,
        installed_job10_contract:$installed_job10,installed_topology_map:$installed_topology,
        installed_package_manifest:$installed_manifest,cron_path:$cron_path,
        runtime_receipt_root:$receipt_root,historical_job10_receipt_target:$historical,
        historical_job10_preserved_read_only:true,maintenance_inhibitor_must_remain:true,
        regular_pow_rpc_forbidden:true,node30_ordinary_pow_enable_forbidden:true,
        chain_config_key_transaction_mutation_forbidden:true,
        allowed_rpc_methods:["getblockchaininfo","getnetworkinfo","getstakinginfo",
          "getwalletinfo","listwallets"],helper_nodes:[range(1;33)],
        helper_execution:"sequential-1-through-32",install_authorized:true,
        renewal_authorized:true,manifest_sha256s:$manifests
      }' >"$output"
    chmod 600 "$output"
}

state="$tmp/state"
manifest_map="$tmp/manifest-map.json"
authority="$tmp/authority.json"
make_state_manifests "$state"
make_manifest_map "$state" "$manifest_map"
make_authority "$authority" "$manifest_map"

expect_pass 'historical job-10 one-shot contract matches every accepted live-audit field' \
  renewal_job10_contract_is_valid "$JOB10_CONTRACT"

job10_mutations=(
  '.scheduler.job_id=11'
  '.scheduler.scheduled_utc="2026-08-14T03:42:00Z"'
  '.scheduler.recurring=true'
  '.body.audited_local_sha256=("0"*64)'
  '.body.stored_suffix_sha256=("0"*64)'
  '.body.stored_suffix_has_one_appended_blank_line=false'
  '.body.stored_minus_final_blank_reproduces_local_sha256=false'
  '.body.sentinel_count=2'
  '.body.contains_secret_passphrase_private_key_payout_or_endpoint=true'
  '.spool.mode="0755"'
  '.global_mutex="/run/other.lock"'
  '.receipt_target="/tmp/receipt"'
  '.preflight.maintenance_marker_sha256=("0"*64)'
  '.preflight.normal_unlock_helper_sha256=("0"*64)'
  '.preflight.image_id="sha256:"+("0"*64)'
  '.preflight.image_ref="other@sha256:"+("0"*64)'
  '.action.helper_nodes[29]=31'
  '.action.post_helper_wait_seconds=59'
  '.postflight.minimum_normal_unlock_remaining_seconds=43199'
  '.postflight.pos_active_nodes=31'
  '.postflight.regular_pow_intent_nodes_observed_by_historical_job=32'
  '.postflight.node30_ordinary_pow_disabled=false'
  '.one_shot_only=false'
  '.historical_receipt_is_read_only=false'
  '.installed_or_executed_by_this_package=true'
  '.extra=true'
)
for mutation in "${job10_mutations[@]}"; do
    mutated="$tmp/job10-mutated.json"
    jq "$mutation" "$JOB10_CONTRACT" >"$mutated"
    expect_fail "historical job-10 contract rejects $mutation" \
      renewal_job10_contract_is_valid "$mutated"
done

expect_pass 'exact install-and-renew authority schema is accepted' \
  renewal_validate_authority_semantics "$authority" "$test_now"

authority_mutations=(
  '.state="reviewed"'
  '.authority_nonce="short"'
  '.valid_until_epoch=1'
  '.valid_until_epoch=(.issued_at_epoch+86401)'
  '.tooling_parent_commit=("0"*40)'
  '.normal_unlock_helper_sha256=("0"*64)'
  '.maintenance_marker_sha256=("0"*64)'
  '.image_id="sha256:"+("0"*64)'
  '.image_ref="other@sha256:"+("0"*64)'
  '.network_version=300105'
  '.minimum_peers=0'
  '.minimum_post_unlock_seconds=43199'
  '.post_helper_wait_seconds=0'
  '.renewal_cadence_minutes=60'
  '.cron_expression="* * * * *"'
  '.global_lock="/run/other.lock"'
  '.per_node_lock_pattern="/tmp/node-%02d.lock"'
  '.historical_job10_receipt_target="/tmp/other"'
  '.historical_job10_preserved_read_only=false'
  '.maintenance_inhibitor_must_remain=false'
  '.regular_pow_rpc_forbidden=false'
  '.node30_ordinary_pow_enable_forbidden=false'
  '.chain_config_key_transaction_mutation_forbidden=false'
  '.allowed_rpc_methods += ["getpowmininginfo"]'
  '.helper_nodes[0]=2'
  '.helper_execution="parallel"'
  '.install_authorized=false'
  '.renewal_authorized=false'
  'del(.manifest_sha256s["runtime-wallet-manifests/node-01.json"])'
  '.manifest_sha256s["extra"]=("0"*64)'
  '.manifest_sha256s["pow-wallet-manifests/node-30.json"]=("0"*64)'
  '.manifest_sha256s["runtime-wallet-manifests/node-01.json"]="bad"'
  '.extra=true'
)
for mutation in "${authority_mutations[@]}"; do
    mutated="$tmp/authority-mutated.json"
    jq "$mutation" "$authority" >"$mutated"
    expect_fail "authority rejects $mutation" renewal_validate_authority_semantics "$mutated" "$test_now"
done

expect_pass 'all exact runtime wallet and identity manifest bytes verify' \
  renewal_verify_manifest_bytes "$authority" "$state" "$uid"
for node in $(seq 1 32); do
    printf -v padded '%02d' "$node"
    expect_pass "node $padded manifests bind the one loaded wallet" \
      renewal_verify_node_manifests "$authority" "$state" "$node" "wallet-$padded" "$uid"
done
expect_fail 'manifest contract rejects a different live wallet identity' \
  renewal_verify_node_manifests "$authority" "$state" 1 'other-wallet' "$uid"

helper_fixture="$tmp/helper.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# listwallets'
    printf '%s\n' '# getwalletinfo'
    printf '%s\n' '# getwalletinfo'
    printf '%s\n' '# getstakinginfo'
    printf '%s\n' '# getstakinginfo'
    printf '%s\n' '# walletpassphrase exact-secret-file-value 999999 false'
    for _ in $(seq 8 53); do printf '%s\n' '# audited helper padding'; done
} >"$helper_fixture"
delta=$((3206 - $(wc -c <"$helper_fixture")))
((delta >= 2))
printf '#%*s\n' "$((delta - 2))" '' >>"$helper_fixture"
chmod 600 "$helper_fixture"
expect_pass 'helper content audit accepts only the exact six-RPC normal-unlock shape' \
  renewal_helper_content_is_audited "$helper_fixture"
helper_bad="$tmp/helper-bad.sh"
sed 's/audited helper padding/setpowmining true/' "$helper_fixture" >"$helper_bad"
chmod 600 "$helper_bad"
expect_fail 'helper content audit rejects an ordinary-PoW mutation primitive' \
  renewal_helper_content_is_audited "$helper_bad"
expect_fail 'installed helper verifier rejects non-pinned bytes even when content shape is safe' \
  renewal_verify_helper "$helper_fixture" "$uid"

global_lock="$tmp/global.lock"
if ((BASH_VERSINFO[0] >= 4)) && command -v flock >/dev/null 2>&1; then
    expect_pass 'global lock can be acquired only as an exact single-link 0600 file' \
      renewal_acquire_lock "$global_lock" "$uid"
    renewal_release_locks
    ln -s "$global_lock" "$tmp/symlink.lock"
    expect_fail 'symlink lock path fails closed' renewal_acquire_lock "$tmp/symlink.lock" "$uid"
    exec 8>"$global_lock"
    flock -n 8
    expect_fail 'contended global lock fails closed' renewal_acquire_lock "$global_lock" "$uid"
    flock -u 8
    exec 8>&-
    expect_pass 'global plus all 32 ordered per-node locks are acquired together' \
      renewal_acquire_fleet_locks "$global_lock" "$tmp/node-%02d.lock" "$uid"
    if [[ "${#RENEWAL_LOCK_FDS[@]}" -eq 33 ]]; then ok 'fleet lock set contains exactly 33 locks';
    else not_ok 'fleet lock set contains exactly 33 locks'; fi
    renewal_release_locks
else
    expect_fail 'unsupported Bash cannot enter the held-lock runtime' renewal_require_supported_bash
    skip 'global lock runtime semantics' 'local host lacks Bash 4+ and util-linux flock'
    skip 'symlink and contention lock hostiles' 'local host lacks Bash 4+ and util-linux flock'
    skip 'global plus 32 per-node held locks' 'local host lacks Bash 4+ and util-linux flock'
    skip 'fleet lock set contains exactly 33 locks' 'local host lacks Bash 4+ and util-linux flock'
fi

MOCK_BAD_IMAGE_NODE=0
MOCK_BAD_CHAIN_NODE=0
MOCK_IBD_NODE=0
MOCK_ZERO_PEERS_NODE=0
MOCK_TWO_WALLETS_NODE=0
MOCK_CHAIN_DRIFT_NODE=0
MOCK_UNSAFE_STAKING_NODE=0
mock_node_for_container()
{
    local container=$1 node
    node=$(awk -v container="$container" '!/^#/ && $3 == container {print $1}' "$TOPOLOGY_MAP")
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    printf '%s\n' "$node"
}
renewal_docker()
{
    local command=$1 container=$2 node method tip counter calls=0
    shift 2
    node=$(mock_node_for_container "$container") || return 1
    if [[ "$command" == inspect ]]; then
        local image_id=$EXPECTED_IMAGE_ID
        [[ "$node" -eq "$MOCK_BAD_IMAGE_NODE" ]] && image_id="sha256:$hex_e"
        jq -cn --arg container "/$container" --arg ref "$EXPECTED_IMAGE_REF" \
          --arg id "$image_id" '[{Name:$container,Config:{Image:$ref},Image:$id,
          State:{Running:true,Restarting:false,Paused:false,Health:{Status:"healthy"}}}]'
        return
    fi
    [[ "$command" == exec ]] || return 1
    method=${!#}
    case "$method" in
        getblockchaininfo)
            counter="$tmp/mock-chain-call-$node"
            [[ ! -f "$counter" ]] || read -r calls <"$counter"
            calls=$((calls + 1))
            printf '%s\n' "$calls" >"$counter"
            tip=$hex_a
            [[ "$node" -eq "$MOCK_CHAIN_DRIFT_NODE" && "$calls" -gt 1 ]] && tip=$hex_b
            jq -cn --arg chain "$([[ "$node" -eq "$MOCK_BAD_CHAIN_NODE" ]] && printf test || printf main)" \
              --arg tip "$tip" --arg work "$hex_c" \
              --argjson ibd "$([[ "$node" -eq "$MOCK_IBD_NODE" ]] && printf true || printf false)" \
              '{chain:$chain,blocks:6000000,headers:6000000,bestblockhash:$tip,
                chainwork:$work,initialblockdownload:$ibd}'
            ;;
        getnetworkinfo)
            jq -cn --arg sub "$EXPECTED_SUBVERSION" \
              --argjson peers "$([[ "$node" -eq "$MOCK_ZERO_PEERS_NODE" ]] && printf 0 || printf 12)" \
              '{version:300104,subversion:$sub,connections:$peers}'
            ;;
        listwallets)
            printf -v padded '%02d' "$node"
            if [[ "$node" -eq "$MOCK_TWO_WALLETS_NODE" ]]; then
                jq -cn --arg wallet "wallet-$padded" '[$wallet,"extra"]'
            else
                jq -cn --arg wallet "wallet-$padded" '[$wallet]'
            fi
            ;;
        getwalletinfo)
            printf -v padded '%02d' "$node"
            jq -cn --arg wallet "wallet-$padded" --argjson unlock "$((test_now + 50000))" '{
              walletname:$wallet,private_keys_enabled:true,scanning:false,
              unlocked_until:$unlock,unlocked_staking_only:false}'
            ;;
        getstakinginfo)
            jq -cn --argjson unsafe "$([[ "$node" -eq "$MOCK_UNSAFE_STAKING_NODE" ]] && printf true || printf false)" '{
              enabled:true,autostart_staking:true,automatic_qqsignal:$unsafe,
              automatic_demurrage_attestation:false,automatic_redelegation:false,
              allow_automatic_quantum_key_creation:false,staking:true,worker_running:true,
              eligible:true,staking_snapshot_current:true,staking_state:"searching",
              weight:100,weight_cached:true}'
            ;;
        *) return 1 ;;
    esac
}

reset_mock()
{
    MOCK_BAD_IMAGE_NODE=0 MOCK_BAD_CHAIN_NODE=0 MOCK_IBD_NODE=0 MOCK_ZERO_PEERS_NODE=0
    MOCK_TWO_WALLETS_NODE=0 MOCK_CHAIN_DRIFT_NODE=0 MOCK_UNSAFE_STAKING_NODE=0
    find "$tmp" -type f -name 'mock-chain-call-*' -delete
}

expect_pass 'read-only node preflight binds image, main, sync, peers, wallet, manifests, and PoS intent' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_BAD_IMAGE_NODE=1
expect_fail 'node preflight rejects wrong image ID' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_BAD_CHAIN_NODE=1
expect_fail 'node preflight rejects non-main chain' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_IBD_NODE=1
expect_fail 'node preflight rejects initial block download' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_ZERO_PEERS_NODE=1
expect_fail 'node preflight rejects zero peers' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_TWO_WALLETS_NODE=1
expect_fail 'node preflight rejects multiple loaded wallets' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_CHAIN_DRIFT_NODE=1
expect_fail 'node preflight rejects a mixed chain bracket' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_UNSAFE_STAKING_NODE=1
expect_fail 'node preflight rejects automatic staking-side key authority' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock
expect_pass 'postflight requires normal unlock beyond twelve hours and active searching PoS' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 30 post "$uid"
expect_pass 'complete 32-node preflight shares one exact live tip and chainwork' \
  renewal_capture_fleet "$authority" "$state" "$TOPOLOGY_MAP" pre "$uid"

# shellcheck disable=SC2016 # The single-quoted program is intentionally evaluated by bash -c.
expect_pass 'supervisor RPC callsites use only the five read-only allowlisted methods' bash -c '
  set -euo pipefail
  file=$1
  actual=$(sed -n -E "s/.*renewal_(wallet_)?rpc .* ((get[a-z0-9]+)|listwallets).*/\\2/p" "$file" | sort -u)
  expected=$(printf "%s\n" getblockchaininfo getnetworkinfo getstakinginfo getwalletinfo listwallets | sort)
  test "$actual" = "$expected"
' bash "$supervisor"
expect_pass 'supervisor has no regular-PoW RPC read or write callsite' bash -c \
  "! grep -Eq 'renewal_(wallet_)?rpc .* (getpowmininginfo|setpowmining)' '$supervisor'"
expect_pass 'supervisor cannot read a regular-PoW intent manifest' bash -c \
  "! grep -Fq 'pow-wallet-manifests' '$supervisor'"
expect_pass 'supervisor has no chain, config, key, or transaction RPC mutation callsite' bash -c \
  "! grep -Eiq 'renewal_(wallet_)?rpc .* (walletlock|set|send|create|commit|resolve|abandon|import|dump|backup|rescan|reindex|gettransaction|listtransactions)' '$supervisor'"
expect_pass 'supervisor never invokes Docker Compose or container lifecycle mutation' bash -c \
  "! grep -Eiq 'renewal_docker[[:space:]]+(compose|start|stop|restart|update|rm|kill|pause|unpause)' '$supervisor'"
expect_pass 'supervisor never removes the maintenance inhibitor or historical job receipt' bash -c \
  "! grep -Eq 'rm[^#\n]*(MAINTENANCE_MARKER|HISTORICAL_JOB10_RECEIPT)|mv[^#\n]*(MAINTENANCE_MARKER|HISTORICAL_JOB10_RECEIPT)' '$supervisor'"
expect_pass 'helper execution is isolated and pins the exact snapshot path and node argument' bash -c \
  "test \"\$(grep -Fc '/bin/bash --noprofile --norc \"\$snapshot\" \"\$node\"' '$supervisor')\" = 1 && grep -Fq '/usr/bin/env -i PATH=\"\$PATH\" LC_ALL=C TZ=UTC' '$supervisor'"
expect_pass 'historical at job can be neither inspected nor cancelled by the supervisor' bash -c \
  "! grep -Eq '(^|[[:space:]/])(at|atq|atrm)([[:space:]]|$)' '$supervisor'"

ORCHESTRATION_LOG="$tmp/orchestration.log"
ORCHESTRATION_FAIL_PREFLIGHT=0
ORCHESTRATION_MARKER_LIMIT=0
ORCHESTRATION_MARKER_CALLS=0
renewal_acquire_fleet_locks() { printf '%s\n' locks >>"$ORCHESTRATION_LOG"; }
renewal_verify_marker()
{
    ORCHESTRATION_MARKER_CALLS=$((ORCHESTRATION_MARKER_CALLS + 1))
    printf 'marker-%s\n' "$ORCHESTRATION_MARKER_CALLS" >>"$ORCHESTRATION_LOG"
    [[ "$ORCHESTRATION_MARKER_LIMIT" -eq 0 ||
       "$ORCHESTRATION_MARKER_CALLS" -le "$ORCHESTRATION_MARKER_LIMIT" ]]
}
renewal_verify_helper() { printf '%s\n' helper-audit >>"$ORCHESTRATION_LOG"; }
renewal_verify_manifest_bytes() { printf '%s\n' manifests >>"$ORCHESTRATION_LOG"; }
# shellcheck disable=SC2329 # Invoked indirectly by renewal_execute_cycle.
renewal_validate_topology_map() { printf '%s\n' topology >>"$ORCHESTRATION_LOG"; }
renewal_capture_fleet()
{
    printf 'capture-%s\n' "$4" >>"$ORCHESTRATION_LOG"
    [[ "$ORCHESTRATION_FAIL_PREFLIGHT" -eq 0 || "$4" != pre ]] || return 1
    jq -cn --arg phase "$4" '[range(1;33) | {node:.,phase:$phase}]'
}
renewal_prepare_helper_snapshot()
{
    # shellcheck disable=SC2034 # Read indirectly by renewal_execute_cycle.
    RENEWAL_HELPER_SNAPSHOT="$tmp/exact-helper-snapshot"
    printf '%s\n' snapshot >>"$ORCHESTRATION_LOG"
}
renewal_invoke_helper_snapshot()
{
    [[ "$1" == "$tmp/exact-helper-snapshot" ]]
    printf 'invoke-%02d\n' "$2" >>"$ORCHESTRATION_LOG"
}
# shellcheck disable=SC2329 # Invoked indirectly by renewal_execute_cycle.
renewal_sleep() { [[ "$1" -eq 60 ]]; printf 'sleep-%s\n' "$1" >>"$ORCHESTRATION_LOG"; }
renewal_publish_receipt() { printf '%s\n' publish >>"$ORCHESTRATION_LOG"; }
renewal_sha256_file()
{
    if [[ "$1" == "$authority" ]]; then sha256sum "$authority" | awk '{print $1}'
    else command sha256sum "$1" | awk '{print $1}'; fi
}
authority_sha=$(renewal_sha256_file "$authority")
: >"$ORCHESTRATION_LOG"
expect_pass 'cycle invokes the exact helper sequentially only after complete locked preflight' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
# shellcheck disable=SC2016 # The single-quoted program is intentionally evaluated by bash -c.
expect_pass 'cycle order is locks, safety gates, full preflight, 1..32 helpers, wait, postflight, receipt' bash -c '
  set -euo pipefail
  log=$1
  line() { grep -n -m1 -F "$1" "$log" | cut -d: -f1; }
  test "$(grep -c "^invoke-" "$log")" = 32
  test "$(sed -n "s/^invoke-//p" "$log" | paste -sd, -)" = "01,02,03,04,05,06,07,08,09,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32"
  test "$(line locks)" -lt "$(line capture-pre)"
  test "$(line capture-pre)" -lt "$(line snapshot)"
  test "$(line snapshot)" -lt "$(line invoke-01)"
  test "$(line invoke-32)" -lt "$(line sleep-60)"
  test "$(line sleep-60)" -lt "$(line capture-post)"
  test "$(line capture-post)" -lt "$(line publish)"
' bash "$ORCHESTRATION_LOG"

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_FAIL_PREFLIGHT=1
ORCHESTRATION_MARKER_CALLS=0
expect_fail 'failed all-node preflight prevents every helper invocation' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if ! grep -q '^invoke-' "$ORCHESTRATION_LOG"; then ok 'preflight failure invoked zero helpers';
else not_ok 'preflight failure invoked zero helpers'; fi
ORCHESTRATION_FAIL_PREFLIGHT=0

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_MARKER_LIMIT=4
expect_fail 'maintenance-marker drift stops sequential renewal immediately' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if [[ "$(grep -c '^invoke-' "$ORCHESTRATION_LOG" || true)" -lt 32 ]]; then
    ok 'marker drift prevented remaining helper calls'
else
    not_ok 'marker drift prevented remaining helper calls'
fi
ORCHESTRATION_MARKER_LIMIT=0

expect_fail 'install mode is unavailable without an explicit receipt and exact hash' \
  "$supervisor" install
offline_plan_contract_is_safe()
(
    # This semantic-stage test isolates the plan contract from the independent
    # package-manifest seal, which is deliberately left for the integration stage.
    # shellcheck disable=SC2329 # Invoked indirectly by renewal_audit_or_plan.
    renewal_package_tree_is_valid() { return 0; }
    output=$(renewal_audit_or_plan plan)
    jq -e '.mode == "plan" and .status == "offline-only" and
      .deployment_authorized == false and .live_fleet_contacted == false and
      .live_fleet_mutated == false and .installed == false and .executed == false and
      .historical_job10.one_shot == true and
      .historical_job10.installation_or_execution_claimed_by_this_package == false' \
      >/dev/null <<<"$output"
)
expect_pass 'offline plan without authority is read-only and reports deployment disabled' \
  offline_plan_contract_is_safe

printf '1..%d\n' "$tests"
if ((failures != 0)); then
    printf '%d/%d tests failed\n' "$failures" "$tests" >&2
    exit 1
fi
printf '%d/%d tests passed\n' "$tests" "$tests"
