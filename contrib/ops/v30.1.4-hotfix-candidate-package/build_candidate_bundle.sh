#!/usr/bin/env bash
export LC_ALL=C

# Assemble an unpublished linux/amd64 post-release hotfix-candidate bundle from
# two byte-identical exact-source builds. This adapter can pull only the pinned
# immutable v30.1.4 base and has no registry publication path.

set -Eeuo pipefail
umask 077
export TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
REPO_ROOT=$(CDPATH='' cd -P -- "$PACKAGE_ROOT/../../.." && pwd -P) || exit 1
readonly PACKAGE_ROOT REPO_ROOT
readonly POLICY=${1:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}
readonly PRIMARY=${2:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}
readonly VERIFIER=${3:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}
readonly SOURCE_SIGNATURE=${4:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}
readonly CORE_CI=${5:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}
readonly OUTPUT=${6:?usage: build_candidate_bundle.sh POLICY PRIMARY VERIFIER SOURCE_SIGNATURE CORE_CI OUTPUT}

: "${TOOLING_COMMIT:?TOOLING_COMMIT is required}"
: "${WORKFLOW_RUN_ID:?WORKFLOW_RUN_ID is required}"
: "${WORKFLOW_RUN_ATTEMPT:?WORKFLOW_RUN_ATTEMPT is required}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required}"
: "${CONFIRM_CANDIDATE_BUILD:?CONFIRM_CANDIDATE_BUILD is required}"
: "${ALLOW_IMMUTABLE_BASE_PULL:?ALLOW_IMMUTABLE_BASE_PULL is required}"
readonly TOOLING_COMMIT WORKFLOW_RUN_ID WORKFLOW_RUN_ATTEMPT SOURCE_DATE_EPOCH
readonly CONFIRM_CANDIDATE_BUILD ALLOW_IMMUTABLE_BASE_PULL
readonly EXPECTED_SOURCE='8a3a5aa1c01caf57acc694b836398c5acba969d0'
readonly EXPECTED_BASE_MANIFEST='sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly EXPECTED_BASE_CONFIG='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'
readonly EXPECTED_FINGERPRINT='SHA256:jAkpBudDw+ntWHSUx3e1KY+czAFjnlaPxQtRFtptL70'
readonly METADATA_TOOL="$REPO_ROOT/ci/release/generate_hotfix_candidate_metadata.py"
readonly REPRO_TOOL="$REPO_ROOT/ci/release/verify_reproducible.py"
readonly BINARY_NAMES=(blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind)

TEMP_ROOT=

fail()
{
    printf 'hotfix-candidate build failed: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
}
trap cleanup EXIT INT TERM

for command in awk chmod cmp cp date docker file find grep jq mkdir mktemp paste python3 \
    readlink realpath sha256sum skopeo sort stat tar; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[[ "$CONFIRM_CANDIDATE_BUILD" == BUILD_V30_1_4_HOTFIX_CANDIDATE_LINUX_X86_64 ]] ||
    fail 'candidate build confirmation is absent'
[[ "$ALLOW_IMMUTABLE_BASE_PULL" == 1 ]] || fail 'the one exact immutable base pull was not authorized'
[[ "$TOOLING_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'tooling commit is malformed'
[[ "$WORKFLOW_RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail 'workflow run ID is malformed'
[[ "$WORKFLOW_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || fail 'workflow run attempt is malformed'
[[ "$SOURCE_DATE_EPOCH" =~ ^[1-9][0-9]*$ ]] || fail 'source date epoch is malformed'

for path in "$POLICY" "$SOURCE_SIGNATURE" "$CORE_CI" "$METADATA_TOOL" "$REPRO_TOOL"; do
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] ||
        fail "input is missing or unsafe: $path"
done
for directory in "$PRIMARY" "$VERIFIER"; do
    [[ -d "$directory" && ! -L "$directory" && "$(realpath -e -- "$directory")" == "$directory" ]] ||
        fail "build input directory is missing or unsafe: $directory"
    [[ -z "$(find "$directory" -type l -print -quit)" &&
       -z "$(find "$directory" ! -type d ! -type f -print -quit)" ]] ||
        fail "build input directory contains an unsafe entry: $directory"
done
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail 'output path already exists'

python3 "$METADATA_TOOL" validate-policy --policy "$POLICY" >/dev/null ||
    fail 'candidate policy validation failed'
source_commit=$(jq -er '.source.commit' "$POLICY")
base_ref=$(jq -er '.base_image.reference' "$POLICY")
base_manifest=$(jq -er '.base_image.manifest_digest' "$POLICY")
base_config=$(jq -er '.base_image.config_digest' "$POLICY")
signing_fingerprint=$(jq -er '.source.signing_fingerprint' "$POLICY")
[[ "$source_commit" == "$EXPECTED_SOURCE" ]] || fail 'policy does not pin the approved Core source'
[[ "$base_manifest" == "$EXPECTED_BASE_MANIFEST" && "$base_config" == "$EXPECTED_BASE_CONFIG" ]] ||
    fail 'policy does not pin the immutable v30.1.4 base'
[[ "$base_ref" == "qqblackcoin/blackcoin-v4-gui@$EXPECTED_BASE_MANIFEST" ]] ||
    fail 'policy base reference is not digest-addressed'
[[ "$signing_fingerprint" == "$EXPECTED_FINGERPRINT" ]] || fail 'policy signing fingerprint changed'
short_source=${source_commit:0:12}
prefix="Blackcoin-30.1.4-hotfix-candidate-$short_source"
binary_tar="$prefix-Linux-x86_64.tar.gz"
source_marker="$prefix-SOURCE_COMMIT.txt"
binary_sums="$prefix-BINARY_SHA256SUMS.txt"
versions="$prefix-VERSIONS.txt"
toolchain="$prefix-TOOLCHAIN.txt"
readonly source_commit base_ref base_manifest base_config short_source prefix
readonly binary_tar source_marker binary_sums versions toolchain

expected_raw=$(printf '%s\n' "$binary_tar" "$source_marker" "$binary_sums" "$versions" "$toolchain" | sort)
for directory in "$PRIMARY" "$VERIFIER"; do
    actual_raw=$(find "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [[ "$actual_raw" == "$expected_raw" ]] || fail "raw build artifact set changed: $directory"
done
python3 "$REPRO_TOOL" --primary "$PRIMARY" --verifier "$VERIFIER" >/dev/null ||
    fail 'primary and verifier builds are not byte-identical'
[[ "$(<"$PRIMARY/$source_marker")" == "$source_commit" ]] || fail 'primary source marker changed'
[[ "$(<"$VERIFIER/$source_marker")" == "$source_commit" ]] || fail 'verifier source marker changed'

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/blackcoin-hotfix-candidate.XXXXXX") ||
    fail 'could not create temporary build root'
[[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]] || fail 'temporary build root is unsafe'
readonly BUILD_CONTEXT="$TEMP_ROOT/context"
readonly EXTRACTED="$BUILD_CONTEXT/binaries"
readonly DOCKERFILE="$BUILD_CONTEXT/Dockerfile"
readonly BASE_INSPECT="$TEMP_ROOT/base-inspect.json"
readonly IMAGE_INSPECT="$TEMP_ROOT/image-inspect.json"
readonly OCI_RAW_MANIFEST="$TEMP_ROOT/oci-manifest.json"
readonly OCI_CONFIG="$TEMP_ROOT/oci-config.json"
mkdir -p "$EXTRACTED"

entries=$(tar -tzf "$PRIMARY/$binary_tar" | paste -sd, -)
[[ "$entries" == 'blackcoin-cli,blackcoin-qt,blackcoin-tx,blackcoin-util,blackcoin-wallet,blackcoind' ]] ||
    fail 'binary archive must contain exactly the six expected root-level entries'
tar -xzf "$PRIMARY/$binary_tar" --no-same-owner --no-same-permissions -C "$EXTRACTED"
for binary in "${BINARY_NAMES[@]}"; do
    [[ -f "$EXTRACTED/$binary" && ! -L "$EXTRACTED/$binary" ]] || fail "unsafe binary: $binary"
    chmod 755 "$EXTRACTED/$binary"
    file "$EXTRACTED/$binary" | grep -Fq 'ELF 64-bit LSB pie executable, x86-64' ||
        fail "binary is not a linux/amd64 PIE: $binary"
done
(
    cd "$EXTRACTED"
    sha256sum "${BINARY_NAMES[@]}"
) > "$TEMP_ROOT/binary-sha256.txt"
cmp -s "$TEMP_ROOT/binary-sha256.txt" "$PRIMARY/$binary_sums" ||
    fail 'raw binary checksums do not match the extracted archive'
primary_hash=$(sha256sum "$PRIMARY/$binary_tar" | awk '{print $1}')
binary_sums_sha=$(sha256sum "$PRIMARY/$binary_sums" | awk '{print $1}')
readonly primary_hash binary_sums_sha
binary_hashes='{}'
for binary in "${BINARY_NAMES[@]}"; do
    digest=$(awk -v name="$binary" '$2 == name {print $1}' "$TEMP_ROOT/binary-sha256.txt")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "binary hash is malformed: $binary"
    binary_hashes=$(jq -c --arg name "$binary" --arg digest "$digest" '. + {($name):$digest}' <<< "$binary_hashes")
done
readonly binary_hashes

docker pull "$base_ref" >/dev/null || fail 'immutable v30.1.4 base pull failed'
[[ "$(docker image inspect -f '{{.Id}}' "$base_ref")" == "$base_config" ]] ||
    fail 'pulled base config digest changed'
docker image inspect "$base_ref" > "$BASE_INSPECT"
jq -e --arg config "$base_config" '
    length == 1 and .[0].Id == $config and .[0].Os == "linux" and
    .[0].Architecture == "amd64" and .[0].Config.User == "blackcoin" and
    .[0].Config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
    .[0].Config.Cmd == null and .[0].Config.WorkingDir == "/home/blackcoin" and
    .[0].Config.Healthcheck == null and .[0].RootFS.Type == "layers" and
    (.[0].RootFS.Layers | length) >= 1
' "$BASE_INSPECT" >/dev/null || fail 'immutable base runtime contract changed'
base_alias="blackcoin-hotfix-base:${base_config#sha256:}"
candidate_ref="qqblackcoin/blackcoin-v4-gui:30.1.4-hotfix-candidate-$short_source-ci1"
readonly base_alias candidate_ref
docker tag "$base_ref" "$base_alias"
[[ "$(docker image inspect -f '{{.Id}}' "$base_alias")" == "$base_config" ]] ||
    fail 'local base alias changed identity'
if docker image inspect "$candidate_ref" >/dev/null 2>&1; then
    fail 'refusing to overwrite an existing candidate image reference'
fi

{
    printf 'FROM %s\n\n' "$base_alias"
    printf 'USER root\n\n'
    printf 'COPY --chmod=0755 binaries/blackcoin-cli binaries/blackcoin-qt binaries/blackcoin-tx binaries/blackcoin-util binaries/blackcoin-wallet binaries/blackcoind /usr/local/bin/\n\n'
    printf 'LABEL org.blackcoin.release.channel="post-release-hotfix-candidate" \\\n'
    printf '      org.blackcoin.release.qualification="canary-only-not-release" \\\n'
    printf '      org.blackcoin.release.tag="none" \\\n'
    printf '      org.blackcoin.candidate.kind="post-release-hotfix-candidate" \\\n'
    printf '      org.blackcoin.candidate.published="false" \\\n'
    printf '      org.blackcoin.candidate.registry-pushed="false" \\\n'
    printf '      org.blackcoin.deployment.scope="canary-only" \\\n'
    printf '      org.blackcoin.source.commit="%s" \\\n' "$source_commit"
    printf '      org.blackcoin.source.verification="blackcoin-dev-ssh-plus-github-verified" \\\n'
    printf '      org.opencontainers.image.revision="%s" \\\n' "$source_commit"
    printf '      org.opencontainers.image.version="30.1.4-hotfix-candidate-%s" \\\n' "$short_source"
    printf '      org.blackcoin.base.image="%s" \\\n' "$base_ref"
    printf '      org.blackcoin.base.image.id="%s" \\\n' "$base_config"
    printf '      org.blackcoin.artifact.sha256="%s" \\\n' "$primary_hash"
    printf '      org.blackcoin.sha256sums.sha256="%s" \\\n' "$binary_sums_sha"
    printf '      org.blackcoin.package.verification="two-build-reproducible-plus-binary-sha256" \\\n'
    for binary in "${BINARY_NAMES[@]}"; do
        digest=$(jq -er --arg name "$binary" '.[$name]' <<< "$binary_hashes")
        if [[ "$binary" == blackcoind ]]; then
            printf '      org.blackcoin.binary.%s.sha256="%s"\n\n' "$binary" "$digest"
        else
            printf '      org.blackcoin.binary.%s.sha256="%s" \\\n' "$binary" "$digest"
        fi
    done
    printf 'USER blackcoin\n'
} > "$DOCKERFILE"
DOCKER_BUILDKIT=1 docker build --pull=false --network=none --no-cache \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -t "$candidate_ref" "$BUILD_CONTEXT" >/dev/null ||
    fail 'candidate image build failed'
docker image inspect "$candidate_ref" > "$IMAGE_INSPECT"
candidate_config=$(jq -er '.[0].Id | select(test("^sha256:[0-9a-f]{64}$"))' "$IMAGE_INSPECT")
readonly candidate_config

expected_labels=$(jq -n -c \
    --arg source "$source_commit" --arg short "$short_source" --arg base "$base_ref" \
    --arg base_config "$base_config" --arg artifact "$primary_hash" \
    --arg binary_sums "$binary_sums_sha" --argjson binaries "$binary_hashes" '
    {
      "org.blackcoin.release.channel":"post-release-hotfix-candidate",
      "org.blackcoin.release.qualification":"canary-only-not-release",
      "org.blackcoin.release.tag":"none",
      "org.blackcoin.candidate.kind":"post-release-hotfix-candidate",
      "org.blackcoin.candidate.published":"false",
      "org.blackcoin.candidate.registry-pushed":"false",
      "org.blackcoin.deployment.scope":"canary-only",
      "org.blackcoin.source.commit":$source,
      "org.blackcoin.source.verification":"blackcoin-dev-ssh-plus-github-verified",
      "org.opencontainers.image.revision":$source,
      "org.opencontainers.image.version":("30.1.4-hotfix-candidate-" + $short),
      "org.blackcoin.base.image":$base,
      "org.blackcoin.base.image.id":$base_config,
      "org.blackcoin.artifact.sha256":$artifact,
      "org.blackcoin.sha256sums.sha256":$binary_sums,
      "org.blackcoin.package.verification":"two-build-reproducible-plus-binary-sha256"
    } + ($binaries | with_entries(.key = ("org.blackcoin.binary." + .key + ".sha256")))
')
readonly expected_labels
jq -e -n --slurpfile image "$IMAGE_INSPECT" --slurpfile base "$BASE_INSPECT" \
    --argjson labels "$expected_labels" '
    $image[0][0] as $i | $base[0][0] as $b |
    $i.Os == "linux" and $i.Architecture == "amd64" and
    $i.Config.User == $b.Config.User and $i.Config.Entrypoint == $b.Config.Entrypoint and
    $i.Config.Cmd == $b.Config.Cmd and $i.Config.WorkingDir == $b.Config.WorkingDir and
    $i.Config.Healthcheck == $b.Config.Healthcheck and
    $i.Config.ExposedPorts == $b.Config.ExposedPorts and
    $i.RootFS.Type == "layers" and
    ($i.RootFS.Layers | length) == (($b.RootFS.Layers | length) + 1) and
    $i.RootFS.Layers[0:($b.RootFS.Layers | length)] == $b.RootFS.Layers and
    all($labels | to_entries[]; $i.Config.Labels[.key] == .value)
' >/dev/null || fail 'candidate image runtime, rootfs, or label contract changed'

docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
    --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum "$candidate_ref" \
    /usr/local/bin/blackcoin-cli /usr/local/bin/blackcoin-qt /usr/local/bin/blackcoin-tx \
    /usr/local/bin/blackcoin-util /usr/local/bin/blackcoin-wallet /usr/local/bin/blackcoind \
    > "$TEMP_ROOT/embedded-binary-sha256.txt"
for binary in "${BINARY_NAMES[@]}"; do
    digest=$(jq -er --arg name "$binary" '.[$name]' <<< "$binary_hashes")
    grep -Fqx "$digest  /usr/local/bin/$binary" "$TEMP_ROOT/embedded-binary-sha256.txt" ||
        fail "embedded binary hash changed: $binary"
done

for binary in blackcoin-cli blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint "/usr/local/bin/$binary" "$candidate_ref" -version \
        > "$TEMP_ROOT/$binary-version.txt"
    grep -Fqx "Source commit: $source_commit" "$TEMP_ROOT/$binary-version.txt" ||
        fail "$binary does not report the exact clean source"
    ! grep -Fq '(dirty)' "$TEMP_ROOT/$binary-version.txt" || fail "$binary reports a dirty source"
done
docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs '/tmp:rw,noexec,nosuid,nodev,mode=1777' \
    --entrypoint /bin/sh "$candidate_ref" -c '
        set -eu
        Xvfb :99 -screen 0 640x480x24 >/tmp/xvfb.log 2>&1 &
        xvfb_pid=$!
        trap '\''kill "$xvfb_pid" 2>/dev/null || true; wait "$xvfb_pid" 2>/dev/null || true'\'' EXIT
        attempt=0
        while [ ! -S /tmp/.X11-unix/X99 ]; do
            attempt=$((attempt + 1))
            [ "$attempt" -lt 100 ] || exit 1
            sleep 0.05
        done
        DISPLAY=:99 QT_QPA_PLATFORM=xcb /usr/local/bin/blackcoin-qt -version
    ' > "$TEMP_ROOT/blackcoin-qt-version.txt"
grep -Fqx "Source commit: $source_commit" "$TEMP_ROOT/blackcoin-qt-version.txt" ||
    fail 'blackcoin-qt does not report the exact clean source'
! grep -Fq '(dirty)' "$TEMP_ROOT/blackcoin-qt-version.txt" || fail 'blackcoin-qt reports a dirty source'

docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs '/tmp:rw,nosuid,nodev,mode=1777' \
    --entrypoint /bin/sh "$candidate_ref" -c '
        set -eu
        datadir=/tmp/blackcoin-regtest
        mkdir -p "$datadir"
        /usr/local/bin/blackcoind -regtest -datadir="$datadir" -server=1 -listen=0 \
            -dnsseed=0 -discover=0 -printtoconsole=1 > /tmp/blackcoind.log 2>&1 &
        daemon_pid=$!
        ready=0
        attempt=0
        while [ "$attempt" -lt 200 ]; do
            if /usr/local/bin/blackcoin-cli -regtest -datadir="$datadir" getnetworkinfo >/tmp/network.json 2>/dev/null; then
                ready=1
                break
            fi
            attempt=$((attempt + 1))
            sleep 0.05
        done
        if [ "$ready" -ne 1 ]; then
            cat /tmp/blackcoind.log >&2
            kill "$daemon_pid" 2>/dev/null || true
            wait "$daemon_pid" 2>/dev/null || true
            exit 1
        fi
        /usr/local/bin/blackcoin-cli -regtest -datadir="$datadir" stop >/dev/null
        wait "$daemon_pid"
        grep -q '"subversion"' /tmp/network.json
    ' > "$TEMP_ROOT/regtest-smoke.txt"

mkdir "$OUTPUT"
cp "$PRIMARY/$binary_tar" "$OUTPUT/$binary_tar"
cp "$PRIMARY/$binary_sums" "$OUTPUT/$binary_sums"
cp "$PRIMARY/$source_marker" "$OUTPUT/$source_marker"
cp "$PRIMARY/$toolchain" "$OUTPUT/$toolchain"
signature_name="$prefix-SOURCE-SIGNATURE.json"
core_ci_name="$prefix-CORE-CI.json"
cp "$SOURCE_SIGNATURE" "$OUTPUT/$signature_name"
cp "$CORE_CI" "$OUTPUT/$core_ci_name"
repro_name="$prefix-REPRODUCIBILITY.txt"
verifier_hash=$(sha256sum "$VERIFIER/$binary_tar" | awk '{print $1}')
{
    printf 'source_commit=%s\n' "$source_commit"
    printf 'method=two-isolated-builds-byte-identical\n'
    printf 'primary_artifact_sha256=%s\n' "$primary_hash"
    printf 'verifier_artifact_sha256=%s\n' "$verifier_hash"
    printf 'result=passed\n'
} > "$OUTPUT/$repro_name"
notice_name="$prefix-UNSIGNED-CANARY.txt"
{
    printf 'POST-RELEASE HOTFIX CANDIDATE - CANARY ONLY - NOT A RELEASE\n'
    printf 'source_commit=%s\n' "$source_commit"
    printf 'core_version_self_report=30.1.4\n'
    printf 'signed_source=true\n'
    printf 'artifact_platform_signed=false\n'
    printf 'tag=none\n'
    printf 'published=false\n'
    printf 'registry_pushed=false\n'
} > "$OUTPUT/$notice_name"

oci_name="blackcoin-v4-gui-30.1.4-hotfix-candidate-$short_source.oci.tar"
skopeo copy --format oci "docker-daemon:$candidate_ref" \
    "oci-archive:$OUTPUT/$oci_name:$candidate_ref" >/dev/null ||
    fail 'could not create the sealed OCI archive'
skopeo inspect --raw "oci-archive:$OUTPUT/$oci_name" > "$OCI_RAW_MANIFEST"
skopeo inspect --config "oci-archive:$OUTPUT/$oci_name" > "$OCI_CONFIG"
oci_manifest=$(skopeo inspect --format '{{.Digest}}' "oci-archive:$OUTPUT/$oci_name")
[[ "$oci_manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'OCI manifest digest is malformed'
oci_config=$(jq -er '.config.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$OCI_RAW_MANIFEST")
[[ "$oci_config" == "$candidate_config" ]] ||
    fail 'OCI archive config digest differs from the fully probed candidate image'
archive_sha=$(sha256sum "$OUTPUT/$oci_name" | awk '{print $1}')
jq -e --argjson labels "$expected_labels" '
    . as $config |
    $config.architecture == "amd64" and $config.os == "linux" and
    $config.config.User == "blackcoin" and
    $config.config.Entrypoint == ["/home/blackcoin/start-gui.sh"] and
    $config.config.Cmd == null and $config.config.WorkingDir == "/home/blackcoin" and
    $config.config.Healthcheck == null and
    all($labels | to_entries[]; $config.config.Labels[.key] == .value)
' "$OCI_CONFIG" >/dev/null || fail 'OCI archive config changed during conversion'
roundtrip_ref="blackcoin-hotfix-candidate-roundtrip:30.1.4-$short_source"
readonly roundtrip_ref
if docker image inspect "$roundtrip_ref" >/dev/null 2>&1; then
    fail 'refusing to overwrite an existing OCI round-trip image reference'
fi
skopeo copy "oci-archive:$OUTPUT/$oci_name" "docker-daemon:$roundtrip_ref" >/dev/null ||
    fail 'OCI archive could not be imported back into the local daemon'
[[ "$(docker image inspect -f '{{.Id}}' "$roundtrip_ref")" == "$oci_config" ]] ||
    fail 'OCI archive round-trip changed the candidate config digest'

oci_identity_name="$prefix-OCI-IDENTITY.json"
jq -n --arg classification POST_RELEASE_HOTFIX_CANDIDATE_CANARY_ONLY \
    --arg source "$source_commit" --arg image "$candidate_ref" --arg archive "$oci_name" \
    --arg archive_sha "$archive_sha" --arg manifest "$oci_manifest" --arg config "$oci_config" \
    --arg base_ref "$base_ref" --arg base_manifest "$base_manifest" --arg base_config "$base_config" \
    --argjson labels "$expected_labels" --argjson binaries "$binary_hashes" '
    {schema:1,classification:$classification,source_commit:$source,image_reference:$image,
     archive_name:$archive,archive_sha256:$archive_sha,image_manifest_digest:$manifest,
     image_config_digest:$config,base_reference:$base_ref,base_manifest_digest:$base_manifest,
     base_config_digest:$base_config,os:"linux",architecture:"amd64",user:"blackcoin",
     entrypoint:["/home/blackcoin/start-gui.sh"],cmd:null,working_dir:"/home/blackcoin",
     healthcheck:null,rootfs_base_prefix_exact:true,candidate_added_rootfs_layers:1,
     oci_roundtrip_verified:true,published:false,registry_pushed:false,
     labels:$labels,binaries:$binaries}
' > "$OUTPUT/$oci_identity_name"

manifest_name="$prefix-MANIFEST.json"
provenance_name="$prefix-PROVENANCE.intoto.json"
python3 "$METADATA_TOOL" generate --policy "$POLICY" --artifacts "$OUTPUT" \
    --adapter-sha "$TOOLING_COMMIT" --workflow-run-id "$WORKFLOW_RUN_ID" \
    --workflow-run-attempt "$WORKFLOW_RUN_ATTEMPT" --manifest "$OUTPUT/$manifest_name" \
    --provenance "$OUTPUT/$provenance_name" >/dev/null || fail 'candidate metadata generation failed'
checksums_name="$prefix-SHA256SUMS.txt"
(
    cd "$OUTPUT"
    find . -mindepth 1 -maxdepth 1 -type f ! -name "$checksums_name" -printf '%P\n' |
        sort | while IFS= read -r name; do sha256sum "$name"; done
) > "$OUTPUT/$checksums_name"
"$PACKAGE_ROOT/verify_candidate_bundle.sh" "$POLICY" "$OUTPUT" >/dev/null ||
    fail 'final candidate bundle verification failed'
printf 'CANDIDATE_BUNDLE=%s\nSOURCE_COMMIT=%s\nTOOLING_COMMIT=%s\nOCI_ARCHIVE=%s\n' \
    "$OUTPUT" "$source_commit" "$TOOLING_COMMIT" "$OUTPUT/$oci_name"
