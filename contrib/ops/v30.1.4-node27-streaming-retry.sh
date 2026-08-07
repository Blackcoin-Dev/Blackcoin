#!/usr/bin/env bash
export LC_ALL=C

# One-time attempt-3 launcher for the sealed node-27 adoption package. It
# changes only the wallet audit transport: large listtransactions JSON is fed
# to jq on stdin instead of being copied into argv. All mutation, locking,
# containment, retry, activation and terminal evidence remain implemented and
# verified by the exact sealed adoption package below.

set -Eeuo pipefail
umask 077
export TZ=UTC

readonly SEALED_ROOT=/mnt/pulsar/Blackcoin_Blocks/operations/v30.1.4-packages/rollout-express-readoption-20260806T1323Z/seal-root/v30.1.4-rollout-transaction
readonly SEALED_MANIFEST_SHA256=dadcca0cd0b9f742021cb92f7287afd7db61b9f359a9b78dfe01e89d5ccb49bd
readonly SEALED_ADOPTION="$SEALED_ROOT/adopt_contained_node27.sh"

[[ "$(id -u)" -eq 0 && -f "$SEALED_ADOPTION" && ! -L "$SEALED_ADOPTION" &&
   "$(sha256sum "$SEALED_ROOT/SHA256SUMS" | awk '{print $1}')" == "$SEALED_MANIFEST_SHA256" ]] || {
    printf '%s\n' 'FATAL: sealed node27 adoption package is absent or changed' >&2
    exit 1
}
(cd "$SEALED_ROOT" && sha256sum --strict -c SHA256SUMS >/dev/null) || {
    printf '%s\n' 'FATAL: sealed node27 adoption package integrity failed' >&2
    exit 1
}

# Load the sealed implementation through its read-only plan action.
set -- plan
# shellcheck disable=SC1090
source "$SEALED_ADOPTION"

publish_wallet_send_audit()
{
    local path baseline audit
    path=$(wallet_send_audit_path) || return 1
    baseline="$TARGET_WAVE/node-27-wallet-txids.prelaunch.json"
    if [[ -e "$path" || -L "$path" ]]; then
        verify_wallet_send_audit
        return
    fi
    protected_root_file "$baseline" || return 1
    [[ "$(container_generation_for "$TARGET_NODE")" == "$READOPTION_GENERATION" ]] || return 1
    audit=$(wallet_rpc_for "$TARGET_NODE" listtransactions '*' 1000000 0 true |
        jq -cnS --slurpfile transactions /dev/stdin --slurpfile baseline "$baseline" '
        def authorized_pow_claim:
          .comment == "PoW Claim" and .qq_shadow_pow_authored == "1" and
          (.qq_shadow_pow_created_height | type) == "string" and
          (.qq_shadow_pow_created_height | test("^[0-9]+$")) and
          (.qq_shadow_pow_created_tip | type) == "string" and
          (.qq_shadow_pow_created_tip | test("^[0-9a-f]{64}$")) and
          (.fee | type) == "number" and .fee <= 0 and
          (.amount | type) == "number" and .amount == 0 and .abandoned == false;
        ($transactions[0] |
          if type == "array" and all(.[];
            (.txid | type) == "string" and (.txid | test("^[0-9a-f]{64}$")) and
            (.category | type) == "string") then .
          else error("invalid listtransactions result") end) as $txs |
        ($baseline[0] | unique | sort) as $before |
        [$txs[] |
          select(.category == "send") |
          .txid as $txid |
          select(($before | index($txid)) == null) |
          {txid,comment:(.comment // null),
           qq_shadow_pow_authored:(.qq_shadow_pow_authored // null),
           qq_shadow_pow_created_height:(.qq_shadow_pow_created_height // null),
           qq_shadow_pow_created_tip:(.qq_shadow_pow_created_tip // null),
           fee:(.fee // null),amount:(.amount // null),
           abandoned:(.abandoned // null)}] |
        sort_by([.txid,(.amount | tostring),(.fee | tostring),(.comment | tostring)]) as $new |
        [$new[] | select(authorized_pow_claim) | .txid] |
        unique | sort as $authorized |
        {observed:$new,authorized:$authorized,
         unexpected:[$new[] | select((authorized_pow_claim) | not)]}
    ') || return 1
    jq -e '.unexpected == []' >/dev/null <<< "$audit" || return 1
    jq -n --arg generation "$READOPTION_GENERATION" \
        --arg baseline_sha "$(sha256sum "$baseline" | awk '{print $1}')" \
        --arg run "$TARGET_RUN" --arg wave "$TARGET_WAVE" \
        --argjson observed "$(jq -c '.observed' <<< "$audit")" \
        --argjson authorized "$(jq -c '.authorized' <<< "$audit")" \
        --arg created_at "$(date -u +%FT%TZ)" '
        {schema:1,transaction:"v30.1.4-fleet-rollout",
         state:"readoption-wallet-send-audited",node:27,
         run_dir:$run,wave_dir:$wave,
         container_generation:$generation,prelaunch_wallet_txids_sha256:$baseline_sha,
         observed_new_send_transactions:$observed,
         authorized_protocol_pow_claim_txids:$authorized,
         unexpected_send_transactions:[],managed_recovery_payment_created:false,
         created_at:$created_at}' | atomic_write_json_exclusive "$path" || return 1
    verify_wallet_send_audit
}

adoption_apply
