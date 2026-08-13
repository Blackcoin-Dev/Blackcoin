#!/usr/bin/env bash

# Isolated repair for the two audited VPN failures. It never recreates a VPN,
# changes a VPN image/configuration, or touches another node/VPN pair. A target
# node must already be stopped before its paired PIA container may be restarted.

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
    printf '%s\n' 'FATAL: repair package failed bootstrap integrity verification' >&2
    exit 1
}
unset -f bootstrap_package_integrity
# shellcheck source=lib/live_checks.sh
source "$PACKAGE_ROOT/lib/live_checks.sh"

readonly ACTION=${1:-plan}
readonly NODE=${2:-}
readonly MAX_ATTEMPTS=3
readonly NORMAL_UNLOCK_HELPER="$STATE_DIR/blackcoin_node_normal_unlock.sh"
readonly POW_START_HELPER="$STATE_DIR/blackcoin_pow_start_only.sh"
readonly NORMAL_UNLOCK_HELPER_SHA256=acf28446e842fd0fa92b06c2ebc182e9da38fcde7bac06dd920d50a33e4e3dd1
readonly POW_START_HELPER_SHA256=21808f232ca3961e180a4c2dd3853e4aef93c2dfdf4821b5d63ca5106c5676ea
RUN_DIR=
CONFIG_BACKUP=
CONFIG_COMMITTED=0
MUTATION_STARTED=0
REPAIR_SUCCEEDED=0
RECOVERY_FEE_BASELINE=

[[ "$NODE" == 7 || "$NODE" == 22 ]] || {
    printf 'usage: %s plan|preflight|apply 7|22\n' "$0" >&2
    exit 64
}

PADDED=$(node_padded "$NODE")
CONTAINER=$(container_for "$NODE")
VPN=$(vpn_for "$NODE")
CONF="$(host_datadir_for "$NODE")/blackcoin.conf"
readonly PADDED CONTAINER VPN CONF
readonly EXPECTED_CONFIRM="node-$PADDED-vpn-repair"

capture_other_generations()
{
    local output="$1" node container vpn container_state vpn_state
    : > "$output"
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "$node" -eq "$NODE" ]] && continue
        container=$(container_for "$node")
        vpn=$(vpn_for "$node")
        container_state=$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}|{{.State.Status}}' "$container") || return 1
        vpn_state=$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}|{{.State.Status}}' "$vpn") || return 1
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

current_policy_expectation()
{
    local class
    class=$(jq -er --arg node "$PADDED" '.nodes[$node]' "$IMAGE_POLICY") || return 1
    jq -er --arg class "$class" '.images[$class] | .config_image + "|" + .image_id' "$IMAGE_POLICY"
}

verify_target_topology_stopped()
{
    local expected expected_ref expected_id vpn_id inspect
    expected=$(current_policy_expectation) || return 1
    IFS='|' read -r expected_ref expected_id <<< "$expected"
    vpn_id=$(docker inspect -f '{{.Id}}' "$VPN") || return 1
    inspect=$(docker inspect "$CONTAINER") || return 1
    jq -e --arg ref "$expected_ref" --arg id "$expected_id" \
        --arg mode "container:$vpn_id" --arg data "$(host_datadir_for "$NODE")" \
        --arg blocks "$(host_blocks_for "$NODE")" '
        length == 1 and .[0].State.Running == false and
        .[0].State.ExitCode == 0 and .[0].State.OOMKilled == false and .[0].State.Error == "" and
        .[0].Config.Image == $ref and .[0].Image == $id and
        .[0].HostConfig.NetworkMode == $mode and
        .[0].HostConfig.RestartPolicy.Name == "on-failure" and
        .[0].HostConfig.RestartPolicy.MaximumRetryCount == 3 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/.blackcoin" and
            .Source == $data and .RW == true)] | length) == 1 and
        ([.[0].Mounts[] | select(.Destination == "/home/blackcoin/blocks_storage" and
            .Source == $blocks and .RW == true)] | length) == 1
    ' >/dev/null <<< "$inspect"
}

verify_vpn_container_contract()
{
    docker inspect "$VPN" | jq -e --arg id "$EXPECTED_VPN_IMAGE_ID" '
        length == 1 and .[0].State.Running == true and
        .[0].Image == $id and .[0].HostConfig.RestartPolicy.Name == "unless-stopped" and
        .[0].HostConfig.NetworkMode == "bridge"
    ' >/dev/null
}

proof_is_unique()
{
    local target_proof target_ip node proof ip
    target_proof=$(read_vpn_proof "$NODE") || return 1
    IFS='|' read -r target_ip _ <<< "$target_proof"
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$VPN")" == healthy ]] || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ "$node" -eq "$NODE" ]] && continue
        proof=$(read_vpn_proof "$node") || return 1
        IFS='|' read -r ip _ <<< "$proof"
        [[ "$ip" != "$target_ip" ]] || return 1
    done
}

preflight()
{
    require_command awk bash docker flock grep install jq mktemp mv readlink realpath \
        sed seq sha256sum stat sync timeout
    verify_package_integrity "$PACKAGE_ROOT" ||
        die 'rollout package bytes differ from the validated manifest'
    [[ "$(id -u)" -eq 0 ]] || die 'root is required on the Unraid host'
    [[ -f "$IMAGE_POLICY" && ! -L "$IMAGE_POLICY" ]] || die 'image policy is unsafe'
    [[ -f "$ENDPOINT_GUARD" && ! -L "$ENDPOINT_GUARD" ]] || die 'endpoint guard is unsafe'
    [[ -f "$CONFIG_REPAIR_AWK" && ! -L "$CONFIG_REPAIR_AWK" ]] || die 'config repair program is unsafe'
    [[ -f "$CONF" && ! -L "$CONF" && "$(stat -c '%u:%g:%a' "$CONF")" == 1000:1000:600 ]] ||
        die 'target blackcoin.conf is unsafe'
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == false ]] ||
        die 'target node must already be stopped; this procedure will not disrupt a running node'
    verify_target_topology_stopped || die 'target stopped-container topology or image policy is invalid'
    verify_vpn_container_contract || die 'target VPN container contract is invalid'
    assert_marker_state_local "$ENABLE_GUARD_STARTS" || die 'automatic-start authority is unavailable'
    assert_marker_state_local "$CUTOVER_MARKER" 'cutover_ready=yes containers=32 state=created' ||
        die 'Pulsar cutover marker is unavailable'
    verify_repair_program_pin || die 'config repair program is not pinned by the endpoint guard'
}

assert_marker_state_local()
{
    local path="$1" content="${2:-}"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || return 1
    [[ -z "$content" || "$(cat "$path")" == "$content" ]]
}

verify_repair_program_pin()
{
    local expected actual
    expected=$(sed -n "s/^EXPECTED_REPAIR_AWK_SHA='\([0-9a-f]\{64\}\)'$/\1/p" "$ENDPOINT_GUARD")
    actual=$(sha256sum "$CONFIG_REPAIR_AWK" | awk '{print $1}')
    [[ -n "$expected" && "$actual" == "$expected" ]]
}

render_target_config()
{
    local proof ip port candidate key required
    proof=$(read_vpn_proof "$NODE") || die 'target VPN proof disappeared before configuration render'
    IFS='|' read -r ip port <<< "$proof"
    candidate="$RUN_DIR/blackcoin.conf.candidate"
    awk -v public_ip="$ip" -v forwarded_port="$port" -f "$CONFIG_REPAIR_AWK" "$CONF" > "$candidate"
    for key in networkactive staking autostartstaking powmining qqautoshadowsignal \
        externalip port bind server listen discover dnsseed blocksdir; do
        [[ "$(grep -Ec "^[[:space:]]*${key}[[:space:]]*=" "$candidate")" -eq 1 ]] ||
            die "candidate config does not contain exactly one $key"
    done
    for required in "externalip=$ip:$port" "port=$port" "bind=0.0.0.0:$port" \
        'networkactive=1' 'staking=1' 'autostartstaking=0' 'powmining=0' \
        'qqautoshadowsignal=0' 'server=1' 'listen=1' 'discover=0' 'dnsseed=1' \
        'blocksdir=/home/blackcoin/blocks_storage'; do
        grep -Fqx -- "$required" "$candidate" || die "candidate config omitted: $required"
    done
    ! grep -Eiq '^[[:space:]]*(reindex|reindex-chainstate)[[:space:]]*=' "$candidate" ||
        die 'candidate config contains a reindex directive'
}

commit_target_config()
{
    local temporary
    temporary=$(mktemp "${CONF%/*}/.vpn-repair-conf.XXXXXX")
    trap 'rm -f -- "${temporary:-}"' RETURN
    install -m 600 -o 1000 -g 1000 "$RUN_DIR/blackcoin.conf.candidate" "$temporary"
    sync -f "$temporary"
    mv -fT -- "$temporary" "$CONF"
    CONFIG_COMMITTED=1
    temporary=
    sync -f "${CONF%/*}"
    trap - RETURN
}

wait_recovered_node()
{
    local attempt
    for attempt in $(seq 1 300); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true &&
              "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" == healthy ]] &&
           live_netns_matches "$NODE" &&
           verify_policy_compatible_runtime_gate "$NODE" "$RECOVERY_FEE_BASELINE"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

drain_repair_claims()
{
    local attempt mining
    wallet_rpc_for "$NODE" setpowmining false 1 1 >/dev/null || return 1
    for attempt in $(seq 1 240); do
        mining=$(wallet_rpc_for "$NODE" getpowmininginfo 2>/dev/null || true)
        jq -e '.enabled == false and .live_claims == 0' >/dev/null 2>&1 <<< "$mining" && return 0
        sleep 5
    done
    return 1
}

stop_repair_target_cleanly()
{
    local attempt
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true ]]; then
        drain_repair_claims || return 1
        rpc_for "$NODE" stop >/dev/null 2>&1 || true
        for attempt in $(seq 1 180); do
            [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]] && break
            sleep 1
        done
        if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" == true ]]; then
            timeout --foreground --kill-after=30 660 docker stop -t 600 "$CONTAINER" >/dev/null 2>&1 || return 1
        fi
    fi
    docker inspect "$CONTAINER" | jq -e 'length == 1 and .[0].State.Running == false and
        .[0].State.ExitCode == 0 and .[0].State.OOMKilled == false and .[0].State.Error == ""' \
        >/dev/null
}

rollback_config_and_contain()
{
    local temporary='' expected_hash='' actual_hash='' restore_ok=1 contain_ok=1
    set +e
    stop_repair_target_cleanly || contain_ok=0
    if [[ "$CONFIG_COMMITTED" -eq 1 && "$contain_ok" -eq 1 ]]; then
        [[ -f "$CONFIG_BACKUP" && ! -L "$CONFIG_BACKUP" ]] || restore_ok=0
        if ((restore_ok == 1)); then
            expected_hash=$(sha256sum "$CONFIG_BACKUP" | awk '{print $1}') || restore_ok=0
        fi
        if ((restore_ok == 1)); then
            temporary=$(mktemp "${CONF%/*}/.vpn-repair-rollback.XXXXXX") || restore_ok=0
        fi
        if ((restore_ok == 1)); then
            install -m 600 -o 1000 -g 1000 "$CONFIG_BACKUP" "$temporary" || restore_ok=0
        fi
        if ((restore_ok == 1)); then
            mv -fT -- "$temporary" "$CONF" || restore_ok=0
            temporary=
        fi
        if ((restore_ok == 1)); then
            sync -f "${CONF%/*}" || restore_ok=0
            actual_hash=$(sha256sum "$CONF" | awk '{print $1}') || restore_ok=0
            [[ -f "$CONF" && ! -L "$CONF" && "$(stat -c '%u:%g:%a' "$CONF")" == 1000:1000:600 &&
               "$actual_hash" == "$expected_hash" ]] || restore_ok=0
        fi
    elif [[ "$CONFIG_COMMITTED" -eq 1 ]]; then
        restore_ok=0
    fi
    rm -f -- "$temporary"
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]] || contain_ok=0
    if ((restore_ok == 1 && contain_ok == 1)); then
        printf '%s\n' 'failed-contained-config-restored-node-stopped' > "$RUN_DIR/RESULT"
        sync -f "$RUN_DIR/RESULT"
        set -e
        return 0
    fi
    rm -f -- "$RUN_DIR/RESULT"
    printf 'config_restored=%s node_contained=%s\n' "$restore_ok" "$contain_ok" \
        > "$RUN_DIR/FAILURE_REQUIRES_OPERATOR"
    sync -f "$RUN_DIR/FAILURE_REQUIRES_OPERATOR" 2>/dev/null || true
    log 'ERROR: VPN repair containment could not prove config restoration and node stop'
    set -e
    return 1
}

on_repair_exit()
{
    local rc=$?
    trap - EXIT INT TERM
    if ((rc != 0 && MUTATION_STARTED == 1 && REPAIR_SUCCEEDED == 0)); then
        rollback_config_and_contain || true
    fi
    exit "$rc"
}

apply_repair()
{
    local stamp attempt other_before other_after
    [[ "${CONFIRM_VPN_REPAIR:-}" == "$EXPECTED_CONFIRM" ]] ||
        die "apply requires CONFIRM_VPN_REPAIR=$EXPECTED_CONFIRM"
    preflight
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    RUN_DIR="$OPS_ROOT/vpn-repair-node-$PADDED-$stamp"
    install -d -m 700 -o root -g root "$OPS_ROOT" "$RUN_DIR"
    CONFIG_BACKUP="$RUN_DIR/blackcoin.conf.before"
    other_before="$RUN_DIR/unaffected.before"
    other_after="$RUN_DIR/unaffected.after"

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
    preflight
    install -m 600 -o root -g root "$CONF" "$CONFIG_BACKUP"
    capture_other_generations "$other_before"
    trap on_repair_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    MUTATION_STARTED=1
    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
        log "node=$NODE restarting only VPN=$VPN attempt=$attempt"
        if ! timeout --foreground --kill-after=30 180 docker restart -t 120 "$VPN" >/dev/null; then
            log "node=$NODE VPN restart command failed attempt=$attempt"
            continue
        fi
        for _ in $(seq 1 120); do
            if proof_is_unique; then break 2; fi
            sleep 2
        done
    done
    proof_is_unique || die 'VPN did not obtain a healthy, valid, unique endpoint after three attempts'
    render_target_config
    commit_target_config
    docker start "$CONTAINER" >/dev/null
    capture_recovery_fee_baseline || die 'target claim-recovery fee baseline is unavailable after start'
    run_pinned_helper "$NORMAL_UNLOCK_HELPER" "$NORMAL_UNLOCK_HELPER_SHA256" ||
        die 'pinned normal-unlock helper failed'
    run_pinned_helper "$POW_START_HELPER" "$POW_START_HELPER_SHA256" ||
        die 'pinned PoW start-only helper failed'
    wait_recovered_node || die 'target node did not recover after the proven VPN endpoint change'
    proof_is_unique || die 'target VPN endpoint uniqueness changed after Core recovery'
    capture_other_generations "$other_after"
    cmp -s "$other_before" "$other_after" || die 'another node or VPN generation changed during isolated repair'
    printf '%s\n' passed > "$RUN_DIR/RESULT"
    sha256sum "$CONFIG_BACKUP" "$RUN_DIR/blackcoin.conf.candidate" "$RUN_DIR/RESULT" \
        > "$RUN_DIR/SHA256SUMS"
    REPAIR_SUCCEEDED=1
    log "isolated VPN repair passed node=$NODE evidence=$RUN_DIR"
}

case "$ACTION" in
    plan)
        printf 'node=%s container=%s vpn=%s max_restarts=%s\n' "$NODE" "$CONTAINER" "$VPN" "$MAX_ATTEMPTS"
        printf '%s\n' 'plan only: paired node must be stopped; only the paired VPN would restart'
        ;;
    preflight)
        preflight
        log "node=$NODE isolated VPN repair preflight passed"
        ;;
    apply)
        apply_repair
        ;;
    *)
        printf 'usage: %s plan|preflight|apply 7|22\n' "$0" >&2
        exit 64
        ;;
esac
