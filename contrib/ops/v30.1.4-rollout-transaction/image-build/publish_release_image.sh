#!/usr/bin/env bash
export LC_ALL=C

# Publishes only the exact, sealed native-linux/amd64 v30.1.4 build. The
# Docker Hub tag is never treated as immutable rollout authority: a same-GET
# content digest is verified, refetched by digest, and emitted for deployment.

set -Eeuo pipefail
umask 077
export TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
readonly PACKAGE_ROOT
readonly BUILD_RUN=${1:?usage: publish_release_image.sh BUILD_RUN_DIR}
readonly BUILD="$BUILD_RUN/build"
readonly EVIDENCE="$BUILD_RUN/evidence"
readonly BUILD_RESULT="$EVIDENCE/BUILD_RESULT.json"
readonly BUILD_INPUTS="$EVIDENCE/BUILD_INPUTS.json"
readonly IMAGE_ID_FILE="$EVIDENCE/image-id.txt"
readonly BUILD_MANIFEST="$EVIDENCE/SHA256SUMS"
readonly PUBLICATION_ROOT="$BUILD_RUN/publication"
readonly PUBLISH_LOCK=/var/run/blackcoin-v30.1.4-image-publish.lock
readonly IMAGE_BUILD_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-image-builds

readonly EXPECTED_RELEASE_TAG=v30.1.4
readonly EXPECTED_SOURCE_COMMIT=13262151077cce3f72d07d17dc7725b2b6a8e1ab
readonly EXPECTED_ASSET=Blackcoin-30.1.4-Linux-x86_64.tar.gz
readonly EXPECTED_ARTIFACT_SHA256=8139520add8609aa65bd38e0524b1b55b567d7563969a65db919e4d537e4f20b
readonly EXPECTED_SUMS_SHA256=c969eb048436d809a65d2425927513bef500f7b051149d039901255f3bd32bed
readonly EXPECTED_REPOSITORY=qqblackcoin/blackcoin-v4-gui
readonly EXPECTED_TARGET_IMAGE="${EXPECTED_REPOSITORY}:30.1.4-final-${EXPECTED_SOURCE_COMMIT:0:12}-ops1"
readonly EXPECTED_BASE_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87'
readonly EXPECTED_BASE_BUILD_REF='blackcoin-ops-base:alpha1-8670d7f4fd03'
readonly EXPECTED_BASE_IMAGE_ID='sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e'
readonly EXPECTED_REPLAY_SCHEMA=12
readonly SEALED_IMAGE_INSPECT="$EVIDENCE/image-inspect.json"
readonly SEALED_BASE_INSPECT="$EVIDENCE/base-image-inspect.json"

: "${TARGET_IMAGE_REF:?TARGET_IMAGE_REF is required}"
: "${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
: "${CONFIRM_PUBLISH:?CONFIRM_PUBLISH is required}"
: "${CONFIRM_EXCLUSIVE_PUBLICATION_AUTHORITY:?CONFIRM_EXCLUSIVE_PUBLICATION_AUTHORITY is required}"
readonly TARGET_IMAGE_REF SOURCE_COMMIT CONFIRM_PUBLISH CONFIRM_EXCLUSIVE_PUBLICATION_AUTHORITY

ATTEMPT_DIR=
CURRENT_TMP=

fail()
{
    printf 'FATAL: %s\n' "$*" >&2
    exit 1
}

cleanup_tmp()
{
    [[ -z "$CURRENT_TMP" ]] || rm -f -- "$CURRENT_TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT INT TERM

protected_file()
{
    local path="$1" mode="${2:-600}"
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" &&
       "$(stat -c '%u:%g:%a' "$path")" == "0:0:$mode" ]]
}

protected_directory()
{
    local path="$1" mode owner
    [[ -d "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] || return 1
    owner=$(stat -c '%u:%g' "$path") || return 1
    mode=$(stat -c '%a' "$path") || return 1
    [[ "$owner" == 0:0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

verify_package()
{
    local path mode
    protected_directory "$PACKAGE_ROOT" && protected_file "$PACKAGE_ROOT/SHA256SUMS" 600 || return 1
    [[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
       -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g' "$path")" == 0:0 ]] || return 1
        mode=$(stat -c '%a' "$path") || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
    done < <(find "$PACKAGE_ROOT" -print0)
    cmp -s \
        <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
            name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
        }' "$PACKAGE_ROOT/SHA256SUMS" | sort) || return 1
    (cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null)
}

verify_build_evidence()
{
    local path mode
    protected_directory "$BUILD_RUN" && protected_directory "$BUILD" &&
        protected_directory "$EVIDENCE" && protected_file "$BUILD_MANIFEST" 600 || return 1
    [[ -z "$(find "$BUILD" "$EVIDENCE" -type l -print -quit)" &&
       -z "$(find "$BUILD" "$EVIDENCE" ! -type d ! -type f -print -quit)" ]] || return 1
    while IFS= read -r -d '' path; do
        [[ "$(stat -c '%u:%g' "$path")" == 0:0 ]] || return 1
        mode=$(stat -c '%a' "$path") || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 0022) == 0 )) || return 1
    done < <(find "$BUILD" "$EVIDENCE" -print0)
    cmp -s \
        <(cd "$BUILD_RUN" && find build evidence -type f ! -path 'evidence/SHA256SUMS' -print | sort) \
        <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {name=$2; sub(/^\\*/, "", name); print name}' \
            "$BUILD_MANIFEST" | sort) || return 1
    (cd "$BUILD_RUN" && sha256sum --strict -c evidence/SHA256SUMS >/dev/null)
}

registry_token()
{
    curl -fsS \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${EXPECTED_REPOSITORY}:pull" |
        jq -er '.token | select(type == "string" and length > 20)'
}

manifest_url()
{
    printf 'https://registry-1.docker.io/v2/%s/manifests/%s\n' "$EXPECTED_REPOSITORY" "$1"
}

fetch_manifest()
{
    local token="$1" ref="$2" output="$3" headers="$4" status
    status=$(curl -sS -D "$headers" -o "$output" -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "$(manifest_url "$ref")") || return 1
    case "$status" in
        200) return 0 ;;
        404) return 44 ;;
        *) return 1 ;;
    esac
}

same_get_digest()
{
    local body="$1" headers="$2" digest body_sha
    digest=$(awk 'tolower($1) == "docker-content-digest:" {
        gsub(/\r/, "", $2); if ($2 ~ /^sha256:[0-9a-f]{64}$/) print $2
    }' "$headers") || return 1
    [[ "$(wc -l <<< "$digest")" -eq 1 && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    body_sha=$(sha256sum "$body" | awk '{print $1}') || return 1
    [[ "$digest" == "sha256:$body_sha" ]] || return 1
    printf '%s\n' "$digest"
}

verify_manifest_config()
{
    local manifest="$1" image_id="$2"
    jq -e --arg id "$image_id" '
        .schemaVersion == 2 and
        .mediaType == "application/vnd.docker.distribution.manifest.v2+json" and
        .config.mediaType == "application/vnd.docker.container.image.v1+json" and
        .config.digest == $id and (.layers | type) == "array" and (.layers | length) >= 1
    ' "$manifest" >/dev/null
}

fetch_config_blob()
{
    local token="$1" image_id="$2" output="$3" headers="$4" status body_sha header_digests digest
    status=$(curl -sS --location -D "$headers" -o "$output" -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        "https://registry-1.docker.io/v2/${EXPECTED_REPOSITORY}/blobs/${image_id}") || return 1
    [[ "$status" == 200 ]] || return 1
    body_sha=$(sha256sum "$output" | awk '{print $1}') || return 1
    [[ "$image_id" == "sha256:$body_sha" ]] || return 1
    header_digests=$(awk 'tolower($1) == "docker-content-digest:" {
        gsub(/\r/, "", $2); print $2
    }' "$headers") || return 1
    while IFS= read -r digest; do
        [[ -z "$digest" || "$digest" == "$image_id" ]] || return 1
    done <<< "$header_digests"
}

for command in awk cmp curl date docker find flock jq mkdir mktemp mv realpath rm sed \
    sha256sum sort stat sync wc; do
    command -v "$command" >/dev/null 2>&1 || fail "required command unavailable: $command"
done
[[ "$(id -u)" -eq 0 ]] || fail 'root is required on the native build host'
[[ "$CONFIRM_PUBLISH" == v30.1.4-publish-immutable-image ]] ||
    fail 'CONFIRM_PUBLISH must equal v30.1.4-publish-immutable-image'
[[ "$CONFIRM_EXCLUSIVE_PUBLICATION_AUTHORITY" == v30.1.4-exclusive-dockerhub-tag-writer ]] ||
    fail 'exclusive Docker Hub tag-writer authority was not confirmed'
[[ "$SOURCE_COMMIT" == "$EXPECTED_SOURCE_COMMIT" ]] || fail 'source commit is not the final signed release commit'
[[ "$TARGET_IMAGE_REF" == "$EXPECTED_TARGET_IMAGE" ]] || fail 'target image is not the exact v30.1.4 release tag'
verify_package || fail 'rollout package integrity verification failed'

run_name=${BUILD_RUN##*/}
[[ "${BUILD_RUN%/*}" == "$IMAGE_BUILD_ROOT" &&
   "$run_name" =~ ^build-[0-9]{8}T[0-9]{6}Z$ ]] ||
    fail 'build run name or parent is not canonical'
verify_build_evidence || fail 'native build evidence is not an exact authenticated file set'
for file in "$BUILD_RESULT" "$BUILD_INPUTS" "$IMAGE_ID_FILE" \
    "$SEALED_IMAGE_INSPECT" "$SEALED_BASE_INSPECT"; do
    protected_file "$file" 600 || fail "required build evidence is unsafe: $file"
done

IMAGE_ID=$(awk 'NF == 1 && $1 ~ /^sha256:[0-9a-f]{64}$/ {print $1}' "$IMAGE_ID_FILE")
readonly IMAGE_ID
[[ -n "$IMAGE_ID" ]] || fail 'sealed image ID is malformed'
BUILD_MANIFEST_SHA256=$(sha256sum "$BUILD_MANIFEST" | awk '{print $1}')
BUILD_RESULT_SHA256=$(sha256sum "$BUILD_RESULT" | awk '{print $1}')
BUILD_INPUTS_SHA256=$(sha256sum "$BUILD_INPUTS" | awk '{print $1}')
readonly BUILD_MANIFEST_SHA256 BUILD_RESULT_SHA256 BUILD_INPUTS_SHA256

jq -e --arg target "$TARGET_IMAGE_REF" --arg id "$IMAGE_ID" \
    --arg source "$EXPECTED_SOURCE_COMMIT" --arg tag "$EXPECTED_RELEASE_TAG" \
    --arg asset "$EXPECTED_ASSET" --arg artifact "$EXPECTED_ARTIFACT_SHA256" \
    --arg sums "$EXPECTED_SUMS_SHA256" --arg base_ref "$EXPECTED_BASE_IMAGE_REF" \
    --arg base_build_ref "$EXPECTED_BASE_BUILD_REF" --arg base_id "$EXPECTED_BASE_IMAGE_ID" \
    --arg replay_schema "$EXPECTED_REPLAY_SCHEMA" '
    .schema == 1 and .result == "passed" and .target_image == $target and
    .image_id == $id and .source_commit == $source and .release_tag == $tag and
    .release_asset == $asset and .artifact_sha256 == $artifact and
    .sha256sums_sha256 == $sums and .docker_server_platform == "linux/amd64" and
    .native_linux_amd64 == true and .base_rootfs_exact_prefix == true and
    .candidate_added_rootfs_layers == 1 and
    .base_image_ref == $base_ref and .base_build_ref == $base_build_ref and
    .base_image_id == $base_id and .replay_schema == $replay_schema and
    (.blackcoind_sha256 | test("^[0-9a-f]{64}$")) and
    (.blackcoin_cli_sha256 | test("^[0-9a-f]{64}$")) and
    .pull_performed == false and .production_containers_mutated == false
' "$BUILD_RESULT" >/dev/null || fail 'build result does not authorize this exact image'
jq -e --arg target "$TARGET_IMAGE_REF" --arg source "$EXPECTED_SOURCE_COMMIT" \
    --arg tag "$EXPECTED_RELEASE_TAG" --arg asset "$EXPECTED_ASSET" \
    --arg artifact "$EXPECTED_ARTIFACT_SHA256" --arg sums "$EXPECTED_SUMS_SHA256" \
    --arg base_ref "$EXPECTED_BASE_IMAGE_REF" --arg base_build_ref "$EXPECTED_BASE_BUILD_REF" \
    --arg base_id "$EXPECTED_BASE_IMAGE_ID" --arg replay_schema "$EXPECTED_REPLAY_SCHEMA" '
    .schema == 1 and .target_image == $target and .source_commit == $source and
    .release_tag == $tag and .release_asset == $asset and
    .artifact_sha256 == $artifact and .sha256sums_sha256 == $sums and
    .base_image_ref == $base_ref and .base_build_ref == $base_build_ref and
    .base_image_id == $base_id and .replay_schema == $replay_schema and
    .pull_allowed == false and .build_network == "none" and
    .docker_server_platform == "linux/amd64" and .native_linux_amd64_required == true and
    (.binaries | keys | sort) ==
      (["blackcoin-cli","blackcoin-qt","blackcoin-tx","blackcoin-util","blackcoin-wallet","blackcoind"] | sort) and
    all(.binaries[]; test("^[0-9a-f]{64}$"))
' "$BUILD_INPUTS" >/dev/null || fail 'sealed build inputs do not match the v30.1.4 publication contract'

base_inspect_tmp=$(mktemp /tmp/v3014-base-image-inspect.XXXXXX)
CURRENT_TMP="$base_inspect_tmp"
docker image inspect "$EXPECTED_BASE_IMAGE_REF" "$EXPECTED_BASE_BUILD_REF" > "$base_inspect_tmp"
jq -e --arg id "$EXPECTED_BASE_IMAGE_ID" '
    length == 2 and all(.[];
      .Id == $id and .Os == "linux" and .Architecture == "amd64" and
      .Config.User == "blackcoin" and .RootFS.Type == "layers" and
      (.RootFS.Layers | type) == "array" and (.RootFS.Layers | length) >= 1)
' "$base_inspect_tmp" >/dev/null || fail 'audited base refs are absent or changed before publication'
rm -f -- "$base_inspect_tmp"
CURRENT_TMP=

local_inspect_tmp=$(mktemp /tmp/v3014-local-image-inspect.XXXXXX)
CURRENT_TMP="$local_inspect_tmp"
docker image inspect "$TARGET_IMAGE_REF" > "$local_inspect_tmp"
jq -e --arg id "$IMAGE_ID" --arg source "$EXPECTED_SOURCE_COMMIT" \
    --arg artifact "$EXPECTED_ARTIFACT_SHA256" --arg sums "$EXPECTED_SUMS_SHA256" \
    --arg base_id "$EXPECTED_BASE_IMAGE_ID" --arg replay_schema "$EXPECTED_REPLAY_SCHEMA" \
    --slurpfile inputs "$BUILD_INPUTS" --slurpfile sealed "$SEALED_IMAGE_INSPECT" \
    --slurpfile base "$SEALED_BASE_INSPECT" '
    .[0] as $i | $sealed[0][0] as $s | $base[0][0] as $b |
    length == 1 and $i.Id == $id and $i.Os == "linux" and $i.Architecture == "amd64" and
    $s.Id == $id and $b.Id == $base_id and $b.Config.User == "blackcoin" and
    $i.RootFS.Type == "layers" and $s.RootFS.Layers == $i.RootFS.Layers and
    ($i.RootFS.Layers | length) == (($b.RootFS.Layers | length) + 1) and
    $i.RootFS.Layers[0:($b.RootFS.Layers | length)] == $b.RootFS.Layers and
    $i.Config.User == "blackcoin" and
    $i.Config.Entrypoint == $b.Config.Entrypoint and $i.Config.Cmd == $b.Config.Cmd and
    $i.Config.Healthcheck == $b.Config.Healthcheck and
    $i.Config.WorkingDir == $b.Config.WorkingDir and
    $i.Config.ExposedPorts == $b.Config.ExposedPorts and
    $i.Config.Labels["org.blackcoin.source.commit"] == $source and
    $i.Config.Labels["org.opencontainers.image.version"] == "v30.1.4" and
    $i.Config.Labels["org.opencontainers.image.revision"] == $source and
    $i.Config.Labels["org.blackcoin.artifact.sha256"] == $artifact and
    $i.Config.Labels["org.blackcoin.sha256sums.sha256"] == $sums and
    $i.Config.Labels["org.blackcoin.base.image.id"] == $base_id and
    $i.Config.Labels["org.blackcoin.replay.schema"] == $replay_schema and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-cli.sha256"] == $inputs[0].binaries["blackcoin-cli"] and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-qt.sha256"] == $inputs[0].binaries["blackcoin-qt"] and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-tx.sha256"] == $inputs[0].binaries["blackcoin-tx"] and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-util.sha256"] == $inputs[0].binaries["blackcoin-util"] and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-wallet.sha256"] == $inputs[0].binaries["blackcoin-wallet"] and
    $i.Config.Labels["org.blackcoin.binary.blackcoind.sha256"] == $inputs[0].binaries.blackcoind
' "$local_inspect_tmp" >/dev/null || fail 'local image identity, platform, or labels changed after sealing'
rm -f -- "$local_inspect_tmp"
CURRENT_TMP=

exec 9>"$PUBLISH_LOCK"
flock -w 60 9 || fail 'another image publication is active'
if [[ -e "$PUBLICATION_ROOT" || -L "$PUBLICATION_ROOT" ]]; then
    protected_directory "$PUBLICATION_ROOT" || fail 'publication evidence root is unsafe'
else
    install -d -m 700 -o root -g root "$PUBLICATION_ROOT"
fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
attempt=0
while :; do
    if ((attempt == 0)); then
        ATTEMPT_DIR="$PUBLICATION_ROOT/publish-$stamp"
    else
        ATTEMPT_DIR=$(printf '%s/publish-%s-retry-%02d' "$PUBLICATION_ROOT" "$stamp" "$attempt")
    fi
    [[ -e "$ATTEMPT_DIR" || -L "$ATTEMPT_DIR" ]] || break
    attempt=$((attempt + 1))
done
install -d -m 700 -o root -g root "$ATTEMPT_DIR"

token=$(registry_token) || fail 'could not acquire a Docker Hub pull token'
tag_body="$ATTEMPT_DIR/tag-manifest.json"
tag_headers="$ATTEMPT_DIR/tag-manifest.headers"
already_published=false
if fetch_manifest "$token" "${TARGET_IMAGE_REF##*:}" "$tag_body" "$tag_headers"; then
    already_published=true
else
    rc=$?
    [[ "$rc" -eq 44 ]] || fail 'Docker Hub manifest preflight failed'
    printf '%s\n' 'initial_tag_status=404' > "$ATTEMPT_DIR/registry-preflight.txt"
    rm -f -- "$tag_body" "$tag_headers"
    # Recheck immediately under the local publication lock. The separate
    # authority confirmation asserts that no other writer owns this unique tag.
    if fetch_manifest "$token" "${TARGET_IMAGE_REF##*:}" "$tag_body" "$tag_headers"; then
        already_published=true
    else
        rc=$?
        [[ "$rc" -eq 44 ]] || fail 'Docker Hub second manifest preflight failed'
        rm -f -- "$tag_body" "$tag_headers"
        docker push "$TARGET_IMAGE_REF" || fail 'Docker Hub image push failed'
        token=$(registry_token) || fail 'could not refresh the Docker Hub pull token'
        fetch_manifest "$token" "${TARGET_IMAGE_REF##*:}" "$tag_body" "$tag_headers" ||
            fail 'published manifest is not readable'
    fi
fi
verify_manifest_config "$tag_body" "$IMAGE_ID" || fail 'tag manifest config differs from the sealed image'
MANIFEST_DIGEST=$(same_get_digest "$tag_body" "$tag_headers") ||
    fail 'tag manifest body and same-GET registry digest do not match'
readonly MANIFEST_DIGEST

digest_body="$ATTEMPT_DIR/digest-manifest.json"
digest_headers="$ATTEMPT_DIR/digest-manifest.headers"
fetch_manifest "$token" "$MANIFEST_DIGEST" "$digest_body" "$digest_headers" ||
    fail 'registry manifest could not be refetched by immutable digest'
[[ "$(same_get_digest "$digest_body" "$digest_headers")" == "$MANIFEST_DIGEST" ]] ||
    fail 'digest-refetched manifest has a different content digest'
cmp -s "$tag_body" "$digest_body" || fail 'tag and digest manifest response bodies differ'
verify_manifest_config "$digest_body" "$IMAGE_ID" || fail 'digest manifest config differs from the sealed image'

config_body="$ATTEMPT_DIR/registry-config.json"
config_headers="$ATTEMPT_DIR/registry-config.headers"
fetch_config_blob "$token" "$IMAGE_ID" "$config_body" "$config_headers" ||
    fail 'registry config blob does not match the sealed local image ID'
jq -e --arg source "$EXPECTED_SOURCE_COMMIT" --arg artifact "$EXPECTED_ARTIFACT_SHA256" \
    --arg sums "$EXPECTED_SUMS_SHA256" --arg base_id "$EXPECTED_BASE_IMAGE_ID" \
    --arg replay_schema "$EXPECTED_REPLAY_SCHEMA" --slurpfile inputs "$BUILD_INPUTS" \
    --slurpfile sealed "$SEALED_IMAGE_INSPECT" --slurpfile base "$SEALED_BASE_INSPECT" '
    .architecture == "amd64" and .os == "linux" and .config.User == "blackcoin" and
    .config.Labels["org.blackcoin.source.commit"] == $source and
    .config.Labels["org.opencontainers.image.version"] == "v30.1.4" and
    .config.Labels["org.opencontainers.image.revision"] == $source and
    .config.Labels["org.blackcoin.artifact.sha256"] == $artifact and
    .config.Labels["org.blackcoin.sha256sums.sha256"] == $sums and
    .config.Labels["org.blackcoin.base.image.id"] == $base_id and
    .config.Labels["org.blackcoin.replay.schema"] == $replay_schema and
    .rootfs.type == "layers" and .rootfs.diff_ids == $sealed[0][0].RootFS.Layers and
    (.rootfs.diff_ids | length) == (($base[0][0].RootFS.Layers | length) + 1) and
    .rootfs.diff_ids[0:($base[0][0].RootFS.Layers | length)] == $base[0][0].RootFS.Layers and
    .config.Entrypoint == $base[0][0].Config.Entrypoint and
    .config.Cmd == $base[0][0].Config.Cmd and
    .config.Healthcheck == $base[0][0].Config.Healthcheck and
    .config.WorkingDir == $base[0][0].Config.WorkingDir and
    .config.ExposedPorts == $base[0][0].Config.ExposedPorts and
    .config.Labels["org.blackcoin.binary.blackcoin-cli.sha256"] == $inputs[0].binaries["blackcoin-cli"] and
    .config.Labels["org.blackcoin.binary.blackcoin-qt.sha256"] == $inputs[0].binaries["blackcoin-qt"] and
    .config.Labels["org.blackcoin.binary.blackcoin-tx.sha256"] == $inputs[0].binaries["blackcoin-tx"] and
    .config.Labels["org.blackcoin.binary.blackcoin-util.sha256"] == $inputs[0].binaries["blackcoin-util"] and
    .config.Labels["org.blackcoin.binary.blackcoin-wallet.sha256"] == $inputs[0].binaries["blackcoin-wallet"] and
    .config.Labels["org.blackcoin.binary.blackcoind.sha256"] == $inputs[0].binaries.blackcoind
' "$config_body" >/dev/null || fail 'registry config labels do not match the sealed build inputs'

IMMUTABLE_IMAGE_REF="${EXPECTED_REPOSITORY}@${MANIFEST_DIGEST}"
readonly IMMUTABLE_IMAGE_REF
result_tmp="$ATTEMPT_DIR/.PUBLISH_RESULT.json.$$"
CURRENT_TMP="$result_tmp"
jq -n --arg image "$TARGET_IMAGE_REF" --arg immutable "$IMMUTABLE_IMAGE_REF" \
    --arg image_id "$IMAGE_ID" --arg manifest "$MANIFEST_DIGEST" \
    --arg source "$EXPECTED_SOURCE_COMMIT" --arg build_manifest "$BUILD_MANIFEST_SHA256" \
    --arg build_result "$BUILD_RESULT_SHA256" --arg build_inputs "$BUILD_INPUTS_SHA256" \
    --argjson resumed "$already_published" \
    '{schema:1,result:"passed",target_image:$image,immutable_image:$immutable,
      image_id:$image_id,manifest_digest:$manifest,source_commit:$source,
      build_manifest_sha256:$build_manifest,build_result_sha256:$build_result,
      build_inputs_sha256:$build_inputs,
      remote_tag_preexisted_with_exact_bytes:$resumed,
      remote_manifest_same_get_digest_verified:true,
      remote_manifest_digest_refetched:true,remote_config_digest_verified:true,
      exclusive_publication_authority_asserted:true}' > "$result_tmp" || fail 'could not render publish result'
chmod 600 "$result_tmp"
chown root:root "$result_tmp"
sync -f "$result_tmp"
mv -fT -- "$result_tmp" "$ATTEMPT_DIR/PUBLISH_RESULT.json"
CURRENT_TMP=

find "$ATTEMPT_DIR" -type f -exec chmod 600 {} +
find "$ATTEMPT_DIR" -type f -exec chown root:root {} +
manifest_tmp="$ATTEMPT_DIR/.SHA256SUMS.$$"
CURRENT_TMP="$manifest_tmp"
(
    cd "$ATTEMPT_DIR"
    find . -type f ! -path './SHA256SUMS' ! -name '.SHA256SUMS.*' -print0 |
        sort -z | xargs -0 sha256sum
) > "$manifest_tmp"
chmod 600 "$manifest_tmp"
chown root:root "$manifest_tmp"
sync -f "$manifest_tmp"
mv -fT -- "$manifest_tmp" "$ATTEMPT_DIR/SHA256SUMS"
CURRENT_TMP=
cmp -s \
    <(cd "$ATTEMPT_DIR" && find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {name=$2; sub(/^\\*/, "", name); print name}' \
        "$ATTEMPT_DIR/SHA256SUMS" | sort) || fail 'publication manifest is not an exact relative file set'
(cd "$ATTEMPT_DIR" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
    fail 'publication evidence checksum verification failed'
sync -f "$ATTEMPT_DIR/SHA256SUMS"
sync -f "$ATTEMPT_DIR"
sync -f "$PUBLICATION_ROOT"
trap - EXIT INT TERM
printf 'IMAGE=%s\nIMAGE_ID=%s\nIMMUTABLE_IMAGE=%s\nEVIDENCE=%s\n' \
    "$TARGET_IMAGE_REF" "$IMAGE_ID" "$IMMUTABLE_IMAGE_REF" "$ATTEMPT_DIR/PUBLISH_RESULT.json"
