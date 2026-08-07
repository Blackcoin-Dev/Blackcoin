#!/usr/bin/env bash
export LC_ALL=C

# Build adapter for the published v30.1.4 linux/amd64 package. It performs no
# download or pull, refuses target-tag overwrite, derives all binary pins only
# after verifying the release asset against both supplied immutable checksums,
# and probes the result with no network and a read-only root filesystem.

set -Eeuo pipefail
umask 077
export TZ=UTC

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
readonly PACKAGE_ROOT
readonly RUN_DIR=${1:?usage: build_release_image.sh RUN_DIR RELEASE_TAR SHA256SUMS}
readonly RELEASE_TAR=${2:?usage: build_release_image.sh RUN_DIR RELEASE_TAR SHA256SUMS}
readonly RELEASE_SUMS=${3:?usage: build_release_image.sh RUN_DIR RELEASE_TAR SHA256SUMS}

: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
: "${RELEASE_ASSET_NAME:?RELEASE_ASSET_NAME is required}"
: "${RELEASE_ARTIFACT_SHA256:?RELEASE_ARTIFACT_SHA256 is required}"
: "${RELEASE_SHA256SUMS_SHA256:?RELEASE_SHA256SUMS_SHA256 is required}"
: "${TARGET_IMAGE_REF:?TARGET_IMAGE_REF is required}"
: "${CONFIRM_BUILD:?CONFIRM_BUILD is required}"

readonly RELEASE_TAG SOURCE_COMMIT RELEASE_ASSET_NAME RELEASE_ARTIFACT_SHA256
readonly RELEASE_SHA256SUMS_SHA256 TARGET_IMAGE_REF CONFIRM_BUILD
readonly BASE_IMAGE_REF='qqblackcoin/blackcoin-v4-gui:30.1.1-alpha1-a6dba4b5a8e6716dd7e6e859a840de2a584d8d87'
readonly BASE_BUILD_REF='blackcoin-ops-base:alpha1-8670d7f4fd03'
readonly BASE_IMAGE_ID='sha256:8670d7f4fd03831426a4e2052e7328d71a5e559bc561ab9a584a737f05dc403e'
readonly IMAGE_BUILD_ROOT=${IMAGE_BUILD_ROOT:-/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-image-builds}
readonly BUILD="$RUN_DIR/build"
readonly INPUTS="$BUILD/inputs"
readonly BINARIES="$BUILD/binaries"
readonly EVIDENCE="$RUN_DIR/evidence"
readonly DOCKERFILE="$BUILD/Dockerfile"
readonly BINARY_SUMS="$EVIDENCE/BINARY_SHA256SUMS"
readonly BUILD_LOCK=/var/run/blackcoin-v30.1.4-image-build.lock
readonly SOURCE_LABEL_KEY=${SOURCE_LABEL_KEY:-org.blackcoin.source.commit}
readonly VERSION_LABEL_KEY=${VERSION_LABEL_KEY:-org.opencontainers.image.version}
readonly REPLAY_SCHEMA=12

PHASE=preflight
IMAGE_ID=
RUN_DIR_VALIDATED=0

fail()
{
    printf 'FATAL phase=%s: %s\n' "$PHASE" "$*" >&2
    exit 1
}

record_result()
{
    local rc=$? temporary
    trap - EXIT
    [[ "$rc" -ne 0 && "$RUN_DIR_VALIDATED" -eq 1 &&
       -d "$EVIDENCE" && ! -L "$EVIDENCE" ]] || exit "$rc"
    temporary="$EVIDENCE/.BUILD_FAILURE.json.$$"
    jq -n --arg result failed --arg phase "$PHASE" --argjson exit_code "$rc" \
        '{schema:1,result:$result,phase:$phase,exit_code:$exit_code,
          pull_performed:false,production_containers_mutated:false}' > "$temporary" || true
    if [[ -f "$temporary" ]]; then
        chmod 600 "$temporary" 2>/dev/null || true
        chown root:root "$temporary" 2>/dev/null || true
        mv -fT -- "$temporary" "$EVIDENCE/BUILD_FAILURE.json" 2>/dev/null || true
        sync -f "$EVIDENCE/BUILD_FAILURE.json" 2>/dev/null || true
    fi
    exit "$rc"
}
trap record_result EXIT

for command in awk cmp date docker file find flock grep install jq mktemp paste readlink realpath \
    sha256sum sort stat sync tar; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[[ -d "$PACKAGE_ROOT" && ! -L "$PACKAGE_ROOT" &&
   "$(realpath -e -- "$PACKAGE_ROOT")" == "$PACKAGE_ROOT" &&
   "$(stat -c '%u:%g' "$PACKAGE_ROOT")" == 0:0 ]] ||
    fail 'rollout package root is unsafe or is not root-owned'
package_mode=$(stat -c '%a' "$PACKAGE_ROOT")
if [[ ! "$package_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$package_mode & 0022) != 0 )); then
    fail 'rollout package root is group/world writable'
fi
[[ -f "$PACKAGE_ROOT/SHA256SUMS" && ! -L "$PACKAGE_ROOT/SHA256SUMS" &&
   "$(realpath -e -- "$PACKAGE_ROOT/SHA256SUMS")" == "$PACKAGE_ROOT/SHA256SUMS" &&
   "$(stat -c '%u:%g:%a' "$PACKAGE_ROOT/SHA256SUMS")" == 0:0:600 ]] ||
    fail 'rollout package checksum manifest is absent or unsafe'
[[ -z "$(find "$PACKAGE_ROOT" -type l -print -quit)" &&
   -z "$(find "$PACKAGE_ROOT" ! -type d ! -type f -print -quit)" ]] ||
    fail 'rollout package contains a symlink or nonregular entry'
while IFS= read -r -d '' path; do
    [[ "$(stat -c '%u:%g' "$path")" == 0:0 ]] ||
        fail "rollout package path is not root-owned: $path"
    path_mode=$(stat -c '%a' "$path")
    if [[ ! "$path_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$path_mode & 0022) != 0 )); then
        fail "rollout package path is group/world writable: $path"
    fi
done < <(find "$PACKAGE_ROOT" -print0)
cmp -s \
    <(cd "$PACKAGE_ROOT" && find . -type f ! -path './SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {
        name=$2; sub(/^\\*/, "", name); sub(/^[.]\//, "", name); print "./" name
    }' "$PACKAGE_ROOT/SHA256SUMS" | sort) ||
    fail 'rollout package manifest does not cover the exact package file set'
(cd "$PACKAGE_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null) ||
    fail 'rollout package bytes differ from the validated manifest'
[[ "$(id -u)" -eq 0 ]] || fail 'root is required on the native linux/amd64 build host'
[[ "$CONFIRM_BUILD" == v30.1.4-immutable-image-build ]] ||
    fail 'CONFIRM_BUILD must equal v30.1.4-immutable-image-build'
[[ "$RELEASE_TAG" == v30.1.4 ]] || fail 'release tag must be exactly v30.1.4'
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail 'source commit is malformed'
[[ "$RELEASE_ASSET_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'release asset name is unsafe'
[[ "${RELEASE_TAR##*/}" == "$RELEASE_ASSET_NAME" ]] || fail 'release tar basename differs from the pinned asset name'
[[ "$RELEASE_ARTIFACT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'release artifact hash is malformed'
[[ "$RELEASE_SHA256SUMS_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'SHA256SUMS hash is malformed'
[[ "$BASE_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'base image ID is malformed'
[[ "$BASE_BUILD_REF" =~ ^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$ &&
   "$BASE_BUILD_REF" != *:latest ]] || fail 'base build alias must be a unique local tag'
expected_target="qqblackcoin/blackcoin-v4-gui:30.1.4-final-${SOURCE_COMMIT:0:12}-ops1"
[[ "$TARGET_IMAGE_REF" == "$expected_target" ]] ||
    fail "target image must be exactly $expected_target"
[[ "$SOURCE_LABEL_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || fail 'source label key is unsafe'
[[ "$VERSION_LABEL_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || fail 'version label key is unsafe'
[[ "$REPLAY_SCHEMA" =~ ^[0-9]+$ ]] || fail 'replay schema label is malformed'
DOCKER_SERVER_PLATFORM=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}') ||
    fail 'Docker server platform is unavailable'
readonly DOCKER_SERVER_PLATFORM
[[ "$DOCKER_SERVER_PLATFORM" == linux/amd64 ]] ||
    fail "native Docker server must be linux/amd64, got $DOCKER_SERVER_PLATFORM"

exec 9>"$BUILD_LOCK"
flock -w 60 9 || fail 'image build lock is busy'
[[ -d "$IMAGE_BUILD_ROOT" && ! -L "$IMAGE_BUILD_ROOT" &&
   "$(realpath -e -- "$IMAGE_BUILD_ROOT")" == "$IMAGE_BUILD_ROOT" &&
   "$(stat -c '%u:%g:%a' "$IMAGE_BUILD_ROOT")" == 0:0:700 ]] ||
    fail 'image build root is unsafe'
run_basename=${RUN_DIR##*/}
[[ "${RUN_DIR%/*}" == "$IMAGE_BUILD_ROOT" &&
   "$run_basename" =~ ^build-[0-9]{8}T[0-9]{6}Z$ &&
   -d "$RUN_DIR" && ! -L "$RUN_DIR" && "$(realpath -e -- "$RUN_DIR")" == "$RUN_DIR" &&
   "$(stat -c '%u:%g:%a' "$RUN_DIR")" == 0:0:700 ]] ||
    fail 'run directory is unsafe or outside the build root'
RUN_DIR_VALIDATED=1
[[ ! -e "$BUILD" && ! -e "$EVIDENCE" ]] || fail 'build/evidence output already exists'
for input in "$RELEASE_TAR" "$RELEASE_SUMS"; do
    [[ -f "$input" && ! -L "$input" && "$(realpath -e -- "$input")" == "$input" &&
       "$(stat -c '%u:%g:%a' "$input")" == 0:0:600 ]] || fail "input is unsafe: $input"
done
[[ "$(sha256sum "$RELEASE_TAR" | awk '{print $1}')" == "$RELEASE_ARTIFACT_SHA256" ]] ||
    fail 'release tar does not match the independently pinned artifact SHA256'
[[ "$(sha256sum "$RELEASE_SUMS" | awk '{print $1}')" == "$RELEASE_SHA256SUMS_SHA256" ]] ||
    fail 'downloaded SHA256SUMS does not match its independently pinned SHA256'
[[ "$(awk -v file="$RELEASE_ASSET_NAME" -v sha="$RELEASE_ARTIFACT_SHA256" '
    $1 == sha {name=$2; sub(/^\*/, "", name); if (name == file) found++}
    END {print found+0}' "$RELEASE_SUMS")" -eq 1 ]] ||
    fail 'SHA256SUMS does not contain exactly one matching release-asset entry'
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE_REF" 2>/dev/null)" == "$BASE_IMAGE_ID" ]] ||
    fail 'exact audited alpha base image is absent or has the wrong ID; pulls are forbidden'
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_BUILD_REF" 2>/dev/null)" == "$BASE_IMAGE_ID" ]] ||
    fail 'exact local build alias is absent or does not resolve to the audited base ID'
docker image inspect "$BASE_IMAGE_REF" "$BASE_BUILD_REF" | jq -e --arg id "$BASE_IMAGE_ID" '
    length == 2 and all(.[];
      .Id == $id and .Os == "linux" and .Architecture == "amd64" and
      .Config.User == "blackcoin" and .RootFS.Type == "layers" and
      (.RootFS.Layers | type) == "array" and (.RootFS.Layers | length) >= 1)
' >/dev/null || fail 'base image and local build alias are not the exact linux/amd64 image'
if docker image inspect "$TARGET_IMAGE_REF" >/dev/null 2>&1; then
    fail "refusing to overwrite existing target image: $TARGET_IMAGE_REF"
fi

PHASE=copying-verified-inputs
install -d -m 700 -o root -g root "$BUILD" "$INPUTS" "$EVIDENCE"
# The base image runs as `blackcoin`. Docker bind-mounts BINARIES as the
# /candidate mount root during the no-network package probe, so it must be
# traversable (but not writable) by that runtime user.
install -d -m 755 -o root -g root "$BINARIES"
install -m 600 -o root -g root "$RELEASE_TAR" "$INPUTS/$RELEASE_ASSET_NAME"
install -m 600 -o root -g root "$RELEASE_SUMS" "$INPUTS/SHA256SUMS"
sync -f "$INPUTS/$RELEASE_ASSET_NAME"
sync -f "$INPUTS/SHA256SUMS"
sync -f "$INPUTS"
[[ "$(sha256sum "$INPUTS/$RELEASE_ASSET_NAME" | awk '{print $1}')" == "$RELEASE_ARTIFACT_SHA256" ]] ||
    fail 'protected archive copy changed'
[[ "$(sha256sum "$INPUTS/SHA256SUMS" | awk '{print $1}')" == "$RELEASE_SHA256SUMS_SHA256" ]] ||
    fail 'protected SHA256SUMS copy changed'

entries=$(tar -tzf "$INPUTS/$RELEASE_ASSET_NAME" | sort | paste -sd, -)
[[ "$entries" == 'blackcoin-cli,blackcoin-qt,blackcoin-tx,blackcoin-util,blackcoin-wallet,blackcoind' ]] ||
    fail 'release archive must contain exactly the six expected root-level binaries'
tar -xzf "$INPUTS/$RELEASE_ASSET_NAME" --no-same-owner --no-same-permissions -C "$BINARIES"
for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    [[ -f "$BINARIES/$binary" && ! -L "$BINARIES/$binary" ]] || fail "unsafe extracted binary: $binary"
    chown root:root "$BINARIES/$binary"
    chmod 755 "$BINARIES/$binary"
    file "$BINARIES/$binary" | grep -Fq 'ELF 64-bit LSB pie executable, x86-64' ||
        fail "binary is not a native linux/amd64 PIE: $binary"
done
(
    cd "$BINARIES"
    sha256sum blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind
) > "$BINARY_SUMS"
chmod 600 "$BINARY_SUMS"
chown root:root "$BINARY_SUMS"

sha_for()
{
    awk -v binary="$1" '$2 == binary {print $1}' "$BINARY_SUMS"
}

probe_binary_version()
{
    local image="$1" binary_path="$2" output="$3"
    shift 3
    local -a extra_run_args=("$@")
    if [[ "${binary_path##*/}" == blackcoin-qt ]]; then
        # The published Qt package ships xcb (not the minimal/offscreen QPA
        # plugins). Exercise it against the audited base's Xvfb, still as the
        # unprivileged runtime user in a no-network, read-only container.
        docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
            --security-opt no-new-privileges \
            --tmpfs '/tmp:rw,noexec,nosuid,nodev,mode=1777' "${extra_run_args[@]}" \
            --entrypoint /bin/sh "$image" -c '
                set -eu
                Xvfb :99 -screen 0 640x480x24 >/tmp/xvfb.log 2>&1 &
                xvfb_pid=$!
                cleanup() {
                    kill "$xvfb_pid" 2>/dev/null || true
                    wait "$xvfb_pid" 2>/dev/null || true
                }
                trap cleanup EXIT INT TERM
                attempt=0
                while [ ! -S /tmp/.X11-unix/X99 ]; do
                    attempt=$((attempt + 1))
                    [ "$attempt" -lt 100 ] || {
                        cat /tmp/xvfb.log >&2
                        exit 1
                    }
                    sleep 0.05
                done
                DISPLAY=:99 QT_QPA_PLATFORM=xcb "$1" -version
            ' _ "$binary_path" > "$output"
    else
        docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
            --security-opt no-new-privileges "${extra_run_args[@]}" \
            --entrypoint "$binary_path" "$image" -version > "$output"
    fi
}

cli_sha=$(sha_for blackcoin-cli)
qt_sha=$(sha_for blackcoin-qt)
tx_sha=$(sha_for blackcoin-tx)
util_sha=$(sha_for blackcoin-util)
wallet_sha=$(sha_for blackcoin-wallet)
daemon_sha=$(sha_for blackcoind)
for hash in "$cli_sha" "$qt_sha" "$tx_sha" "$util_sha" "$wallet_sha" "$daemon_sha"; do
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail 'failed to derive all six binary SHA256 pins'
done
readonly cli_sha qt_sha tx_sha util_sha wallet_sha daemon_sha

PHASE=rendering-dockerfile
{
    # Dockerfile FROM requires a valid image reference. The unique local alias
    # is checked against the audited config ID before and after the build.
    printf 'FROM %s\n\n' "$BASE_BUILD_REF"
    printf 'USER root\n\n'
    printf 'COPY --chmod=0755 binaries/blackcoin-cli binaries/blackcoin-qt binaries/blackcoin-tx binaries/blackcoin-util binaries/blackcoin-wallet binaries/blackcoind /usr/local/bin/\n\n'
    printf 'LABEL org.blackcoin.release.channel="final-production" \\\n'
    printf '      org.blackcoin.release.tag="%s" \\\n' "$RELEASE_TAG"
    printf '      org.blackcoin.release.qualification="published-package-ops-canary-pending" \\\n'
    printf '      %s="%s" \\\n' "$SOURCE_LABEL_KEY" "$SOURCE_COMMIT"
    printf '      %s="%s" \\\n' "$VERSION_LABEL_KEY" "$RELEASE_TAG"
    printf '      org.opencontainers.image.revision="%s" \\\n' "$SOURCE_COMMIT"
    printf '      org.blackcoin.source.verification="operator-pinned-commit" \\\n'
    printf '      org.blackcoin.package.verification="sha256sums-plus-independent-pin" \\\n'
    printf '      org.blackcoin.artifact.sha256="%s" \\\n' "$RELEASE_ARTIFACT_SHA256"
    printf '      org.blackcoin.sha256sums.sha256="%s" \\\n' "$RELEASE_SHA256SUMS_SHA256"
    printf '      org.blackcoin.binary.blackcoin-cli.sha256="%s" \\\n' "$cli_sha"
    printf '      org.blackcoin.binary.blackcoin-qt.sha256="%s" \\\n' "$qt_sha"
    printf '      org.blackcoin.binary.blackcoin-tx.sha256="%s" \\\n' "$tx_sha"
    printf '      org.blackcoin.binary.blackcoin-util.sha256="%s" \\\n' "$util_sha"
    printf '      org.blackcoin.binary.blackcoin-wallet.sha256="%s" \\\n' "$wallet_sha"
    printf '      org.blackcoin.binary.blackcoind.sha256="%s" \\\n' "$daemon_sha"
    printf '      org.blackcoin.base.image.id="%s" \\\n' "$BASE_IMAGE_ID"
    printf '      org.blackcoin.replay.schema="%s"\n\n' "$REPLAY_SCHEMA"
    printf 'USER blackcoin\n'
} > "$DOCKERFILE"
chmod 600 "$DOCKERFILE"
chown root:root "$DOCKERFILE"
dockerfile_sha=$(sha256sum "$DOCKERFILE" | awk '{print $1}')
readonly dockerfile_sha

jq -n \
    --arg release_tag "$RELEASE_TAG" --arg source_commit "$SOURCE_COMMIT" \
    --arg asset "$RELEASE_ASSET_NAME" --arg artifact "$RELEASE_ARTIFACT_SHA256" \
    --arg sums "$RELEASE_SHA256SUMS_SHA256" --arg base_ref "$BASE_IMAGE_REF" \
    --arg base_build_ref "$BASE_BUILD_REF" \
    --arg base_id "$BASE_IMAGE_ID" --arg target "$TARGET_IMAGE_REF" \
    --arg replay_schema "$REPLAY_SCHEMA" \
    --arg dockerfile "$dockerfile_sha" --arg server_platform "$DOCKER_SERVER_PLATFORM" \
    --arg cli "$cli_sha" --arg qt "$qt_sha" --arg tx "$tx_sha" --arg util "$util_sha" \
    --arg wallet "$wallet_sha" --arg daemon "$daemon_sha" '
    {schema:1,release_tag:$release_tag,source_commit:$source_commit,
      release_asset:$asset,artifact_sha256:$artifact,sha256sums_sha256:$sums,
      base_image_ref:$base_ref,base_build_ref:$base_build_ref,
      base_image_id:$base_id,replay_schema:$replay_schema,target_image:$target,
      dockerfile_sha256:$dockerfile,pull_allowed:false,build_network:"none",
      docker_server_platform:$server_platform,native_linux_amd64_required:true,
      binaries:{"blackcoin-cli":$cli,"blackcoin-qt":$qt,"blackcoin-tx":$tx,
        "blackcoin-util":$util,"blackcoin-wallet":$wallet,"blackcoind":$daemon}}
' > "$EVIDENCE/BUILD_INPUTS.json"
chmod 600 "$EVIDENCE/BUILD_INPUTS.json"
chown root:root "$EVIDENCE/BUILD_INPUTS.json"

# Prove the extracted package itself before image construction. The audited
# base supplies the loader/libraries; the candidate binaries are mounted RO.
PHASE=probing-package
for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    probe_binary_version "$BASE_IMAGE_REF" "/candidate/$binary" \
        "$EVIDENCE/package-$binary-version.txt" -v "$BINARIES:/candidate:ro"
    grep -Fq 'v30.1.4' "$EVIDENCE/package-$binary-version.txt" || fail "$binary version is not v30.1.4"
done
grep -Fq "$SOURCE_COMMIT" "$EVIDENCE/package-blackcoind-version.txt" ||
    fail 'package blackcoind does not report the exact source commit'

PHASE=building-image
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE_REF")" == "$BASE_IMAGE_ID" ]] ||
    fail 'base image identity changed before build'
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_BUILD_REF")" == "$BASE_IMAGE_ID" ]] ||
    fail 'base build alias identity changed before build'
if docker image inspect "$TARGET_IMAGE_REF" >/dev/null 2>&1; then
    fail 'target image appeared during protected preparation; refusing overwrite'
fi
DOCKER_BUILDKIT=1 docker build --pull=false --network=none --no-cache \
    -t "$TARGET_IMAGE_REF" "$BUILD"
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$TARGET_IMAGE_REF")
[[ "$IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'built image ID is malformed'
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_IMAGE_REF")" == "$BASE_IMAGE_ID" ]] ||
    fail 'base image identity changed during build'
[[ "$(docker image inspect -f '{{.Id}}' "$BASE_BUILD_REF")" == "$BASE_IMAGE_ID" ]] ||
    fail 'base build alias identity changed during build'

PHASE=probing-image
docker image inspect "$TARGET_IMAGE_REF" > "$EVIDENCE/image-inspect.json"
docker image inspect "$BASE_BUILD_REF" > "$EVIDENCE/base-image-inspect.json"
jq -e -n \
    --slurpfile image "$EVIDENCE/image-inspect.json" \
    --slurpfile base "$EVIDENCE/base-image-inspect.json" \
    --arg image_id "$IMAGE_ID" --arg source "$SOURCE_COMMIT" --arg tag "$RELEASE_TAG" \
    --arg artifact "$RELEASE_ARTIFACT_SHA256" --arg sums "$RELEASE_SHA256SUMS_SHA256" \
    --arg base_id "$BASE_IMAGE_ID" --arg schema "$REPLAY_SCHEMA" \
    --arg source_key "$SOURCE_LABEL_KEY" --arg version_key "$VERSION_LABEL_KEY" \
    --arg cli "$cli_sha" --arg qt "$qt_sha" --arg tx "$tx_sha" --arg util "$util_sha" \
    --arg wallet "$wallet_sha" --arg daemon "$daemon_sha" '
    ($image[0][0]) as $i | ($base[0][0]) as $b |
    $i.Id == $image_id and $i.Os == "linux" and $i.Architecture == "amd64" and
    $b.Os == "linux" and $b.Architecture == "amd64" and
    $i.RootFS.Type == "layers" and $b.RootFS.Type == "layers" and
    ($i.RootFS.Layers | length) == (($b.RootFS.Layers | length) + 1) and
    $i.RootFS.Layers[0:($b.RootFS.Layers | length)] == $b.RootFS.Layers and
    $i.Config.User == "blackcoin" and
    $i.Config.Entrypoint == $b.Config.Entrypoint and $i.Config.Cmd == $b.Config.Cmd and
    $i.Config.Healthcheck == $b.Config.Healthcheck and
    $i.Config.WorkingDir == $b.Config.WorkingDir and
    $i.Config.ExposedPorts == $b.Config.ExposedPorts and
    $i.Config.Labels[$source_key] == $source and
    $i.Config.Labels[$version_key] == $tag and
    $i.Config.Labels["org.opencontainers.image.revision"] == $source and
    $i.Config.Labels["org.blackcoin.release.tag"] == $tag and
    $i.Config.Labels["org.blackcoin.artifact.sha256"] == $artifact and
    $i.Config.Labels["org.blackcoin.sha256sums.sha256"] == $sums and
    $i.Config.Labels["org.blackcoin.base.image.id"] == $base_id and
    $i.Config.Labels["org.blackcoin.replay.schema"] == $schema and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-cli.sha256"] == $cli and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-qt.sha256"] == $qt and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-tx.sha256"] == $tx and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-util.sha256"] == $util and
    $i.Config.Labels["org.blackcoin.binary.blackcoin-wallet.sha256"] == $wallet and
    $i.Config.Labels["org.blackcoin.binary.blackcoind.sha256"] == $daemon
' >/dev/null || fail 'built image contract or labels differ from the audited template'

docker run --rm --pull=never --network none --read-only --user blackcoin --cap-drop ALL \
    --security-opt no-new-privileges --entrypoint /usr/bin/sha256sum \
    "$TARGET_IMAGE_REF" /usr/local/bin/blackcoin-cli /usr/local/bin/blackcoin-qt \
    /usr/local/bin/blackcoin-tx /usr/local/bin/blackcoin-util \
    /usr/local/bin/blackcoin-wallet /usr/local/bin/blackcoind \
    > "$EVIDENCE/embedded-binary-sha256.txt"
for binary in blackcoin-cli blackcoin-qt blackcoin-tx blackcoin-util blackcoin-wallet blackcoind; do
    expected=$(sha_for "$binary")
    grep -Fqx "$expected  /usr/local/bin/$binary" "$EVIDENCE/embedded-binary-sha256.txt" ||
        fail "embedded hash mismatch: $binary"
    probe_binary_version "$TARGET_IMAGE_REF" "/usr/local/bin/$binary" \
        "$EVIDENCE/image-$binary-version.txt"
    grep -Fq 'v30.1.4' "$EVIDENCE/image-$binary-version.txt" || fail "image $binary version mismatch"
done
grep -Fq "$SOURCE_COMMIT" "$EVIDENCE/image-blackcoind-version.txt" ||
    fail 'image blackcoind source commit mismatch'

PHASE=finalizing-evidence
printf '%s\n' "$IMAGE_ID" > "$EVIDENCE/image-id.txt"
result_tmp=$(mktemp "$EVIDENCE/.BUILD_RESULT.XXXXXX") || fail 'could not create build result'
jq -n --arg result passed --arg image "$TARGET_IMAGE_REF" --arg image_id "$IMAGE_ID" \
    --arg source "$SOURCE_COMMIT" --arg tag "$RELEASE_TAG" \
    --arg asset "$RELEASE_ASSET_NAME" --arg artifact "$RELEASE_ARTIFACT_SHA256" \
    --arg sums "$RELEASE_SHA256SUMS_SHA256" --arg server "$DOCKER_SERVER_PLATFORM" \
    --arg daemon "$daemon_sha" --arg cli "$cli_sha" \
    --arg base_ref "$BASE_IMAGE_REF" --arg base_build_ref "$BASE_BUILD_REF" \
    --arg base_id "$BASE_IMAGE_ID" --arg replay_schema "$REPLAY_SCHEMA" \
    '{schema:1,result:$result,target_image:$image,image_id:$image_id,
      source_commit:$source,release_tag:$tag,release_asset:$asset,
      artifact_sha256:$artifact,sha256sums_sha256:$sums,
      docker_server_platform:$server,native_linux_amd64:true,
      blackcoind_sha256:$daemon,blackcoin_cli_sha256:$cli,
      base_image_ref:$base_ref,base_build_ref:$base_build_ref,
      base_image_id:$base_id,replay_schema:$replay_schema,
      base_rootfs_exact_prefix:true,candidate_added_rootfs_layers:1,
      pull_performed:false,production_containers_mutated:false}' > "$result_tmp" ||
    fail 'could not render successful build result'
chmod 600 "$result_tmp"
chown root:root "$result_tmp"
sync -f "$result_tmp"
mv -fT -- "$result_tmp" "$EVIDENCE/BUILD_RESULT.json"
sync -f "$EVIDENCE/BUILD_RESULT.json"
[[ -z "$(find "$BUILD" "$EVIDENCE" -type l -print -quit)" &&
   -z "$(find "$BUILD" "$EVIDENCE" ! -type d ! -type f -print -quit)" ]] ||
    fail 'build evidence contains a symlink or nonregular entry'
while IFS= read -r -d '' path; do
    [[ "$(stat -c '%u:%g' "$path")" == 0:0 ]] || fail "build evidence is not root-owned: $path"
    path_mode=$(stat -c '%a' "$path")
    if [[ ! "$path_mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$path_mode & 0022) != 0 )); then
        fail "build evidence is group/world writable: $path"
    fi
done < <(find "$BUILD" "$EVIDENCE" -print0)
(
    cd "$RUN_DIR"
    find build evidence -type f ! -path 'evidence/SHA256SUMS' \
        -print0 | sort -z | xargs -0 sha256sum > evidence/SHA256SUMS
)
chmod 600 "$EVIDENCE"/*
chown root:root "$EVIDENCE"/*
cmp -s \
    <(cd "$RUN_DIR" && find build evidence -type f ! -path 'evidence/SHA256SUMS' -print | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {name=$2; sub(/^\\*/, "", name); print name}' \
        "$EVIDENCE/SHA256SUMS" | sort) || fail 'sealed build manifest is not an exact file set'
(
    cd "$RUN_DIR"
    sha256sum --strict -c evidence/SHA256SUMS >/dev/null
) || fail 'sealed build evidence failed checksum verification'
sync -f "$EVIDENCE/SHA256SUMS"
sync -f "$EVIDENCE"
sync -f "$RUN_DIR"
PHASE=complete
printf 'IMAGE=%s\nIMAGE_ID=%s\nEVIDENCE=%s\n' "$TARGET_IMAGE_REF" "$IMAGE_ID" "$EVIDENCE"
