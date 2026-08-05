#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

[[ $# -ge 4 ]] || {
    printf 'usage: %s INPUT_POLICY OUTPUT_POLICY IMAGE_REF IMAGE_ID NODE...\n' "$0" >&2
    exit 64
}

input=$1
output=$2
image_ref=$3
image_id=$4
shift 4

[[ -f "$input" && ! -L "$input" && ! -e "$output" ]] || exit 65
[[ "$image_ref" =~ ^[A-Za-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] || exit 65
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 65
(($# >= 1 && $# <= 4)) || exit 65

nodes_json='[]'
for node in "$@"; do
    [[ "$node" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || exit 65
    padded=$(printf '%02d' "$node")
    nodes_json=$(jq -cn --argjson old "$nodes_json" --arg node "$padded" \
        '$old + [$node] | unique')
done
[[ "$(jq 'length' <<< "$nodes_json")" -eq "$#" ]] || exit 65

temporary="${output}.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT
jq --arg image_ref "$image_ref" --arg image_id "$image_id" \
   --argjson nodes "$nodes_json" '
    select(.schema == 1 and (.images | type == "object") and
      (.nodes | type == "object" and length == 32)) |
    .images.final3014 = {config_image:$image_ref,image_id:$image_id} |
    reduce $nodes[] as $node (. ; .nodes[$node] = "final3014")
' "$input" > "$temporary"

jq -e --arg image_ref "$image_ref" --arg image_id "$image_id" \
   --argjson nodes "$nodes_json" '
    .schema == 1 and .images.final3014.config_image == $image_ref and
    .images.final3014.image_id == $image_id and
    (.nodes | length == 32) and
    (. as $policy | all($nodes[]; $policy.nodes[.] == "final3014"))
' "$temporary" >/dev/null

mv -- "$temporary" "$output"
trap - EXIT
