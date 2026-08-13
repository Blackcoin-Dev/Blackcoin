#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C
export TZ=UTC
umask 077

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P)
readonly SELF_DIR
readonly V3015_PACKAGE="$SELF_DIR/v30.1.5-rollout-durability"
readonly NODE27_PACKAGE="$SELF_DIR/v30.1.4-node27-recovery-canary"

[[ -x "$V3015_PACKAGE/tests/run.sh" ]] || {
    printf 'FATAL: v30.1.5 aggregate suite is unavailable\n' >&2
    exit 1
}
[[ -x "$NODE27_PACKAGE/tests/run.sh" ]] || {
    printf 'FATAL: node27 dedicated suite is unavailable\n' >&2
    exit 1
}

# The v30.1.5 aggregate invokes its dedicated PoS-renewal and node30
# release-gate suites. Node27 remains a separately sealed installed-v30.1.4
# package, so this commit-level integration runner invokes it without creating
# a runtime dependency between the two deployment payloads.
bash "$V3015_PACKAGE/tests/run.sh"
bash "$NODE27_PACKAGE/tests/run.sh"

printf 'PASS: v30.1.5 fleet semantic integration suites\n'
