#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

[[ $# -eq 3 ]] || {
    printf 'usage: %s INPUT_GUARD OUTPUT_GUARD POLICY_SHA256\n' "$0" >&2
    exit 64
}

input=$1
output=$2
policy_sha=$3
[[ -f "$input" && ! -L "$input" && ! -e "$output" ]] || exit 65
[[ "$policy_sha" =~ ^[0-9a-f]{64}$ ]] || exit 65
[[ "$(grep -Ec '^EXPECTED_IMAGE_POLICY_SHA=' "$input")" -eq 1 ]] || exit 65

awk -v sha="$policy_sha" '
    /^EXPECTED_IMAGE_POLICY_SHA=/ {
        print "EXPECTED_IMAGE_POLICY_SHA=\047" sha "\047"
        changed++
        next
    }
    { print }
    END { if (changed != 1) exit 65 }
' "$input" > "$output"

bash -n "$output"
[[ "$(grep -Ec "^EXPECTED_IMAGE_POLICY_SHA='$policy_sha'$" "$output")" -eq 1 ]]
