#!/bin/bash -p
export LC_ALL=C
export TZ=UTC
set -Eeuo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# This tool is intentionally single-subject.  It is not a fleet loop and it is
# not a generic transaction wrapper.  The only wallet mutation it can invoke
# on the installed v30.1.4 interface is one exact-plan sign_only recovery.
# Installed v30.1.4 cannot consume the externally reviewed relay plan/tip
# identity atomically with commit, so public relay is an explicit hard blocker.

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
readonly INSTALLED_RELAY_ELIGIBLE=false
readonly RELAY_INTERFACE_BLOCKER='installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding'
readonly PRODUCTION_DOCKER_PATH='/usr/bin/docker'
readonly PRODUCTION_FLOCK_PATH='/usr/bin/flock'
readonly MUTATION_LOCK_BASENAMES=(
    blackcoin-v3015-rollout.lock
    blackcoin-endpoint-guard.lock
    blackcoin-node-cutover.lock
    blackcoin-pow-quarantine-cycle.lock
    blackcoin-wallet-runtime-guard.lock
    blackcoin-node27-recovery.lock
)
# Updated with the hostile fixture's sealed bytes. The override accepts only
# this inert repository fixture; ambient PATH is never a transport selector.
readonly TEST_DOCKER_SHA256='99e5ed4c70268ee0406d51478164edcbf69d53de47bf0b20b76594033e892961'

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
AUDIT_JSON=''
SIGN_JSON=''
RELAY_JSON=''
AUTHORITY_JSON=''
DOCKER_PATH=''
DOCKER_SHA256=''
DOCKER_OWNER_UID=''
DOCKER_OWNER_GID=''
DOCKER_MODE=''
DOCKER_ANCESTRY=''
SELF_PATH=''
TOOL_SHA256=''
FLOCK_PATH=''
FLOCK_SHA256=''
FLOCK_OWNER_UID=''
FLOCK_OWNER_GID=''
FLOCK_MODE=''
FLOCK_ANCESTRY=''
MUTATION_LOCK_PATHS=()
MUTATION_LOCK_FDS=()
TEST_LOCK_RESERVATIONS=()
MUTATION_LOCK_IDENTITIES='[]'
MUTATION_LOCK_IDENTITIES_SHA256=''

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
  node27_recovery_canary.sh reconcile-sign --output ABSOLUTE_PATH \
      --audit-receipt ABSOLUTE_PATH --audit-sha256 HEX \
      --authority-receipt ABSOLUTE_PATH --authority-sha256 HEX
  node27_recovery_canary.sh reconcile-relay --output ABSOLUTE_PATH \
      --sign-receipt ABSOLUTE_PATH --sign-sha256 HEX \
      --authority-receipt ABSOLUTE_PATH --authority-sha256 HEX
  node27_recovery_canary.sh verify-final --output ABSOLUTE_PATH \
      --sign-receipt ABSOLUTE_PATH --sign-sha256 HEX \
      --relay-receipt ABSOLUTE_PATH --relay-sha256 HEX

No arguments means audit. audit, reconcile-sign, reconcile-relay, and
verify-final invoke no mutating RPC. sign-only acquires the canonical shared
rollout, endpoint, cutover, PoW, wallet-runtime, and node27 recovery locks in
that fixed order. relay always fails before receipt parsing, locks, transport,
or RPC because installed v30.1.4 cannot atomically consume the externally
authorized plan/tip/wallet/component identity. reconcile-relay is observation
only and cannot create an admissible relay or final-acceptance receipt.
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

file_gid()
{
    if stat -f '%g' "$1" >/dev/null 2>&1; then
        stat -f '%g' "$1"
    else
        stat -c '%g' "$1"
    fi
}

file_links()
{
    if stat -f '%l' "$1" >/dev/null 2>&1; then
        stat -f '%l' "$1"
    else
        stat -c '%h' "$1"
    fi
}

file_device()
{
    if stat -f '%d' "$1" >/dev/null 2>&1; then
        stat -f '%d' "$1"
    else
        stat -c '%d' "$1"
    fi
}

file_inode()
{
    if stat -f '%i' "$1" >/dev/null 2>&1; then
        stat -f '%i' "$1"
    else
        stat -c '%i' "$1"
    fi
}

file_device_follow()
{
    if stat -Lf '%d' "$1" >/dev/null 2>&1; then
        stat -Lf '%d' "$1"
    else
        stat -Lc '%d' "$1"
    fi
}

file_inode_follow()
{
    if stat -Lf '%i' "$1" >/dev/null 2>&1; then
        stat -Lf '%i' "$1"
    else
        stat -Lc '%i' "$1"
    fi
}

transport_ancestry_json()
{
    local path=$1 current mode uid gid rows='[]'
    current=${path%/*}
    while :; do
        [[ -d "$current" && ! -L "$current" && "$(realpath "$current")" == "$current" ]] ||
            return 1
        mode=$(file_mode "$current") || return 1
        uid=$(file_uid "$current") || return 1
        gid=$(file_gid "$current") || return 1
        rows=$(jq -c --arg path "$current" --argjson uid "$uid" --argjson gid "$gid" \
          --arg mode "$mode" '. + [{path:$path,owner_uid:$uid,owner_gid:$gid,mode:$mode}]' \
          <<< "$rows") || return 1
        [[ "$current" == / ]] && break
        current=${current%/*}
        [[ -n "$current" ]] || current=/
    done
    jq -c . <<< "$rows"
}

mode_is_not_group_or_world_writable()
{
    local mode=$1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

production_ancestry_is_safe()
{
    local ancestry=$1 path uid gid mode
    while IFS=$'\t' read -r path uid gid mode; do
        [[ -n "$path" && "$uid" == 0 && "$gid" == 0 ]] || return 1
        mode_is_not_group_or_world_writable "$mode" || return 1
    done < <(jq -r '.[] | [.path,.owner_uid,.owner_gid,.mode] | @tsv' <<< "$ancestry")
}

mutation_lock_paths_json()
{
    printf '%s\n' "${MUTATION_LOCK_PATHS[@]}" | jq -Rsc 'split("\n")[:-1]'
}

resolve_mutation_lock_contract()
{
    local basename root
    MUTATION_LOCK_PATHS=()
    if [[ -n "${NODE27_TEST_LOCK_ROOT:-}" ]]; then
        [[ -n "${NODE27_TEST_TRANSPORT_PATH:-}" && $EUID != 0 ]] ||
            die 'internal hostile-test lock root requires the sealed nonroot test transport'
        root=$(realpath "$NODE27_TEST_LOCK_ROOT") || die 'test lock root is unavailable'
        [[ "$root" == /* && -d "$root" && ! -L "$root" &&
           "$(file_uid "$root")" == "$(id -u)" ]] ||
            die 'test lock root is not an owned canonical directory'
    else
        [[ -z "${NODE27_TEST_TRANSPORT_PATH:-}" ]] ||
            die 'test transport requires an explicit test lock root'
        root=/run
    fi
    for basename in "${MUTATION_LOCK_BASENAMES[@]}"; do
        MUTATION_LOCK_PATHS+=("$root/$basename")
    done
}

release_mutation_locks()
{
    local status=$? reservation
    trap - EXIT HUP INT TERM
    for reservation in "${TEST_LOCK_RESERVATIONS[@]-}"; do
        [[ -n "$reservation" ]] || continue
        rmdir -- "$reservation" 2>/dev/null || true
    done
    exit "$status"
}

acquire_mutation_locks()
{
    local path parent fd fd_path uid gid mode links device inode identities='[]'
    local reservation expected_uid expected_gid index=0
    expected_uid=$(id -u)
    expected_gid=$(id -g)
    MUTATION_LOCK_FDS=()
    TEST_LOCK_RESERVATIONS=()
    MUTATION_LOCK_IDENTITIES='[]'
    trap release_mutation_locks EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for path in "${MUTATION_LOCK_PATHS[@]}"; do
        parent=${path%/*}
        [[ -d "$parent" && ! -L "$parent" && "$(realpath "$parent")" == "$parent" &&
           ! -e "$path" && ! -L "$path" ]] || {
            [[ -f "$path" && ! -L "$path" && "$(realpath "$path")" == "$path" ]] ||
                die "mutation lock path is unsafe: $path"
        }
        if [[ -z "${NODE27_TEST_LOCK_ROOT:-}" ]]; then
            production_ancestry_is_safe "$(transport_ancestry_json "$path")" ||
                die "mutation lock ancestry is unsafe: $path"
        fi
        # macOS still ships Bash 3.2, which lacks dynamic {var} file
        # descriptors. Six explicit descriptors keep the reviewed order
        # portable without evaluating a path as shell text.
        case "$index" in
            0) exec 20<>"$path"; fd=20 ;;
            1) exec 21<>"$path"; fd=21 ;;
            2) exec 22<>"$path"; fd=22 ;;
            3) exec 23<>"$path"; fd=23 ;;
            4) exec 24<>"$path"; fd=24 ;;
            5) exec 25<>"$path"; fd=25 ;;
            *) die 'unexpected mutation lock cardinality' ;;
        esac
        uid=$(file_uid "$path") || die "mutation lock owner is unavailable: $path"
        gid=$(file_gid "$path") || die "mutation lock group is unavailable: $path"
        mode=$(file_mode "$path") || die "mutation lock mode is unavailable: $path"
        links=$(file_links "$path") || die "mutation lock link count is unavailable: $path"
        [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" &&
           "$mode" == 600 && "$links" == 1 ]] ||
            die "mutation lock metadata changed: $path"
        if [[ -e "/proc/$$/fd/$fd" ]]; then
            fd_path="/proc/$$/fd/$fd"
        else
            fd_path="/dev/fd/$fd"
        fi
        device=$(file_device "$path") || die "mutation lock device is unavailable: $path"
        inode=$(file_inode "$path") || die "mutation lock inode is unavailable: $path"
        if [[ "$fd_path" == /proc/* ]]; then
            [[ "$device" == "$(file_device_follow "$fd_path")" &&
               "$inode" == "$(file_inode_follow "$fd_path")" ]] ||
                die "opened mutation lock identity changed: $path"
        else
            # Darwin's devfs reports /dev/fd/N as a distinct device even
            # while preserving the underlying inode. The inode comparison is
            # the available opened-fd/path identity predicate there.
            [[ "$inode" == "$(file_inode_follow "$fd_path")" ]] ||
                die "opened mutation lock inode changed: $path"
        fi
        if [[ -n "${NODE27_TEST_LOCK_ROOT:-}" ]]; then
            reservation="$path.held"
            mkdir -- "$reservation" 2>/dev/null || die "mutation lock is active: $path"
            TEST_LOCK_RESERVATIONS+=("$reservation")
        else
            "$FLOCK_PATH" -n "$fd" || die "mutation lock is active: $path"
        fi
        MUTATION_LOCK_FDS+=("$fd")
        identities=$(jq -c --arg path "$path" --argjson device "$device" \
          --argjson inode "$inode" --argjson uid "$uid" --argjson gid "$gid" \
          --arg mode "$mode" --argjson links "$links" \
          '. + [{path:$path,device:$device,inode:$inode,owner_uid:$uid,owner_gid:$gid,
            mode:$mode,link_count:$links}]' <<< "$identities") ||
            die 'could not record mutation lock identity'
        index=$((index + 1))
    done
    [[ "${#MUTATION_LOCK_FDS[@]}" -eq "${#MUTATION_LOCK_PATHS[@]}" ]] ||
        die 'not every required mutation lock is held'
    MUTATION_LOCK_IDENTITIES=$(jq -c . <<< "$identities")
    MUTATION_LOCK_IDENTITIES_SHA256=$(jq -S -c . <<< "$identities" | hash_stdin) ||
        die 'could not hash mutation lock identities'
}

require_hex64()
{
    [[ "$1" =~ ^[0-9a-f]{64}$ ]] || die "$2 must be lowercase 64-hex"
}

private_path_ancestry_is_safe()
{
    local path=$1 parent current trusted expected_uid expected_gid mode
    parent=${path%/*}
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    parent=$(realpath "$parent") || return 1
    expected_uid=$(id -u)
    expected_gid=$(id -g)
    if [[ -z "${NODE27_TEST_LOCK_ROOT:-}" ]]; then
        production_ancestry_is_safe "$(transport_ancestry_json "$path")"
        return
    fi
    trusted=$(realpath "$NODE27_TEST_LOCK_ROOT") || return 1
    trusted=${trusted%/*}
    trusted=${trusted%/*}
    [[ "$parent" == "$trusted" || "$parent" == "$trusted/"* ]] || return 1
    current=$parent
    while :; do
        [[ -d "$current" && ! -L "$current" && "$(realpath "$current")" == "$current" ]] ||
            return 1
        [[ "$(file_uid "$current")" == "$expected_uid" &&
           "$(file_gid "$current")" == "$expected_gid" ]] || return 1
        mode=$(file_mode "$current") || return 1
        mode_is_not_group_or_world_writable "$mode" || return 1
        [[ "$current" == "$trusted" ]] && break
        current=${current%/*}
        [[ -n "$current" ]] || return 1
    done
}

require_receipt_file()
{
    local path=$1 expected=$2 label=$3 destination=$4
    local uid gid mode links device inode fd30_path fd31_path snapshot
    [[ "$path" == /* && -f "$path" && ! -L "$path" ]] ||
        die "$label must be an absolute regular non-symlink file"
    [[ "$(realpath "$path")" == "$path" ]] || die "$label must be canonical"
    private_path_ancestry_is_safe "$path" || die "$label ancestry is unsafe"
    mode=$(file_mode "$path") || die "$label mode is unavailable"
    uid=$(file_uid "$path") || die "$label owner is unavailable"
    gid=$(file_gid "$path") || die "$label group is unavailable"
    links=$(file_links "$path") || die "$label link count is unavailable"
    [[ "$mode" == 600 ]] || die "$label must be mode 0600"
    [[ "$uid" == "$(id -u)" && "$gid" == "$(id -g)" ]] ||
        die "$label ownership changed"
    [[ "$links" == 1 ]] || die "$label must have exactly one link"
    require_hex64 "$expected" "$label sha256"
    device=$(file_device "$path") || die "$label device is unavailable"
    inode=$(file_inode "$path") || die "$label inode is unavailable"
    exec 30<"$path" || die "$label could not be opened for hashing"
    exec 31<"$path" || { exec 30<&-; die "$label could not be opened for parsing"; }
    if [[ -e /proc/$$/fd/30 ]]; then
        fd30_path=/proc/$$/fd/30
        fd31_path=/proc/$$/fd/31
        [[ "$device" == "$(file_device_follow "$fd30_path")" &&
           "$device" == "$(file_device_follow "$fd31_path")" ]] || {
            exec 30<&- 31<&-; die "$label opened device changed"; }
    else
        fd30_path=/dev/fd/30
        fd31_path=/dev/fd/31
    fi
    [[ "$inode" == "$(file_inode_follow "$fd30_path")" &&
       "$inode" == "$(file_inode_follow "$fd31_path")" ]] || {
        exec 30<&- 31<&-; die "$label opened inode changed"; }
    [[ "$(hash_file "$fd30_path")" == "$expected" ]] || {
        exec 30<&- 31<&-; die "$label sha256 mismatch"; }
    snapshot=$(jq -c 'select(type == "object")' "$fd31_path") || {
        exec 30<&- 31<&-; die "$label is not a JSON object"; }
    exec 30<&- 31<&-
    [[ -f "$path" && ! -L "$path" && "$(file_device "$path")" == "$device" &&
       "$(file_inode "$path")" == "$inode" && "$(file_links "$path")" == 1 ]] ||
        die "$label path changed while it was snapshotted"
    printf -v "$destination" '%s' "$snapshot"
}

require_tool_receipt_sidecar()
{
    local path=$1 expected=$2 label=$3 sidecar="$1.sha256"
    local device inode fd30_path expected_sidecar_sha
    [[ -f "$sidecar" && ! -L "$sidecar" && "$(realpath "$sidecar")" == "$sidecar" ]] ||
        die "$label sha256 sidecar is absent or unsafe"
    private_path_ancestry_is_safe "$sidecar" || die "$label sha256 sidecar ancestry is unsafe"
    [[ "$(file_mode "$sidecar")" == 600 && "$(file_uid "$sidecar")" == "$(id -u)" &&
       "$(file_gid "$sidecar")" == "$(id -g)" && "$(file_links "$sidecar")" == 1 ]] ||
        die "$label sha256 sidecar metadata changed"
    device=$(file_device "$sidecar") || die "$label sha256 sidecar device is unavailable"
    inode=$(file_inode "$sidecar") || die "$label sha256 sidecar inode is unavailable"
    exec 30<"$sidecar" || die "$label sha256 sidecar could not be opened"
    if [[ -e /proc/$$/fd/30 ]]; then
        fd30_path=/proc/$$/fd/30
        [[ "$device" == "$(file_device_follow "$fd30_path")" ]] || {
            exec 30<&-; die "$label sha256 sidecar opened device changed"; }
    else
        fd30_path=/dev/fd/30
    fi
    [[ "$inode" == "$(file_inode_follow "$fd30_path")" ]] || {
        exec 30<&-; die "$label sha256 sidecar opened inode changed"; }
    expected_sidecar_sha=$(printf '%s\n' "$expected" | hash_stdin)
    [[ "$(hash_file "$fd30_path")" == "$expected_sidecar_sha" ]] || {
        exec 30<&-; die "$label sha256 sidecar mismatch"; }
    exec 30<&-
    [[ -f "$sidecar" && ! -L "$sidecar" && "$(file_device "$sidecar")" == "$device" &&
       "$(file_inode "$sidecar")" == "$inode" && "$(file_links "$sidecar")" == 1 ]] ||
        die "$label sha256 sidecar path changed while it was checked"
}

write_receipt()
{
    local json=$1 parent tmp sidecar sidecar_tmp expected
    if [[ -z "$OUTPUT" ]]; then
        jq -S . <<< "$json"
        return
    fi
    sidecar="$OUTPUT.sha256"
    [[ "$OUTPUT" == /* && ! -e "$OUTPUT" && ! -L "$OUTPUT" &&
       ! -e "$sidecar" && ! -L "$sidecar" ]] ||
        die 'output must be a new absolute path'
    parent=${OUTPUT%/*}
    [[ -d "$parent" && ! -L "$parent" && "$(realpath "$parent")" == "$parent" ]] ||
        die 'output parent must be a canonical non-symlink directory'
    private_path_ancestry_is_safe "$OUTPUT" || die 'output parent ancestry is unsafe'
    tmp=$(mktemp "${parent}/.node27-recovery-receipt.XXXXXX") ||
        die 'could not allocate receipt temporary file'
    jq -S . <<< "$json" > "$tmp" || { rm -f "$tmp"; die 'could not render receipt'; }
    chmod 600 "$tmp" || { rm -f "$tmp"; die 'could not protect receipt'; }
    sync -f "$tmp" || { rm -f "$tmp"; die 'could not sync receipt bytes'; }
    expected=$(hash_file "$tmp") || { rm -f "$tmp"; die 'could not hash receipt bytes'; }
    if ! ln "$tmp" "$OUTPUT"; then
        rm -f "$tmp"
        die 'could not publish receipt without replacement'
    fi
    rm -f "$tmp"
    [[ -f "$OUTPUT" && ! -L "$OUTPUT" && "$(file_mode "$OUTPUT")" == 600 &&
       "$(file_uid "$OUTPUT")" == "$(id -u)" && "$(file_links "$OUTPUT")" == 1 &&
       "$(hash_file "$OUTPUT")" == "$expected" ]] || die 'published receipt reread failed'
    sync -f "$OUTPUT" || die 'could not sync published receipt'
    sidecar_tmp=$(mktemp "${parent}/.node27-recovery-sidecar.XXXXXX") ||
        die 'could not allocate receipt sidecar temporary file'
    printf '%s\n' "$expected" > "$sidecar_tmp" || {
        rm -f "$sidecar_tmp"; die 'could not render receipt sidecar'; }
    if ! chmod 600 "$sidecar_tmp" || ! sync -f "$sidecar_tmp"; then
        rm -f "$sidecar_tmp"
        die 'could not protect receipt sidecar'
    fi
    if ! ln "$sidecar_tmp" "$sidecar"; then
        rm -f "$sidecar_tmp"
        die 'could not publish receipt sidecar without replacement'
    fi
    rm -f "$sidecar_tmp"
    [[ -f "$sidecar" && ! -L "$sidecar" && "$(file_mode "$sidecar")" == 600 &&
       "$(file_uid "$sidecar")" == "$(id -u)" && "$(file_links "$sidecar")" == 1 &&
       "$(<"$sidecar")" == "$expected" ]] || die 'published receipt sidecar reread failed'
    if ! sync -f "$sidecar" || ! sync -f "$parent"; then
        die 'could not durably commit receipt directory'
    fi
    private_path_ancestry_is_safe "$OUTPUT" || die 'output parent ancestry changed'
    printf 'RECEIPT %s SHA256 %s\n' "$OUTPUT" "$expected" >&2
}

resolve_self_and_transport()
{
    local self_dir
    SELF_PATH=$(realpath "$0") || die 'tool path is unavailable'
    [[ -f "$SELF_PATH" && ! -L "$SELF_PATH" ]] || die 'tool must be a regular file'
    TOOL_SHA256=$(hash_file "$SELF_PATH") || die 'tool sha256 is unavailable'
    if [[ -n "${NODE27_TEST_TRANSPORT_PATH:-}" ]]; then
        ((EUID != 0)) || die 'internal hostile-test transport is forbidden for root'
        self_dir=${SELF_PATH%/*}
        [[ "$NODE27_TEST_TRANSPORT_PATH" == "$self_dir/tests/mock_docker.sh" ]] ||
            die 'internal hostile-test transport is not the sealed sibling fixture'
        DOCKER_PATH=$NODE27_TEST_TRANSPORT_PATH
    else
        ((EUID == 0)) || die 'live node27 phases require root and the reviewed transport'
        DOCKER_PATH=$PRODUCTION_DOCKER_PATH
    fi
    DOCKER_PATH=$(realpath "$DOCKER_PATH") || die 'docker path is unavailable'
    [[ "$DOCKER_PATH" == /* && -f "$DOCKER_PATH" && -x "$DOCKER_PATH" && ! -L "$DOCKER_PATH" ]] ||
        die 'docker must resolve to an executable regular file'
    DOCKER_SHA256=$(hash_file "$DOCKER_PATH") || die 'docker sha256 is unavailable'
    DOCKER_OWNER_UID=$(file_uid "$DOCKER_PATH") || die 'docker owner is unavailable'
    DOCKER_OWNER_GID=$(file_gid "$DOCKER_PATH") || die 'docker group is unavailable'
    DOCKER_MODE=$(file_mode "$DOCKER_PATH") || die 'docker mode is unavailable'
    DOCKER_ANCESTRY=$(transport_ancestry_json "$DOCKER_PATH") || die 'docker ancestry is unsafe'
    if [[ -n "${NODE27_TEST_TRANSPORT_PATH:-}" ]]; then
        [[ "$DOCKER_SHA256" == "$TEST_DOCKER_SHA256" ]] ||
            die 'test transport bytes are not the sealed inert fixture'
    else
        [[ "$DOCKER_PATH" == "$PRODUCTION_DOCKER_PATH" &&
           "$DOCKER_OWNER_UID" == 0 && "$DOCKER_OWNER_GID" == 0 ]] ||
            die 'production docker transport is not the reviewed root-owned path'
        mode_is_not_group_or_world_writable "$DOCKER_MODE" ||
            die 'production docker transport is group/world writable'
        production_ancestry_is_safe "$DOCKER_ANCESTRY" ||
            die 'production docker ancestry is not root-owned and nonwritable'
    fi
    resolve_mutation_lock_contract
    if [[ -n "${NODE27_TEST_LOCK_ROOT:-}" ]]; then
        FLOCK_PATH='internal-test-mkdir-reservation'
        FLOCK_SHA256=$(printf '%s' "$FLOCK_PATH" | hash_stdin)
        FLOCK_OWNER_UID=$(id -u)
        FLOCK_OWNER_GID=$(id -g)
        FLOCK_MODE='builtin'
        FLOCK_ANCESTRY='[]'
    else
        FLOCK_PATH=$(realpath "$PRODUCTION_FLOCK_PATH") || die 'flock path is unavailable'
        [[ "$FLOCK_PATH" == "$PRODUCTION_FLOCK_PATH" && -f "$FLOCK_PATH" &&
           -x "$FLOCK_PATH" && ! -L "$FLOCK_PATH" ]] ||
            die 'flock must be the reviewed absolute executable'
        FLOCK_SHA256=$(hash_file "$FLOCK_PATH") || die 'flock sha256 is unavailable'
        FLOCK_OWNER_UID=$(file_uid "$FLOCK_PATH") || die 'flock owner is unavailable'
        FLOCK_OWNER_GID=$(file_gid "$FLOCK_PATH") || die 'flock group is unavailable'
        FLOCK_MODE=$(file_mode "$FLOCK_PATH") || die 'flock mode is unavailable'
        FLOCK_ANCESTRY=$(transport_ancestry_json "$FLOCK_PATH") ||
            die 'flock ancestry is unsafe'
        [[ "$FLOCK_OWNER_UID" == 0 && "$FLOCK_OWNER_GID" == 0 ]] ||
            die 'flock is not root owned'
        mode_is_not_group_or_world_writable "$FLOCK_MODE" ||
            die 'flock is group/world writable'
        production_ancestry_is_safe "$FLOCK_ANCESTRY" ||
            die 'flock ancestry is not root-owned and nonwritable'
    fi
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
        listwallets|getblockchaininfo|getnetworkinfo|getwalletinfo|getstakinginfo|getpowmininginfo|getpowclaimrecoveryinfo|gettransaction|gettxout|getrawmempool|getaddressinfo|getquantumkeyinventory|decoderawtransaction|testmempoolaccept)
            ;;
        resolveallshadowpowclaims)
            [[ "$PHASE" == audit || "$PHASE" == sign-only || "$PHASE" == relay ||
               "$PHASE" == reconcile-sign || "$PHASE" == reconcile-relay ]] ||
                die "resolveallshadowpowclaims is forbidden in phase $PHASE"
            ;;
        commitshadowpowclaimresolution)
            die "$RELAY_INTERFACE_BLOCKER"
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
        (.chainwork | test("^[0-9a-f]{64}$")) and .chainwork != ("0"*64) and
        (.blocks | type == "number" and floor == . and . > 0)
    ' >/dev/null <<< "$CHAIN" || die 'chain is not an exact synchronized unpruned mainnet view'
    jq -e --argjson version "$NETWORK_VERSION" --arg subversion "$SUBVERSION" '
        .version == $version and .subversion == $subversion and
        .networkactive == true and (.connections // 0) > 0 and
        (.connections_out // 0) > 0 and (.warnings // "") == ""
    ' >/dev/null <<< "$NETWORK" || die 'installed v30.1.4 network identity is not exact and connected'
}

stable_main_chain_cut()
{
    local before=$1 after=$2
    jq -e -n --argjson before "$before" --argjson after "$after" '
      def exact: {chain,blocks,headers,bestblockhash,chainwork,
        initialblockdownload,pruned,warnings};
      ($before | exact) == ($after | exact) and
      $before.chain == "main" and $before.blocks == $before.headers and
      $before.initialblockdownload == false and $before.pruned == false and
      ($before.warnings // "") == "" and
      ($before.bestblockhash | type == "string" and test("^[0-9a-f]{64}$")) and
      ($before.chainwork | type == "string" and test("^[0-9a-f]{64}$")) and
      $before.chainwork != ("0"*64) and
      ($before.blocks | type == "number" and floor == . and . > 0)
    ' >/dev/null
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
        if stable_main_chain_cut "$before" "$after" &&
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
    local key_sha quantum_sha component lock_paths
    key_sha=$(key_fingerprint "$WALLET_INFO")
    quantum_sha=$(jq -S -c . <<< "$QUANTUM_KEYS" | hash_stdin)
    component=$(jq -c --arg anchor "$ANCHOR_TXID" \
        '[.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)][0]' \
        <<< "$RECOVERY")
    lock_paths=$(mutation_lock_paths_json)
    jq -n -c \
        --arg contract "$CONTRACT" --arg phase audit --arg tool "$TOOL_SHA256" \
        --arg docker_path "$DOCKER_PATH" --arg docker_sha "$DOCKER_SHA256" \
        --argjson docker_uid "$DOCKER_OWNER_UID" --argjson docker_gid "$DOCKER_OWNER_GID" \
        --arg docker_mode "$DOCKER_MODE" --argjson docker_ancestry "$DOCKER_ANCESTRY" \
        --arg flock_path "$FLOCK_PATH" --arg flock_sha "$FLOCK_SHA256" \
        --argjson flock_uid "$FLOCK_OWNER_UID" --argjson flock_gid "$FLOCK_OWNER_GID" \
        --arg flock_mode "$FLOCK_MODE" --argjson flock_ancestry "$FLOCK_ANCESTRY" \
        --argjson lock_paths "$lock_paths" \
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
         transport:{path:$docker_path,sha256:$docker_sha,owner_uid:$docker_uid,
           owner_gid:$docker_gid,mode:$docker_mode,ancestry:$docker_ancestry},
         mutation_lock_contract:{paths:$lock_paths,
           order:"rollout_endpoint_cutover_pow_wallet_node27",required_for:["sign-only"],
           read_only_observation:["reconcile-sign","reconcile-relay"],
           utility:{path:$flock_path,sha256:$flock_sha,owner_uid:$flock_uid,
             owner_gid:$flock_gid,mode:$flock_mode,ancestry:$flock_ancestry}},
         installed_source:{commit:$source,network_version:300104,subversion:"/Blackcoin:30.1.4/"},
         runtime:$runtime,
         wallet:{name:$wallet,format:$wallet_info.format,walletversion:$wallet_info.walletversion,
           txcount:$wallet_info.txcount,key_fingerprint_sha256:$key_sha,
           quantum_inventory_sha256:$quantum_sha,payout_address:$payout,
           payout_address_unchanged_required:true,key_creation_authorized:false},
         chain:{height:$chain.blocks,headers:$chain.headers,tip:$chain.bestblockhash,
           chainwork:$chain.chainwork,initial_block_download:$chain.initialblockdownload},
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
           tool_sha256:$tool,transport:{path:$docker_path,sha256:$docker_sha,
             owner_uid:$docker_uid,owner_gid:$docker_gid,mode:$docker_mode,
             ancestry:$docker_ancestry},mutation_lock_paths:$lock_paths,
           lock_utility:{path:$flock_path,sha256:$flock_sha,owner_uid:$flock_uid,
             owner_gid:$flock_gid,mode:$flock_mode,ancestry:$flock_ancestry},
           node:27,service:"node27",
           container:"blackcoin-v4-gui-27",image_ref:$runtime.image_ref,image_id:$runtime.image_id,
           wallet:$wallet,claim_txid:$claim,anchor_txid:$anchor,anchor_vout:0,
           generation_fingerprint:$generation,plan_id:$preview.plan_id,
           active_tip:$preview.active_tip,active_height:$preview.active_height,
           chainwork:$chain.chainwork,
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
    local lock_paths
    lock_paths=$(mutation_lock_paths_json)
    require_receipt_file "$AUDIT_RECEIPT" "$AUDIT_SHA256" 'audit receipt' AUDIT_JSON
    require_tool_receipt_sidecar "$AUDIT_RECEIPT" "$AUDIT_SHA256" 'audit receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg docker_path "$DOCKER_PATH" --arg docker_sha "$DOCKER_SHA256" \
        --argjson docker_uid "$DOCKER_OWNER_UID" --argjson docker_gid "$DOCKER_OWNER_GID" \
        --arg docker_mode "$DOCKER_MODE" --argjson docker_ancestry "$DOCKER_ANCESTRY" \
        --arg flock_path "$FLOCK_PATH" --arg flock_sha "$FLOCK_SHA256" \
        --argjson flock_uid "$FLOCK_OWNER_UID" --argjson flock_gid "$FLOCK_OWNER_GID" \
        --arg flock_mode "$FLOCK_MODE" --argjson flock_ancestry "$FLOCK_ANCESTRY" \
        --argjson lock_paths "$lock_paths" \
        --arg source "$SOURCE_COMMIT" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --arg fee "$RECOVERY_FEE" '
        .schema == 1 and .contract == $contract and .phase == "audit" and
        .result == "approved_for_external_financial_review" and
        .mutation_performed == false and .tool_sha256 == $tool and
        .transport == {path:$docker_path,sha256:$docker_sha,owner_uid:$docker_uid,
          owner_gid:$docker_gid,mode:$docker_mode,ancestry:$docker_ancestry} and
        .mutation_lock_contract == {paths:$lock_paths,
          order:"rollout_endpoint_cutover_pow_wallet_node27",required_for:["sign-only"],
          read_only_observation:["reconcile-sign","reconcile-relay"],
          utility:{path:$flock_path,sha256:$flock_sha,owner_uid:$flock_uid,
            owner_gid:$flock_gid,mode:$flock_mode,ancestry:$flock_ancestry}} and
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
        (.chain | keys | sort) == (["chainwork","headers","height",
          "initial_block_download","tip"] | sort) and
        .chain.height == .chain.headers and .chain.initial_block_download == false and
        (.chain.tip | test("^[0-9a-f]{64}$")) and
        (.chain.chainwork | test("^[0-9a-f]{64}$")) and .chain.chainwork != ("0"*64) and
        .plan.transaction_count == 1 and .plan.fee_rate_sat_vb == 100 and
        .plan.vsize == 191 and .plan.fee_blk == $fee and
        .plan.max_fee_per_resolution_blk == $fee and .plan.max_total_fee_blk == $fee and
        .plan.other_inputs_allowed == false and .plan.change_output == false and
        .plan.new_key_or_address == false and .baseline.claims_submitted == 4 and
        (.plan.plan_id | test("^[0-9a-f]{64}$")) and
        (.plan.active_tip | test("^[0-9a-f]{64}$")) and
        (.plan.component_fingerprint | test("^[0-9a-f]{64}$")) and
        (.plan.unsigned_template_hash | test("^[0-9a-f]{64}$"))
    ' <<< "$AUDIT_JSON" >/dev/null || die 'audit receipt does not bind the exact node27 subject'
}

validate_sign_authority()
{
    local lock_paths
    lock_paths=$(mutation_lock_paths_json)
    require_receipt_file "$AUTHORITY_RECEIPT" "$AUTHORITY_SHA256" \
      'sign authority receipt' AUTHORITY_JSON
    jq -e --arg audit_sha "$AUDIT_SHA256" --arg tool "$TOOL_SHA256" \
        --arg transport_path "$DOCKER_PATH" --arg transport_sha "$DOCKER_SHA256" \
        --argjson transport_uid "$DOCKER_OWNER_UID" --argjson transport_gid "$DOCKER_OWNER_GID" \
        --arg transport_mode "$DOCKER_MODE" --argjson transport_ancestry "$DOCKER_ANCESTRY" \
        --arg flock_path "$FLOCK_PATH" --arg flock_sha "$FLOCK_SHA256" \
        --argjson flock_uid "$FLOCK_OWNER_UID" --argjson flock_gid "$FLOCK_OWNER_GID" \
        --arg flock_mode "$FLOCK_MODE" --argjson flock_ancestry "$FLOCK_ANCESTRY" \
        --argjson lock_paths "$lock_paths" \
        --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --arg fee "$RECOVERY_FEE" \
        --argjson audit "$AUDIT_JSON" '
        (keys | sort) == (["acknowledgements","active_height","active_tip","anchor_txid","anchor_vout",
          "audit_receipt_sha256","authority","claim_txid","component_fingerprint","container",
          "decision","fee_blk","fee_rate_sat_vb","generation_fingerprint","image_id","image_ref",
          "lock_utility","max_fee_per_resolution_blk","max_total_fee_blk","mutation_lock_paths",
          "node","plan_id","schema","service",
          "chainwork","tool_sha256","transaction_count","transport","unsigned_template_hash","wallet",
          "wallet_generation"] | sort) and
        .schema == 1 and .authority == "node27-v30.1.4-recovery-sign-only" and
        .decision == "authorize" and .audit_receipt_sha256 == $audit_sha and
        .tool_sha256 == $tool and .transport == {path:$transport_path,sha256:$transport_sha,
          owner_uid:$transport_uid,owner_gid:$transport_gid,mode:$transport_mode,
          ancestry:$transport_ancestry} and
        .mutation_lock_paths == $lock_paths and
        .lock_utility == {path:$flock_path,sha256:$flock_sha,owner_uid:$flock_uid,
          owner_gid:$flock_gid,mode:$flock_mode,ancestry:$flock_ancestry} and
        .node == 27 and .service == "node27" and .container == "blackcoin-v4-gui-27" and
        .image_ref == $audit.runtime.image_ref and .image_id == $audit.runtime.image_id and
        .wallet == "" and .claim_txid == $claim and .anchor_txid == $anchor and
        .anchor_vout == 0 and .generation_fingerprint == $generation and
        .plan_id == $audit.plan.plan_id and .active_tip == $audit.plan.active_tip and
        .active_height == $audit.plan.active_height and
        .chainwork == $audit.chain.chainwork and
        .wallet_generation == $audit.plan.wallet_generation and
        .component_fingerprint == $audit.plan.component_fingerprint and
        .unsigned_template_hash == $audit.plan.unsigned_template_hash and
        .transaction_count == 1 and .fee_rate_sat_vb == 100 and .fee_blk == $fee and
        .max_fee_per_resolution_blk == $fee and .max_total_fee_blk == $fee and
        .acknowledgements == {fee_and_conflict_risk:true,
          unbound_qqp2_may_revalidate:true,potential_quantum_payout_forfeiture:true,
          durable_draft_has_no_public_delete:true,no_relay_authority_in_this_phase:true,
          future_pow_claim_fees_not_capped_by_this_receipt:true,
          no_generic_transaction_rpc:true,no_fleet_expansion:true}
    ' <<< "$AUTHORITY_JSON" >/dev/null || die 'sign authority receipt is not exact'
}

assert_current_audit_matches_receipt()
{
    local current
    current=$(audit_receipt_json)
    jq -e -n --argjson old "$AUDIT_JSON" --argjson new "$current" '
        $old.tool_sha256 == $new.tool_sha256 and
        $old.transport == $new.transport and $old.runtime == $new.runtime and
        $old.mutation_lock_contract == $new.mutation_lock_contract and
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
    local result=$1 plan=$2 tip height wallet_generation component
    tip=$(jq -er '.bestblockhash' <<< "$CHAIN") || die 'sign result chain tip is unavailable'
    height=$(jq -er '.blocks' <<< "$CHAIN") || die 'sign result chain height is unavailable'
    wallet_generation=$(jq -er '.wallet_generation' <<< "$RECOVERY") ||
        die 'sign result wallet generation is unavailable'
    component=$(jq -er --arg anchor "$ANCHOR_TXID" \
      '[.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)][0].component_fingerprint' \
      <<< "$RECOVERY") || die 'sign result component fingerprint is unavailable'
    jq -e --arg plan "$plan" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --argjson fee "$RECOVERY_FEE" \
        --arg tip "$tip" --argjson height "$height" \
        --argjson wallet_generation "$wallet_generation" --arg component "$component" '
        .action == "sign_only" and .success == true and .stale_plan == false and
        .durable_state_changed == true and .durable_state_ambiguous == false and
        .plan_consumed == true and .acknowledged_plan_id == $plan and
        .acknowledged_active_tip == $tip and .acknowledged_active_height == $height and
        .acknowledged_wallet_generation == $wallet_generation and
        .acknowledged_total_fee == $fee and .signed_and_persisted == 1 and
        .relay_authority_granted == 0 and .broadcast == 0 and
        .already_in_mempool == 0 and .relay_deferred == 0 and
        (.actions | length) == 1 and (.actions[0] |
          .anchor == {txid:$anchor,vout:0} and .claim_txids == [$claim] and
          .generation_fingerprint == $generation and
          .component_fingerprint == $component and .fee == $fee and
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

relay_binding_json()
{
    local preview=$1 recovery=$2 chain=$3 txid=$4 signed_sha=$5 mempool_accept=$6
    local mempool_accept_sha=$7
    jq -e -c -n --argjson p "$preview" --argjson r "$recovery" --argjson c "$chain" \
        --argjson mempool_accept "$mempool_accept" \
        --arg mempool_accept_sha "$mempool_accept_sha" \
        --arg txid "$txid" --arg signed_sha "$signed_sha" --arg anchor "$ANCHOR_TXID" \
        --arg generation "$GENERATION_FINGERPRINT" --arg claim "$CLAIM_TXID" '
        ([$r.component_details[] |
          select(.anchor.txid == $anchor and .anchor.vout == 0)][0]) as $component |
        ($p.actions[0]) as $action |
        ($p.active_tip == $r.active_tip and $p.active_height == $r.active_height and
         $p.active_tip == $c.bestblockhash and $p.active_height == $c.blocks and
         $p.wallet_generation == $r.wallet_generation and
         $r.wallet_processed_tip == $c.bestblockhash and
         $r.wallet_processed_height == $c.blocks and
         $action.component_fingerprint == $component.component_fingerprint and
         $action.generation_fingerprint == $component.generation_fingerprint and
         $action.claim_txids == $component.claim_txids and
         $action.resolution_txid == $txid and $component.resolution_txids == [$txid] and
         $action.generation_fingerprint == $generation and $action.claim_txids == [$claim] and
         ($mempool_accept | type == "array" and length == 1 and
           .[0].txid == $txid and .[0].allowed == true and
           ((.[0] | keys | sort) == (["allowed","txid","vsize"] | sort)) and
           (.[0].vsize == 191))) as $bound |
        if $bound then
          {plan_id:$p.plan_id,active_tip:$p.active_tip,active_height:$p.active_height,
           chainwork:$c.chainwork,wallet_name:"",wallet_generation:$p.wallet_generation,
           wallet_processed_tip:$r.wallet_processed_tip,
           wallet_processed_height:$r.wallet_processed_height,
           anchor_txid:$anchor,anchor_vout:0,
           component_fingerprint:$action.component_fingerprint,
           generation_fingerprint:$action.generation_fingerprint,
           claim_txids:$action.claim_txids,lineage_head_txid:$txid,
           resolution_txid:$txid,signed_transaction_sha256:$signed_sha,
           testmempoolaccept:$mempool_accept,
           testmempoolaccept_sha256:$mempool_accept_sha}
        else error("relay binding does not match the stable signed component cut") end
    '
}

relay_binding_sha256()
{
    jq -S -c . <<< "$1" | hash_stdin
}

validate_post_sign_state()
{
    local txid=$1 baseline_txcount=$2 baseline_key=$3 baseline_quantum=$4 expected_hex_sha=$5
    local wallet mining staking recovery mempool quantum persisted key_after quantum_after
    local preview chain_before chain_after raw mempool_accept mempool_accept_sha
    chain_before=$(rpc getblockchaininfo) || die 'post-sign initial chain bracket failed'
    wallet=$(rpc getwalletinfo) || die 'post-sign wallet RPC failed'
    mining=$(rpc getpowmininginfo) || die 'post-sign PoW RPC failed'
    staking=$(rpc getstakinginfo) || die 'post-sign PoS RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'post-sign recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'post-sign mempool RPC failed'
    quantum=$(rpc getquantumkeyinventory) || die 'post-sign quantum inventory failed'
    preview=$(rpc resolveallshadowpowclaims "$(signed_preview_options)") ||
        die 'post-sign exact managed-byte preview failed'
    persisted=$(rpc gettransaction "$txid" false true) || die 'persisted resolution is unavailable'
    raw=$(jq -er '.hex' <<< "$persisted") || die 'persisted signed transaction hex is unavailable'
    [[ "$(printf '%s' "$raw" | hash_stdin)" == "$expected_hex_sha" ]] ||
        die 'persisted signed transaction bytes differ from sign-only result'
    mempool_accept=$(rpc testmempoolaccept "$(jq -cn --arg raw "$raw" '[$raw]')") ||
        die 'post-sign testmempoolaccept failed'
    mempool_accept=$(jq -S -c . <<< "$mempool_accept") ||
        die 'post-sign testmempoolaccept response is malformed'
    mempool_accept_sha=$(jq -S -c . <<< "$mempool_accept" | hash_stdin)
    jq -e --arg txid "$txid" 'type == "array" and length == 1 and
      .[0] == {txid:$txid,allowed:true,vsize:191}' >/dev/null <<< "$mempool_accept" ||
        die 'signed resolution is not exactly accepted by current mempool policy'
    chain_after=$(rpc getblockchaininfo) || die 'post-sign chain bracket failed'
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
    stable_main_chain_cut "$chain_before" "$chain_after" ||
        die 'chain changed during post-sign evidence cut'
    stable_main_chain_cut "$CHAIN" "$chain_after" ||
        die 'tip changed across sign-only evidence cut'
    validate_signed_preview "$preview" "$txid" "$recovery" "$chain_after"
    POST_WALLET=$wallet
    POST_MINING=$mining
    POST_STAKING=$staking
    POST_RECOVERY=$recovery
    POST_PREVIEW=$preview
    POST_CHAIN=$chain_after
    POST_MEMPOOL_ACCEPT=$mempool_accept
    POST_MEMPOOL_ACCEPT_SHA=$mempool_accept_sha
    POST_KEY_SHA=$key_after
    POST_QUANTUM_SHA=$quantum_after
}

run_sign_only()
{
    local plan options result txid hex decoded hex_sha baseline_txcount baseline_key baseline_quantum
    local relay_binding relay_binding_sha receipt
    [[ -n "$OUTPUT" ]] || die 'sign-only requires --output'
    validate_audit_receipt
    validate_sign_authority
    acquire_mutation_locks
    # Recheck the exact receipt bytes after acquiring every shared lock so a
    # pre-lock authority validation can never authorize a changed file.
    validate_audit_receipt
    validate_sign_authority
    collect_unsigned_audit
    assert_current_audit_matches_receipt
    plan=$(jq -r '.plan.plan_id' <<< "$AUDIT_JSON")
    baseline_txcount=$(jq -r '.wallet.txcount' <<< "$AUDIT_JSON")
    baseline_key=$(jq -r '.wallet.key_fingerprint_sha256' <<< "$AUDIT_JSON")
    baseline_quantum=$(jq -r '.wallet.quantum_inventory_sha256' <<< "$AUDIT_JSON")
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
    validate_post_sign_state "$txid" "$baseline_txcount" "$baseline_key" "$baseline_quantum" \
      "$hex_sha"
    assert_runtime_unchanged "$RUNTIME"
    relay_binding=$(relay_binding_json "$POST_PREVIEW" "$POST_RECOVERY" "$POST_CHAIN" \
      "$txid" "$hex_sha" "$POST_MEMPOOL_ACCEPT" "$POST_MEMPOOL_ACCEPT_SHA") ||
        die 'could not bind the signed relay plan to the stable component cut'
    relay_binding_sha=$(relay_binding_sha256 "$relay_binding")
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
        --arg audit_sha "$AUDIT_SHA256" --arg authority_sha "$AUTHORITY_SHA256" \
        --arg mutation_locks_sha "$MUTATION_LOCK_IDENTITIES_SHA256" \
        --argjson mutation_locks "$MUTATION_LOCK_IDENTITIES" \
        --arg txid "$txid" --arg hex_sha "$hex_sha" --arg fee "$RECOVERY_FEE" \
        --argjson runtime "$RUNTIME" --argjson transport "$(jq -c '.transport' <<< "$AUDIT_JSON")" \
        --argjson decoded "$decoded" \
        --argjson execution "$result" --argjson wallet "$POST_WALLET" \
        --argjson mining "$POST_MINING" --argjson staking "$POST_STAKING" \
        --argjson recovery "$POST_RECOVERY" --arg key_sha "$POST_KEY_SHA" \
        --arg quantum_sha "$POST_QUANTUM_SHA" --arg relay_sha "$relay_binding_sha" \
        --argjson relay_binding "$relay_binding" '
        {schema:1,contract:$contract,phase:"sign-only",result:"signed_nonrelayable_draft",
         mutation_performed:true,tool_sha256:$tool,audit_receipt_sha256:$audit_sha,
         financial_authority_receipt_sha256:$authority_sha,transport:$transport,
         mutation_locks:$mutation_locks,mutation_locks_sha256:$mutation_locks_sha,runtime:$runtime,
         subject:{claim_txid:"2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d",
           anchor_txid:"3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87",
           anchor_vout:0,generation_fingerprint:"0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860"},
         signed_transaction:{txid:$txid,hex_sha256:$hex_sha,decoded:$decoded,
           fee_blk:$fee,persisted:true,relay_authorized:false,in_mempool:false},
         relay_binding:$relay_binding,relay_plan_sha256:$relay_sha,
         execution:$execution,
         post_state:{wallet_txcount:$wallet.txcount,key_fingerprint_sha256:$key_sha,
           quantum_inventory_sha256:$quantum_sha,payout_address:$mining.payout_address,
           claims_submitted:$mining.claims_submitted,pow_enabled:$mining.enabled,
           pow_state:$mining.state,pow_hashrate:$mining.hashrate,
           pos_enabled:$staking.enabled,pos_staking:$staking.staking,pos_weight:$staking.weight,
           pending_manual_resolutions:$recovery.pending_manual_resolutions,
           database_outcome_ambiguous:$recovery.database_outcome_ambiguous},
         next_authority:{required:true,status:"blocked_on_successor_core_interface",
           authority:"node27-successor-targeted-recovery-relay",relay_eligible:false,
           interface_blocker:"installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding",
           exact_resolution_txid:$txid,sign_receipt_sha256:"REPLACE_WITH_SIGN_RECEIPT_SHA256",
           relay_plan_sha256:$relay_sha,durable_commit_receipt_reconstructable:false,
           recall_available:false,generic_sendrawtransaction_authorized:false,
           fleet_expansion_authorized:false}}
    ')
    write_receipt "$receipt"
}

validate_sign_receipt()
{
    local binding binding_sha lock_sha mempool_sha require_current=false lock_paths
    lock_paths=$(mutation_lock_paths_json)
    if [[ "$PHASE" == relay || "$PHASE" == reconcile-relay ]] &&
       ((${#MUTATION_LOCK_FDS[@]} > 0)); then
        require_current=true
    fi
    require_receipt_file "$SIGN_RECEIPT" "$SIGN_SHA256" 'sign receipt' SIGN_JSON
    require_tool_receipt_sidecar "$SIGN_RECEIPT" "$SIGN_SHA256" 'sign receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" --arg claim "$CLAIM_TXID" \
        --arg anchor "$ANCHOR_TXID" --arg generation "$GENERATION_FINGERPRINT" \
        --arg transport_path "$DOCKER_PATH" --arg transport_sha "$DOCKER_SHA256" \
        --argjson transport_uid "$DOCKER_OWNER_UID" --argjson transport_gid "$DOCKER_OWNER_GID" \
        --arg transport_mode "$DOCKER_MODE" --argjson transport_ancestry "$DOCKER_ANCESTRY" \
        --argjson mutation_locks "$MUTATION_LOCK_IDENTITIES" \
        --arg mutation_locks_sha "$MUTATION_LOCK_IDENTITIES_SHA256" \
        --argjson lock_paths "$lock_paths" --argjson require_current "$require_current" \
        --arg fee "$RECOVERY_FEE" '
        .schema == 1 and .contract == $contract and
        ((.phase == "sign-only" and .result == "signed_nonrelayable_draft" and
          .mutation_performed == true and (.mutation_observed // false) == false) or
         (.phase == "reconcile-sign" and
          .result == "reconciled_signed_nonrelayable_draft" and
          .mutation_performed == false and .mutation_observed == true and
          .reconciliation == {read_only:true,sign_rpc_invoked:false,
            relay_rpc_invoked:false,exact_tool_and_authority_hashes:true,
            ambiguous_state:false})) and
        .tool_sha256 == $tool and .subject.claim_txid == $claim and
        .transport == {path:$transport_path,sha256:$transport_sha,
          owner_uid:$transport_uid,owner_gid:$transport_gid,mode:$transport_mode,
          ancestry:$transport_ancestry} and
        ([.mutation_locks[].path] == $lock_paths) and
        (.mutation_locks_sha256 | test("^[0-9a-f]{64}$")) and
        (if $require_current then
           .mutation_locks == $mutation_locks and
           .mutation_locks_sha256 == $mutation_locks_sha
         else true end) and
        .subject.anchor_txid == $anchor and .subject.anchor_vout == 0 and
        .subject.generation_fingerprint == $generation and
        (.signed_transaction.txid | test("^[0-9a-f]{64}$")) and
        (.signed_transaction.hex_sha256 | test("^[0-9a-f]{64}$")) and
        .signed_transaction.fee_blk == $fee and .signed_transaction.persisted == true and
        .signed_transaction.relay_authorized == false and .signed_transaction.in_mempool == false and
        (.relay_binding | type == "object" and (keys | sort) ==
          (["active_height","active_tip","anchor_txid","anchor_vout","chainwork",
            "claim_txids","component_fingerprint","generation_fingerprint",
            "lineage_head_txid","plan_id","resolution_txid","signed_transaction_sha256",
            "testmempoolaccept","testmempoolaccept_sha256",
            "wallet_generation","wallet_name","wallet_processed_height",
            "wallet_processed_tip"] | sort)) and
        (.relay_plan_sha256 | test("^[0-9a-f]{64}$")) and
        .relay_binding.wallet_name == "" and
        .relay_binding.anchor_txid == $anchor and .relay_binding.anchor_vout == 0 and
        .relay_binding.generation_fingerprint == $generation and
        .relay_binding.claim_txids == [$claim] and
        .relay_binding.resolution_txid == .signed_transaction.txid and
        .relay_binding.lineage_head_txid == .signed_transaction.txid and
        .relay_binding.signed_transaction_sha256 == .signed_transaction.hex_sha256 and
        .relay_binding.testmempoolaccept ==
          [{txid:.signed_transaction.txid,allowed:true,vsize:191}] and
        (.relay_binding.testmempoolaccept_sha256 | test("^[0-9a-f]{64}$")) and
        .next_authority.status == "blocked_on_successor_core_interface" and
        .next_authority.authority == "node27-successor-targeted-recovery-relay" and
        .next_authority.relay_eligible == false and
        .next_authority.interface_blocker ==
          "installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding" and
        .next_authority.durable_commit_receipt_reconstructable == false and
        .post_state.claims_submitted == 4 and .post_state.pow_enabled == true and
        .post_state.pos_enabled == true and .post_state.pos_staking == true and
        .post_state.database_outcome_ambiguous == false
    ' <<< "$SIGN_JSON" >/dev/null || die 'sign receipt is not exact'
    binding=$(jq -c '.relay_binding' <<< "$SIGN_JSON")
    binding_sha=$(relay_binding_sha256 "$binding")
    [[ "$binding_sha" == "$(jq -r '.relay_plan_sha256' <<< "$SIGN_JSON")" ]] ||
        die 'sign receipt relay-plan hash is not canonical'
    mempool_sha=$(jq -S -c '.relay_binding.testmempoolaccept' <<< "$SIGN_JSON" | hash_stdin)
    [[ "$mempool_sha" == "$(jq -r '.relay_binding.testmempoolaccept_sha256' \
      <<< "$SIGN_JSON")" ]] || die 'sign receipt mempool-accept hash is not canonical'
    lock_sha=$(jq -S -c '.mutation_locks' <<< "$SIGN_JSON" | hash_stdin)
    [[ "$lock_sha" == "$(jq -r '.mutation_locks_sha256' <<< "$SIGN_JSON")" ]] ||
        die 'sign receipt mutation-lock hash is not canonical'
}

validate_relay_authority()
{
    local require_current=${1:-true} now
    now=$(date +%s)
    require_receipt_file "$AUTHORITY_RECEIPT" "$AUTHORITY_SHA256" \
      'relay authority receipt' AUTHORITY_JSON
    jq -e --arg sign_sha "$SIGN_SHA256" --arg tool "$TOOL_SHA256" \
        --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" --arg fee "$RECOVERY_FEE" \
        --argjson now "$now" --argjson require_current "$require_current" \
        --argjson sign "$SIGN_JSON" '
        (keys | sort) == (["acknowledgements","active_height","active_tip","anchor_txid","anchor_vout",
          "authority","authority_nonce","chainwork","claim_txid","component_fingerprint",
          "decision","expires_epoch","fee_blk","generation_fingerprint","image_id","image_ref",
          "mutation_lock_paths","mutation_locks_sha256","node","not_before_epoch","plan_id",
          "relay_plan_sha256","resolution_txid","schema",
          "service","sign_receipt_sha256","signed_transaction_sha256","tool_sha256",
          "testmempoolaccept_sha256","transaction_count","transport","wallet",
          "wallet_generation","wallet_processed_height",
          "wallet_processed_tip"] | sort) and
        .schema == 1 and
        .authority == "node27-v30.1.4-historical-relay-observation-context" and
        .decision == "observe_only" and .sign_receipt_sha256 == $sign_sha and
        .tool_sha256 == $tool and .node == 27 and .service == "node27" and
        .transport == $sign.transport and
        .mutation_lock_paths == [$sign.mutation_locks[].path] and
        .mutation_locks_sha256 == $sign.mutation_locks_sha256 and
        .image_ref == $sign.runtime.image_ref and .image_id == $sign.runtime.image_id and
        .wallet == "" and .claim_txid == $claim and .anchor_txid == $anchor and
        .anchor_vout == 0 and .resolution_txid == $sign.signed_transaction.txid and
        .plan_id == $sign.relay_binding.plan_id and
        .relay_plan_sha256 == $sign.relay_plan_sha256 and
        .active_tip == $sign.relay_binding.active_tip and
        .active_height == $sign.relay_binding.active_height and
        .chainwork == $sign.relay_binding.chainwork and
        .wallet_generation == $sign.relay_binding.wallet_generation and
        .wallet_processed_tip == $sign.relay_binding.wallet_processed_tip and
        .wallet_processed_height == $sign.relay_binding.wallet_processed_height and
        .component_fingerprint == $sign.relay_binding.component_fingerprint and
        .generation_fingerprint == $sign.relay_binding.generation_fingerprint and
        .signed_transaction_sha256 == $sign.signed_transaction.hex_sha256 and
        .testmempoolaccept_sha256 == $sign.relay_binding.testmempoolaccept_sha256 and
        (.authority_nonce | test("^[0-9a-f]{32}$")) and
        . as $authority |
        (.not_before_epoch | type == "number" and floor == . and . >= 0) and
        (.expires_epoch | type == "number" and floor == . and
          . > $authority.not_before_epoch and (. - $authority.not_before_epoch) <= 3600) and
        (if $require_current then .not_before_epoch <= $now and $now < .expires_epoch
         else true end) and
        .transaction_count == 1 and .fee_blk == $fee and
        .acknowledgements == {exact_signed_bytes_identified:true,no_mutation_authority:true,
          installed_relay_ineligible:true,observation_cannot_prove_commit_binding:true,
          expired_context_permitted_for_read_only_observation:true}
    ' <<< "$AUTHORITY_JSON" >/dev/null || die 'relay observation context is not exact'
}

validate_persisted_pre_relay()
{
    local txid=$1 expected_runtime=$2 expected_key=$3 expected_quantum=$4
    local wallet mining staking recovery mempool persisted preview key_sha quantum quantum_sha decoded
    local chain_before chain_after binding binding_sha signed_sha expected_binding raw
    local mempool_accept mempool_accept_sha
    assert_runtime_unchanged "$expected_runtime"
    chain_before=$(rpc getblockchaininfo) || die 'pre-relay initial chain bracket failed'
    wallet=$(rpc getwalletinfo) || die 'pre-relay wallet RPC failed'
    mining=$(rpc getpowmininginfo) || die 'pre-relay PoW RPC failed'
    staking=$(rpc getstakinginfo) || die 'pre-relay PoS RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'pre-relay recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'pre-relay mempool RPC failed'
    persisted=$(rpc gettransaction "$txid" false true) || die 'pre-relay signed tx is unavailable'
    raw=$(jq -er '.hex' <<< "$persisted") || die 'pre-relay signed tx hex is unavailable'
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
    signed_sha=$(jq -r '.signed_transaction.hex_sha256' <<< "$SIGN_JSON")
    [[ "$(printf '%s' "$raw" | hash_stdin)" == "$signed_sha" ]] ||
        die 'pre-relay persisted bytes differ from the signed receipt'
    mempool_accept=$(rpc testmempoolaccept "$(jq -cn --arg raw "$raw" '[$raw]')") ||
        die 'pre-relay testmempoolaccept failed'
    mempool_accept=$(jq -S -c . <<< "$mempool_accept") ||
        die 'pre-relay testmempoolaccept response is malformed'
    mempool_accept_sha=$(jq -S -c . <<< "$mempool_accept" | hash_stdin)
    preview=$(rpc resolveallshadowpowclaims "$(signed_preview_options)") ||
        die 'pre-relay exact managed-byte preview failed'
    chain_after=$(rpc getblockchaininfo) || die 'pre-relay ending chain bracket failed'
    stable_main_chain_cut "$chain_before" "$chain_after" ||
        die 'chain changed during pre-relay evidence cut'
    validate_signed_preview "$preview" "$txid" "$recovery" "$chain_after"
    binding=$(relay_binding_json "$preview" "$recovery" "$chain_after" "$txid" "$signed_sha" \
      "$mempool_accept" "$mempool_accept_sha") ||
        die 'current relay plan is not bound to the signed component cut'
    binding_sha=$(relay_binding_sha256 "$binding")
    expected_binding=$(jq -c '.relay_binding' <<< "$SIGN_JSON")
    jq -e -n --argjson expected "$expected_binding" --argjson current "$binding" \
        '$expected == $current' >/dev/null ||
        die 'relay plan, tip, wallet generation, or component drifted after signing'
    [[ "$binding_sha" == "$(jq -r '.relay_plan_sha256' <<< "$SIGN_JSON")" ]] ||
        die 'current relay plan hash differs from the signed receipt'
}

validate_relay_result()
{
    local result=$1 txid=$2 binding=$3
    jq -e --arg txid "$txid" --arg claim "$CLAIM_TXID" --arg anchor "$ANCHOR_TXID" \
        --argjson fee "$RECOVERY_FEE" --argjson binding "$binding" '
        .action == "commit_and_broadcast" and .success == true and
        .stale_plan == false and .durable_state_changed == true and
        .durable_state_ambiguous == false and .plan_consumed == true and
        .acknowledged_plan_id == $binding.plan_id and
        .acknowledged_active_tip == $binding.active_tip and
        .acknowledged_active_height == $binding.active_height and
        .acknowledged_wallet_generation == $binding.wallet_generation and
        .acknowledged_total_fee == $fee and .signed_and_persisted == 0 and
        .relay_authority_granted == 1 and (.actions | length) == 1 and
        (.broadcast + .already_in_mempool + .relay_deferred) == 1 and
        (.actions[0] | .anchor == {txid:$anchor,vout:0} and .claim_txids == [$claim] and
          .resolution_txid == $txid and .fee == $fee and .persisted == true and
          .component_fingerprint == $binding.component_fingerprint and
          .generation_fingerprint == $binding.generation_fingerprint and
          .claim_txids == $binding.claim_txids and
          .relay_authorized == true and
          (.status == "broadcast" or .status == "already_in_mempool" or .status == "relay_deferred"))
    ' >/dev/null <<< "$result" || die 'targeted relay RPC result exceeded exact authority'
}

run_relay()
{
    [[ -n "$OUTPUT" ]] || die 'relay requires --output'
    [[ "$INSTALLED_RELAY_ELIGIBLE" == false ]] ||
        die 'installed relay eligibility constant changed unexpectedly'
    die "$RELAY_INTERFACE_BLOCKER"
}

validate_relay_receipt()
{
    require_receipt_file "$RELAY_RECEIPT" "$RELAY_SHA256" 'relay receipt' RELAY_JSON
    require_tool_receipt_sidecar "$RELAY_RECEIPT" "$RELAY_SHA256" 'relay receipt'
    jq -e --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" --arg sign_sha "$SIGN_SHA256" \
        --argjson sign "$SIGN_JSON" '
        .schema == 1 and .contract == $contract and
        .phase == "relay" and .mutation_performed == true and
        (.mutation_observed // false) == false and .tool_sha256 == $tool and
        .sign_receipt_sha256 == $sign_sha and
        .resolution_txid == $sign.signed_transaction.txid and
        .mutation_locks == $sign.mutation_locks and
        .mutation_locks_sha256 == $sign.mutation_locks_sha256 and
        .relay_plan_sha256 == $sign.relay_plan_sha256 and
        .relay_binding == $sign.relay_binding and
        (.financial_authority_nonce | test("^[0-9a-f]{32}$")) and
        .execution.original_commit_result_available == true and
        .execution.acknowledged_plan_id == $sign.relay_binding.plan_id and
        .execution.acknowledged_active_tip == $sign.relay_binding.active_tip and
        .execution.acknowledged_active_height == $sign.relay_binding.active_height and
        .execution.acknowledged_wallet_generation == $sign.relay_binding.wallet_generation and
        (.result == "resolution_in_mempool" or .result == "resolution_confirmed" or
         .result == "original_claim_confirmed") and
        .containment == {exact_bytes_only:true,fee_bump_or_replacement:false,
          generic_sendrawtransaction:false,abandonment:false,fleet_expansion:false,
          propagated_bytes_recallable:false} and
        .final_acceptance.required_confirmations == 6 and
        .final_acceptance.pos_active_required == true and
        .final_acceptance.positive_hashrate_required == true and
        .final_acceptance.claims_submitted_must_exceed == 4
    ' <<< "$RELAY_JSON" >/dev/null || die 'relay receipt is not exact'
}

run_reconcile_sign()
{
    local expected_runtime baseline_txcount baseline_key baseline_quantum current_recovery
    local txid persisted raw decoded hex_sha relay_binding relay_binding_sha receipt
    [[ -n "$OUTPUT" ]] || die 'reconcile-sign requires --output'
    validate_audit_receipt
    validate_sign_authority
    acquire_mutation_locks
    validate_audit_receipt
    validate_sign_authority
    expected_runtime=$(jq -c '.runtime' <<< "$AUDIT_JSON")
    RUNTIME=$(runtime_snapshot)
    jq -e -n --argjson expected "$expected_runtime" --argjson current "$RUNTIME" \
      '$expected == $current' >/dev/null || die 'runtime changed before sign reconciliation'
    CHAIN=$(rpc getblockchaininfo) || die 'sign reconciliation chain RPC failed'
    NETWORK=$(rpc getnetworkinfo) || die 'sign reconciliation network RPC failed'
    validate_chain_network
    jq -e -n --argjson chain "$CHAIN" --argjson audit "$AUDIT_JSON" '
      $chain.bestblockhash == $audit.chain.tip and
      $chain.blocks == $audit.chain.height and
      $chain.chainwork == $audit.chain.chainwork
    ' >/dev/null || die 'sign reconciliation is not on the authorized audit cut'
    current_recovery=$(rpc getpowclaimrecoveryinfo true) ||
        die 'sign reconciliation recovery RPC failed'
    txid=$(jq -er --arg anchor "$ANCHOR_TXID" '
      [.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0)] |
      select(length == 1) | .[0] | select(.classification == "resolution_pending") |
      .resolution_txids | select(length == 1) | .[0]
    ' <<< "$current_recovery") ||
        die 'sign reconciliation found no single exact persisted resolution'
    persisted=$(rpc gettransaction "$txid" false true) ||
        die 'sign reconciliation cannot read persisted transaction'
    raw=$(jq -er '.hex' <<< "$persisted") || die 'sign reconciliation raw bytes are absent'
    decoded=$(jq -ec '.decoded' <<< "$persisted") || die 'sign reconciliation decode is absent'
    validate_signed_transaction "$decoded" "$txid"
    hex_sha=$(printf '%s' "$raw" | hash_stdin)
    baseline_txcount=$(jq -r '.wallet.txcount' <<< "$AUDIT_JSON")
    baseline_key=$(jq -r '.wallet.key_fingerprint_sha256' <<< "$AUDIT_JSON")
    baseline_quantum=$(jq -r '.wallet.quantum_inventory_sha256' <<< "$AUDIT_JSON")
    validate_post_sign_state "$txid" "$baseline_txcount" "$baseline_key" "$baseline_quantum" \
      "$hex_sha"
    assert_runtime_unchanged "$RUNTIME"
    relay_binding=$(relay_binding_json "$POST_PREVIEW" "$POST_RECOVERY" "$POST_CHAIN" \
      "$txid" "$hex_sha" "$POST_MEMPOOL_ACCEPT" "$POST_MEMPOOL_ACCEPT_SHA") ||
        die 'sign reconciliation could not bind current persisted bytes'
    relay_binding_sha=$(relay_binding_sha256 "$relay_binding")
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
      --arg audit_sha "$AUDIT_SHA256" --arg authority_sha "$AUTHORITY_SHA256" \
      --arg mutation_locks_sha "$MUTATION_LOCK_IDENTITIES_SHA256" \
      --argjson mutation_locks "$MUTATION_LOCK_IDENTITIES" --arg txid "$txid" \
      --arg hex_sha "$hex_sha" --arg fee "$RECOVERY_FEE" --argjson runtime "$RUNTIME" \
      --argjson transport "$(jq -c '.transport' <<< "$AUDIT_JSON")" --argjson decoded "$decoded" \
      --argjson wallet "$POST_WALLET" --argjson mining "$POST_MINING" \
      --argjson staking "$POST_STAKING" --argjson recovery "$POST_RECOVERY" \
      --arg key_sha "$POST_KEY_SHA" --arg quantum_sha "$POST_QUANTUM_SHA" \
      --arg relay_sha "$relay_binding_sha" --argjson relay_binding "$relay_binding" '
      {schema:1,contract:$contract,phase:"reconcile-sign",
       result:"reconciled_signed_nonrelayable_draft",mutation_performed:false,
       mutation_observed:true,tool_sha256:$tool,audit_receipt_sha256:$audit_sha,
       financial_authority_receipt_sha256:$authority_sha,transport:$transport,
       mutation_locks:$mutation_locks,mutation_locks_sha256:$mutation_locks_sha,runtime:$runtime,
       subject:{claim_txid:"2e76269d688a5c218703b800516a9c0b0b2757d5077a14c84a6473e33006103d",
         anchor_txid:"3e5437d71a2ba10e7cf1ab7b02ec458847d081a97041efd1e5336660b22cde87",
         anchor_vout:0,generation_fingerprint:"0699e87473f8595f3ca9663ba5f8f3212a51fdab4f4aed62a4bea9a3f70ef860"},
       signed_transaction:{txid:$txid,hex_sha256:$hex_sha,decoded:$decoded,
         fee_blk:$fee,persisted:true,relay_authorized:false,in_mempool:false},
       relay_binding:$relay_binding,relay_plan_sha256:$relay_sha,
       execution:{reconstructed_read_only:true,original_sign_result_available:false,
         persisted_bytes_exact:true},
       post_state:{wallet_txcount:$wallet.txcount,key_fingerprint_sha256:$key_sha,
         quantum_inventory_sha256:$quantum_sha,payout_address:$mining.payout_address,
         claims_submitted:$mining.claims_submitted,pow_enabled:$mining.enabled,
         pow_state:$mining.state,pow_hashrate:$mining.hashrate,
         pos_enabled:$staking.enabled,pos_staking:$staking.staking,pos_weight:$staking.weight,
         pending_manual_resolutions:$recovery.pending_manual_resolutions,
         database_outcome_ambiguous:$recovery.database_outcome_ambiguous},
       reconciliation:{read_only:true,sign_rpc_invoked:false,relay_rpc_invoked:false,
         exact_tool_and_authority_hashes:true,ambiguous_state:false},
       next_authority:{required:true,status:"blocked_on_successor_core_interface",
         authority:"node27-successor-targeted-recovery-relay",relay_eligible:false,
         interface_blocker:"installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding",
         exact_resolution_txid:$txid,sign_receipt_sha256:"REPLACE_WITH_SIGN_RECEIPT_SHA256",
         relay_plan_sha256:$relay_sha,durable_commit_receipt_reconstructable:false,
         recall_available:false,generic_sendrawtransaction_authorized:false,
         fleet_expansion_authorized:false}}
    ')
    write_receipt "$receipt"
}

run_reconcile_relay()
{
    local txid expected_runtime recovery mempool resolution claim chain_before chain_after
    local network_state authority_nonce receipt result_name raw decoded expected_raw_sha
    [[ -n "$OUTPUT" ]] || die 'reconcile-relay requires --output'
    validate_sign_receipt
    validate_relay_authority false
    acquire_mutation_locks
    validate_sign_receipt
    validate_relay_authority false
    txid=$(jq -r '.signed_transaction.txid' <<< "$SIGN_JSON")
    expected_runtime=$(jq -c '.runtime' <<< "$SIGN_JSON")
    assert_runtime_unchanged "$expected_runtime"
    chain_before=$(rpc getblockchaininfo) || die 'relay reconciliation chain-open RPC failed'
    recovery=$(rpc getpowclaimrecoveryinfo true) || die 'relay reconciliation recovery RPC failed'
    mempool=$(rpc getrawmempool) || die 'relay reconciliation mempool RPC failed'
    resolution=$(rpc gettransaction "$txid" false true) ||
        die 'relay reconciliation exact resolution is unavailable'
    raw=$(jq -er '.hex' <<< "$resolution") ||
        die 'relay reconciliation exact raw transaction is unavailable'
    decoded=$(jq -ec '.decoded' <<< "$resolution") ||
        die 'relay reconciliation decoded transaction is unavailable'
    validate_signed_transaction "$decoded" "$txid"
    expected_raw_sha=$(jq -r '.signed_transaction.hex_sha256' <<< "$SIGN_JSON")
    [[ "$(printf '%s' "$raw" | hash_stdin)" == "$expected_raw_sha" ]] ||
        die 'relay reconciliation observed different persisted bytes'
    claim=$(rpc gettransaction "$CLAIM_TXID" false true) ||
        die 'relay reconciliation original claim is unavailable'
    chain_after=$(rpc getblockchaininfo) || die 'relay reconciliation chain-close RPC failed'
    stable_main_chain_cut "$chain_before" "$chain_after" ||
        die 'chain changed during relay reconciliation cut'
    jq -e --arg txid "$txid" --arg anchor "$ANCHOR_TXID" --argjson chain "$chain_after" \
      --argjson binding "$(jq -c '.relay_binding' <<< "$SIGN_JSON")" '
      .database_outcome_ambiguous == false and .active_tip == $chain.bestblockhash and
      .active_height == $chain.blocks and .wallet_processed_tip == $chain.bestblockhash and
      .wallet_processed_height == $chain.blocks and
      .wallet_generation == $binding.wallet_generation and
      ([.component_details[] | select(.anchor.txid == $anchor and .anchor.vout == 0 and
        .component_fingerprint == $binding.component_fingerprint and
        .generation_fingerprint == $binding.generation_fingerprint and
        .claim_txids == $binding.claim_txids and .resolution_txids == [$txid]) |
        .nodes[] | select(.txid == $txid and .kind == "managed_resolution" and
          .resolution_metadata_valid == true and .resolution_relay_authorized == true)] |
        length) == 1
    ' >/dev/null <<< "$recovery" ||
        die 'relay reconciliation lacks exact durable relay authority metadata'
    network_state=$(jq -n -r --arg txid "$txid" --argjson mempool "$mempool" \
      --argjson resolution "$resolution" --argjson claim "$claim" '
      if ($resolution.confirmations // 0) > 0 then "resolution_confirmed"
      elif ($claim.confirmations // 0) > 0 then "original_claim_confirmed"
      elif ($mempool | index($txid)) != null then "resolution_in_mempool"
      else "AMBIGUOUS_CONTAINED" end')
    authority_nonce=$(jq -r '.authority_nonce' <<< "$AUTHORITY_JSON")
    if [[ "$network_state" == AMBIGUOUS_CONTAINED ]]; then
        result_name=AMBIGUOUS_CONTAINED
    else
        result_name=EXACT_BYTES_OBSERVED_UNATTRIBUTED
    fi
    receipt=$(jq -n -c --arg contract "$CONTRACT" --arg tool "$TOOL_SHA256" \
      --arg sign_sha "$SIGN_SHA256" --arg authority_sha "$AUTHORITY_SHA256" \
      --arg authority_nonce "$authority_nonce" --arg txid "$txid" --arg network "$result_name" \
      --arg disposition "$network_state" \
      --arg mutation_locks_sha "$MUTATION_LOCK_IDENTITIES_SHA256" \
      --argjson mutation_locks "$MUTATION_LOCK_IDENTITIES" --argjson runtime "$expected_runtime" \
      --arg relay_plan_sha "$(jq -r '.relay_plan_sha256' <<< "$SIGN_JSON")" \
      --argjson relay_binding "$(jq -c '.relay_binding' <<< "$SIGN_JSON")" \
      --argjson pre_chain "$chain_before" --argjson post_chain "$chain_after" \
      --argjson recovery "$recovery" --argjson resolution "$resolution" --argjson claim "$claim" '
      {schema:1,contract:$contract,phase:"reconcile-relay-observation",result:$network,
       mutation_performed:false,mutation_observed:($network != "AMBIGUOUS_CONTAINED"),
       tool_sha256:$tool,sign_receipt_sha256:$sign_sha,
       historical_observation_context_sha256:$authority_sha,runtime:$runtime,
       historical_context_nonce:$authority_nonce,resolution_txid:$txid,
       mutation_locks:$mutation_locks,mutation_locks_sha256:$mutation_locks_sha,
       relay_plan_sha256:$relay_plan_sha,relay_binding:$relay_binding,
       pre_relay_chain:$pre_chain,
       execution:{reconstructed_read_only:true,original_commit_result_available:false,
         commit_acknowledgements_available:false,authorized_commit_proven:false},
       post_relay_chain:$post_chain,
       post_relay:{recovery:$recovery,resolution:$resolution,original_claim:$claim},
       reconciliation:{read_only:true,sign_rpc_invoked:false,relay_rpc_invoked:false,
         exact_tool_and_historical_authority_hashes:true,
         authority_time_validated_for_mutation:false,
         admissible_as_relay_receipt:false,
         ambiguous_state:($network == "AMBIGUOUS_CONTAINED")},
       observation:{network_disposition:$disposition,
         exact_bytes_observed:($disposition != "AMBIGUOUS_CONTAINED"),
         attribution_to_authorized_commit:false,consumed_plan_identity_reconstructable:false,
         installed_relay_eligible:false,
         interface_blocker:"installed-v30.1.4-commit-does-not-consume-external-plan-tip-wallet-component-binding"},
       containment:{exact_bytes_only:true,fee_bump_or_replacement:false,
         generic_sendrawtransaction:false,abandonment:false,fleet_expansion:false,
         propagated_bytes_recallable:false},
       final_acceptance:{required_confirmations:6,pos_active_required:true,
         positive_hashrate_required:true,claims_submitted_must_exceed:4}}
    ')
    write_receipt "$receipt"
    [[ "$network_state" != AMBIGUOUS_CONTAINED ]] ||
        die 'relay outcome is AMBIGUOUS_CONTAINED; observe only the exact reviewed txid'
}

run_verify_final()
{
    [[ -n "$OUTPUT" ]] || die 'verify-final requires --output'
    [[ "$INSTALLED_RELAY_ELIGIBLE" == false ]] ||
        die 'installed relay eligibility constant changed unexpectedly'
    die 'final acceptance is unavailable because installed-v30.1.4 relay is nondeployable'
}

parse_args()
{
    if (($# > 0)); then
        case "$1" in
            audit|sign-only|relay|reconcile-sign|reconcile-relay|verify-final) PHASE=$1; shift ;;
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
        reconcile-sign)
            [[ -n "$AUDIT_RECEIPT" && -n "$AUDIT_SHA256" &&
               -n "$AUTHORITY_RECEIPT" && -n "$AUTHORITY_SHA256" ]] ||
                die 'reconcile-sign requires exact audit and original sign-authority receipts'
            [[ -z "$SIGN_RECEIPT$SIGN_SHA256$RELAY_RECEIPT$RELAY_SHA256" ]] ||
                die 'reconcile-sign rejects relay or prior sign receipts'
            run_reconcile_sign
            ;;
        reconcile-relay)
            [[ -n "$SIGN_RECEIPT" && -n "$SIGN_SHA256" &&
               -n "$AUTHORITY_RECEIPT" && -n "$AUTHORITY_SHA256" ]] ||
                die 'reconcile-relay requires exact sign and historical observation-context receipts'
            [[ -z "$AUDIT_RECEIPT$AUDIT_SHA256$RELAY_RECEIPT$RELAY_SHA256" ]] ||
                die 'reconcile-relay rejects audit and prior relay receipt arguments'
            run_reconcile_relay
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
