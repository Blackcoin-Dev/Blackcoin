#!/usr/bin/env bash
export LC_ALL=C

# Verifies a GitHub Actions candidate artifact offline by default. The live
# branch imports the exact OCI archive and publishes only after an explicit,
# nonce-bound request; deployment authority is emitted only as a digest ref.

set -Eeuo pipefail
umask 077
export TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly PACKAGE_ROOT
readonly VERIFY="$PACKAGE_ROOT/verify_candidate_publication.py"
readonly REQUEST=${1:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly OUTPUT=${2:?usage: publish_candidate_oci.sh REQUEST.json OUTPUT_DIR}
readonly LOCK=/var/lock/blackcoin-v30.1.5-candidate-publication.lock
readonly EXPECTED_REPOSITORY=qqblackcoin/blackcoin-v4-gui
readonly MAX_REGISTRY_RESPONSE_BYTES=33554432
LOCAL_REF=
TARGET_REF=
CREATED_LOCAL=0

fail()
{
    printf 'v30.1.5 candidate publication failed: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    local status=$?
    trap - EXIT INT TERM
    if ((status != 0)); then
        if ((CREATED_LOCAL == 1)) && [[ -n "$LOCAL_REF" ]]; then
            docker image rm "$LOCAL_REF" >/dev/null 2>&1 || true
        fi
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
    actual=$(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort)
    expected=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); print "./" name
    }' "$PACKAGE_ROOT/SHA256SUMS" | sort)
    [[ "$actual" == "$expected" ]] || return 1
    [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
       -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict --check SHA256SUMS >/dev/null)
}

for command in awk find python3 sha256sum sort; do
    command -v "$command" >/dev/null 2>&1 || fail "required offline command unavailable: $command"
done
verify_package || fail 'publication adapter package seal is invalid'
[[ "$REQUEST" == /* && -f "$REQUEST" && ! -L "$REQUEST" ]] || fail 'request must be an absolute regular file'
[[ "$OUTPUT" == /* && ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail 'output must be an absent absolute path'
"$VERIFY" prepare --request "$REQUEST" --output "$OUTPUT"

readonly VERIFIED="$OUTPUT/VERIFIED_INPUT.json"
execute=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["execution"]["execute"]).lower())' "$VERIFIED")
if [[ "$execute" == false ]]; then
    printf 'OFFLINE_VERIFICATION_ONLY=%s\n' "$VERIFIED"
    printf 'NO_DOCKER_OR_REGISTRY_OPERATION_PERFORMED=true\n'
    exit 0
fi
[[ "$execute" == true ]] || fail 'verified execution state is malformed'

for command in curl docker flock id install jq mktemp stat sync skopeo; do
    command -v "$command" >/dev/null 2>&1 || fail "required live command unavailable: $command"
done
[[ "$(id -u)" -eq 0 ]] || fail 'root is required for live import and publication'
[[ "$(stat -c '%u:%g:%a' "$REQUEST")" == 0:0:600 ]] || fail 'live request must be root-owned mode 0600'
[[ "$(stat -c '%u:%g:%a' "$OUTPUT")" == 0:0:700 ]] || fail 'live evidence directory must be root-owned mode 0700'

SOURCE=$(jq -er '.identity.source_commit' "$VERIFIED")
CONFIG=$(jq -er '.oci.source_config_digest' "$VERIFIED")
OCI_REL=$(jq -er '.oci.archive_path' "$VERIFIED")
NONCE=$(jq -er '.execution.nonce' "$VERIFIED")
REPOSITORY=$(jq -er '.registry.repository' "$OUTPUT/request.json")
TAG=$(jq -er '.registry.tag' "$OUTPUT/request.json")
readonly SOURCE CONFIG OCI_REL NONCE REPOSITORY TAG
[[ "$REPOSITORY" == "$EXPECTED_REPOSITORY" ]] || fail 'registry repository changed after verification'
[[ "$CONFIG" =~ ^sha256:[0-9a-f]{64}$ && "$NONCE" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'verified config or nonce is malformed'
readonly OCI_ARCHIVE="$OUTPUT/$OCI_REL"
[[ -f "$OCI_ARCHIVE" && ! -L "$OCI_ARCHIVE" ]] || fail 'verified OCI archive is absent'
LOCAL_REF="blackcoin-v3015-publication:${SOURCE:0:12}-${NONCE:0:12}"
TARGET_REF="$REPOSITORY:$TAG"

exec 9>"$LOCK"
flock -w 60 9 || fail 'another v30.1.5 publication is active'
if docker image inspect "$LOCAL_REF" >/dev/null 2>&1; then
    fail 'nonce-derived local import reference already exists'
fi
skopeo copy "oci-archive:$OCI_ARCHIVE" "docker-daemon:$LOCAL_REF" >/dev/null ||
    fail 'OCI archive import failed'
CREATED_LOCAL=1
[[ "$(docker image inspect -f '{{.Id}}' "$LOCAL_REF")" == "$CONFIG" ]] ||
    fail 'imported OCI config digest changed'

REGISTRY_EVIDENCE="$OUTPUT/registry"
install -d -m 700 -o root -g root "$REGISTRY_EVIDENCE"
docker image inspect "$LOCAL_REF" > "$REGISTRY_EVIDENCE/local-image-inspect.json"
docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
    --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum "$LOCAL_REF" \
    /usr/local/bin/blackcoin-cli /usr/local/bin/blackcoin-qt \
    /usr/local/bin/blackcoin-tx /usr/local/bin/blackcoin-util \
    /usr/local/bin/blackcoin-wallet /usr/local/bin/blackcoind \
    > "$REGISTRY_EVIDENCE/embedded-binary-sha256.txt" ||
    fail 'imported six-executable verification failed'

registry_token()
{
    curl --proto '=https' --tlsv1.2 -fsS --get \
        --data-urlencode service=registry.docker.io \
        --data-urlencode "scope=repository:${REPOSITORY}:pull" \
        https://auth.docker.io/token | jq -er '.token | select(type == "string" and length > 20)'
}

fetch_manifest()
{
    local token=$1 reference=$2 body=$3 headers=$4 status
    status=$(curl --proto '=https' --tlsv1.2 -sS -D "$headers" -o "$body" -w '%{http_code}' \
        --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry-1.docker.io/v2/${REPOSITORY}/manifests/${reference}") || return 1
    case "$status" in
        200) return 0 ;;
        404) return 44 ;;
        *) return 1 ;;
    esac
}

TOKEN=$(registry_token) || fail 'could not acquire Docker Hub pull token'
readonly TAG_BODY="$REGISTRY_EVIDENCE/tag-manifest.json"
readonly TAG_HEADERS="$REGISTRY_EVIDENCE/tag-manifest.headers"
PUBLISHED_NOW=false
if fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS"; then
    PUBLISHED_NOW=false
else
    rc=$?
    [[ "$rc" -eq 44 ]] || fail 'registry tag preflight failed'
    rm -f -- "$TAG_BODY" "$TAG_HEADERS"
    TOKEN=$(registry_token) || fail 'could not refresh Docker Hub pull token'
    if fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS"; then
        PUBLISHED_NOW=false
    else
        rc=$?
        [[ "$rc" -eq 44 ]] || fail 'registry second tag preflight failed'
        rm -f -- "$TAG_BODY" "$TAG_HEADERS"
        skopeo copy --preserve-digests "oci-archive:$OCI_ARCHIVE" "docker://$TARGET_REF" >/dev/null ||
            fail 'digest-preserving candidate registry publication failed'
        PUBLISHED_NOW=true
        TOKEN=$(registry_token) || fail 'could not refresh token after publication'
        fetch_manifest "$TOKEN" "$TAG" "$TAG_BODY" "$TAG_HEADERS" ||
            fail 'published tag manifest is unreadable'
    fi
fi

MANIFEST_DIGEST=$(python3 - "$TAG_BODY" "$TAG_HEADERS" <<'PY'
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
status=$(curl --proto '=https' --tlsv1.2 -sS --location -D "$CONFIG_HEADERS" \
    --max-filesize "$MAX_REGISTRY_RESPONSE_BYTES" \
    -o "$CONFIG_BODY" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    "https://registry-1.docker.io/v2/${REPOSITORY}/blobs/${CONFIG}") ||
    fail 'registry config fetch failed'
[[ "$status" == 200 ]] || fail 'registry config fetch did not return 200'

"$VERIFY" verify-registry --verified "$VERIFIED" --request "$OUTPUT/request.json" \
    --tag-manifest "$TAG_BODY" --tag-headers "$TAG_HEADERS" \
    --digest-manifest "$DIGEST_BODY" --digest-headers "$DIGEST_HEADERS" \
    --config-body "$CONFIG_BODY" --config-headers "$CONFIG_HEADERS" \
    --local-inspect "$REGISTRY_EVIDENCE/local-image-inspect.json" \
    --embedded-sums "$REGISTRY_EVIDENCE/embedded-binary-sha256.txt" \
    --published-now "$PUBLISHED_NOW" --output "$REGISTRY_EVIDENCE/RESULT.json"

MANIFEST_TMP=$(mktemp "$OUTPUT/.PUBLICATION_SHA256SUMS.XXXXXX") ||
    fail 'could not create publication evidence manifest'
(
    cd "$OUTPUT"
    find . -type f ! -name PUBLICATION_SHA256SUMS \
        ! -name '.PUBLICATION_SHA256SUMS.*' -print0 | sort -z |
        xargs -0 sha256sum > "$MANIFEST_TMP"
    mv -- "$MANIFEST_TMP" PUBLICATION_SHA256SUMS
    sha256sum --strict --check PUBLICATION_SHA256SUMS >/dev/null
)
sync -f "$REGISTRY_EVIDENCE/RESULT.json"
sync -f "$OUTPUT/PUBLICATION_SHA256SUMS"
sync -f "$OUTPUT"
IMMUTABLE_REF=$(jq -er '.immutable_image_ref' "$REGISTRY_EVIDENCE/RESULT.json")
readonly IMMUTABLE_REF
[[ "$IMMUTABLE_REF" =~ ^qqblackcoin/blackcoin-v4-gui@sha256:[0-9a-f]{64}$ ]] ||
    fail 'result did not emit immutable rollout authority'
printf 'IMMUTABLE_IMAGE_REF=%s\n' "$IMMUTABLE_REF"
printf 'PUBLICATION_RESULT=%s\n' "$REGISTRY_EVIDENCE/RESULT.json"
printf 'PUBLICATION_EVIDENCE_SHA256SUMS=%s\n' "$(sha256sum "$OUTPUT/PUBLICATION_SHA256SUMS" | awk '{print $1}')"
