# BEGIN V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR
ROLLOUT_MAINTENANCE_MARKER="$STATE_DIR/V30_1_4_ROLLOUT_MAINTENANCE.json"
rollout_maintenance_marker_valid() {
    local marker="$ROLLOUT_MAINTENANCE_MARKER" transaction run_dir nonce run_state
    [[ -f "$marker" && ! -L "$marker" &&
       "$(realpath -e -- "$marker" 2>/dev/null || true)" == "$marker" &&
       "$(stat -c '%u:%g:%a' "$marker" 2>/dev/null || true)" == 0:0:600 ]] || return 1
    transaction=$(jq -er '.transaction | select(type == "string")' "$marker" 2>/dev/null) || return 1
    run_dir=$(jq -er '.run_dir | select(type == "string")' "$marker" 2>/dev/null) || return 1
    case "$transaction" in
        v30.1.4-fleet-rollout)
            [[ "$run_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/v30[.]1[.]4-fleet-rollout/rollout-[0-9]{8}T[0-9]{6}Z$ ]] ||
                return 1
            ;;
        v30.1.4-node27-canary)
            [[ "$run_dir" =~ ^/mnt/pulsar/Blackcoin_Blocks/operations/releases/v30[.]1[.]4-[0-9a-f]{40}/node27-canary-[0-9]{8}T[0-9]{6}Z$ ]] ||
                return 1
            ;;
        *)
            return 1
            ;;
    esac
    [[ -d "$run_dir" && ! -L "$run_dir" &&
       "$(realpath -e -- "$run_dir" 2>/dev/null || true)" == "$run_dir" &&
       "$(stat -c '%u:%g:%a' "$run_dir" 2>/dev/null || true)" == 0:0:700 ]] || return 1
    [[ -f "$run_dir/MAINTENANCE-NONCE" && ! -L "$run_dir/MAINTENANCE-NONCE" &&
       "$(realpath -e -- "$run_dir/MAINTENANCE-NONCE" 2>/dev/null || true)" == "$run_dir/MAINTENANCE-NONCE" &&
       "$(stat -c '%u:%g:%a' "$run_dir/MAINTENANCE-NONCE" 2>/dev/null || true)" == 0:0:600 ]] || return 1
    nonce=$(cat -- "$run_dir/MAINTENANCE-NONCE" 2>/dev/null) || return 1
    [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -f "$run_dir/STATE" && ! -L "$run_dir/STATE" &&
       "$(realpath -e -- "$run_dir/STATE" 2>/dev/null || true)" == "$run_dir/STATE" &&
       "$(stat -c '%u:%g:%a' "$run_dir/STATE" 2>/dev/null || true)" == 0:0:600 ]] || return 1
    run_state=$(cat -- "$run_dir/STATE" 2>/dev/null) || return 1
    case "$transaction" in
        v30.1.4-fleet-rollout)
            [[ "$run_state" == prepared || "$run_state" == applying ||
               "$run_state" == complete || "$run_state" == rolled-back ]] || return 1
            ;;
        v30.1.4-node27-canary)
            [[ "$run_state" == active ]] || return 1
            ;;
    esac
    jq -e --arg transaction "$transaction" --arg nonce "$nonce" --arg run "$run_dir" '
        . == {schema:1,transaction:$transaction,state:"active",
              run_nonce:$nonce,run_dir:$run}
    ' "$marker" >/dev/null 2>&1
}
if [[ -e "$ROLLOUT_MAINTENANCE_MARKER" || -L "$ROLLOUT_MAINTENANCE_MARKER" ]]; then
    if rollout_maintenance_marker_valid; then
        logger -t blackcoin-rollout-maintenance 'v30.1.4 rollout maintenance active; supervisor mutation inhibited' || true
        exit 0
    fi
    logger -t blackcoin-rollout-maintenance 'invalid v30.1.4 rollout maintenance marker; supervisor mutation refused' || true
    exit 1
fi
# END V30.1.4 DURABLE ROLLOUT MAINTENANCE INHIBITOR
