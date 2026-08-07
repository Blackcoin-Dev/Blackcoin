#!/usr/bin/env bash
export LC_ALL=C

# Resume the original sealed v30.1.4 transaction with the independently
# checksum-sealed compatibility implementation authorized by
# RESUME-COMPATIBILITY.json. The old package remains the transaction identity;
# this package supplies only the explicitly listed lifecycle fixes.

set -Eeuo pipefail
umask 077
export TZ=UTC

readonly RESUME_ACTION=${1:-preflight}
RESUME_PACKAGE_ROOT=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) ||
    exit 1
readonly RESUME_PACKAGE_ROOT
readonly TRANSACTION_PACKAGE_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/seal-root/v30.1.4-rollout-transaction
readonly TRANSACTION_ENV=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-c15d60a/rollout.env
readonly TRANSACTION_ENV_SHA256=6227fb0d2c20427911522f440639c3805285070b616e773561ec38c9f54abba9
readonly TARGET_RUN=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-fleet-rollout/rollout-20260806T094713Z

[[ "$(id -u)" -eq 0 ]] || {
    printf '%s\n' 'FATAL: compatible resume requires root on the Unraid host' >&2
    exit 1
}
[[ -f "$TRANSACTION_ENV" && ! -L "$TRANSACTION_ENV" &&
   "$(realpath -e -- "$TRANSACTION_ENV")" == "$TRANSACTION_ENV" &&
   "$(stat -c '%u:%g:%a' "$TRANSACTION_ENV")" == 0:0:600 &&
   "$(sha256sum "$TRANSACTION_ENV" | awk '{print $1}')" == "$TRANSACTION_ENV_SHA256" ]] || {
    printf '%s\n' 'FATAL: sealed rollout environment is absent or changed' >&2
    exit 1
}
# shellcheck disable=SC1090
source "$TRANSACTION_ENV"
export RESUME_RUN_DIR="$TARGET_RUN"
export WAVE_PLAN="$TRANSACTION_PACKAGE_ROOT/waves.txt"
export SEALED_TRANSACTION_PACKAGE_ROOT="$TRANSACTION_PACKAGE_ROOT"
export PATH="$RESUME_PACKAGE_ROOT/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

case "$RESUME_ACTION" in
    preflight)
        exec /bin/bash "$RESUME_PACKAGE_ROOT/fleet_rollout.sh" preflight
        ;;
    apply)
        [[ "${CONFIRM_APPLY:-}" == v30.1.4-exact-32 ]] || {
            printf '%s\n' 'FATAL: apply requires CONFIRM_APPLY=v30.1.4-exact-32' >&2
            exit 1
        }
        exec /bin/bash "$RESUME_PACKAGE_ROOT/fleet_rollout.sh" apply
        ;;
    rollback)
        [[ "${CONFIRM_ROLLBACK:-}" == v30.1.4-rollback ]] || {
            printf '%s\n' 'FATAL: rollback requires CONFIRM_ROLLBACK=v30.1.4-rollback' >&2
            exit 1
        }
        exec /bin/bash "$RESUME_PACKAGE_ROOT/fleet_rollout.sh" rollback "$TARGET_RUN"
        ;;
    *)
        printf '%s\n' 'Usage: resume_compatible_rollout.sh [preflight|apply|rollback]' >&2
        exit 64
        ;;
esac
