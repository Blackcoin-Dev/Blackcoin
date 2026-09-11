#!/bin/sh
# shellcheck shell=bash
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Direct execution is the only supported entrypoint. Re-enter through a clean,
# fixed interpreter before parsing any Bashism; caller-controlled PATH,
# BASH_ENV, exported functions, proxy, CA, Python, Git, and Docker variables
# therefore do not cross the trust boundary.
BOOTSTRAP_STAT=/usr/bin/stat
BOOTSTRAP_ENV=/usr/bin/env
BOOTSTRAP_BASH=/bin/bash
bootstrap_fail()
{
    printf 'v30.1.5 candidate publication failed: %s\n' "$*" >&2
    exit 1
}
if [ ! -f "$BOOTSTRAP_STAT" ] || [ -L "$BOOTSTRAP_STAT" ] ||
    [ ! -x "$BOOTSTRAP_STAT" ]; then
    bootstrap_fail 'fixed bootstrap stat is unsafe'
fi
if [ ! -f "$BOOTSTRAP_ENV" ] || [ -L "$BOOTSTRAP_ENV" ] ||
    [ ! -x "$BOOTSTRAP_ENV" ]; then
    bootstrap_fail 'fixed bootstrap env is unsafe'
fi
if [ ! -f "$BOOTSTRAP_BASH" ] || [ -L "$BOOTSTRAP_BASH" ] ||
    [ ! -x "$BOOTSTRAP_BASH" ]; then
    bootstrap_fail 'fixed bootstrap bash is unsafe'
fi
for bootstrap_path in "$BOOTSTRAP_STAT" "$BOOTSTRAP_ENV" "$BOOTSTRAP_BASH"; do
    if bootstrap_metadata=$(
        "$BOOTSTRAP_STAT" -c '%u %g %a' -- "$bootstrap_path" 2>/dev/null
    ); then
        :
    else
        bootstrap_metadata=$(
            "$BOOTSTRAP_STAT" -f '%u %g %Lp' -- "$bootstrap_path" 2>/dev/null
        ) || bootstrap_fail 'fixed bootstrap metadata is unavailable'
    fi
    bootstrap_uid=${bootstrap_metadata%% *}
    bootstrap_rest=${bootstrap_metadata#* }
    bootstrap_gid=${bootstrap_rest%% *}
    bootstrap_mode=${bootstrap_rest#* }
    if [ "$bootstrap_mode" = "$bootstrap_rest" ] ||
        [ "$bootstrap_uid:$bootstrap_gid" != 0:0 ]; then
        bootstrap_fail 'fixed bootstrap executable is not root-owned'
    fi
    case "$bootstrap_mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
        *) bootstrap_fail 'fixed bootstrap executable mode is malformed' ;;
    esac
    case "$bootstrap_mode" in
        *[2367][0-7]|*[0-7][2367])
            bootstrap_fail 'fixed bootstrap executable is group/world writable'
            ;;
    esac
done
bootstrap_reexec=0
[ "${V3015_FIXED_BASH_BOOTSTRAP:-}" = 1 ] || bootstrap_reexec=1
[ "${BASH:-}" = /bin/bash ] || bootstrap_reexec=1
if [ -e "/proc/$$/exe" ] && [ ! "/proc/$$/exe" -ef "$BOOTSTRAP_BASH" ]; then
    bootstrap_reexec=1
fi
if [ "$bootstrap_reexec" -eq 1 ]; then
    exec "$BOOTSTRAP_ENV" -i \
        HOME=/var/empty LC_ALL=C \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        TZ=UTC V3015_FIXED_BASH_BOOTSTRAP=1 \
        "$BOOTSTRAP_BASH" --noprofile --norc "$0" "$@"
fi
unset bootstrap_path bootstrap_metadata bootstrap_rest bootstrap_uid bootstrap_gid
unset bootstrap_mode bootstrap_reexec
# END POSIX BOOTSTRAP

# Verify a GitHub Actions candidate artifact offline by default. The live path
# burns one complete, time-limited authority before any Docker or registry
# mutation and emits rollout authority only after exact remote-byte equality.

set -Eeuo pipefail
umask 077
export TZ=UTC

SCRIPT_SOURCE=${BASH_SOURCE[0]}
case "$SCRIPT_SOURCE" in
    */*) SCRIPT_DIRECTORY=${SCRIPT_SOURCE%/*} ;;
    *) SCRIPT_DIRECTORY=. ;;
esac
PACKAGE_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIRECTORY" && pwd -P) || exit 1
readonly PACKAGE_ROOT
REPO_ROOT=$(CDPATH='' cd -P -- "$PACKAGE_ROOT/../../.." && pwd -P) || exit 1
readonly REPO_ROOT
readonly VERIFY="$PACKAGE_ROOT/verify_candidate_publication.py"
readonly REQUEST=${1:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly OUTPUT=${2:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly LOCK=/run/blackcoin-v30.1.5-candidate-publication.lock
readonly EXPECTED_REPOSITORY=qqblackcoin/blackcoin-v4-gui
readonly EXPECTED_REGISTRY_HOST=registry-1.docker.io
readonly EXPECTED_CREDENTIAL_HOST=docker.io
readonly MAX_REGISTRY_RESPONSE_BYTES=33554432
readonly CLEAN_HOME=/var/empty
LOCAL_REF=
TARGET_REF=
CONTAINER_ID=
CREATED_LOCAL=0
CREATED_CONTAINER=0
LIVE_MODE=0
LIVE_PACKAGE_LEDGER=

fail()
{
    printf 'v30.1.5 candidate publication failed: %s\n' "$*" >&2
    exit 1
}

clean_exec()
{
    /usr/bin/env -i HOME="$CLEAN_HOME" LC_ALL=C PATH="$PATH" TZ=UTC "$@"
}

python_exec()
{
    if ((LIVE_MODE == 1)); then
        [[ "$(live_package_ledger)" == "$LIVE_PACKAGE_LEDGER" ]] ||
            fail 'protected live publication tooling changed'
    fi
    clean_exec "$PYTHON" -I -B "$@"
}

cleanup()
{
    local status=$?
    trap - EXIT INT TERM
    if ((CREATED_CONTAINER == 1)) && [[ -n "$CONTAINER_ID" && -n "${DOCKER:-}" &&
       -n "${TIMEOUT:-}" ]]; then
        "$TIMEOUT" --signal=TERM --kill-after=30s 120s \
            /usr/bin/env -i HOME="$CLEAN_HOME" LC_ALL=C PATH="$PATH" TZ=UTC \
            DOCKER_HOST=unix:///var/run/docker.sock \
            "$DOCKER" container rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi
    if ((status != 0)) && ((CREATED_LOCAL == 1)) &&
       [[ -n "$LOCAL_REF" && -n "${DOCKER:-}" && -n "${TIMEOUT:-}" ]]; then
        "$TIMEOUT" --signal=TERM --kill-after=30s 120s \
            /usr/bin/env -i HOME="$CLEAN_HOME" LC_ALL=C PATH="$PATH" TZ=UTC \
            DOCKER_HOST=unix:///var/run/docker.sock \
            "$DOCKER" image rm "$LOCAL_REF" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_package()
{
    local actual expected
    [[ -d "$PACKAGE_ROOT/tests" && ! -L "$PACKAGE_ROOT/tests" &&
       -f "$PACKAGE_ROOT/SHA256SUMS" && ! -L "$PACKAGE_ROOT/SHA256SUMS" ]] || return 1
    actual=$(cd "$PACKAGE_ROOT" && "$FIND" . -type f ! -path './SHA256SUMS' -print | "$SORT")
    # shellcheck disable=SC2016
    expected=$("$AWK" 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); print "./" name
    }' "$PACKAGE_ROOT/SHA256SUMS" | "$SORT")
    [[ "$actual" == "$expected" ]] || return 1
    [[ -z "$("$FIND" "$PACKAGE_ROOT" -type l -print -quit)" &&
       -z "$("$FIND" "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    (cd "$PACKAGE_ROOT" && "$SHA256SUM" --strict --check SHA256SUMS >/dev/null)
}

# Bootstrap from the operating system's fixed stat path. No PATH-selected
# executable is invoked before every other tool (including Python) is proven a
# root-owned, non-symlink regular file without group/world write permission.
readonly STAT=/usr/bin/stat
readonly READLINK=/usr/bin/readlink
[[ -f "$STAT" && ! -L "$STAT" ]] || fail 'fixed system stat is absent or unsafe'
[[ -f "$READLINK" && ! -L "$READLINK" ]] ||
    fail 'fixed system readlink is absent or unsafe'
if "$STAT" -c '%u %g %a %h' -- "$STAT" >/dev/null 2>&1; then
    readonly STAT_STYLE=gnu
else
    "$STAT" -f '%u %g %Lp %l' -- "$STAT" >/dev/null 2>&1 ||
        fail 'fixed system stat cannot report safe metadata'
    readonly STAT_STYLE=bsd
fi

file_metadata()
{
    if [[ "$STAT_STYLE" == gnu ]]; then
        "$STAT" -c '%u %g %a %h' -- "$1"
    else
        "$STAT" -f '%u %g %Lp %l' -- "$1"
    fi
}

file_identity()
{
    if [[ "$STAT_STYLE" == gnu ]]; then
        "$STAT" -c '%d %i %s %Y %Z' -- "$1"
    else
        "$STAT" -f '%d %i %z %m %c' -- "$1"
    fi
}

read -r stat_uid stat_gid stat_mode stat_links <<<"$(file_metadata "$STAT")"
[[ "$stat_uid:$stat_gid" == 0:0 && "$stat_mode" =~ ^[0-7]{3,4}$ &&
   "$stat_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'fixed system stat ownership or mode is malformed'
(( (8#$stat_mode & 8#22) == 0 )) || fail 'fixed system stat is group/world writable'

read -r readlink_uid readlink_gid readlink_mode readlink_links \
    <<<"$(file_metadata "$READLINK")"
[[ "$readlink_uid:$readlink_gid" == 0:0 && "$readlink_mode" =~ ^[0-7]{3,4}$ &&
   "$readlink_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'fixed system readlink ownership or mode is malformed'
(( (8#$readlink_mode & 8#22) == 0 )) ||
    fail 'fixed system readlink is group/world writable'

safe_system_parent_chain()
{
    local path=$1 parent prefix=/ component metadata uid gid mode links
    parent=${path%/*}
    [[ "$parent" == /* ]] || return 1
    IFS=/ read -r -a components <<<"${parent#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
        prefix=${prefix%/}/$component
        [[ -d "$prefix" && ! -L "$prefix" ]] || return 1
        metadata=$(file_metadata "$prefix") || return 1
        read -r uid gid mode links <<<"$metadata"
        [[ "$uid:$gid" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ &&
           "$links" =~ ^[1-9][0-9]*$ ]] || return 1
        (( (8#$mode & 8#22) == 0 )) || return 1
    done
}

safe_system_tool()
{
    local name=$1 path selected target parent base physical_parent
    local metadata identity_before identity_after uid gid mode links seen=: index
    selected=$(type -P -- "$name") || return 1
    [[ "$selected" == /* ]] || return 1
    path=$selected
    for ((index = 0; index < 32; ++index)); do
        parent=${path%/*}
        base=${path##*/}
        [[ "$parent" == /* && -n "$base" ]] || return 1
        physical_parent=$(CDPATH='' cd -P -- "$parent" && pwd -P) || return 1
        path=${physical_parent%/}/$base
        [[ "$seen" != *":$path:"* ]] || return 1
        seen+=$path:
        if [[ -L "$path" ]]; then
            safe_system_parent_chain "$path" || return 1
            metadata=$(file_metadata "$path") || return 1
            read -r uid gid mode links <<<"$metadata"
            # Symlink mode bits are normally 0777 and do not grant access.
            # Bind the protected parent, root owner, inode, and target text;
            # the resolved terminal bytes carry the non-writable mode gate.
            [[ "$uid:$gid" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ &&
               "$links" =~ ^[1-9][0-9]*$ ]] || return 1
            identity_before=$(file_identity "$path") || return 1
            target=$("$READLINK" "$path") || return 1
            [[ -n "$target" ]] || return 1
            identity_after=$(file_identity "$path") || return 1
            [[ "$identity_before" == "$identity_after" ]] || return 1
            if [[ "$target" == /* ]]; then
                path=$target
            else
                path=${physical_parent%/}/$target
            fi
            continue
        fi
        break
    done
    ((index < 32)) || return 1
    [[ "$path" == /bin/* || "$path" == /sbin/* || "$path" == /usr/* ]] || return 1
    safe_system_parent_chain "$path" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata=$(file_metadata "$path") || return 1
    identity_before=$(file_identity "$path") || return 1
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ &&
       "$links" =~ ^[1-9][0-9]*$ ]] ||
        return 1
    (( (8#$mode & 8#22) == 0 )) || return 1
    # Re-resolve the selected name and require the same terminal bytes before use.
    [[ "$(type -P -- "$name")" == "$selected" ]] || return 1
    identity_after=$(file_identity "$path") || return 1
    [[ "$identity_before" == "$identity_after" ]] || return 1
    printf '%s\n' "$path"
}

live_package_ledger()
{
    local unsafe path metadata uid gid mode links
    [[ -d "$REPO_ROOT/.git" && ! -L "$REPO_ROOT/.git" ]] || return 1
    safe_system_parent_chain "$REPO_ROOT/.git/config" || return 1
    unsafe=$(
        "$FIND" "$REPO_ROOT" \
            \( -type l -o ! -user 0 -o -perm -0022 \) -print -quit
    ) || return 1
    [[ -z "$unsafe" ]] || return 1
    for path in \
        "$PACKAGE_ROOT/README.md" \
        "$PACKAGE_ROOT/SHA256SUMS" \
        "$PACKAGE_ROOT/publish_candidate_oci.sh" \
        "$PACKAGE_ROOT/request.example.json" \
        "$PACKAGE_ROOT/tests/run.sh" \
        "$PACKAGE_ROOT/verify_candidate_publication.py"; do
        [[ -f "$path" && ! -L "$path" ]] || return 1
        metadata=$(file_metadata "$path") || return 1
        read -r uid gid mode links <<<"$metadata"
        [[ "$uid:$gid" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ &&
           "$links" == 1 ]] || return 1
        (( (8#$mode & 8#22) == 0 )) || return 1
        # shellcheck disable=SC2016
        printf '%s %s %s\n' "$path" "$(file_identity "$path")" \
            "$("$SHA256SUM" "$path" | "$AWK" '{print $1}')"
    done
    verify_package || return 1
}

require_protected_live_path()
{
    local path=$1 expected_mode=$2 metadata uid gid mode links
    safe_system_parent_chain "$path" || return 1
    metadata=$(file_metadata "$path") || return 1
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid:$mode:$links" == "0:0:$expected_mode:1" ]]
}

for command in awk find python3 sha256sum sort; do
    path=$(safe_system_tool "$command") || fail "offline command path is unsafe: $command"
    case "$command" in
        awk) AWK=$path ;;
        find) FIND=$path ;;
        python3) PYTHON=$path ;;
        sha256sum) SHA256SUM=$path ;;
        sort) SORT=$path ;;
    esac
done
readonly AWK FIND PYTHON SHA256SUM SORT
verify_package || fail 'publication adapter package seal is invalid'
[[ "$REQUEST" == /* && -f "$REQUEST" && ! -L "$REQUEST" ]] ||
    fail 'request must be an absolute regular file'
[[ "$OUTPUT" == /* && ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] ||
    fail 'output must be an absent absolute path'
requested_execute=$(python_exec -c \
    'import json,sys; v=json.load(open(sys.argv[1])); x=v["execution"]["execute"]; assert type(x) is bool; print(str(x).lower())' \
    "$REQUEST") ||
    fail 'request execution mode cannot be read safely'
if [[ "$requested_execute" == true ]]; then
    ((EUID == 0)) || fail 'root is required for live import and publication'
    require_protected_live_path "$REQUEST" 600 ||
        fail 'live request or its directory ancestry is unsafe'
    requested_exclusive=$(python_exec -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["execution"]["exclusive_writer_authority_path"])' \
        "$REQUEST") || fail 'exclusive-writer authority path cannot be read safely'
    requested_authfile=$(python_exec -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["registry"]["authfile_path"])' \
        "$REQUEST") || fail 'registry authfile path cannot be read safely'
    requested_ledger=$(python_exec -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["execution"]["nonce_ledger_path"])' \
        "$REQUEST") || fail 'nonce-ledger path cannot be read safely'
    require_protected_live_path "$requested_exclusive" 600 ||
        fail 'exclusive-writer authority or its ancestry is unsafe'
    require_protected_live_path "$requested_authfile" 600 ||
        fail 'registry authfile or its ancestry is unsafe'
    safe_system_parent_chain "$requested_ledger" ||
        fail 'nonce-ledger parent ancestry is unsafe'
    requested_ledger_parent=${requested_ledger%/*}
    read -r ledger_parent_uid ledger_parent_gid ledger_parent_mode ledger_parent_links \
        <<<"$(file_metadata "$requested_ledger_parent")"
    [[ "$ledger_parent_uid:$ledger_parent_gid:$ledger_parent_mode" == 0:0:700 &&
       "$ledger_parent_links" =~ ^[1-9][0-9]*$ ]] ||
        fail 'nonce-ledger parent must be root-owned mode 0700'
    output_parent=${OUTPUT%/*}
    [[ -n "$output_parent" ]] || output_parent=/
    safe_system_parent_chain "$OUTPUT" ||
        fail 'live output parent ancestry is unsafe'
    read -r output_parent_uid output_parent_gid output_parent_mode output_parent_links \
        <<<"$(file_metadata "$output_parent")"
    [[ "$output_parent_uid:$output_parent_gid:$output_parent_mode" == 0:0:700 &&
       "$output_parent_links" =~ ^[1-9][0-9]*$ ]] ||
        fail 'live output parent must be root-owned mode 0700'
    LIVE_PACKAGE_LEDGER=$(live_package_ledger) ||
        fail 'live publication requires a protected root-owned full clone'
    [[ -n "$LIVE_PACKAGE_LEDGER" ]] || fail 'live publication tooling ledger is empty'
    LIVE_MODE=1
    unset requested_exclusive requested_authfile requested_ledger requested_ledger_parent
    unset ledger_parent_uid ledger_parent_gid ledger_parent_mode ledger_parent_links
elif [[ "$requested_execute" != false ]]; then
    fail 'request execution state is malformed'
fi
python_exec "$VERIFY" prepare --request "$REQUEST" --output "$OUTPUT"

readonly VERIFIED="$OUTPUT/VERIFIED_INPUT.json"
execute=$(python_exec -c \
    'import json,sys; print(str(json.load(open(sys.argv[1]))["execution"]["execute"]).lower())' \
    "$VERIFIED")
[[ "$execute" == "$requested_execute" ]] || fail 'prepared execution mode changed'
if [[ "$execute" == false ]]; then
    printf 'OFFLINE_VERIFICATION_ONLY=%s\n' "$VERIFIED"
    printf 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true\n'
    exit 0
fi
[[ "$execute" == true ]] || fail 'verified execution state is malformed'

for command in curl docker flock install jq mktemp mv rm rmdir skopeo timeout xargs; do
    path=$(safe_system_tool "$command") || fail "live command path is unsafe: $command"
    case "$command" in
        curl) CURL=$path ;;
        docker) DOCKER=$path ;;
        flock) FLOCK=$path ;;
        install) INSTALL=$path ;;
        jq) JQ=$path ;;
        mktemp) MKTEMP=$path ;;
        mv) MV=$path ;;
        rm) RM=$path ;;
        rmdir) RMDIR=$path ;;
        skopeo) SKOPEO=$path ;;
        timeout) TIMEOUT=$path ;;
        xargs) XARGS=$path ;;
    esac
done
readonly CURL DOCKER FLOCK INSTALL JQ MKTEMP MV RM RMDIR SKOPEO TIMEOUT XARGS

run_bounded()
{
    local seconds=$1
    shift
    "$TIMEOUT" --signal=TERM --kill-after=30s "${seconds}s" \
        /usr/bin/env -i HOME="$CLEAN_HOME" LC_ALL=C PATH="$PATH" TZ=UTC \
        DOCKER_HOST=unix:///var/run/docker.sock "$@"
}
read -r request_uid request_gid request_mode request_links <<<"$(file_metadata "$REQUEST")"
[[ "$request_uid:$request_gid:$request_mode:$request_links" == 0:0:600:1 ]] ||
    fail 'live request must be root-owned mode 0600'
read -r output_uid output_gid output_mode output_links <<<"$(file_metadata "$OUTPUT")"
[[ "$output_uid:$output_gid:$output_mode" == 0:0:700 &&
   "$output_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'live evidence directory must be root-owned mode 0700'
readonly OUTPUT_ANCHOR="$OUTPUT/OUTPUT_ANCHOR.json"
python_exec "$VERIFY" anchor-live-output --root "$OUTPUT" --output "$OUTPUT_ANCHOR"

SOURCE=$("$JQ" -er '.source.commit' "$VERIFIED")
CONFIG=$("$JQ" -er '.oci.source_config_digest' "$VERIFIED")
OCI_REL=$("$JQ" -er '.oci.archive_path' "$VERIFIED")
NONCE=$("$JQ" -er '.execution.nonce' "$VERIFIED")
LEDGER=$("$JQ" -er '.execution.nonce_ledger_path' "$VERIFIED")
EXCLUSIVE_AUTHORITY=$("$JQ" -er '.execution.exclusive_writer_authority_path' "$VERIFIED")
REGISTRY_HOST=$("$JQ" -er '.registry.host' "$OUTPUT/request.json")
CREDENTIAL_HOST=$("$JQ" -er '.registry.credential_host' "$OUTPUT/request.json")
REPOSITORY=$("$JQ" -er '.registry.repository' "$OUTPUT/request.json")
TAG=$("$JQ" -er '.registry.tag' "$OUTPUT/request.json")
AUTHFILE=$("$JQ" -er '.registry.authfile_path' "$OUTPUT/request.json")
readonly SOURCE CONFIG OCI_REL NONCE LEDGER EXCLUSIVE_AUTHORITY
readonly REGISTRY_HOST CREDENTIAL_HOST REPOSITORY TAG AUTHFILE
[[ "$REGISTRY_HOST" == "$EXPECTED_REGISTRY_HOST" &&
   "$CREDENTIAL_HOST" == "$EXPECTED_CREDENTIAL_HOST" &&
   "$REPOSITORY" == "$EXPECTED_REPOSITORY" ]] || fail 'registry authority changed after verification'
[[ "$CONFIG" =~ ^sha256:[0-9a-f]{64}$ && "$NONCE" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'verified config or nonce is malformed'
read -r auth_uid auth_gid auth_mode auth_links <<<"$(file_metadata "$AUTHFILE")"
[[ "$AUTHFILE" == /* && -f "$AUTHFILE" && ! -L "$AUTHFILE" &&
   "$auth_uid:$auth_gid:$auth_mode:$auth_links" == 0:0:600:1 ]] ||
    fail 'selected registry authfile must be root-owned, single-linked, and mode 0600'
read -r exclusive_uid exclusive_gid exclusive_mode exclusive_links \
    <<<"$(file_metadata "$EXCLUSIVE_AUTHORITY")"
[[ "$EXCLUSIVE_AUTHORITY" == /* && -f "$EXCLUSIVE_AUTHORITY" &&
   ! -L "$EXCLUSIVE_AUTHORITY" &&
   "$exclusive_uid:$exclusive_gid:$exclusive_mode:$exclusive_links" == 0:0:600:1 ]] ||
    fail 'exclusive-writer authority must be root-owned mode 0600'

readonly OCI_ARCHIVE="$OUTPUT/$OCI_REL"
[[ -f "$OCI_ARCHIVE" && ! -L "$OCI_ARCHIVE" ]] || fail 'verified OCI archive is absent'
LOCAL_REF="blackcoin-v3015-publication:${SOURCE:0:12}-${NONCE:0:12}"
# Skopeo's transport name is the exact credential host proven by
# `skopeo login --get-login`; raw registry evidence uses the separately bound
# distribution API host.
TARGET_REF="$CREDENTIAL_HOST/$REPOSITORY:$TAG"

readonly REGISTRY_EVIDENCE="$OUTPUT/registry"
"$INSTALL" -d -m 700 -o root -g root "$REGISTRY_EVIDENCE"
readonly AUTHFILE_RECEIPT="$REGISTRY_EVIDENCE/REGISTRY_AUTHFILE.json"
python_exec "$VERIFY" verify-authfile --request "$OUTPUT/request.json" \
    --skopeo "$SKOPEO" --output "$AUTHFILE_RECEIPT"

# Open the lock only beneath protected /run, never follow a terminal symlink,
# and bind the path to the descriptor before flock. Append-open cannot
# truncate a preexisting inode; the nonce ledger is the independent durable
# exactly-once barrier.
safe_system_parent_chain "$LOCK" || fail 'publication lock parent is unsafe'
if [[ -e "$LOCK" || -L "$LOCK" ]]; then
    read -r lock_uid lock_gid lock_mode lock_links <<<"$(file_metadata "$LOCK")"
    [[ -f "$LOCK" && ! -L "$LOCK" &&
       "$lock_uid:$lock_gid:$lock_mode:$lock_links" == 0:0:600:1 ]] ||
        fail 'preexisting publication lock inode is unsafe'
fi
exec 9>>"$LOCK"
read -r lock_uid lock_gid lock_mode lock_links <<<"$(file_metadata "$LOCK")"
[[ -f "$LOCK" && ! -L "$LOCK" &&
   "$lock_uid:$lock_gid:$lock_mode:$lock_links" == 0:0:600:1 ]] ||
    fail 'publication lock inode is unsafe'
[[ -e "/proc/$$/fd/9" &&
   "$(file_identity "$LOCK")" == "$(file_identity "/proc/$$/fd/9")" ]] ||
    fail 'publication lock path and descriptor differ'
"$FLOCK" -w 60 9 || fail 'another v30.1.5 publication is active'
readonly NONCE_RECEIPT="$OUTPUT/NONCE_CONSUMPTION.json"
python_exec "$VERIFY" verify-live-output-anchor --root "$OUTPUT" --anchor "$OUTPUT_ANCHOR"
python_exec "$VERIFY" consume-nonce --verified "$VERIFIED" \
    --request "$OUTPUT/request.json" --ledger "$LEDGER" --output "$NONCE_RECEIPT"

# Nothing below may run before the nonce is durably consumed.
existing_local=$(
    run_bounded 300 "$DOCKER" image ls --quiet --no-trunc \
        --filter "reference=$LOCAL_REF"
) || fail 'could not prove nonce-derived local import reference absence'
[[ -z "$existing_local" ]] || fail 'nonce-derived local import reference already exists'
unset existing_local
CREATED_LOCAL=1
run_bounded 1800 "$SKOPEO" copy --preserve-digests "oci-archive:$OCI_ARCHIVE" \
    "docker-daemon:$LOCAL_REF" >/dev/null || fail 'OCI archive import failed'
[[ "$(run_bounded 300 "$DOCKER" image inspect -f '{{.Id}}' "$LOCAL_REF")" == "$CONFIG" ]] ||
    fail 'imported OCI config digest changed'

run_bounded 300 "$DOCKER" image inspect "$LOCAL_REF" > \
    "$REGISTRY_EVIDENCE/local-image-inspect.json"
readonly EXTRACTED_DIR="$REGISTRY_EVIDENCE/extracted-binaries"
"$INSTALL" -d -m 700 -o root -g root "$EXTRACTED_DIR"
CONTAINER_ID=$(run_bounded 300 "$DOCKER" create --pull=never --network none "$LOCAL_REF") ||
    fail 'could not create stopped extraction container'
CREATED_CONTAINER=1
[[ "$CONTAINER_ID" =~ ^[0-9a-f]{12,64}$ &&
   "$(run_bounded 300 "$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER_ID")" == created ]] ||
    fail 'extraction container is not in the never-started created state'
for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    run_bounded 600 "$DOCKER" cp "$CONTAINER_ID:/usr/local/bin/$binary" \
        "$EXTRACTED_DIR/$binary" ||
        fail "could not extract imported binary: $binary"
    [[ "$(run_bounded 300 "$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER_ID")" == created ]] ||
        fail 'extraction container state changed'
done
readonly EXTRACTED_RECEIPT="$REGISTRY_EVIDENCE/EXTRACTED_BINARIES.json"
python_exec "$VERIFY" verify-extracted-binaries --verified "$VERIFIED" \
    --directory "$EXTRACTED_DIR" --output "$EXTRACTED_RECEIPT"
run_bounded 120 "$DOCKER" container rm "$CONTAINER_ID" >/dev/null ||
    fail 'could not remove extraction container'
CREATED_CONTAINER=0
CONTAINER_ID=
"$RM" -f -- "$EXTRACTED_DIR"/*
"$RMDIR" "$EXTRACTED_DIR"

registry_token()
{
    "$CURL" --disable --proto '=https' --tlsv1.2 -fsS --get \
        --connect-timeout 15 --max-time 120 \
        --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
        --data-urlencode service=registry.docker.io \
        --data-urlencode "scope=repository:${REPOSITORY}:pull" \
        https://auth.docker.io/token |
        "$JQ" -er '.token | select(type == "string" and length > 20)'
}

fetch_manifest()
{
    local token=$1 reference=$2 body=$3 headers=$4 status
    status=$("$CURL" --disable --proto '=https' --tlsv1.2 -sS \
        --connect-timeout 15 --max-time 120 \
        -D "$headers" -o "$body" -w '%{http_code}' \
        --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY_HOST}/v2/${REPOSITORY}/manifests/${reference}") || return 1
    case "$status" in
        200) return 0 ;;
        404) return 44 ;;
        *) return 1 ;;
    esac
}

TOKEN=$(registry_token) || fail 'could not acquire Docker Hub pull token'
readonly TAG_BODY="$REGISTRY_EVIDENCE/tag-manifest.json"
readonly TAG_HEADERS="$REGISTRY_EVIDENCE/tag-manifest.headers"
PUBLICATION_OUTCOME=tag-already-exact
if fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS"; then
    PUBLICATION_OUTCOME=tag-already-exact
else
    rc=$?
    [[ "$rc" -eq 44 ]] || fail 'registry tag preflight failed'
    "$RM" -f -- "$TAG_BODY" "$TAG_HEADERS"
    TOKEN=$(registry_token) || fail 'could not refresh Docker Hub pull token'
    if fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS"; then
        PUBLICATION_OUTCOME=tag-already-exact
    else
        rc=$?
        [[ "$rc" -eq 44 ]] || fail 'registry second tag preflight failed'
        "$RM" -f -- "$TAG_BODY" "$TAG_HEADERS"
        python_exec "$VERIFY" validate-authfile --request "$OUTPUT/request.json" \
            --skopeo "$SKOPEO" >/dev/null
        if run_bounded 1800 "$SKOPEO" copy --authfile "$AUTHFILE" --preserve-digests \
            "oci-archive:$OCI_ARCHIVE" "docker://$TARGET_REF" >/dev/null; then
            PUBLICATION_OUTCOME=copy-succeeded
        else
            # A transport failure can occur after a registry has committed the
            # tag. Do not retry or infer success: refetch and let the exact-byte
            # final gate decide. A failed gate emits no RESULT or authority.
            PUBLICATION_OUTCOME=copy-error-remote-exact
        fi
        TOKEN=$(registry_token) || fail 'could not refresh token after publication attempt'
        fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS" ||
            fail 'publication attempt did not produce an exactly verifiable tag'
    fi
fi
readonly PUBLICATION_OUTCOME

MANIFEST_DIGEST=$(python_exec - "$TAG_BODY" "$TAG_HEADERS" <<'PY'
import hashlib
import re
import sys
body = open(sys.argv[1], 'rb').read()
headers = open(sys.argv[2], 'rb').read()
blocks = re.split(br'\r?\n\r?\n', headers)
responses = [block for block in blocks if block.startswith(b'HTTP/')]
if not responses:
    raise SystemExit(1)
values = []
for line in re.split(br'\r?\n', responses[-1])[1:]:
    if line.lower().startswith(b'docker-content-digest:'):
        values.append(line.split(b':', 1)[1].strip().decode('ascii'))
expected = 'sha256:' + hashlib.sha256(body).hexdigest()
if values != [expected]:
    raise SystemExit(1)
print(expected)
PY
) || fail 'tag response lacks its exact same-response digest'
readonly MANIFEST_DIGEST
readonly DIGEST_BODY="$REGISTRY_EVIDENCE/digest-manifest.json"
readonly DIGEST_HEADERS="$REGISTRY_EVIDENCE/digest-manifest.headers"
fetch_manifest "$TOKEN" "$MANIFEST_DIGEST" "$DIGEST_BODY" "$DIGEST_HEADERS" ||
    fail 'registry manifest cannot be refetched by digest'

readonly CONFIG_BODY="$REGISTRY_EVIDENCE/registry-config.json"
readonly CONFIG_HEADERS="$REGISTRY_EVIDENCE/registry-config.headers"
status=$("$CURL" --disable --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 120 \
    -sS --location -D "$CONFIG_HEADERS" --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
    -o "$CONFIG_BODY" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    "https://${REGISTRY_HOST}/v2/${REPOSITORY}/blobs/${CONFIG}") ||
    fail 'registry config fetch failed'
[[ "$status" == 200 ]] || fail 'registry config fetch did not return 200'

python_exec "$VERIFY" verify-registry --verified "$VERIFIED" \
    --request "$OUTPUT/request.json" --tag-manifest "$TAG_BODY" \
    --tag-headers "$TAG_HEADERS" --digest-manifest "$DIGEST_BODY" \
    --digest-headers "$DIGEST_HEADERS" --config-body "$CONFIG_BODY" \
    --config-headers "$CONFIG_HEADERS" \
    --local-inspect "$REGISTRY_EVIDENCE/local-image-inspect.json" \
    --extracted-binaries "$EXTRACTED_RECEIPT" --nonce-consumption "$NONCE_RECEIPT" \
    --registry-authfile "$AUTHFILE_RECEIPT" --publication-outcome "$PUBLICATION_OUTCOME" \
    --output "$REGISTRY_EVIDENCE/RESULT.json"

MANIFEST_TMP=$("$MKTEMP" "$OUTPUT/.PUBLICATION_SHA256SUMS.XXXXXX") ||
    fail 'could not create publication evidence manifest'
(
    cd "$OUTPUT"
    "$FIND" . -type f ! -name PUBLICATION_SHA256SUMS \
        ! -name PUBLICATION_COMPLETE.json \
        ! -name '.PUBLICATION_SHA256SUMS.*' -print0 | "$SORT" -z |
        "$XARGS" -0 "$SHA256SUM" > "$MANIFEST_TMP"
    "$MV" -- "$MANIFEST_TMP" PUBLICATION_SHA256SUMS
    "$SHA256SUM" --strict --check PUBLICATION_SHA256SUMS >/dev/null
)
python_exec "$VERIFY" fsync-tree --root "$OUTPUT" >/dev/null
python_exec "$VERIFY" verify-live-output-anchor --root "$OUTPUT" --anchor "$OUTPUT_ANCHOR"
readonly PUBLICATION_COMPLETE="$OUTPUT/PUBLICATION_COMPLETE.json"
python_exec "$VERIFY" complete-publication --root "$OUTPUT" \
    --result "$REGISTRY_EVIDENCE/RESULT.json" \
    --manifest "$OUTPUT/PUBLICATION_SHA256SUMS" --output "$PUBLICATION_COMPLETE" >/dev/null
python_exec "$VERIFY" verify-completion --root "$OUTPUT" \
    --completion "$PUBLICATION_COMPLETE" >/dev/null
python_exec "$VERIFY" fsync-tree --root "$OUTPUT" >/dev/null
python_exec "$VERIFY" verify-live-output-anchor --root "$OUTPUT" --anchor "$OUTPUT_ANCHOR"
python_exec "$VERIFY" verify-completion --root "$OUTPUT" \
    --completion "$PUBLICATION_COMPLETE" >/dev/null
IMMUTABLE_REF=$("$JQ" -er '.registry.immutable_image_ref' "$PUBLICATION_COMPLETE")
readonly IMMUTABLE_REF
[[ "$IMMUTABLE_REF" =~ ^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$ ]] ||
    fail 'result did not emit immutable rollout authority'
printf 'IMMUTABLE_IMAGE_REF=%s\n' "$IMMUTABLE_REF"
printf 'PUBLICATION_RESULT=%s\n' "$REGISTRY_EVIDENCE/RESULT.json"
printf 'PUBLICATION_COMPLETE=%s\n' "$PUBLICATION_COMPLETE"
# shellcheck disable=SC2016
printf 'PUBLICATION_EVIDENCE_SHA256SUMS=%s\n' \
    "$("$SHA256SUM" "$OUTPUT/PUBLICATION_SHA256SUMS" | "$AWK" '{print $1}')"
# shellcheck disable=SC2016
printf 'PUBLICATION_COMPLETE_SHA256=%s\n' \
    "$("$SHA256SUM" "$PUBLICATION_COMPLETE" | "$AWK" '{print $1}')"
