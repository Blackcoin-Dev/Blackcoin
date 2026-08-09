#!/usr/bin/env bash
export LC_ALL=C
set -Eeuo pipefail
umask 077

[[ $# -ge 5 ]] || {
    printf 'usage: %s INPUT OUTPUT IMAGE_REF IMAGE_ID ROLE NODE...\n' "$0" >&2
    exit 64
}
input=$1 output=$2 image_ref=$3 image_id=$4 role=$5
shift 5
[[ -f "$input" && ! -L "$input" && ! -e "$output" && ! -L "$output" ]] || exit 65
[[ "$image_ref" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] || exit 65
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 65
[[ "$role" == regular || "$role" == free_claim ]] || exit 65
(($# >= 1 && $# <= 4)) || exit 65

nodes='[]'
for node in "$@"; do
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || exit 65
    [[ "$role" == free_claim && "$node" == 30 || "$role" == regular && "$node" != 30 ]] || exit 65
    padded=$(printf '%02d' "$node")
    nodes=$(jq -cn --argjson old "$nodes" --arg node "$padded" '$old + [$node] | unique')
done
[[ "$(jq 'length' <<<"$nodes")" -eq "$#" ]] || exit 65

temporary="${output}.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT
jq --arg ref "$image_ref" --arg id "$image_id" --arg role "$role" --argjson nodes "$nodes" '
  select(.schema == 1 and (.images | type == "object") and
    (.nodes | type == "object" and length == 32)) |
  .images.v3015 = {config_image:$ref,image_id:$id,source_version:300105,
    subversion:"/Blackcoin:30.1.5/"} |
  reduce $nodes[] as $node (. ; .nodes[$node] =
    (if $role == "free_claim" then "v3015_free_claim" else "v3015_regular" end))
' "$input" >"$temporary"
jq -e --argjson nodes "$nodes" --arg role "$role" '
  (.nodes | length) == 32 and
  (. as $p | all($nodes[]; $p.nodes[.] ==
    (if $role == "free_claim" then "v3015_free_claim" else "v3015_regular" end)))
' "$temporary" >/dev/null
mv -- "$temporary" "$output"
trap - EXIT
