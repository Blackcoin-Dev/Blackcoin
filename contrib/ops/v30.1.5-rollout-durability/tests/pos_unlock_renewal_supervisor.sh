#!/usr/bin/env bash
export LC_ALL=C TZ=UTC
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
supervisor="$package_dir/pos_unlock_renewal_supervisor.sh"
normal_unlock_helper="$package_dir/blackcoin_node_normal_unlock.sh"
# shellcheck disable=SC1090 # The exact package-local supervisor is the unit under test.
source "$supervisor"
# shellcheck disable=SC1090 # Pure helper functions are exercised with a mocked Docker boundary.
source "$normal_unlock_helper"

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
        if [[ "$node" -eq 30 ]]; then wallet=''; else wallet="wallet-$padded"; fi
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
    local generation=${7:-1} supersedes=${8:-}
    local issued=$((test_now - 10)) valid_from=$((test_now - 5)) valid_until=$((test_now + 86390))
    [[ -n "$supersedes" ]] || supersedes=$(printf '0%.0s' {1..64})
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
      --arg cron_expression "$CRON_EXPRESSION" --argjson generation "$generation" \
      --arg supersedes "$supersedes" --argjson shared_locks "$(renewal_shared_lock_paths_json)" \
      --argjson minimum_runway "$MINIMUM_CYCLE_RUNWAY_SECONDS" '{
        schema:1,kind:"blackcoin-pos-unlock-renewal-supervisor-authority",state:"authorized",
        authority_generation:$generation,authority_nonce:$nonce,
        authority_rotation_authorized:true,supersedes_authority_sha256:$supersedes,
        issued_at_epoch:$issued,valid_from_epoch:$valid_from,
        valid_until_epoch:$valid_until,tooling_parent_commit:$parent,
        supervisor_sha256:$supervisor_sha,package_manifest_sha256:$package_sha,
        topology_map_sha256:$topology_sha,job10_contract_sha256:$job10_sha,
        cron_sha256:$cron_sha,normal_unlock_helper_sha256:$helper,
        maintenance_marker_sha256:$marker,image_id:$image_id,image_ref:$image_ref,
        network_version:300104,subversion:$subversion,minimum_peers:1,
        minimum_post_unlock_seconds:43200,minimum_cycle_runway_seconds:$minimum_runway,
        stable_census_attempts:3,post_helper_wait_seconds:60,
        renewal_cadence_minutes:360,cron_expression:$cron_expression,
        shared_locks:$shared_locks,global_lock:$global,
        lock_order:($shared_locks+[$global,$per_node]),per_node_lock_pattern:$per_node,
        install_root:$install_root,
        installed_supervisor:$installed_supervisor,installed_authority:$installed_authority,
        installed_job10_contract:$installed_job10,installed_topology_map:$installed_topology,
        installed_package_manifest:$installed_manifest,cron_path:$cron_path,
        runtime_receipt_root:$receipt_root,historical_job10_receipt_target:$historical,
        historical_job10_preserved_read_only:true,maintenance_inhibitor_must_remain:true,
        regular_pow_mutation_rpc_forbidden:true,regular_pow_observation_required:true,
        node30_ordinary_pow_enable_forbidden:true,
        chain_config_key_transaction_mutation_forbidden:true,
        allowed_rpc_methods:["getblockchaininfo","getnetworkinfo","getpowmininginfo",
          "getstakinginfo","getwalletinfo","listwallets"],helper_nodes:[range(1;33)],
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
  '.authority_generation=0'
  '.authority_nonce="short"'
  '.authority_rotation_authorized=false'
  '.supersedes_authority_sha256=("1"*64)'
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
  '.minimum_cycle_runway_seconds-=1'
  '.stable_census_attempts=4'
  '.post_helper_wait_seconds=0'
  '.renewal_cadence_minutes=60'
  '.cron_expression="* * * * *"'
  '.shared_locks=[]'
  '.global_lock="/run/other.lock"'
  '.lock_order |= reverse'
  '.per_node_lock_pattern="/tmp/node-%02d.lock"'
  '.historical_job10_receipt_target="/tmp/other"'
  '.historical_job10_preserved_read_only=false'
  '.maintenance_inhibitor_must_remain=false'
  '.regular_pow_mutation_rpc_forbidden=false'
  '.regular_pow_observation_required=false'
  '.node30_ordinary_pow_enable_forbidden=false'
  '.chain_config_key_transaction_mutation_forbidden=false'
  '.allowed_rpc_methods += ["setpowmining"]'
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
    wallet="wallet-$padded"
    [[ "$node" -eq 30 ]] && wallet=''
    expect_pass "node $padded manifests bind the one loaded wallet" \
      renewal_verify_node_manifests "$authority" "$state" "$node" "$wallet" "$uid"
done
expect_fail 'manifest contract rejects a different live wallet identity' \
  renewal_verify_node_manifests "$authority" "$state" 1 'other-wallet' "$uid"

helper_fixture="$tmp/helper.sh"
cp -- "$normal_unlock_helper" "$helper_fixture"
chmod 600 "$helper_fixture"
expect_pass 'helper content audit accepts the exact corrected normal-unlock bytes' \
  renewal_helper_content_is_audited "$helper_fixture"
helper_bad="$tmp/helper-bad.sh"
sed 's/staking true/setpowmining true/' "$helper_fixture" >"$helper_bad"
chmod 600 "$helper_bad"
expect_fail 'helper content audit rejects an ordinary-PoW mutation primitive' \
  renewal_helper_content_is_audited "$helper_bad"
expect_pass 'installed helper verifier accepts a secure exact-byte copy' \
  renewal_verify_helper "$helper_fixture" "$uid"

for node in $(seq 1 32); do
    expect_pass "normal-unlock helper accepts exact fleet node $node" \
      normal_unlock_valid_node "$node"
done
for node in '' 0 00 01 033 33 -1 abc '30 '; do
    expect_fail "normal-unlock helper rejects out-of-contract node '${node}'" \
      normal_unlock_valid_node "$node"
done
if [[ "$(normal_unlock_container_for_node 1)" == blackcoin-v4-gui &&
      "$(normal_unlock_container_for_node 30)" == blackcoin-v4-gui-30 &&
      "$(normal_unlock_container_for_node 32)" == blackcoin-v4-gui-32 ]]; then
    ok 'normal-unlock helper maps node1 and suffixed node30/node32 containers exactly'
else
    not_ok 'normal-unlock helper maps node1 and suffixed node30/node32 containers exactly'
fi

declare -a NORMAL_UNLOCK_CAPTURE_ARGS=()
NORMAL_UNLOCK_CAPTURE_TIMEOUT=''
NORMAL_UNLOCK_CAPTURE_STDIN="$tmp/captured-helper-stdin"
NORMAL_UNLOCK_CAPTURE_READ_STDIN=false
normal_unlock_docker()
{
    NORMAL_UNLOCK_CAPTURE_TIMEOUT=$1
    shift
    NORMAL_UNLOCK_CAPTURE_ARGS=("$@")
    if [[ "$NORMAL_UNLOCK_CAPTURE_READ_STDIN" == true ]]; then
        cat >"$NORMAL_UNLOCK_CAPTURE_STDIN"
    fi
}
normal_unlock_capture_matches()
{
    local timeout_seconds=$1
    shift
    [[ "$NORMAL_UNLOCK_CAPTURE_TIMEOUT" == "$timeout_seconds" &&
       "${#NORMAL_UNLOCK_CAPTURE_ARGS[@]}" -eq "$#" ]] || return 1
    [[ "$(printf '%s\n' "${NORMAL_UNLOCK_CAPTURE_ARGS[@]}")" == "$(printf '%s\n' "$@")" ]]
}

normal_unlock_wallet_rpc 30 blackcoin-v4-gui-30 '' getwalletinfo
expect_pass 'node30 unnamed-wallet RPC omits the empty selector entirely' \
  normal_unlock_capture_matches 30 exec blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin getwalletinfo
if ! printf '%s\n' "${NORMAL_UNLOCK_CAPTURE_ARGS[@]}" | grep -q '^-rpcwallet='; then
    ok 'node30 unnamed-wallet argv contains no rpcwallet option'
else
    not_ok 'node30 unnamed-wallet argv contains no rpcwallet option'
fi

named_wallet='named wallet with spaces'
normal_unlock_wallet_rpc 30 blackcoin-v4-gui-30 "$named_wallet" getstakinginfo
expect_pass 'node30 named-wallet RPC retains one exact selector argv element' \
  normal_unlock_capture_matches 30 exec blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin \
    '-rpcwallet=named wallet with spaces' getstakinginfo
if [[ "$(printf '%s\n' "${NORMAL_UNLOCK_CAPTURE_ARGS[@]}" | grep -c '^-rpcwallet=')" -eq 1 ]]; then
    ok 'named-wallet argv contains exactly one rpcwallet option'
else
    not_ok 'named-wallet argv contains exactly one rpcwallet option'
fi

secret_sentinel='hostile-secret-must-never-enter-argv-or-output'
NORMAL_UNLOCK_CAPTURE_READ_STDIN=true
normal_unlock_wallet_rpc_stdin 65 blackcoin-v4-gui-30 '' \
  -stdinwalletpassphrase walletpassphrase 86400 false <<<"$secret_sentinel"
NORMAL_UNLOCK_CAPTURE_READ_STDIN=false
expect_pass 'node30 unnamed-wallet unlock keeps the secret on stdin and omits selector' \
  normal_unlock_capture_matches 65 exec -i blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin \
    -stdinwalletpassphrase walletpassphrase 86400 false
if [[ "$(<"$NORMAL_UNLOCK_CAPTURE_STDIN")" == "$secret_sentinel" ]] &&
   ! printf '%s\n' "${NORMAL_UNLOCK_CAPTURE_ARGS[@]}" | grep -Fq "$secret_sentinel" &&
   ! grep -Fq "$secret_sentinel" "$normal_unlock_helper"; then
    ok 'unlock secret is consumed only through stdin and is absent from helper argv/source'
else
    not_ok 'unlock secret is consumed only through stdin and is absent from helper argv/source'
fi

normal_unlock_wallet_rpc_stdin 65 blackcoin-v4-gui-30 "$named_wallet" \
  -stdinwalletpassphrase walletpassphrase 86400 false <<<"$secret_sentinel"
expect_pass 'node30 named-wallet unlock retains one exact selector argv element' \
  normal_unlock_capture_matches 65 exec -i blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin \
    '-rpcwallet=named wallet with spaces' -stdinwalletpassphrase walletpassphrase 86400 false
if [[ "$(printf '%s\n' "${NORMAL_UNLOCK_CAPTURE_ARGS[@]}" | grep -c '^-rpcwallet=')" -eq 1 ]]; then
    ok 'named-wallet unlock argv contains exactly one rpcwallet option'
else
    not_ok 'named-wallet unlock argv contains exactly one rpcwallet option'
fi

declare -a RENEWAL_CAPTURE_ARGS=()
# shellcheck disable=SC2329 # Invoked indirectly through renewal_wallet_rpc.
renewal_docker() { RENEWAL_CAPTURE_ARGS=("$@"); }
renewal_capture_matches()
{
    [[ "${#RENEWAL_CAPTURE_ARGS[@]}" -eq "$#" ]] || return 1
    [[ "$(printf '%s\n' "${RENEWAL_CAPTURE_ARGS[@]}")" == "$(printf '%s\n' "$@")" ]]
}
renewal_wallet_rpc blackcoin-v4-gui-30 '' getwalletinfo
expect_pass 'supervisor node30 unnamed-wallet census omits the empty selector entirely' \
  renewal_capture_matches exec blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin getwalletinfo
if ! printf '%s\n' "${RENEWAL_CAPTURE_ARGS[@]}" | grep -q '^-rpcwallet='; then
    ok 'supervisor unnamed-wallet argv contains no rpcwallet option'
else
    not_ok 'supervisor unnamed-wallet argv contains no rpcwallet option'
fi
renewal_wallet_rpc blackcoin-v4-gui-30 "$named_wallet" getstakinginfo
expect_pass 'supervisor named-wallet census retains one exact selector argv element' \
  renewal_capture_matches exec blackcoin-v4-gui-30 \
    /usr/local/bin/blackcoin-cli -datadir=/home/blackcoin/.blackcoin \
    '-rpcwallet=named wallet with spaces' getstakinginfo
if [[ "$(printf '%s\n' "${RENEWAL_CAPTURE_ARGS[@]}" | grep -c '^-rpcwallet=')" -eq 1 ]]; then
    ok 'supervisor named-wallet argv contains exactly one rpcwallet option'
else
    not_ok 'supervisor named-wallet argv contains exactly one rpcwallet option'
fi

if ! grep -Eiq '\b(setpowmining|getpowmininginfo|setpowminingaddress|sendrawtransaction|sendtoaddress|sendmany|createshadowpowclaimresolution|commitshadowpowclaimresolution|setpowclaimrecovery|resolveshadowpowclaims|abandontransaction|bumpfee)\b' \
  "$normal_unlock_helper"; then
    ok 'normal-unlock helper contains no PoW, claim-recovery, relay, or payment action'
else
    not_ok 'normal-unlock helper contains no PoW, claim-recovery, relay, or payment action'
fi

global_lock="$tmp/global.lock"
expect_pass 'authority start horizon accepts one complete bounded cycle' \
  renewal_authority_has_runway "$authority" "$test_now" "$MINIMUM_CYCLE_RUNWAY_SECONDS"
expect_fail 'authority start horizon rejects a cycle longer than remaining authority' \
  renewal_authority_has_runway "$authority" "$test_now" 86391
if [[ "$(renewal_remaining_runway_for_node 1)" -gt \
      "$(renewal_remaining_runway_for_node 32)" ]]; then
    ok 'per-helper expiry horizon monotonically decreases through node 32'
else
    not_ok 'per-helper expiry horizon monotonically decreases through node 32'
fi
expect_fail 'per-helper expiry horizon rejects a node outside the fleet' \
  renewal_remaining_runway_for_node 33

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
else
    expect_fail 'unsupported Bash cannot enter the held-lock runtime' renewal_require_supported_bash
    skip 'global lock runtime semantics' 'local host lacks Bash 4+ and util-linux flock'
    skip 'symlink and contention lock hostiles' 'local host lacks Bash 4+ and util-linux flock'
fi

original_acquire_lock=$(declare -f renewal_acquire_lock)
LOCK_ORDER_LOG="$tmp/lock-order.log"
: >"$LOCK_ORDER_LOG"
renewal_acquire_lock() { printf '%s\n' "$1" >>"$LOCK_ORDER_LOG"; }
expect_pass 'shared, global, and all 32 per-node locks are requested together' \
  renewal_acquire_fleet_locks "$global_lock" "$tmp/node-%02d.lock" "$uid"
expected_locks="$tmp/expected-lock-order"
{
    printf '%s\n' "${SHARED_LOCKS[@]}"
    printf '%s\n' "$global_lock"
    for node in $(seq 1 32); do printf "$tmp/node-%02d.lock\n" "$node"; done
} >"$expected_locks"
if cmp -s "$expected_locks" "$LOCK_ORDER_LOG"; then
    ok 'fleet locks follow exact shared then global then node01-through-node32 order'
else
    not_ok 'fleet locks follow exact shared then global then node01-through-node32 order'
fi
eval "$original_acquire_lock"

shape_root="$tmp/initial-install-shape"
shape_supervisor="$shape_root/pos_unlock_renewal_supervisor.sh"
shape_cron="$tmp/initial-install.cron"
mkdir -m 700 "$shape_root"
shape_current_source="$tmp/shape-current-source"
shape_predecessor_source="$tmp/shape-predecessor-source"
printf 'current supervisor bytes\n' >"$shape_current_source"
printf 'predecessor supervisor bytes\n' >"$shape_predecessor_source"
shape_current_sha=$(sha256sum "$shape_current_source" | awk '{print $1}')
shape_predecessor_sha=$(sha256sum "$shape_predecessor_source" | awk '{print $1}')
gid=$(id -g)
shape_is()
{
    local expected=$1
    shift
    [[ "$(renewal_classify_initial_install_shape "$@")" == "$expected" ]]
}
expect_pass 'initial install accepts an exact empty root with no cron' shape_is clean \
  "$shape_root" "$shape_supervisor" "$shape_cron" "$shape_current_sha" \
  "$shape_predecessor_sha" "$uid" "$gid"
cp "$shape_current_source" "$shape_supervisor"; chmod 600 "$shape_supervisor"
expect_pass 'initial install accepts only the exact current 0600 supervisor singleton' \
  shape_is current-singleton "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
cp "$shape_predecessor_source" "$shape_supervisor"; chmod 600 "$shape_supervisor"
expect_pass 'initial install accepts the exact predecessor 0600 supervisor singleton' \
  shape_is predecessor-singleton "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
expect_fail 'initial install rejects a predecessor singleton with the wrong group identity' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$((gid + 1))"
printf 'unknown supervisor bytes\n' >"$shape_supervisor"; chmod 600 "$shape_supervisor"
expect_fail 'initial install rejects an unknown supervisor singleton' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
cp "$shape_predecessor_source" "$shape_supervisor"; chmod 700 "$shape_supervisor"
expect_fail 'initial install rejects an executable-mode predecessor on the Unraid boot contract' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
chmod 600 "$shape_supervisor"; printf 'unexpected\n' >"$shape_root/AUTHORITY.json"; chmod 600 "$shape_root/AUTHORITY.json"
expect_fail 'initial install rejects a supervisor plus any partial companion' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
rm -f -- "$shape_root/AUTHORITY.json"; printf 'cron\n' >"$shape_cron"; chmod 600 "$shape_cron"
expect_fail 'initial install rejects a predecessor singleton with an active cron' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
rm -f -- "$shape_cron" "$shape_supervisor"; ln -s "$shape_predecessor_source" "$shape_supervisor"
expect_fail 'initial install rejects a symlinked predecessor singleton' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
rm -f -- "$shape_supervisor"; mkdir "$shape_root/activation-staging"
expect_fail 'initial install rejects an unexplained partial subdirectory' \
  renewal_classify_initial_install_shape "$shape_root" "$shape_supervisor" "$shape_cron" \
  "$shape_current_sha" "$shape_predecessor_sha" "$uid" "$gid"
rm -rf -- "$shape_root/activation-staging"
if [[ "$HISTORICAL_PARTIAL_SUPERVISOR_SHA256" == \
      d433532d25187f763a67b57f4028a167cb7905b52b2382184ceaf7b27c3ca89d ]]; then
    ok 'initial reconciliation pins the exact observed d433 predecessor singleton'
else
    not_ok 'initial reconciliation pins the exact observed d433 predecessor singleton'
fi

MOCK_BAD_IMAGE_NODE=0
MOCK_BAD_CHAIN_NODE=0
MOCK_IBD_NODE=0
MOCK_ZERO_PEERS_NODE=0
MOCK_TWO_WALLETS_NODE=0
MOCK_CHAIN_DRIFT_NODE=0
MOCK_UNSAFE_STAKING_NODE=0
MOCK_BAD_REGULAR_POW_NODE=0
MOCK_BAD_NODE30_POW=0
mock_node_for_container()
{
    local container=$1 node
    node=$(awk -v container="$container" '!/^#/ && $3 == container {print $1}' "$TOPOLOGY_MAP")
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    printf '%s\n' "$node"
}
renewal_docker()
{
    local command=$1 container=$2 node method tip counter wallet calls=0
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
    if [[ "$node" -eq 30 ]] && printf '%s\n' "$@" | grep -Fxq -- '-rpcwallet='; then
        return 1
    fi
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
            elif [[ "$node" -eq 30 ]]; then
                printf '[""]\n'
            else
                jq -cn --arg wallet "wallet-$padded" '[$wallet]'
            fi
            ;;
        getwalletinfo)
            printf -v padded '%02d' "$node"
            wallet="wallet-$padded"
            [[ "$node" -eq 30 ]] && wallet=''
            jq -cn --arg wallet "$wallet" --argjson unlock "$((test_now + 50000))" '{
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
        getpowmininginfo)
            printf -v padded '%02d' "$node"
            if [[ "$node" -eq 30 ]]; then
                jq -cn --argjson bad "$([[ "$MOCK_BAD_NODE30_POW" -eq 1 ]] && printf true || printf false)" '{
                  enabled:$bad,autostart:$bad,threads:(if $bad then 1 else 0 end),
                  cpu_percent:(if $bad then 1 else 0 end),state:(if $bad then "searching" else "disabled" end),
                  hashrate:(if $bad then 1 else 0 end),payout_address:"",claims_submitted:0,
                  allow_automatic_quantum_key_creation:false}'
            else
                jq -cn --arg payout "pow-payout-$padded" \
                  --argjson bad "$([[ "$node" -eq "$MOCK_BAD_REGULAR_POW_NODE" ]] && printf true || printf false)" '{
                  enabled:($bad|not),autostart:($bad|not),threads:1,cpu_percent:1,
                  state:(if $bad then "disabled" else "claim_quarantined" end),hashrate:0,
                  payout_address:$payout,claims_submitted:0,
                  allow_automatic_quantum_key_creation:false}'
            fi
            ;;
        *) return 1 ;;
    esac
}

reset_mock()
{
    MOCK_BAD_IMAGE_NODE=0 MOCK_BAD_CHAIN_NODE=0 MOCK_IBD_NODE=0 MOCK_ZERO_PEERS_NODE=0
    MOCK_TWO_WALLETS_NODE=0 MOCK_CHAIN_DRIFT_NODE=0 MOCK_UNSAFE_STAKING_NODE=0
    MOCK_BAD_REGULAR_POW_NODE=0 MOCK_BAD_NODE30_POW=0
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
reset_mock; MOCK_BAD_REGULAR_POW_NODE=1
expect_fail 'node preflight rejects disabled ordinary-PoW intent on a regular node' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 1 pre "$uid"
reset_mock; MOCK_BAD_NODE30_POW=1
expect_fail 'node30 preflight rejects any ordinary-PoW enablement' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 30 pre "$uid"
reset_mock
expect_pass 'postflight requires normal unlock beyond twelve hours and active searching PoS' \
  renewal_capture_node "$authority" "$state" "$TOPOLOGY_MAP" 30 post "$uid"
expect_pass 'complete 32-node preflight shares one exact live tip and chainwork' \
  renewal_capture_fleet "$authority" "$state" "$TOPOLOGY_MAP" pre "$uid"

original_capture_fleet_once=$(declare -f renewal_capture_fleet_once)
original_sleep=$(declare -f renewal_sleep)
census_counter="$tmp/census-counter"
census_sleep_log="$tmp/census-sleep.log"
printf '0\n' >"$census_counter"
: >"$census_sleep_log"
# shellcheck disable=SC2329 # Invoked indirectly through renewal_capture_fleet.
renewal_capture_fleet_once()
{
    local count
    read -r count <"$census_counter"
    count=$((count + 1))
    printf '%s\n' "$count" >"$census_counter"
    [[ "$count" -ge 3 ]] || return 1
    printf '[]\n'
}
# shellcheck disable=SC2329 # Invoked indirectly through renewal_capture_fleet.
renewal_sleep() { printf '%s\n' "$1" >>"$census_sleep_log"; }
expect_pass 'stable census retries transient read drift and succeeds on the bounded third sample' \
  renewal_capture_fleet "$authority" "$state" "$TOPOLOGY_MAP" pre "$uid"
if [[ "$(<"$census_counter")" -eq 3 && "$(wc -l <"$census_sleep_log")" -eq 2 ]]; then
    ok 'stable census performs exactly three attempts and two bounded retry delays'
else
    not_ok 'stable census performs exactly three attempts and two bounded retry delays'
fi
printf '0\n' >"$census_counter"
: >"$census_sleep_log"
# shellcheck disable=SC2329 # Invoked indirectly through renewal_capture_fleet.
renewal_capture_fleet_once()
{
    local count
    read -r count <"$census_counter"
    count=$((count + 1))
    printf '%s\n' "$count" >"$census_counter"
    return 1
}
expect_fail 'stable census fails closed after the bounded third unstable sample' \
  renewal_capture_fleet "$authority" "$state" "$TOPOLOGY_MAP" post "$uid"
if [[ "$(<"$census_counter")" -eq 3 && "$(wc -l <"$census_sleep_log")" -eq 2 ]]; then
    ok 'unstable census cannot make an unbounded fourth observation'
else
    not_ok 'unstable census cannot make an unbounded fourth observation'
fi
eval "$original_capture_fleet_once"
eval "$original_sleep"

# shellcheck disable=SC2016 # The single-quoted program is intentionally evaluated by bash -c.
expect_pass 'supervisor RPC callsites use only the six read-only allowlisted methods' bash -c '
  set -euo pipefail
  file=$1
  actual=$(sed -n -E "s/.*renewal_(wallet_)?rpc .* ((get[a-z0-9]+)|listwallets).*/\\2/p" "$file" | sort -u)
  expected=$(printf "%s\n" getblockchaininfo getnetworkinfo getpowmininginfo getstakinginfo getwalletinfo listwallets | sort)
  test "$actual" = "$expected"
' bash "$supervisor"
expect_pass 'supervisor observes ordinary PoW exactly once and has no PoW mutation callsite' bash -c \
  "test \"\$(grep -Ec 'renewal_(wallet_)?rpc .* getpowmininginfo' '$supervisor')\" = 1 && ! grep -Eq 'renewal_(wallet_)?rpc .* setpowmining' '$supervisor'"
expect_pass 'supervisor cannot read a regular-PoW intent manifest' bash -c \
  "! grep -Fq 'pow-wallet-manifests' '$supervisor'"
expect_pass 'supervisor has no chain, config, key, or transaction RPC mutation callsite' bash -c \
  "! grep -Eiq 'renewal_(wallet_)?rpc .* (walletlock|set|send|create|commit|resolve|abandon|import|dump|backup|rescan|reindex|gettransaction|listtransactions)' '$supervisor'"
expect_pass 'supervisor never invokes Docker Compose or container lifecycle mutation' bash -c \
  "! grep -Eiq 'renewal_docker[[:space:]]+(compose|start|stop|restart|update|rm|kill|pause|unpause)' '$supervisor'"
expect_pass 'every Docker inspection and RPC has a TERM/KILL wall-clock bound' bash -c \
  "grep -Fq -- '--kill-after=\"\$DOCKER_CALL_KILL_AFTER_SECONDS\" \"\$DOCKER_CALL_TIMEOUT_SECONDS\"' '$supervisor' && test \"\$(grep -Ec '^[[:space:]]*/usr/bin/docker' '$supervisor')\" = 1"
expect_pass 'supervisor never removes the maintenance inhibitor or historical job receipt' bash -c \
  "! grep -Eq 'rm[^#\n]*(MAINTENANCE_MARKER|HISTORICAL_JOB10_RECEIPT)|mv[^#\n]*(MAINTENANCE_MARKER|HISTORICAL_JOB10_RECEIPT)' '$supervisor'"
expect_pass 'helper execution is isolated and pins the exact snapshot path and node argument' bash -c \
  "test \"\$(grep -Fc '/bin/bash --noprofile --norc \"\$snapshot\" \"\$node\"' '$supervisor')\" = 1 && grep -Fq '/usr/bin/env -i PATH=\"\$PATH\" LC_ALL=C TZ=UTC' '$supervisor'"
expect_pass 'historical at job can be neither inspected nor cancelled by the supervisor' bash -c \
  "! grep -Eq '(^|[[:space:]/])(at|atq|atrm)([[:space:]]|$)' '$supervisor'"

partial_root="$tmp/partial-receipts"
mkdir -m 700 "$partial_root"
authority_sha_for_receipt=$(sha256sum "$authority" | awk '{print $1}')
partial_started=$((test_now - 100))
expect_pass 'PARTIAL receipt is written durably with an exact no-clobber hash sidecar' \
  renewal_publish_partial_receipt "$partial_root" "$uid" "$authority" \
    "$authority_sha_for_receipt" "$partial_started" '2026-08-13T21:00:00Z' \
    '[{"node":1}]' '[1,2]' '[1]' helper_failed null
partial_file="$partial_root/renewal-${partial_started}-0123456789abcdef0123456789abcdef-PARTIAL.json"
# shellcheck disable=SC2016 # The single-quoted program is intentionally evaluated by bash -c.
expect_pass 'PARTIAL receipt reports UNSEALED and forbids helper reinvocation' bash -c '
  set -euo pipefail
  receipt=$1
  jq -e ".status == \"PARTIAL\" and .mutation_outcome == \"UNSEALED\" and
    .failure_reason == \"helper_failed\" and .helper_attempted_nodes == [1,2] and
    .helper_succeeded_nodes == [1] and .helper_reinvocation_authorized == false and
    .regular_pow_mutating_rpc_invoked == false" "$receipt" >/dev/null
  actual=$(sha256sum "$receipt")
  actual=${actual%% *}
  test "$actual" = "$(<"$receipt.sha256")"
' bash "$partial_file"
expect_fail 'PARTIAL receipt publisher never overwrites an existing cycle receipt' \
  renewal_publish_partial_receipt "$partial_root" "$uid" "$authority" \
    "$authority_sha_for_receipt" "$partial_started" '2026-08-13T21:00:00Z' \
    '[{"node":1}]' '[1,2]' '[1]' helper_failed null

REAL_PARTIAL_PUBLISHER=$(declare -f renewal_publish_partial_receipt)
ORCHESTRATION_LOG="$tmp/orchestration.log"
ORCHESTRATION_FAIL_PREFLIGHT=0
ORCHESTRATION_FAIL_POSTFLIGHT=0
ORCHESTRATION_FAIL_HELPER_NODE=0
ORCHESTRATION_FAIL_RUNWAY_CALL=0
ORCHESTRATION_RUNWAY_CALLS=0
ORCHESTRATION_FAIL_PASS_PUBLISH=0
ORCHESTRATION_MARKER_LIMIT=0
ORCHESTRATION_MARKER_CALLS=0
renewal_acquire_fleet_locks() { printf '%s\n' locks >>"$ORCHESTRATION_LOG"; }
renewal_authority_has_runway()
{
    ORCHESTRATION_RUNWAY_CALLS=$((ORCHESTRATION_RUNWAY_CALLS + 1))
    printf 'runway-%02d-%s\n' "$ORCHESTRATION_RUNWAY_CALLS" "$3" >>"$ORCHESTRATION_LOG"
    [[ "$ORCHESTRATION_FAIL_RUNWAY_CALL" -eq 0 ||
       "$ORCHESTRATION_RUNWAY_CALLS" -lt "$ORCHESTRATION_FAIL_RUNWAY_CALL" ]]
}
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
    [[ "$ORCHESTRATION_FAIL_POSTFLIGHT" -eq 0 || "$4" != post ]] || return 1
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
    [[ "$ORCHESTRATION_FAIL_HELPER_NODE" -eq 0 || "$2" -ne "$ORCHESTRATION_FAIL_HELPER_NODE" ]]
}
# shellcheck disable=SC2329 # Invoked indirectly by renewal_execute_cycle.
renewal_sleep() { [[ "$1" -eq 60 ]]; printf 'sleep-%s\n' "$1" >>"$ORCHESTRATION_LOG"; }
renewal_publish_receipt()
{
    printf '%s\n' publish >>"$ORCHESTRATION_LOG"
    [[ "$ORCHESTRATION_FAIL_PASS_PUBLISH" -eq 0 ]]
}
renewal_publish_partial_receipt()
{
    printf 'partial-%s attempted=%s succeeded=%s post=%s\n' \
      "${10}" "$8" "$9" "${11:-null}" >>"$ORCHESTRATION_LOG"
}
renewal_sha256_file()
{
    if [[ "$1" == "$authority" ]]; then sha256sum "$authority" | awk '{print $1}'
    else command sha256sum "$1" | awk '{print $1}'; fi
}
authority_sha=$(renewal_sha256_file "$authority")
: >"$ORCHESTRATION_LOG"
ORCHESTRATION_RUNWAY_CALLS=0
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
if [[ "$(grep -c '^runway-' "$ORCHESTRATION_LOG")" -eq 36 ]]; then
    ok 'cycle rechecks authority at start, every helper boundary, postflight, and final publish'
else
    not_ok 'cycle rechecks authority at start, every helper boundary, postflight, and final publish'
fi
if ! grep -q '^partial-' "$ORCHESTRATION_LOG"; then
    ok 'fully sealed cycle publishes no PARTIAL evidence'
else
    not_ok 'fully sealed cycle publishes no PARTIAL evidence'
fi

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_FAIL_PREFLIGHT=1
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_RUNWAY_CALLS=0
expect_fail 'failed all-node preflight prevents every helper invocation' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if ! grep -q '^invoke-' "$ORCHESTRATION_LOG"; then ok 'preflight failure invoked zero helpers';
else not_ok 'preflight failure invoked zero helpers'; fi
ORCHESTRATION_FAIL_PREFLIGHT=0

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_RUNWAY_CALLS=0
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
if grep -Eq '^partial-marker_changed attempted=\[1,2\] succeeded=\[1,2\] post=null$' \
  "$ORCHESTRATION_LOG"; then
    ok 'marker drift after mutation persists exact attempted/succeeded PARTIAL evidence'
else
    not_ok 'marker drift after mutation persists exact attempted/succeeded PARTIAL evidence'
fi
ORCHESTRATION_MARKER_LIMIT=0

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_RUNWAY_CALLS=0
ORCHESTRATION_FAIL_HELPER_NODE=3
expect_fail 'helper failure stops the fleet and persists non-PASS partial evidence' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if grep -Eq '^partial-helper_failed attempted=\[1,2,3\] succeeded=\[1,2\] post=null$' \
  "$ORCHESTRATION_LOG" && [[ "$(grep -c '^invoke-' "$ORCHESTRATION_LOG")" -eq 3 ]]; then
    ok 'helper failure records exact boundary and never invokes a later helper'
else
    not_ok 'helper failure records exact boundary and never invokes a later helper'
fi
ORCHESTRATION_FAIL_HELPER_NODE=0

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_RUNWAY_CALLS=0
ORCHESTRATION_FAIL_RUNWAY_CALL=8
expect_fail 'authority expiry horizon halts before the next helper and persists PARTIAL evidence' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if grep -Eq '^partial-authority_runway_exhausted attempted=\[1,2,3,4,5\] succeeded=\[1,2,3,4,5\] post=null$' \
  "$ORCHESTRATION_LOG" && [[ "$(grep -c '^invoke-' "$ORCHESTRATION_LOG")" -eq 5 ]]; then
    ok 'expiry recheck prevents helper six and records the exact five-node prefix'
else
    not_ok 'expiry recheck prevents helper six and records the exact five-node prefix'
fi
ORCHESTRATION_FAIL_RUNWAY_CALL=0

: >"$ORCHESTRATION_LOG"
ORCHESTRATION_MARKER_CALLS=0
ORCHESTRATION_RUNWAY_CALLS=0
ORCHESTRATION_FAIL_POSTFLIGHT=1
expect_fail 'exhausted stable postflight cannot publish PASS or reinvoke helpers' \
  renewal_execute_cycle "$authority" "$authority_sha" "$state" "$TOPOLOGY_MAP" \
    "$helper_fixture" "$tmp/marker" "$tmp/receipts" "$tmp/global" \
    "$tmp/node-%02d.lock" "$uid" "$tmp"
if grep -q '^partial-postflight_unstable ' "$ORCHESTRATION_LOG" &&
  ! grep -q '^publish$' "$ORCHESTRATION_LOG" &&
  [[ "$(grep -c '^invoke-' "$ORCHESTRATION_LOG")" -eq 32 ]]; then
    ok 'postflight instability produces PARTIAL only and no second helper pass'
else
    not_ok 'postflight instability produces PARTIAL only and no second helper pass'
fi
ORCHESTRATION_FAIL_POSTFLIGHT=0

: >"$ORCHESTRATION_LOG"
signal_partial_contract_is_safe()
{
    local status
    set +e
    (
        renewal_arm_partial_context "$tmp/receipts" "$uid" "$authority" "$authority_sha" \
          "$test_now" '2026-08-13T21:00:00Z' '[{"node":1}]' '[1,2]' '[1]'
        renewal_handle_signal 143 signal_term
    )
    status=$?
    set -e
    [[ "$status" -eq 143 ]]
}
expect_pass 'TERM after a helper boundary exits 143 only after persisting PARTIAL evidence' \
  signal_partial_contract_is_safe
if grep -Eq '^partial-signal_term attempted=\[1,2\] succeeded=\[1\] post=null$' \
  "$ORCHESTRATION_LOG"; then
    ok 'signal PARTIAL evidence preserves exact attempted and succeeded prefixes'
else
    not_ok 'signal PARTIAL evidence preserves exact attempted and succeeded prefixes'
fi

double_signal_root="$tmp/double-signal-receipts"
mkdir -m 700 "$double_signal_root"
double_signal_started=$((test_now - 200))
double_signal_contract_is_safe()
{
    local signal_status
    set +e
    (
        eval "$(printf '%s\n' "$REAL_PARTIAL_PUBLISHER" |
          sed '1s/^renewal_publish_partial_receipt/renewal_real_publish_partial_receipt/')"
        # shellcheck disable=SC2329 # Invoked indirectly by renewal_handle_signal.
        renewal_publish_partial_receipt()
        {
            local current_pid
            current_pid=$(/bin/sh -c 'printf "%s\n" "$PPID"')
            kill -TERM "$current_pid"
            renewal_real_publish_partial_receipt "$@"
        }
        renewal_arm_partial_context "$double_signal_root" "$uid" "$authority" "$authority_sha" \
          "$double_signal_started" '2026-08-13T21:00:00Z' '[{"node":1}]' '[1,2]' '[1]'
        renewal_handle_signal 143 signal_term
    )
    signal_status=$?
    set -e
    [[ "$signal_status" -eq 143 ]]
}
expect_pass 'a repeated TERM is ignored until the signal PARTIAL is durable and cleanup completes' \
  double_signal_contract_is_safe
double_signal_file="$double_signal_root/renewal-${double_signal_started}-0123456789abcdef0123456789abcdef-PARTIAL.json"
if [[ -f "$double_signal_file" && -f "$double_signal_file.sha256" &&
      "$(sha256sum "$double_signal_file" | awk '{print $1}')" == "$(<"$double_signal_file.sha256")" ]]; then
    ok 'repeated TERM still leaves the complete JSON-plus-sidecar terminal evidence pair'
else
    not_ok 'repeated TERM still leaves the complete JSON-plus-sidecar terminal evidence pair'
fi

: >"$ORCHESTRATION_LOG"
abnormal_exit_partial_contract_is_safe()
{
    local status
    set +e
    (
        trap renewal_handle_exit EXIT
        renewal_arm_partial_context "$tmp/receipts" "$uid" "$authority" "$authority_sha" \
          "$test_now" '2026-08-13T21:00:00Z' '[{"node":1}]' '[1]' '[]'
        exit 17
    )
    status=$?
    set -e
    [[ "$status" -eq 17 ]]
}
expect_pass 'unexpected nonzero exit after a helper attempt persists PARTIAL evidence' \
  abnormal_exit_partial_contract_is_safe
if grep -Eq '^partial-abnormal_exit attempted=\[1\] succeeded=\[\] post=null$' \
  "$ORCHESTRATION_LOG"; then
    ok 'unexpected-exit PARTIAL evidence preserves the exact in-flight node boundary'
else
    not_ok 'unexpected-exit PARTIAL evidence preserves the exact in-flight node boundary'
fi

previous_sha=$(command sha256sum "$authority" | awk '{print $1}')
rotated_authority="$tmp/rotated-authority.json"
jq --arg previous_sha "$previous_sha" '
  .authority_generation=2 |
  .authority_nonce="fedcba9876543210fedcba9876543210" |
  .supersedes_authority_sha256=$previous_sha |
  .issued_at_epoch += 1 | .valid_from_epoch += 1 | .valid_until_epoch += 1
' "$authority" >"$rotated_authority"
chmod 600 "$rotated_authority"
rotated_sha=$(command sha256sum "$rotated_authority" | awk '{print $1}')
expect_pass 'authority rotation requires an exact immutable generation-two successor chain' \
  renewal_authority_rotation_is_valid "$rotated_authority" "$rotated_sha" "$authority" "$previous_sha"
bad_rotation="$tmp/bad-rotation.json"
jq '.authority_generation=3' "$rotated_authority" >"$bad_rotation"
chmod 600 "$bad_rotation"
bad_rotation_sha=$(command sha256sum "$bad_rotation" | awk '{print $1}')
expect_fail 'authority rotation rejects a skipped generation' \
  renewal_authority_rotation_is_valid "$bad_rotation" "$bad_rotation_sha" "$authority" "$previous_sha"
jq '.minimum_peers=2' "$rotated_authority" >"$bad_rotation"
chmod 600 "$bad_rotation"
bad_rotation_sha=$(command sha256sum "$bad_rotation" | awk '{print $1}')
expect_fail 'authority rotation cannot broaden or alter operational policy' \
  renewal_authority_rotation_is_valid "$bad_rotation" "$bad_rotation_sha" "$authority" "$previous_sha"

install_receipt="$tmp/install-receipt.json"
renewal_make_install_receipt "$authority" "$previous_sha" \
  "$(command sha256sum "$supervisor" | awk '{print $1}')" \
  "$(command sha256sum "$JOB10_CONTRACT" | awk '{print $1}')" \
  "$(command sha256sum "$TOPOLOGY_MAP" | awk '{print $1}')" \
  "$(command sha256sum "$PACKAGE_MANIFEST" | awk '{print $1}')" \
  "$test_now" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$install_receipt"
chmod 600 "$install_receipt"
expect_pass 'install receipt binds active authority, cron, package bytes, and shared locks' \
  renewal_install_receipt_is_valid "$install_receipt" "$authority" "$previous_sha" \
    "$supervisor" "$JOB10_CONTRACT" "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" "$uid"
mutated_receipt="$tmp/mutated-install-receipt.json"
jq '.receipt_committed_before_cron_activation=false' "$install_receipt" >"$mutated_receipt"
chmod 600 "$mutated_receipt"
expect_fail 'install receipt rejects cron activation without prior durable receipt commitment' \
  renewal_install_receipt_is_valid "$mutated_receipt" "$authority" "$previous_sha" \
    "$supervisor" "$JOB10_CONTRACT" "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" "$uid"

recovery_old_authority="$tmp/recovery-old-authority.json"
recovery_supervisor_sha=$(command sha256sum "$supervisor" | awk '{print $1}')
recovery_contract_sha=$(command sha256sum "$JOB10_CONTRACT" | awk '{print $1}')
recovery_topology_sha=$(command sha256sum "$TOPOLOGY_MAP" | awk '{print $1}')
recovery_manifest_sha=$(command sha256sum "$PACKAGE_MANIFEST" | awk '{print $1}')
make_authority "$recovery_old_authority" "$manifest_map" "$recovery_supervisor_sha" \
  "$recovery_manifest_sha" "$recovery_topology_sha" "$recovery_contract_sha"
recovery_old_sha=$(command sha256sum "$recovery_old_authority" | awk '{print $1}')
recovery_new_authority="$tmp/recovery-new-authority.json"
jq --arg old_sha "$recovery_old_sha" '
  .authority_generation=2 |
  .authority_nonce="11111111111111111111111111111111" |
  .supersedes_authority_sha256=$old_sha |
  .issued_at_epoch += 1 | .valid_from_epoch += 1 | .valid_until_epoch += 1
' "$recovery_old_authority" >"$recovery_new_authority"
chmod 600 "$recovery_new_authority"
recovery_new_sha=$(command sha256sum "$recovery_new_authority" | awk '{print $1}')
recovery_old_receipt="$tmp/recovery-old-receipt.json"
renewal_make_install_receipt "$recovery_old_authority" "$recovery_old_sha" \
  "$recovery_supervisor_sha" "$recovery_contract_sha" "$recovery_topology_sha" \
  "$recovery_manifest_sha" "$test_now" '2026-08-13T21:00:00Z' >"$recovery_old_receipt"
chmod 600 "$recovery_old_receipt"
recovery_new_receipt="$tmp/recovery-new-receipt.json"
renewal_make_install_receipt "$recovery_new_authority" "$recovery_new_sha" \
  "$recovery_supervisor_sha" "$recovery_contract_sha" "$recovery_topology_sha" \
  "$recovery_manifest_sha" "$((test_now + 1))" '2026-08-13T21:00:01Z' >"$recovery_new_receipt"
chmod 600 "$recovery_new_receipt"

recovery_install="$tmp/recovery-install"
recovery_staging="$recovery_install/activation-staging"
recovery_history="$recovery_install/authority-history"
recovery_cron="$tmp/recovery-cron"
recovery_stage="$recovery_staging/$recovery_new_sha"
mkdir -m 700 "$recovery_install" "$recovery_staging" "$recovery_history" "$recovery_stage"
cp "$recovery_new_authority" "$recovery_stage/AUTHORITY.json"
printf '%s\n' "$recovery_new_sha" >"$recovery_stage/AUTHORITY.sha256"
cp "$recovery_new_receipt" "$recovery_stage/INSTALL-RECEIPT.json"
renewal_cron_body >"$recovery_stage/CRON"
chmod 600 "$recovery_stage"/*
recovery_old_nonce=$(jq -er '.authority_nonce' "$recovery_old_authority")
recovery_old_stem="generation-1-${recovery_old_nonce}-${recovery_old_sha}"
cp "$recovery_old_authority" "$recovery_history/$recovery_old_stem.json"
printf '%s\n' "$recovery_old_sha" >"$recovery_history/$recovery_old_stem.sha256"
cp "$recovery_old_receipt" "$recovery_history/$recovery_old_stem-INSTALL-RECEIPT.json"
chmod 600 "$recovery_history"/*
recovery_journal="$recovery_install/ACTIVATION-JOURNAL.json"

write_recovery_journal()
{
    local predecessor=$1 predecessor_sha=$2 predecessor_stem=$3
    renewal_make_activation_journal "$recovery_install" "$recovery_staging" \
      "$recovery_history" "$recovery_cron" "$recovery_new_sha" "$recovery_stage" \
      "$predecessor" "$predecessor_sha" "$predecessor_stem" "$test_now" >"$recovery_journal"
    chmod 600 "$recovery_journal"
}

write_recovery_journal true "$recovery_old_sha" "$recovery_old_stem"
expect_pass 'activation journal binds the exact staged successor and archived predecessor' \
  renewal_activation_journal_is_valid "$recovery_journal" "$recovery_install" \
    "$recovery_staging" "$recovery_history" "$recovery_cron" "$uid"
bad_recovery_journal="$tmp/bad-recovery-journal.json"
jq '.recovery_policy="finish-unconditionally"' "$recovery_journal" >"$bad_recovery_journal"
chmod 600 "$bad_recovery_journal"
expect_fail 'activation journal rejects a broadened crash-recovery policy' \
  renewal_activation_journal_is_valid "$bad_recovery_journal" "$recovery_install" \
    "$recovery_staging" "$recovery_history" "$recovery_cron" "$uid"

ORIGINAL_INSTALL_TEXT_REPLACE=$(declare -f renewal_install_text_replace)
ORIGINAL_INSTALL_TEXT_NOCLOBBER=$(declare -f renewal_install_text_noclobber)
renewal_install_text_replace()
{
    local destination=$1 mode=$2 expected_sha=$3 temporary
    temporary=$(mktemp "$tmp/.local-replace.XXXXXX") || return 1
    cat >"$temporary" || return 1
    chmod "$mode" "$temporary" || return 1
    [[ "$(command sha256sum "$temporary" | awk '{print $1}')" == "$expected_sha" ]] || return 1
    mv -f -- "$temporary" "$destination"
}
renewal_install_text_noclobber()
{
    local destination=$1 mode=$2 expected_sha=$3 temporary
    if [[ -e "$destination" || -L "$destination" ]]; then
        renewal_secure_file_for_uid "$destination" "$mode" "$uid" &&
          [[ "$(command sha256sum "$destination" | awk '{print $1}')" == "$expected_sha" ]]
        return
    fi
    temporary=$(mktemp "$tmp/.local-noclobber.XXXXXX") || return 1
    cat >"$temporary" || return 1
    chmod "$mode" "$temporary" || return 1
    [[ "$(command sha256sum "$temporary" | awk '{print $1}')" == "$expected_sha" ]] || return 1
    mv -n -- "$temporary" "$destination"
}

prepare_rotation_fault()
{
    local boundary=$1
    rm -f -- "$recovery_install/AUTHORITY.json" "$recovery_install/AUTHORITY.sha256" \
      "$recovery_install/INSTALL-RECEIPT.json" "$recovery_cron" "$recovery_journal"
    case "$boundary" in
        before-cron-removal)
            cp "$recovery_old_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_old_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_old_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            renewal_cron_body >"$recovery_cron"
            ;;
        after-cron-removal)
            cp "$recovery_old_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_old_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_old_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            ;;
        after-authority-replace)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_old_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_old_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            ;;
        after-sidecar-replace)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_old_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            ;;
        after-receipt-replace)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_new_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            ;;
        after-cron-activation)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_new_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            renewal_cron_body >"$recovery_cron"
            ;;
        *) return 1 ;;
    esac
    chmod 600 "$recovery_install/AUTHORITY.json" "$recovery_install/AUTHORITY.sha256" \
      "$recovery_install/INSTALL-RECEIPT.json"
    [[ ! -e "$recovery_cron" ]] || chmod 600 "$recovery_cron"
    write_recovery_journal true "$recovery_old_sha" "$recovery_old_stem"
}

recover_rotation_boundary()
{
    local boundary=$1
    prepare_rotation_fault "$boundary" || return 1
    renewal_recover_activation_journal "$recovery_journal" "$recovery_install" \
      "$recovery_staging" "$recovery_history" "$recovery_cron" "$supervisor" \
      "$JOB10_CONTRACT" "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" "$uid" || return 1
    [[ ! -e "$recovery_journal" && ! -L "$recovery_journal" &&
       "$(command sha256sum "$recovery_install/AUTHORITY.json" | awk '{print $1}')" == "$recovery_old_sha" &&
       "$(<"$recovery_install/AUTHORITY.sha256")" == "$recovery_old_sha" &&
       "$(command sha256sum "$recovery_install/INSTALL-RECEIPT.json" | awk '{print $1}')" == \
         "$(command sha256sum "$recovery_old_receipt" | awk '{print $1}')" &&
       "$(command sha256sum "$recovery_cron" | awk '{print $1}')" == "$(renewal_cron_sha256)" ]]
}

for recovery_boundary in before-cron-removal after-cron-removal after-authority-replace \
  after-sidecar-replace after-receipt-replace after-cron-activation; do
    expect_pass "rotation recovery restores the receipt-bound predecessor from $recovery_boundary" \
      recover_rotation_boundary "$recovery_boundary"
done

prepare_initial_fault()
{
    local boundary=$1 zero_sha
    zero_sha=$(printf '0%.0s' {1..64})
    rm -f -- "$recovery_install/AUTHORITY.json" "$recovery_install/AUTHORITY.sha256" \
      "$recovery_install/INSTALL-RECEIPT.json" "$recovery_cron" "$recovery_journal"
    case "$boundary" in
        journal-only) ;;
        after-authority-replace) cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json" ;;
        after-sidecar-replace)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            ;;
        after-receipt-replace)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_new_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            ;;
        after-cron-activation)
            cp "$recovery_new_authority" "$recovery_install/AUTHORITY.json"
            printf '%s\n' "$recovery_new_sha" >"$recovery_install/AUTHORITY.sha256"
            cp "$recovery_new_receipt" "$recovery_install/INSTALL-RECEIPT.json"
            renewal_cron_body >"$recovery_cron"
            ;;
        *) return 1 ;;
    esac
    find "$recovery_install" -maxdepth 1 -type f -exec chmod 600 {} +
    [[ ! -e "$recovery_cron" ]] || chmod 600 "$recovery_cron"
    write_recovery_journal false "$zero_sha" ''
}

recover_initial_boundary()
{
    local boundary=$1
    prepare_initial_fault "$boundary" || return 1
    renewal_recover_activation_journal "$recovery_journal" "$recovery_install" \
      "$recovery_staging" "$recovery_history" "$recovery_cron" "$supervisor" \
      "$JOB10_CONTRACT" "$TOPOLOGY_MAP" "$PACKAGE_MANIFEST" "$uid" || return 1
    [[ ! -e "$recovery_journal" && ! -e "$recovery_install/AUTHORITY.json" &&
       ! -e "$recovery_install/AUTHORITY.sha256" &&
       ! -e "$recovery_install/INSTALL-RECEIPT.json" && ! -e "$recovery_cron" ]]
}

for recovery_boundary in journal-only after-authority-replace after-sidecar-replace \
  after-receipt-replace after-cron-activation; do
    expect_pass "initial-install recovery returns to an inert empty activation from $recovery_boundary" \
      recover_initial_boundary "$recovery_boundary"
done

eval "$ORIGINAL_INSTALL_TEXT_REPLACE"
eval "$ORIGINAL_INSTALL_TEXT_NOCLOBBER"

# shellcheck disable=SC2016 # Static ordering protects install/runtime activation semantics.
expect_pass 'installer commits and validates the install receipt before cron activation' bash -c '
  set -euo pipefail
  body=$(sed -n "/^renewal_install()$/,/^renewal_audit_or_plan()$/p" "$1")
  journal=$(grep -n -m1 "INSTALLED_ACTIVATION_JOURNAL.*600.*journal_sha" <<<"$body" | cut -d: -f1)
  validate_journal=$(grep -n -m1 "renewal_activation_journal_is_valid" <<<"$body" | cut -d: -f1)
  deactivate=$(grep -n -m1 "renewal_deactivate_cron" <<<"$body" | cut -d: -f1)
  receipt=$(grep -n -m1 "renewal_install_text_replace.*INSTALLED_INSTALL_RECEIPT\|INSTALLED_INSTALL_RECEIPT.*600.*receipt_sha" <<<"$body" | cut -d: -f1)
  validate_receipt=$(grep -n "renewal_install_receipt_is_valid.*INSTALLED_INSTALL_RECEIPT" <<<"$body" | tail -1 | cut -d: -f1)
  cron=$(grep -n "renewal_install_text_noclobber.*CRON_PATH\|renewal_cron_body | renewal_install_text_noclobber.*CRON_PATH" <<<"$body" | tail -1 | cut -d: -f1)
  commit=$(grep -n -m1 "renewal_remove_activation_journal" <<<"$body" | cut -d: -f1)
  test "$journal" -lt "$validate_journal" && test "$validate_journal" -lt "$deactivate" &&
    test "$deactivate" -lt "$receipt" && test "$receipt" -lt "$validate_receipt" &&
    test "$validate_receipt" -lt "$cron" && test "$cron" -lt "$commit"
' bash "$supervisor"
# shellcheck disable=SC2016 # Static ordering and exact modes bind the Unraid resume path.
expect_pass 'installer classifies partial initial state before replacing exact 0600 supervisor bytes' bash -c '
  set -euo pipefail
  body=$(sed -n "/^renewal_install()$/,/^renewal_audit_or_plan()$/p" "$1")
  classify=$(grep -n -m1 "renewal_classify_initial_install_shape" <<<"$body" | cut -d: -f1)
  replace=$(grep -n -m1 "renewal_install_text_replace.*INSTALLED_SUPERVISOR" <<<"$body" | cut -d: -f1)
  exact=$(grep -n -m1 "renewal_install_exact_file.*INSTALLED_SUPERVISOR.*600" <<<"$body" | cut -d: -f1)
  test -n "$classify" && test -n "$replace" && test -n "$exact" &&
    test "$classify" -lt "$replace" && test "$classify" -lt "$exact" &&
    ! grep -q "INSTALLED_SUPERVISOR.*700" <<<"$body"
' bash "$supervisor"
# shellcheck disable=SC2016 # Static ordering protects runtime activation semantics.
expect_pass 'runtime acquires canonical locks and validates receipt plus cron before any cycle' bash -c '
  set -euo pipefail
  body=$(sed -n "/^renewal_run_installed()$/,/^renewal_usage()$/p" "$1")
  locks=$(grep -n -m1 "renewal_acquire_fleet_locks" <<<"$body" | cut -d: -f1)
  receipt=$(grep -n -m1 "renewal_install_receipt_is_valid" <<<"$body" | cut -d: -f1)
  cron=$(grep -n -m1 "renewal_cron_activation_is_valid" <<<"$body" | cut -d: -f1)
  execute=$(grep -n -m1 "renewal_execute_cycle" <<<"$body" | cut -d: -f1)
  test "$locks" -lt "$receipt" && test "$receipt" -lt "$cron" && test "$cron" -lt "$execute"
  grep -Eq "PER_NODE_LOCK_PATTERN.*0 /run true|0 /run true" <<<"$body"
' bash "$supervisor"
# shellcheck disable=SC2016 # Cron invokes the nonexecutable root-only supervisor through Bash.
expect_pass 'runtime validates supervisor mode 0600 and cron invokes it through exact Bash' bash -c '
  set -euo pipefail
  file=$1
  grep -Fq "renewal_secure_file_for_owner \"\$INSTALLED_SUPERVISOR\" 600 0 0" "$file"
  grep -Fq "/bin/bash \$INSTALLED_SUPERVISOR run" "$file"
  ! grep -Fq "renewal_secure_file_for_uid \"\$INSTALLED_SUPERVISOR\" 700 0" "$file"
' bash "$supervisor"

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
