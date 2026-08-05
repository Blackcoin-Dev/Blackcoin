#!/usr/bin/env bash

# Shared, side-effect-free helpers for the v30.1.4 fleet transaction.
# Callers choose when mutations are authorized; this file never performs one.

set -Eeuo pipefail
umask 077
export LC_ALL=C TZ=UTC

readonly NODE_COUNT=32
readonly FREE_CLAIM_NODE=30
readonly MAX_WAVE_SIZE=4
readonly MIN_QUANTUM_SIGNAL_BLOCKS=600
readonly MIN_QUANTUM_SIGNAL_SECONDS=43200
readonly CLI_PATH=/usr/local/bin/blackcoin-cli
readonly DATADIR=/home/blackcoin/.blackcoin
readonly COMPOSE_FILE=/boot/config/plugins/compose.manager/projects/blackcoin30/docker-compose.yml
readonly STATE_DIR=/boot/config/plugins/blackcoin-quantum-nodes
readonly IMAGE_POLICY="$STATE_DIR/fleet-image-policy.json"
readonly ENDPOINT_GUARD="$STATE_DIR/blackcoin_endpoint_guard.sh"
readonly WALLET_RUNTIME_GUARD="$STATE_DIR/blackcoin_wallet_runtime_guard.sh"
readonly CONFIG_REPAIR_AWK="$STATE_DIR/blackcoin_config_repair.awk"
readonly ENABLE_GUARD_STARTS="$STATE_DIR/ENABLE_GUARD_STARTS"
readonly CUTOVER_MARKER="$STATE_DIR/PULSAR_CUTOVER_READY"
readonly OPS_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout
readonly FREE_CLAIM_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/free-claim-pool
readonly FREE_CLAIM_LOCK=/var/run/blackcoin-free-claim-pool.lock
readonly ROLLOUT_MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"
readonly FREE_CLAIM_PAUSE_MARKER="$FREE_CLAIM_ROOT/.v30.1.4-free-claim-paused"
readonly EXPECTED_VPN_IMAGE_ID=sha256:5694e33296a1d44a563e83e51113970b230acf2878004f01099ad4a4b83bc762

log()
{
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"
}

die()
{
    log "FATAL: $*" >&2
    exit 1
}

require_command()
{
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
    done
}

verify_package_integrity()
{
    local root="${1:?package root is required}" owner mode
    [[ -d "$root" && ! -L "$root" && "$(realpath -e -- "$root")" == "$root" &&
       -f "$root/SHA256SUMS" && ! -L "$root/SHA256SUMS" &&
       "$(realpath -e -- "$root/SHA256SUMS")" == "$root/SHA256SUMS" &&
       "$(stat -c '%u:%g:%a' "$root/SHA256SUMS")" == 0:0:600 ]] || return 1
    owner=$(stat -c '%u:%g' "$root") || return 1
    mode=$(stat -c '%a' "$root") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z "$(find "$root" -type l -print -quit)" &&
       -z "$(find "$root" ! -type d ! -type f -print -quit)" ]] || return 1
    cmp -s \
        <(cd "$root" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
        }' "$root/SHA256SUMS" | sort) || return 1
    (cd "$root" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

valid_rollout_run_dir()
{
    local path="$1" basename
    basename=${path##*/}
    [[ "${path%/*}" == "$OPS_ROOT" &&
       "$basename" =~ ^rollout-[0-9]{8}T[0-9]{6}Z$ &&
       -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == 0:0:700 ]]
}

node_padded()
{
    printf '%02d\n' "$1"
}

service_for()
{
    valid_node "$1" || return 1
    printf 'node%02d\n' "$1"
}

container_for()
{
    if [[ "$1" -eq 1 ]]; then
        printf '%s\n' blackcoin-v4-gui
    else
        printf 'blackcoin-v4-gui-%s\n' "$1"
    fi
}

vpn_for()
{
    local node="$1"
    valid_node "$node" || return 1
    if [[ "$node" -eq 1 ]]; then
        printf '%s\n' pia-vpn
    else
        printf 'pia-vpn-%d\n' "$((node - 1))"
    fi
}

host_datadir_for()
{
    printf '/mnt/pulsar/Blackcoin_Blocks/node-data/node-%02d\n' "$1"
}

host_blocks_for()
{
    printf '/mnt/pulsar/Blackcoin_Blocks/%d\n' "$1"
}

valid_node()
{
    [[ "$1" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]
}

valid_sha256_hex()
{
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

valid_image_id()
{
    [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]
}

valid_immutable_image_ref()
{
    # A manifest digest is mandatory. A unique tag plus an image ID is not an
    # immutable reference and is therefore intentionally rejected here.
    [[ "$1" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]
}

valid_label_key()
{
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]]
}

valid_public_ipv4()
{
    local ip="$1" a b c d part
    IFS=. read -r a b c d <<< "$ip"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for part in "$a" "$b" "$c" "$d"; do
        [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
    ((10#$a >= 1 && 10#$a <= 223 && 10#$a != 10 && 10#$a != 127)) || return 1
    ! ((10#$a == 100 && 10#$b >= 64 && 10#$b <= 127)) || return 1
    ! ((10#$a == 169 && 10#$b == 254)) || return 1
    ! ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)) || return 1
    ! ((10#$a == 192 && 10#$b == 168)) || return 1
    ! ((10#$a == 192 && 10#$b == 88 && 10#$c == 99)) || return 1
    ! ((10#$a == 198 && (10#$b == 18 || 10#$b == 19))) || return 1
    ! ((10#$a == 192 && 10#$b == 0 && (10#$c == 0 || 10#$c == 2))) || return 1
    ! ((10#$a == 198 && 10#$b == 51 && 10#$c == 100)) || return 1
    ! ((10#$a == 203 && 10#$b == 0 && 10#$c == 113)) || return 1
}

valid_port()
{
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535))
}

rpc_for()
{
    local node="$1"
    shift
    timeout --kill-after=2 45 docker exec "$(container_for "$node")" \
        "$CLI_PATH" -datadir="$DATADIR" "$@"
}

single_wallet_for()
{
    local node="$1" wallets
    wallets=$(rpc_for "$node" listwallets 2>/dev/null) || return 1
    jq -er 'select(type == "array" and length == 1 and
        (.[0] | type == "string" and length <= 128)) | .[0]' <<< "$wallets"
}

wallet_rpc_for()
{
    local node="$1" wallet
    shift
    wallet=$(single_wallet_for "$node") || return 1
    timeout --kill-after=2 45 docker exec "$(container_for "$node")" \
        "$CLI_PATH" -datadir="$DATADIR" -rpcwallet="$wallet" "$@"
}

live_netns_matches()
{
    local node="$1" container vpn container_pid vpn_pid container_ns vpn_ns
    container=$(container_for "$node")
    vpn=$(vpn_for "$node")
    container_pid=$(timeout -k 2 10 docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null) || return 1
    vpn_pid=$(timeout -k 2 10 docker inspect -f '{{.State.Pid}}' "$vpn" 2>/dev/null) || return 1
    [[ "$container_pid" =~ ^[1-9][0-9]*$ && "$vpn_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    container_ns=$(readlink "/proc/$container_pid/ns/net" 2>/dev/null) || return 1
    vpn_ns=$(readlink "/proc/$vpn_pid/ns/net" 2>/dev/null) || return 1
    [[ -n "$container_ns" && "$container_ns" == "$vpn_ns" ]]
}

read_vpn_proof()
{
    local node="$1" vpn proof ip port
    vpn=$(vpn_for "$node")
    proof=$(timeout -k 2 20 docker exec "$vpn" sh -c \
        'ip=$(tr -d "\r\n" </tmp/gluetun/ip) || exit 1
         port=$(tr -d "\r\n" </tmp/gluetun/forwarded_port) || exit 1
         printf "%s|%s\n" "$ip" "$port"' 2>/dev/null) || return 1
    IFS='|' read -r ip port <<< "$proof"
    valid_public_ipv4 "$ip" && valid_port "$port" || return 1
    printf '%s|%s\n' "$ip" "$port"
}

assert_unique_vpn_proofs()
{
    local node proof ip port
    local -A seen=()
    for node in $(seq 1 "$NODE_COUNT"); do
        proof=$(read_vpn_proof "$node") || return 1
        IFS='|' read -r ip port <<< "$proof"
        [[ -z "${seen[$ip]:-}" ]] || return 1
        seen[$ip]="$node"
    done
}

policy_guard_pin_matches()
{
    local policy_sha pin_sha
    [[ -f "$IMAGE_POLICY" && ! -L "$IMAGE_POLICY" &&
       -f "$ENDPOINT_GUARD" && ! -L "$ENDPOINT_GUARD" ]] || return 1
    policy_sha=$(sha256sum "$IMAGE_POLICY" | awk '{print $1}') || return 1
    pin_sha=$(sed -n "s/^EXPECTED_IMAGE_POLICY_SHA='\([0-9a-f]\{64\}\)'$/\1/p" \
        "$ENDPOINT_GUARD") || return 1
    [[ -n "$pin_sha" && "$policy_sha" == "$pin_sha" ]]
}

container_generation_for()
{
    local node="$1" container vpn
    container=$(container_for "$node")
    vpn=$(vpn_for "$node")
    printf '%s|%s\n' \
        "$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}' "$container")" \
        "$(docker inspect -f '{{.Id}}|{{.State.StartedAt}}' "$vpn")"
}

assert_no_reindex_directive()
{
    local node conf
    for node in "$@"; do
        conf="$(host_datadir_for "$node")/blackcoin.conf"
        [[ -f "$conf" && ! -L "$conf" ]] || return 1
        ! grep -Eiq '^[[:space:]]*(reindex|reindex-chainstate)[[:space:]]*=[[:space:]]*(1|true|yes)([[:space:]]|$)' "$conf" || return 1
    done
}

validate_wave_plan()
{
    local plan="$1" line node count=0 line_count=0
    local -A seen=()
    [[ -f "$plan" && ! -L "$plan" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        # shellcheck disable=SC2001
        line=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$line")
        [[ -n "$line" ]] || continue
        read -r -a wave_nodes <<< "$line"
        ((${#wave_nodes[@]} >= 1 && ${#wave_nodes[@]} <= MAX_WAVE_SIZE)) || return 1
        line_count=$((line_count + 1))
        for node in "${wave_nodes[@]}"; do
            valid_node "$node" || return 1
            [[ -z "${seen[$node]:-}" ]] || return 1
            seen[$node]=1
            count=$((count + 1))
        done
    done < "$plan"
    ((count == NODE_COUNT && line_count >= 8)) || return 1
    for node in $(seq 1 "$NODE_COUNT"); do
        [[ -n "${seen[$node]:-}" ]] || return 1
    done
    # Role-specific waves must remain isolated.
    grep -Eq '^[[:space:]]*30[[:space:]]*(#.*)?$' "$plan" || return 1
    grep -Eq '^[[:space:]]*31[[:space:]]+32[[:space:]]*(#.*)?$' "$plan" || return 1
}

require_rollout_identity()
{
    : "${CANDIDATE_IMAGE_REF:?CANDIDATE_IMAGE_REF is required}"
    : "${CANDIDATE_IMAGE_ID:?CANDIDATE_IMAGE_ID is required}"
    : "${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
    : "${SOURCE_LABEL_KEY:?SOURCE_LABEL_KEY is required}"
    : "${SOURCE_LABEL_VALUE:?SOURCE_LABEL_VALUE is required}"
    : "${VERSION_LABEL_KEY:?VERSION_LABEL_KEY is required}"
    : "${VERSION_LABEL_VALUE:?VERSION_LABEL_VALUE is required}"
    : "${BLACKCOIND_SHA256:?BLACKCOIND_SHA256 is required}"
    : "${BLACKCOIN_CLI_SHA256:?BLACKCOIN_CLI_SHA256 is required}"
    : "${PUBLISHED_CANARY_RESULT:?PUBLISHED_CANARY_RESULT is required}"
    : "${EXPECTED_CANARY_RESULT_SHA256:?EXPECTED_CANARY_RESULT_SHA256 is required}"
    : "${PUBLISHED_CANARY_EVIDENCE_MANIFEST:?PUBLISHED_CANARY_EVIDENCE_MANIFEST is required}"
    : "${EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256:?EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256 is required}"
    valid_immutable_image_ref "$CANDIDATE_IMAGE_REF" || die 'candidate image reference must be an immutable manifest digest'
    valid_image_id "$CANDIDATE_IMAGE_ID" || die 'candidate image ID is malformed'
    [[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die 'source commit is malformed'
    valid_label_key "$SOURCE_LABEL_KEY" || die 'source label key is malformed'
    valid_label_key "$VERSION_LABEL_KEY" || die 'version label key is malformed'
    [[ "$SOURCE_LABEL_VALUE" == "$SOURCE_COMMIT" ]] || die 'source label value must equal the source commit'
    [[ "$VERSION_LABEL_VALUE" == v30.1.4 || "$VERSION_LABEL_VALUE" == 30.1.4 ]] || die 'version label must identify v30.1.4'
    valid_sha256_hex "$BLACKCOIND_SHA256" || die 'blackcoind hash is malformed'
    valid_sha256_hex "$BLACKCOIN_CLI_SHA256" || die 'blackcoin-cli hash is malformed'
    valid_sha256_hex "$EXPECTED_CANARY_RESULT_SHA256" || die 'canary result hash is malformed'
    valid_sha256_hex "$EXPECTED_CANARY_EVIDENCE_MANIFEST_SHA256" ||
        die 'canary evidence manifest hash is malformed'
}
