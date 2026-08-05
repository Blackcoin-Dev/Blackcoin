#!/usr/bin/env bash

# Targeted recovery for a clean (exit-code 0) guard stop. Docker's on-failure
# policy intentionally does not restart that generation. This script starts
# exactly one stopped node only after independently re-proving its VPN endpoint,
# public-IP uniqueness, immutable topology, persistent endpoint config, role,
# mounts, and image policy. It never restarts or reconfigures a VPN.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
bootstrap_package_integrity()
{
    local owner mode
    [[ -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" &&
       -f "$PACKAGE_ROOT/SHA256SUMS" && ! -L "$PACKAGE_ROOT/SHA256SUMS" &&
       "$(realpath -e -- "$PACKAGE_ROOT/SHA256SUMS")" == "$PACKAGE_ROOT/SHA256SUMS" &&
       "$(stat -c '%u:%g:%a' "$PACKAGE_ROOT/SHA256SUMS")" == 0:0:600 ]] || return 1
    owner=$(stat -c '%u:%g' "$PACKAGE_ROOT") || return 1
    mode=$(stat -c '%a' "$PACKAGE_ROOT") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
       -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    cmp -s \
        <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
        }' "$PACKAGE_ROOT/SHA256SUMS" | sort) || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}
bootstrap_package_integrity || {
    printf '%s\n' 'FATAL: recovery package failed bootstrap integrity verification' >&2
    exit 1
}
unset -f bootstrap_package_integrity
# shellcheck source=lib/live_checks.sh
source "$PACKAGE_ROOT/lib/live_checks.sh"

readonly ACTION=${1:-plan}
readonly NODE=${2:-}
valid_node "$NODE" || {
    printf 'usage: %s plan|preflight|apply NODE(1-32)\n' "$0" >&2
    exit 64
}
PADDED=$(node_padded "$NODE")
CONTAINER=$(container_for "$NODE")
VPN=$(vpn_for "$NODE")
CONF="$(host_datadir_for "$NODE")/blackcoin.conf"
readonly PADDED CONTAINER VPN CONF
readonly CONFIRM_VALUE="node-$PADDED-clean-stop-recovery"
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly POW_START_HELPER="$STATE_DIR/blackcoin_pow_start_only.sh"
readonly NORMAL_UNLOCK_HELPER_SHA256=acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1
readonly POW_START_HELPER_SHA256=21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea
STARTED=0
FREE_CLAIM_LOCK_HELD=0
RECOVERY_FEE_BASELINE=

capture_other_generations()
{
    local output="$1" node container_state vpn_state
    : > "$output"
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "$node" -eq "$NODE" ]] && continue
        container_state=$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}|{{.State.Status}}' \
            "$(container_for "$node")") || return 1
        vpn_state=$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}|{{.State.Status}}' \
            "$(vpn_for "$node")") || return 1
        printf '%02d|%s|%s\n' "$node" "$container_state" "$vpn_state" >> "$output"
    done
}

run_pinned_helper()
{
    local path="$1" expected="$2" actual
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    /bin/bash "$path" "$NODE"
}

capture_recovery_fee_baseline()
{
    local recovery network version deadline
    deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        network=$(rpc_for "$NODE" getnetworkinfo 2>/dev/null || true)
        version=$(jq -er '.version | select(. == 300103 or . == 300104)' \
            <<< "$network" 2>/dev/null || true)
        if [[ "$version" == 300103 ]]; then
            RECOVERY_FEE_BASELINE=
            return 0
        elif [[ "$version" == 300104 ]]; then
            recovery=$(wallet_rpc_for "$NODE" getpowclaimrecoveryinfo 2>/dev/null || true)
            RECOVERY_FEE_BASELINE=$(jq -er \
                '.confirmed_resolution_fees | select(type == "number")' \
                <<< "$recovery" 2>/dev/null || true)
            [[ -n "$RECOVERY_FEE_BASELINE" ]] && return 0
        fi
        sleep 2
    done
    return 1
}

target_proof_unique()
{
    local target ip node other other_ip
    target=$(read_vpn_proof "$NODE") || return 1
    IFS='|' read -r ip _ <<< "$target"
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "$node" -eq "$NODE" ]] && continue
        other=$(read_vpn_proof "$node") || return 1
        IFS='|' read -r other_ip _ <<< "$other"
        [[ "$other_ip" != "$ip" ]] || return 1
    done
}

verify_stopped_contract()
{
    local class expected_ref expected_id vpn_id inspect proof ip port
    class=$(jq -er --arg node "$PADDED" '.nodes[$node]' "$IMAGE_POLICY") || return 1
    expected_ref=$(jq -er --arg class "$class" '.images[$class].config_image' "$IMAGE_POLICY") || return 1
    expected_id=$(jq -er --arg class "$class" '.images[$class].image_id' "$IMAGE_POLICY") || return 1
    vpn_id=$(docker inspect -f '{{.Id}}' "$VPN") || return 1
    inspect=$(docker inspect "$CONTAINER") || return 1
    jq -e --arg ref "$expected_ref" --arg id "$expected_id" \
        --arg mode "container:$vpn_id" --arg data "$(host_datadir_for "$NODE")" \
        --arg blocks "$(host_blocks_for "$NODE")" '
        length == 1 and .[0].State.Running == false and
        .[0].State.ExitCode == 0 and .[0].State.OOMKilled == false and
        .[0].State.Error == "" and
        .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].HostConfig.NetworkMode == $mode and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
            .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
            .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect" || return 1
    docker inspect "$VPN" | jq -e --arg image "$EXPECTED_VPN_IMAGE_ID" '
        length == 1 and .[0].State.Running == true and
        .[0].State.Health.Status == "healthy" and .[0].Image == $image and
        .[0].HostConfig.RestartPolicy.Name == "unless-stopped" and
        .[0].HostConfig.NetworkMode == "bridge"
    ' >/dev/null || return 1
    target_proof_unique || return 1
    proof=$(read_vpn_proof "$NODE") || return 1
    IFS='|' read -r ip port <<< "$proof"
    [[ -f "$CONF" && ! -L "$CONF" && "$(stat -c '%u:%g:%a' "$CONF")" == 1000:1000:600 ]] || return 1
    for required in "externalip=$ip:$port" "port=$port" "bind=0.0.0.0:$port" \
        'blocksdir=/home/blackcoin/blocks_storage' 'networkactive=1' 'staking=1' \
        'autostartstaking=0' 'powmining=0' 'qqautoshadowsignal=0'; do
        [[ "$(grep -Fxc -- "$required" "$CONF")" -eq 1 ]] || return 1
    done
    ! grep -Eiq '^[[:space:]]*(reindex|reindex-chainstate)[[:space:]]*=' "$CONF"
}

preflight()
{
    require_command docker flock grep jq seq sha256sum stat timeout
    verify_package_integrity "$PACKAGE_ROOT" ||
        die 'rollout package bytes differ from the validated manifest'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required on the Unraid host'
    [[ -f "$IMAGE_POLICY" && ! -L "$IMAGE_POLICY" ]] || die 'image policy is unsafe'
    policy_guard_pin_matches || die 'image policy is not pinned by the endpoint guard'
    [[ -f "$ENABLE_GUARD_STARTS" && ! -L "$ENABLE_GUARD_STARTS" &&
       "$(stat -c '%u:%g:%a' "$ENABLE_GUARD_STARTS")" == 0:0:600 && ! -s "$ENABLE_GUARD_STARTS" ]] ||
        die 'automatic-start authority is absent or unsafe'
    [[ -f "$CUTOVER_MARKER" && ! -L "$CUTOVER_MARKER" &&
       "$(cat "$CUTOVER_MARKER")" == 'cutover_ready=yes containers=32 state=created' ]] ||
        die 'Pulsar cutover authority is absent or unsafe'
    assert_unique_vpn_proofs || die 'fleet VPN proof set is not exact-32 unique'
    verify_stopped_contract || die 'clean-stop recovery proof failed; node remains stopped'
}

wait_runtime()
{
    for _ in $(seq 1 300); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true &&
              "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == healthy ]] &&
           live_netns_matches "$NODE" && target_proof_unique &&
           verify_policy_compatible_runtime_gate "$NODE" "$RECOVERY_FEE_BASELINE"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

ensure_free_claim_lock()
{
    [[ "$NODE" -eq "$FREE_CLAIM_NODE" ]] || return 0
    [[ "$FREE_CLAIM_LOCK_HELD" -eq 0 ]] || return 0
    exec 18>"$FREE_CLAIM_LOCK"
    flock -w 1800 18 || return 1
    FREE_CLAIM_LOCK_HELD=1
}

release_free_claim_lock_local()
{
    [[ "$FREE_CLAIM_LOCK_HELD" -eq 1 ]] || return 0
    flock -u 18 2>/dev/null || true
    exec 18>&- 2>/dev/null || true
    FREE_CLAIM_LOCK_HELD=0
}

drain_target_claims()
{
    local mining
    if [[ "$NODE" -ne "$FREE_CLAIM_NODE" ]]; then
        wallet_rpc_for "$NODE" setpowmining false 1 1 >/dev/null || return 1
    fi
    for _ in $(seq 1 240); do
        mining=$(wallet_rpc_for "$NODE" getpowmininginfo 2>/dev/null || true)
        jq -e '.enabled == false and .live_claims == 0' >/dev/null 2>&1 <<< "$mining" && return 0
        sleep 5
    done
    return 1
}

assert_target_cleanly_stopped()
{
    docker inspect "$CONTAINER" | jq -e 'length == 1 and .[0].State.Running == false and
        .[0].State.ExitCode == 0 and .[0].State.OOMKilled == false and .[0].State.Error == ""' \
        >/dev/null
}

contain_on_failure()
{
    local failed=0
    set +e
    if [[ "$STARTED" -eq 1 && "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true ]]; then
        ensure_free_claim_lock || failed=1
        if ((failed == 0)) && drain_target_claims; then
            rpc_for "$NODE" stop >/dev/null 2>&1 || true
            for _ in $(seq 1 180); do
                [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]] && break
                sleep 1
            done
            if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true ]]; then
                timeout --kill-after=30 660 docker stop -t 600 "$CONTAINER" >/dev/null 2>&1 || failed=1
            fi
            assert_target_cleanly_stopped || failed=1
        else
            failed=1
            log "ERROR: node=$NODE could not reach a claim-safe failure-containment boundary; Core was not forced down"
        fi
    elif [[ "$STARTED" -eq 1 ]]; then
        assert_target_cleanly_stopped || failed=1
    fi
    set -e
    return "$failed"
}

on_recovery_exit()
{
    local rc="$1" before="$2" after="$3"
    trap - EXIT INT TERM
    contain_on_failure || true
    rm -f -- "$before" "$after"
    exit "$rc"
}

apply_recovery()
{
    local before after
    [[ "${CONFIRM_CLEAN_STOP_RECOVERY:-}" == "$CONFIRM_VALUE" ]] ||
        die "apply requires CONFIRM_CLEAN_STOP_RECOVERY=$CONFIRM_VALUE"
    preflight
    before=$(mktemp)
    after=$(mktemp)
    trap 'rm -f -- "$before" "$after"' EXIT
    exec 19>/var/run/blackcoin-v30.1.4-fleet-rollout.lock
    flock -n 19 || die 'fleet rollout lock is busy'
    exec 15>/run/blackcoin-endpoint-guard.lock
    flock -w 1800 15 || die 'endpoint guard did not drain'
    exec 16>/var/run/blackcoin-node-cutover.lock
    flock -x -w 1800 16 || die 'cutover lock did not drain'
    exec 14>/run/blackcoin-pow-quarantine-cycle.lock
    flock -w 1800 14 || die 'PoW quarantine cycle did not drain'
    exec 17>/var/run/blackcoin-wallet-runtime-guard.lock
    flock -w 1800 17 || die 'wallet guard did not drain'
    if [[ "$NODE" -eq "$FREE_CLAIM_NODE" ]]; then
        ensure_free_claim_lock || die 'Free Claim worker did not drain'
    fi
    preflight
    capture_other_generations "$before"
    trap 'on_recovery_exit "$?" "$before" "$after"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    verify_stopped_contract || die 'proof changed after lock acquisition; refusing start'
    docker start "$CONTAINER" >/dev/null
    STARTED=1
    capture_recovery_fee_baseline || die 'target recovery-fee/version baseline is unavailable after start'
    run_pinned_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA256" ||
        die 'pinned normal-unlock helper failed'
    if [[ "$NODE" -ne "$FREE_CLAIM_NODE" ]]; then
        run_pinned_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA256" ||
            die 'pinned PoW start-only helper failed'
    fi
    wait_runtime || die 'target did not become operational; it was contained again'
    capture_other_generations "$after"
    cmp -s "$before" "$after" || die 'another node/VPN generation changed; target was contained'
    if [[ "$NODE" -eq "$FREE_CLAIM_NODE" ]]; then
        release_free_claim_lock_local
        for _ in $(seq 1 120); do
            verify_node30_free_claim_service && break
            sleep 5
        done
        verify_node30_free_claim_service || die 'node30 recovered but its Free Claim service did not'
    fi
    trap - ERR INT TERM EXIT
    rm -f -- "$before" "$after"
    log "clean guard stop recovered node=$NODE; all other 31 generations unchanged"
}

case "$ACTION" in
    plan)
        printf 'node=%s container=%s vpn=%s action=proof-gated-targeted-start\n' "$NODE" "$CONTAINER" "$VPN"
        ;;
    preflight)
        preflight
        log "clean-stop preflight passed node=$NODE"
        ;;
    apply)
        apply_recovery
        ;;
    *)
        printf 'usage: %s plan|preflight|apply NODE(1-32)\n' "$0" >&2
        exit 64
        ;;
esac
