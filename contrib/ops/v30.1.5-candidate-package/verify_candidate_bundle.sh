#!/usr/bin/env bash
export LC_ALL=C

# Read-only verifier for a sealed v30.1.5 candidate bundle. It does
# not invoke Docker, contact a registry, or trust a mutable image tag.

set -Eeuo pipefail
umask 077

PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
REPO_ROOT=$(CDPATH='' cd -P -- "$PACKAGE_ROOT/../../.." && pwd -P) || exit 1
readonly PACKAGE_ROOT REPO_ROOT
readonly POLICY=${1:?usage: verify_candidate_bundle.sh POLICY BUNDLE_DIR}
readonly BUNDLE=${2:?usage: verify_candidate_bundle.sh POLICY BUNDLE_DIR}
readonly METADATA_TOOL="$REPO_ROOT/ci/release/generate_v30_1_5_candidate_metadata.py"
readonly EXPECTED_SOURCE='a0695f22740e111d0487a194fb46f1bae05952c5'
readonly EXPECTED_SOURCE_TREE='86df040ae5eb8e819e940dd08364bcc177a72195'
readonly EXPECTED_BASE_MANIFEST='sha256:7a384dd5f12c15fb41b36868d946007524bebf97650883d533635658641e04a2'
readonly EXPECTED_BASE_CONFIG='sha256:620146d14a57fe0d5d1fc29a7d913d47787ba924c96ba06eeb1ddbe8efb73909'

fail()
{
    printf 'v30.1.5-candidate verification failed: %s\n' "$*" >&2
    exit 1
}

for command in awk cmp find jq python3 realpath sha256sum sort; do
    command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
for path in "$POLICY" "$METADATA_TOOL"; do
    [[ -f "$path" && ! -L "$path" && "$(realpath -e -- "$path")" == "$path" ]] ||
        fail "input is missing or unsafe: $path"
done
[[ -d "$BUNDLE" && ! -L "$BUNDLE" && "$(realpath -e -- "$BUNDLE")" == "$BUNDLE" ]] ||
    fail 'bundle directory is missing or unsafe'
[[ -z "$(find "$BUNDLE" -type l -print -quit)" &&
   -z "$(find "$BUNDLE" ! -type d ! -type f -print -quit)" ]] ||
    fail 'bundle contains a symlink or nonregular entry'

source_commit=$(jq -er '.source.commit' "$POLICY")
source_tree=$(jq -er '.source.tree' "$POLICY")
base_manifest=$(jq -er '.base_image.manifest_digest' "$POLICY")
base_config=$(jq -er '.base_image.config_digest' "$POLICY")
[[ "$source_commit" == "$EXPECTED_SOURCE" ]] || fail 'candidate source policy changed'
[[ "$source_tree" == "$EXPECTED_SOURCE_TREE" ]] || fail 'candidate source-tree policy changed'
[[ "$base_manifest" == "$EXPECTED_BASE_MANIFEST" ]] || fail 'base manifest policy changed'
[[ "$base_config" == "$EXPECTED_BASE_CONFIG" ]] || fail 'base config policy changed'
prefix="Blackcoin-30.1.5-candidate-${source_commit:0:12}"
checksums="$prefix-SHA256SUMS.txt"
readonly source_commit source_tree base_manifest base_config prefix checksums
[[ -f "$BUNDLE/$checksums" && ! -L "$BUNDLE/$checksums" ]] || fail 'checksum manifest is absent or unsafe'

cmp -s \
    <(cd "$BUNDLE" && find . -mindepth 1 -maxdepth 1 -type f ! -name "$checksums" -printf '%P\n' | sort) \
    <(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {name=$2; sub(/^\*/, "", name); print name}' \
        "$BUNDLE/$checksums" | sort) || fail 'checksum manifest does not cover the exact bundle file set'
(
    cd "$BUNDLE"
    sha256sum --strict --check "$checksums" >/dev/null
) || fail 'bundle checksum verification failed'
python3 "$METADATA_TOOL" verify --policy "$POLICY" --bundle "$BUNDLE" >/dev/null ||
    fail 'canonical manifest or provenance verification failed'
printf 'VERIFIED_CANDIDATE_BUNDLE=%s\nSOURCE_COMMIT=%s\nSOURCE_TREE=%s\nBASE_MANIFEST=%s\nBASE_CONFIG=%s\n' \
    "$BUNDLE" "$source_commit" "$source_tree" "$base_manifest" "$base_config"
