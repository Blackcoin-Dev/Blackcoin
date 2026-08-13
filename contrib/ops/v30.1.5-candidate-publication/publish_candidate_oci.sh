#!/usr/bin/env bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

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
readonly VERIFY="$PACKAGE_ROOT/verify_candidate_publication.py"
readonly REQUEST=${1:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly OUTPUT=${2:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly LOCK=/var/lock/blackcoin-v30.1.5-candidate-publication.lock
readonly EXPECTED_REPOSITORY=qqblackcoin/blackcoin-v4-gui
readonly EXPECTED_REGISTRY_HOST=registry-1.docker.io
readonly EXPECTED_CREDENTIAL_HOST=docker.io
readonly MAX_REGISTRY_RESPONSE_BYTES=33554432
LOCAL_REF=
TARGET_REF=
CONTAINER_ID=
CREATED_LOCAL=0
CREATED_CONTAINER=0

fail()
{
    printf 'v30.1.5 candidate publication failed: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    local status=$?
    trap - EXIT INT TERM
    if ((CREATED_CONTAINER == 1)) && [[ -n "$CONTAINER_ID" && -n "${DOCKER:-}" ]]; then
        "$DOCKER" container rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi
    if ((status != 0)) && ((CREATED_LOCAL == 1)) &&
       [[ -n "$LOCAL_REF" && -n "${DOCKER:-}" ]]; then
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
[[ -f "$STAT" && ! -L "$STAT" ]] || fail 'fixed system stat is absent or unsafe'
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

read -r stat_uid stat_gid stat_mode stat_links <<<"$(file_metadata "$STAT")"
[[ "$stat_uid:$stat_gid" == 0:0 && "$stat_mode" =~ ^[0-7]{3,4}$ &&
   "$stat_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'fixed system stat ownership or mode is malformed'
(( (8#$stat_mode & 8#22) == 0 )) || fail 'fixed system stat is group/world writable'

safe_system_tool()
{
    local name=$1 path metadata uid gid mode links
    path=$(type -P -- "$name") || return 1
    [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || return 1
    metadata=$(file_metadata "$path") || return 1
    read -r uid gid mode links <<<"$metadata"
    [[ "$uid:$gid" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ &&
       "$links" =~ ^[1-9][0-9]*$ ]] ||
        return 1
    (( (8#$mode & 8#22) == 0 )) || return 1
    printf '%s\n' "$path"
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
"$PYTHON" "$VERIFY" prepare --request "$REQUEST" --output "$OUTPUT"

readonly VERIFIED="$OUTPUT/VERIFIED_INPUT.json"
execute=$("$PYTHON" -c \
    'import json,sys; print(str(json.load(open(sys.argv[1]))["execution"]["execute"]).lower())' \
    "$VERIFIED")
if [[ "$execute" == false ]]; then
    printf 'OFFLINE_VERIFICATION_ONLY=%s\n' "$VERIFIED"
    printf 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true\n'
    exit 0
fi
[[ "$execute" == true ]] || fail 'verified execution state is malformed'
((EUID == 0)) || fail 'root is required for live import and publication'

for command in curl docker flock install jq mktemp mv rm rmdir skopeo xargs; do
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
        xargs) XARGS=$path ;;
    esac
done
readonly CURL DOCKER FLOCK INSTALL JQ MKTEMP MV RM RMDIR SKOPEO XARGS
read -r request_uid request_gid request_mode request_links <<<"$(file_metadata "$REQUEST")"
[[ "$request_uid:$request_gid:$request_mode:$request_links" == 0:0:600:1 ]] ||
    fail 'live request must be root-owned mode 0600'
read -r output_uid output_gid output_mode output_links <<<"$(file_metadata "$OUTPUT")"
[[ "$output_uid:$output_gid:$output_mode" == 0:0:700 &&
   "$output_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'live evidence directory must be root-owned mode 0700'

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
"$PYTHON" "$VERIFY" verify-authfile --request "$OUTPUT/request.json" \
    --skopeo "$SKOPEO" --output "$AUTHFILE_RECEIPT"

# Append-open avoids truncating any preexisting lock inode. The nonce ledger
# provides the independent durable exactly-once barrier.
exec 9>>"$LOCK"
read -r lock_uid lock_gid lock_mode lock_links <<<"$(file_metadata "$LOCK")"
[[ ! -L "$LOCK" && "$lock_uid:$lock_gid" == 0:0 &&
   "$lock_mode" =~ ^[0-7]{3,4}$ && "$lock_links" =~ ^[1-9][0-9]*$ ]] ||
    fail 'publication lock inode is unsafe'
(( (8#$lock_mode & 8#22) == 0 )) || fail 'publication lock is group/world writable'
"$FLOCK" -w 60 9 || fail 'another v30.1.5 publication is active'
readonly NONCE_RECEIPT="$OUTPUT/NONCE_CONSUMPTION.json"
"$PYTHON" "$VERIFY" consume-nonce --verified "$VERIFIED" \
    --request "$OUTPUT/request.json" --ledger "$LEDGER" --output "$NONCE_RECEIPT"

# Nothing below may run before the nonce is durably consumed.
if "$DOCKER" image inspect "$LOCAL_REF" >/dev/null 2>&1; then
    fail 'nonce-derived local import reference already exists'
fi
CREATED_LOCAL=1
"$SKOPEO" copy --preserve-digests "oci-archive:$OCI_ARCHIVE" \
    "docker-daemon:$LOCAL_REF" >/dev/null || fail 'OCI archive import failed'
[[ "$("$DOCKER" image inspect -f '{{.Id}}' "$LOCAL_REF")" == "$CONFIG" ]] ||
    fail 'imported OCI config digest changed'

"$DOCKER" image inspect "$LOCAL_REF" > "$REGISTRY_EVIDENCE/local-image-inspect.json"
readonly EXTRACTED_DIR="$REGISTRY_EVIDENCE/extracted-binaries"
"$INSTALL" -d -m 700 -o root -g root "$EXTRACTED_DIR"
CONTAINER_ID=$("$DOCKER" create --pull=never --network none "$LOCAL_REF") ||
    fail 'could not create stopped extraction container'
CREATED_CONTAINER=1
[[ "$CONTAINER_ID" =~ ^[0-9a-f]{12,64}$ &&
   "$("$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER_ID")" == created ]] ||
    fail 'extraction container is not in the never-started created state'
for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    "$DOCKER" cp "$CONTAINER_ID:/usr/local/bin/$binary" "$EXTRACTED_DIR/$binary" ||
        fail "could not extract imported binary: $binary"
    [[ "$("$DOCKER" inspect -f '{{.State.Status}}' "$CONTAINER_ID")" == created ]] ||
        fail 'extraction container state changed'
done
readonly EXTRACTED_RECEIPT="$REGISTRY_EVIDENCE/EXTRACTED_BINARIES.json"
"$PYTHON" "$VERIFY" verify-extracted-binaries --verified "$VERIFIED" \
    --directory "$EXTRACTED_DIR" --output "$EXTRACTED_RECEIPT"
"$DOCKER" container rm "$CONTAINER_ID" >/dev/null || fail 'could not remove extraction container'
CREATED_CONTAINER=0
CONTAINER_ID=
"$RM" -f -- "$EXTRACTED_DIR"/*
"$RMDIR" "$EXTRACTED_DIR"

registry_token()
{
    "$CURL" --disable --proto '=https' --tlsv1.2 -fsS --get \
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
        if "$SKOPEO" copy --authfile "$AUTHFILE" --preserve-digests \
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

MANIFEST_DIGEST=$("$PYTHON" - "$TAG_BODY" "$TAG_HEADERS" <<'PY'
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
    -sS --location -D "$CONFIG_HEADERS" --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
    -o "$CONFIG_BODY" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    "https://${REGISTRY_HOST}/v2/${REPOSITORY}/blobs/${CONFIG}") ||
    fail 'registry config fetch failed'
[[ "$status" == 200 ]] || fail 'registry config fetch did not return 200'

"$PYTHON" "$VERIFY" verify-registry --verified "$VERIFIED" \
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
        ! -name '.PUBLICATION_SHA256SUMS.*' -print0 | "$SORT" -z |
        "$XARGS" -0 "$SHA256SUM" > "$MANIFEST_TMP"
    "$MV" -- "$MANIFEST_TMP" PUBLICATION_SHA256SUMS
    "$SHA256SUM" --strict --check PUBLICATION_SHA256SUMS >/dev/null
)
"$PYTHON" "$VERIFY" fsync-tree --root "$OUTPUT" >/dev/null
IMMUTABLE_REF=$("$JQ" -er '.immutable_image_ref' "$REGISTRY_EVIDENCE/RESULT.json")
readonly IMMUTABLE_REF
[[ "$IMMUTABLE_REF" =~ ^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$ ]] ||
    fail 'result did not emit immutable rollout authority'
printf 'IMMUTABLE_IMAGE_REF=%s\n' "$IMMUTABLE_REF"
printf 'PUBLICATION_RESULT=%s\n' "$REGISTRY_EVIDENCE/RESULT.json"
# shellcheck disable=SC2016
printf 'PUBLICATION_EVIDENCE_SHA256SUMS=%s\n' \
    "$("$SHA256SUM" "$OUTPUT/PUBLICATION_SHA256SUMS" | "$AWK" '{print $1}')"
