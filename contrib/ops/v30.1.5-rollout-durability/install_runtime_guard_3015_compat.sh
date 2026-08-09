#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

package_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck disable=SC1091 # Resolved from this sealed package at runtime.
source "$package_dir/lib/common.sh"

[[ $# == 5 ]] || {
    printf 'usage: %s (render|apply) REVIEWED_ENV RUNTIME_GUARD ENDPOINT_GUARD OUTPUT_DIR\n' "$0" >&2
    exit 64
}
mode=$1 env_file=$2 runtime=$3 endpoint=$4 output_dir=$5
[[ "$mode" == render || "$mode" == apply ]] || exit 64
if [[ "$mode" == apply ]]; then
    [[ $EUID == 0 ]] || v3015_die 'guard installation requires root'
    v3015_load_reviewed_env "$env_file"
else
    # Render is local/read-only with respect to the supplied guard pair.
    # shellcheck disable=SC1090
    source "$env_file"
fi
v3015_require_commands awk sha256sum grep cmp bash mkdir chmod rm
[[ -f "$runtime" && ! -L "$runtime" && -f "$endpoint" && ! -L "$endpoint" ]] ||
    v3015_die 'input guard pair missing'
[[ "$(v3015_sha256_file "$runtime")" == "$EXPECTED_RUNTIME_GUARD_SHA256" ]] ||
    v3015_die 'input runtime guard hash mismatch'
[[ "$(v3015_sha256_file "$endpoint")" == "$EXPECTED_ENDPOINT_GUARD_SHA256" ]] ||
    v3015_die 'input endpoint guard hash mismatch'
include="$package_dir/guard_rollout_maintenance_block.sh.inc"
[[ -f "$include" && ! -L "$include" ]] || v3015_die 'guard include missing'
! grep -q 'BEGIN V30.1.5 ROLLOUT MAINTENANCE INHIBITOR' "$runtime" ||
    v3015_die 'runtime guard already contains v30.1.5 inhibitor'
! grep -q 'BEGIN V30.1.5 ROLLOUT MAINTENANCE INHIBITOR' "$endpoint" ||
    v3015_die 'endpoint guard already contains v30.1.5 inhibitor'

insert_after_anchor()
{
    local input=$1 output=$2 anchor=$3 block=$4
    awk -v anchor="$anchor" -v block="$block" '
      BEGIN {
        while ((getline line < block) > 0) lines[++count] = line
        close(block)
        if (count == 0) exit 41
      }
      $0 == anchor {
        matches++
        print
        for (i=1; i<=count; i++) print lines[i]
        next
      }
      {print}
      END {if (matches != 1) exit 42}
    ' "$input" >"$output"
}

render_pair()
{
    local destination=$1 runtime_out endpoint_stage endpoint_out runtime_sha
    [[ ! -e "$destination" && ! -L "$destination" ]] ||
        v3015_die 'render output directory exists'
    mkdir -m 0700 -- "$destination"
    runtime_out="$destination/runtime.guard"
    endpoint_stage="$destination/.endpoint-stage"
    endpoint_out="$destination/endpoint.guard"
    insert_after_anchor "$runtime" "$runtime_out" 'flock -n 7 || exit 1' "$include"
    runtime_sha=$(v3015_sha256_file "$runtime_out")
    awk -v old="EXPECTED_RUNTIME_GUARD_SHA='$EXPECTED_RUNTIME_GUARD_SHA256'" \
      -v new="EXPECTED_RUNTIME_GUARD_SHA='$runtime_sha'" '
      $0 == old {matches++; $0=new}
      {print}
      END {if (matches != 1) exit 42}
    ' "$endpoint" >"$endpoint_stage"
    insert_after_anchor "$endpoint_stage" "$endpoint_out" 'flock -n 9 || exit 0' "$include"
    chmod 0755 "$runtime_out" "$endpoint_out"
    bash -n "$runtime_out"
    bash -n "$endpoint_out"
    grep -Fqx "EXPECTED_RUNTIME_GUARD_SHA='$runtime_sha'" "$endpoint_out"
    rm -- "$endpoint_stage"
}

if [[ "$mode" == render ]]; then
    render_pair "$output_dir"
    printf 'rendered guard pair: %s\n' "$output_dir"
    exit 0
fi

v3015_validate_release_env
v3015_require_commands find realpath stat sed wc flock install sync mv
v3015_verify_package_tree "$package_dir" || v3015_die 'sealed package tree is invalid'
if ! v3015_secure_regular_file "$runtime" 755 ||
   ! v3015_secure_ancestry "$runtime"; then
    v3015_die 'input runtime guard permissions/ancestry are unsafe'
fi
if ! v3015_secure_regular_file "$endpoint" 755 ||
   ! v3015_secure_ancestry "$endpoint"; then
    v3015_die 'input endpoint guard permissions/ancestry are unsafe'
fi
if ! v3015_secure_directory "$output_dir" ||
   ! v3015_secure_ancestry "$output_dir"; then
    v3015_die 'reviewed rendered guard directory is unsafe'
fi
nonce=${LIVE_EXECUTION_CLEARED##*:}
[[ "$RUNTIME_GUARD_INSTALL_CLEARED" == "v30.1.5-guard:${SOURCE_SHA}:${nonce}" ]] ||
    v3015_die 'nonce-bound runtime-guard installation authority missing'
[[ "$runtime" == "$RUNTIME_GUARD_PATH" && "$endpoint" == "$ENDPOINT_GUARD_PATH" ]] ||
    v3015_die 'apply target paths differ from reviewed paths'
exec 201>/run/blackcoin-endpoint-guard.lock
flock -n 201 || v3015_die 'endpoint guard is active'
exec 202>/var/run/blackcoin-wallet-runtime-guard.lock
flock -n 202 || v3015_die 'wallet runtime guard is active'
runtime_candidate="$output_dir/runtime.guard"
endpoint_candidate="$output_dir/endpoint.guard"
[[ -f "$runtime_candidate" && ! -L "$runtime_candidate" &&
   -f "$endpoint_candidate" && ! -L "$endpoint_candidate" ]] ||
    v3015_die 'reviewed rendered guard pair missing'
v3015_secure_regular_file "$runtime_candidate" 755 ||
    v3015_die 'reviewed runtime candidate permissions are unsafe'
v3015_secure_regular_file "$endpoint_candidate" 755 ||
    v3015_die 'reviewed endpoint candidate permissions are unsafe'
[[ "$(v3015_sha256_file "$runtime_candidate")" == "$RENDERED_RUNTIME_GUARD_SHA256" ]] ||
    v3015_die 'reviewed runtime candidate hash mismatch'
[[ "$(v3015_sha256_file "$endpoint_candidate")" == "$RENDERED_ENDPOINT_GUARD_SHA256" ]] ||
    v3015_die 'reviewed endpoint candidate hash mismatch'
bash -n "$runtime_candidate"
bash -n "$endpoint_candidate"

# Endpoint is installed first. A crash between the two renames makes its new
# runtime hash pin fail closed against the old runtime bytes. No supervisor can
# mutate the fleet through a partially installed pair.
endpoint_stage="${endpoint}.v3015.$$"
runtime_stage="${runtime}.v3015.$$"
trap 'rm -f -- "$endpoint_stage" "$runtime_stage"' EXIT
install -o root -g root -m 0755 -- "$endpoint_candidate" "$endpoint_stage"
install -o root -g root -m 0755 -- "$runtime_candidate" "$runtime_stage"
sync -f "$endpoint_stage"
sync -f "$runtime_stage"
mv -f -- "$endpoint_stage" "$endpoint"
mv -f -- "$runtime_stage" "$runtime"
trap - EXIT
[[ "$(v3015_sha256_file "$runtime")" == "$RENDERED_RUNTIME_GUARD_SHA256" &&
   "$(v3015_sha256_file "$endpoint")" == "$RENDERED_ENDPOINT_GUARD_SHA256" ]] ||
    v3015_die 'installed guard pair did not verify'
printf 'installed reviewed v30.1.5-compatible runtime/endpoint guard pair\n'
